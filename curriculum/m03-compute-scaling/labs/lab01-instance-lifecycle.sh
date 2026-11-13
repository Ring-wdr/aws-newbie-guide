#!/usr/bin/env bash
# M03 lab01 — EC2 인스턴스 시작과 상태 전이 (🟢 상태 전이 / 부팅·사용자 데이터 실행은 없음)
# AMI 찾기 → 인스턴스 유형 비교 → 키 페어 → 사용자 데이터 + IMDSv2 로 시작
# → pending→running→stopping→stopped→running→shutting-down→terminated 관찰
# → 에뮬레이터 미구현(DescribeInstanceStatus, ModifyInstanceAttribute) 확인
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab01"
KEY="todayorder-m03-key"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 이전 실행의 흔적 정리 (멱등)
m03_terminate_tagged "$LAB"
m03_network

state() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].State.Name' --output text; }
# 상태가 바뀔 때마다 기록하면서 목표 상태까지 기다린다 (최대 60초)
watch_state() {
  local iid="$1" goal="$2" seen="" s i
  for ((i = 0; i < 60; i++)); do
    s="$(state "$iid")"
    case " $seen " in *" $s "*) ;; *) seen="${seen:+$seen → }$s" ;; esac
    [ "$s" = "$goal" ] && { echo "$seen"; return 0; }
    sleep 0.5
  done
  echo "TIMEOUT: $goal 에 도달하지 못함 (관찰: $seen)" >&2
  return 1
}

echo "== 1. AMI 찾기: SSM 공개 파라미터로 최신 Amazon Linux 2023"
AMI="$(m03_ami)"
aws ec2 describe-images --image-ids "$AMI" \
  --query 'Images[0].{ImageId:ImageId,Name:Name,Arch:Architecture,RootDevice:RootDeviceType,RootSnapshot:BlockDeviceMappings[0].Ebs.SnapshotId,RootSizeGiB:BlockDeviceMappings[0].Ebs.VolumeSize}'

echo "== 2. 인스턴스 유형 비교 (vCPU, 메모리 MiB, 아키텍처, 버스트 가능, 프리 티어)"
aws ec2 describe-instance-types --instance-types t3.micro m7i.large m7g.large c7i.large r7i.large \
  --query 'sort_by(InstanceTypes,&InstanceType)[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,ProcessorInfo.SupportedArchitectures[0],BurstablePerformanceSupported,FreeTierEligible]' \
  --output table

echo "== 3. 키 페어 만들기 (개인 키는 만들 때 한 번만 받을 수 있다)"
# 에뮬레이터는 DeleteKeyPair 가 미구현(501)이라 키 페어를 지울 수 없다. 두 번째 실행부터는
# 같은 이름으로 다시 만들면 InvalidKeyPair.Duplicate 가 나므로 기존 키 페어를 그대로 쓴다.
if aws ec2 describe-key-pairs --key-names "$KEY" >/dev/null 2>&1; then
  echo "(이미 있는 키 페어 재사용 — 개인 키는 처음 만들 때만 받을 수 있다)"
  expect_error InvalidKeyPair.Duplicate aws ec2 create-key-pair --key-name "$KEY"
else
  aws ec2 create-key-pair --key-name "$KEY" --query KeyMaterial --output text >"$WORK/key.pem"
  chmod 600 "$WORK/key.pem"
  head -1 "$WORK/key.pem"
fi
aws ec2 describe-key-pairs --key-names "$KEY" --query 'KeyPairs[0].[KeyName,KeyFingerprint]' --output text

echo "== 4. 사용자 데이터 + IMDSv2 필수로 인스턴스 시작"
cat >"$WORK/user-data.sh" <<'EOF'
#!/bin/bash
dnf install -y nginx
echo "TodayOrder API" > /usr/share/nginx/html/index.html
systemctl enable --now nginx
EOF
IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$M03_SUBNET_A" --key-name "$KEY" \
  --user-data "file://$WORK/user-data.sh" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=todayorder-api-1},{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[0].InstanceId' --output text)"
echo "시작한 인스턴스: $IID"
running_path="$(watch_state "$IID" running)"
echo "상태 전이: $running_path"
aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].{Type:InstanceType,AZ:Placement.AvailabilityZone,PrivateIp:PrivateIpAddress,Key:KeyName,IMDS:MetadataOptions.HttpTokens,HopLimit:MetadataOptions.HttpPutResponseHopLimit,RootVolume:BlockDeviceMappings[0].Ebs.VolumeId}'

echo "== 5. 사용자 데이터는 저장되어 있다 (base64 → 디코드). 하지만 에뮬레이터는 이것을 실행하지 않는다"
aws ec2 describe-instance-attribute --instance-id "$IID" --attribute userData \
  --query UserData.Value --output text | base64 -d >"$WORK/stored.sh"
cat "$WORK/stored.sh"

echo "== 6. 인스턴스 상태 확인(DescribeInstanceStatus) — 에뮬레이터 미구현"
expect_error NotImplemented aws ec2 describe-instance-status --instance-ids "$IID"

echo "== 7. 중지 (EBS 기반 인스턴스는 중지할 수 있다)"
aws ec2 stop-instances --instance-ids "$IID" \
  --query 'StoppingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
stop_path="$(watch_state "$IID" stopped)"
echo "상태 전이: $stop_path"

echo "== 8. 중지 상태에서 인스턴스 유형 변경(ModifyInstanceAttribute) — 에뮬레이터 미구현"
expect_error NotImplemented aws ec2 modify-instance-attribute --instance-id "$IID" --instance-type Value=t3.small

echo "== 9. 다시 시작 → running 까지 기다리기"
aws ec2 start-instances --instance-ids "$IID" \
  --query 'StartingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
# 레슨의 `aws ec2 wait instance-running` 과 같은 조건(running, 도중에 terminated 등이 보이면 실패)을 15초 대신 1초 간격으로 확인한다
wait_for instance running "$IID" && echo "waiter: running (lab 은 1초 간격 확인)"

echo "== 10. 종료 (되돌릴 수 없다)"
aws ec2 terminate-instances --instance-ids "$IID" \
  --query 'TerminatingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
term_path="$(watch_state "$IID" terminated)"
echo "상태 전이: $term_path"

echo "== 11. 키 페어 삭제(DeleteKeyPair) — 에뮬레이터 미구현이라 남겨 둔다"
expect_error NotImplemented aws ec2 delete-key-pair --key-name "$KEY"

# ---- 단언
case "$running_path" in *running) ;; *) fail "running 에 도달하지 않음 ($running_path)" ;; esac
case "$stop_path" in *stopped) ;; *) fail "stopped 에 도달하지 않음 ($stop_path)" ;; esac
case "$term_path" in *terminated) ;; *) fail "terminated 에 도달하지 않음 ($term_path)" ;; esac
cmp -s "$WORK/user-data.sh" "$WORK/stored.sh" || fail "저장된 사용자 데이터가 원본과 다름"
echo "LAB01 OK"
