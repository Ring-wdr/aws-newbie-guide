#!/usr/bin/env bash
# M03 lab03 — EBS 볼륨과 스냅샷 (🟢 볼륨·스냅샷 / 🔴 스냅샷에서 볼륨 복원)
# 유형별 볼륨 만들기와 검증 오류 → 연결과 AZ 제약 → io2 다중 연결 → gp2→gp3 무중단 변경
# → 스냅샷 → 암호화 사본 → 기본 암호화 → (복원은 에뮬레이터에서 실패)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab03"
VTAG="ResourceType=volume,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]"

vol_available() { [ "$(aws ec2 describe-volumes --volume-ids "$1" --query 'Volumes[0].State' --output text)" = available ]; }
cleanup() {
  local v s i
  # 볼륨을 먼저 떼고(다중 연결이면 연결마다), 그다음 인스턴스를 종료한다.
  # (에뮬레이터는 인스턴스를 종료해도 붙어 있던 볼륨을 in-use 로 남겨 둔다)
  for v in $(aws ec2 describe-volumes --filters Name=tag:Lab,Values="$LAB" --query 'Volumes[].VolumeId' --output text); do
    for i in $(aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].Attachments[].InstanceId' --output text); do
      aws ec2 detach-volume --volume-id "$v" --instance-id "$i" >/dev/null 2>&1 || true
    done
    poll 30 "$v available" vol_available "$v" || true
    aws ec2 delete-volume --volume-id "$v" >/dev/null 2>&1 || true
  done
  m03_terminate_tagged "$LAB"
  for s in $(aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Lab,Values="$LAB" --query 'Snapshots[].SnapshotId' --output text); do
    aws ec2 delete-snapshot --snapshot-id "$s" >/dev/null 2>&1 || true
  done
  aws ec2 disable-ebs-encryption-by-default >/dev/null
}
cleanup
m03_network
AMI="$(m03_ami)"

echo "== 1. 유형별 볼륨 만들기 (us-east-1a)"
mkvol() { aws ec2 create-volume --availability-zone us-east-1a --tag-specifications "$VTAG" "$@" --query VolumeId --output text; }
GP3="$(mkvol --volume-type gp3 --size 20 --iops 3000 --throughput 125)"
GP2="$(mkvol --volume-type gp2 --size 10)"
IO2="$(mkvol --volume-type io2 --size 10 --iops 3000 --multi-attach-enabled)"
ST1="$(mkvol --volume-type st1 --size 125)"
wait_for volume available "$GP3" "$GP2" "$IO2" "$ST1" >/dev/null
aws ec2 describe-volumes --volume-ids "$GP3" "$GP2" "$IO2" "$ST1" \
  --query 'sort_by(Volumes,&VolumeType)[].[VolumeType,Size,Iops,Throughput,MultiAttachEnabled,State]' --output table

echo "== 2. 규칙 위반은 거부된다"
echo "-- HDD(st1·sc1)는 125 GiB 부터"
expect_error InvalidParameterValue aws ec2 create-volume --availability-zone us-east-1a --volume-type sc1 --size 100
echo "-- io2 는 IOPS 를 꼭 정해야 한다"
expect_error MissingParameter aws ec2 create-volume --availability-zone us-east-1a --volume-type io2 --size 10
echo "-- 다중 연결(Multi-Attach)은 io1/io2 만"
expect_error InvalidParameterCombination aws ec2 create-volume --availability-zone us-east-1a --volume-type gp3 --size 10 --multi-attach-enabled

echo "== 3. 인스턴스 2대(us-east-1a)에 연결"
read -r I1 I2 < <(aws ec2 run-instances --image-id "$AMI" --instance-type m7i.large --count 2 \
  --subnet-id "$M03_SUBNET_A" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[].InstanceId' --output text)
wait_for instance running "$I1" "$I2" >/dev/null
aws ec2 attach-volume --volume-id "$GP2" --instance-id "$I1" --device /dev/sdf --query State --output text
wait_for volume in-use "$GP2" >/dev/null
echo "-- 같은 gp2 볼륨을 두 번째 인스턴스에 → 거부 (다중 연결 불가 유형)"
expect_error VolumeInUse aws ec2 attach-volume --volume-id "$GP2" --instance-id "$I2" --device /dev/sdf
echo "-- io2 (MultiAttachEnabled) 는 두 인스턴스에 동시에"
aws ec2 attach-volume --volume-id "$IO2" --instance-id "$I1" --device /dev/sdg --query State --output text
aws ec2 attach-volume --volume-id "$IO2" --instance-id "$I2" --device /dev/sdg --query State --output text
wait_for volume in-use "$IO2" >/dev/null
io2_attach="$(aws ec2 describe-volumes --volume-ids "$IO2" --query 'length(Volumes[0].Attachments)' --output text)"
aws ec2 describe-volumes --volume-ids "$IO2" --query 'Volumes[0].Attachments[].[InstanceId,Device,State]' --output text
echo "-- 다른 AZ(us-east-1b)의 볼륨은 연결할 수 없다"
OTHER="$(aws ec2 create-volume --availability-zone us-east-1b --volume-type gp3 --size 1 --tag-specifications "$VTAG" --query VolumeId --output text)"
wait_for volume available "$OTHER" >/dev/null
expect_error InvalidVolume.ZoneMismatch aws ec2 attach-volume --volume-id "$OTHER" --instance-id "$I1" --device /dev/sdh

echo "== 4. 연결된 채로 gp2 → gp3 변경 + 10 → 20 GiB 확장 (Elastic Volumes)"
aws ec2 modify-volume --volume-id "$GP2" --volume-type gp3 --size 20 \
  --query 'VolumeModification.[ModificationState,OriginalVolumeType,TargetVolumeType,OriginalSize,TargetSize,TargetIops,TargetThroughput]' --output text
mod_done() {
  [ "$(aws ec2 describe-volumes-modifications --volume-ids "$GP2" \
    --query 'VolumesModifications[0].ModificationState' --output text)" = completed ]
}
poll 60 "볼륨 변경 completed" mod_done
aws ec2 describe-volumes --volume-ids "$GP2" --query 'Volumes[0].[VolumeType,Size,Iops,Throughput,State]' --output text
gp2_after="$(aws ec2 describe-volumes --volume-ids "$GP2" --query 'Volumes[0].VolumeType' --output text)"
echo "-- 줄이기는 안 된다"
expect_error InvalidParameterValue aws ec2 modify-volume --volume-id "$GP2" --size 10

echo "== 5. 스냅샷 (증분 백업, S3에 저장되어 리전 안에서 쓸 수 있다)"
SNAP="$(aws ec2 create-snapshot --volume-id "$GP3" --description "todayorder data nightly" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query '[SnapshotId,State]' --output text)"
echo "$SNAP"
SNAP="${SNAP%%[[:space:]]*}"
wait_for snapshot completed "$SNAP" >/dev/null
aws ec2 describe-snapshots --snapshot-ids "$SNAP" --query 'Snapshots[0].[State,Progress,VolumeSize,Encrypted,StorageTier]' --output text

echo "== 6. 암호화된 사본 만들기 (암호화 안 된 스냅샷 → 복사하면서 암호화)"
ENC="$(aws ec2 copy-snapshot --source-snapshot-id "$SNAP" --source-region us-east-1 --encrypted \
  --description "todayorder data encrypted copy" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query SnapshotId --output text)"
wait_for snapshot completed "$ENC" >/dev/null
aws ec2 describe-snapshots --snapshot-ids "$SNAP" "$ENC" --query 'Snapshots[].[SnapshotId,Encrypted,Description]' --output text
enc_flag="$(aws ec2 describe-snapshots --snapshot-ids "$ENC" --query 'Snapshots[0].Encrypted' --output text)"

echo "== 7. 계정·리전 단위 'EBS 기본 암호화' 켜기 → 새 볼륨은 자동 암호화"
aws ec2 enable-ebs-encryption-by-default --output text
NEWV="$(aws ec2 create-volume --availability-zone us-east-1a --volume-type gp3 --size 8 --tag-specifications "$VTAG" --query '[VolumeId,Encrypted]' --output text)"
echo "$NEWV"
newv_enc="${NEWV##*[[:space:]]}"
aws ec2 disable-ebs-encryption-by-default --output text

echo "== 8. 스냅샷에서 볼륨 복원 — 에뮬레이터에서는 실패 (실제 AWS에서는 다른 AZ로 옮기는 정석 방법)"
expect_error InvalidSnapshot.NotFound aws ec2 create-volume --availability-zone us-east-1b --snapshot-id "$SNAP"

echo "== 9. 스냅샷 아카이브 계층 이동(ModifySnapshotTier) — 에뮬레이터 미구현"
expect_error NotImplemented aws ec2 modify-snapshot-tier --snapshot-id "$SNAP" --storage-tier archive

echo "== 10. 정리"
cleanup
left="$(aws ec2 describe-volumes --filters Name=tag:Lab,Values="$LAB" Name=status,Values=available,creating \
  --query 'length(Volumes)' --output text)"
echo "남은 볼륨(available): $left"

# ---- 단언
[ "$io2_attach" = "2" ] || fail "io2 다중 연결 수가 2가 아님 ($io2_attach)"
[ "$gp2_after" = "gp3" ] || fail "gp2→gp3 변경이 반영되지 않음 ($gp2_after)"
[ "$enc_flag" = "True" ] || fail "암호화 사본이 Encrypted=True 가 아님 ($enc_flag)"
[ "$newv_enc" = "True" ] || fail "기본 암호화 후 새 볼륨이 암호화되지 않음 ($newv_enc)"
[ "$left" = "0" ] || fail "정리 후 볼륨이 남음 ($left)"
echo "LAB03 OK"
