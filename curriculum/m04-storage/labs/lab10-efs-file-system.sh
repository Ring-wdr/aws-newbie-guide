#!/usr/bin/env bash
# M04 lab10 — EFS 파일 시스템·마운트 타깃·액세스 포인트 (🟡 구성까지. 실제 마운트(NFS)는 불가)
# 1) VPC + 서브넷 2개(AZ a, b) + NFS(2049) 보안 그룹 → 2) 파일 시스템(암호화, Elastic 처리량)
# 3) AZ마다 마운트 타깃 1개 (같은 AZ 두 번째는 MountTargetConflict) → 4) 액세스 포인트, 수명 주기(IA/Archive), 백업, TLS 강제 정책
# 5) 마운트 타깃이 있으면 삭제 불가(FileSystemInUse) → 정리
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

TOKEN="todayorder-m04-shared-uploads"
TAG="todayorder-m04-efs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# poll <설명> <최대 초> <명령...> : 명령이 성공할 때까지 2초 간격으로
poll() {
  local what="$1" limit="$2"
  shift 2
  local deadline=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then echo "FAIL: ${limit}초 안에 '$what' 이(가) 되지 않음"; return 1; fi
    sleep 2
  done
}

cleanup() {
  local fs
  fs="$(aws efs describe-file-systems --output json | jq -r --arg t "$TOKEN" '.FileSystems[] | select(.CreationToken == $t) | .FileSystemId')"
  if [ -n "$fs" ]; then
    for ap in $(aws efs describe-access-points --file-system-id "$fs" --output json | jq -r '.AccessPoints[].AccessPointId'); do
      aws efs delete-access-point --access-point-id "$ap"
    done
    for mt in $(aws efs describe-mount-targets --file-system-id "$fs" --output json | jq -r '.MountTargets[].MountTargetId'); do
      aws efs delete-mount-target --mount-target-id "$mt"
    done
    poll "마운트 타깃 삭제" 120 bash -c "[ \"\$(aws efs describe-mount-targets --file-system-id $fs --output json | jq '.MountTargets | length')\" = 0 ]" || {
      echo "마지막 상태: $(aws efs describe-mount-targets --file-system-id "$fs" --output json | jq -c '[.MountTargets[] | {MountTargetId, LifeCycleState}]')"; exit 1; }
    aws efs delete-file-system --file-system-id "$fs"
  fi
  for vpc in $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$TAG" --query 'Vpcs[].VpcId' --output text); do
    local sgs
    sgs="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --output json | jq -c '[.SecurityGroups[] | select(.GroupName != "default")]')"
    # 다른 보안 그룹을 참조하는 규칙부터 걷어 내야 삭제할 수 있다 (DependencyViolation)
    jq -c '.[] | select(.IpPermissions | length > 0) | {GroupId, IpPermissions}' <<<"$sgs" | while read -r g; do
      aws ec2 revoke-security-group-ingress --group-id "$(jq -r .GroupId <<<"$g")" \
        --ip-permissions "$(jq -c '.IpPermissions | map(del(.Ipv6Ranges, .PrefixListIds) | .UserIdGroupPairs |= map({GroupId}))' <<<"$g")" >/dev/null
    done
    for sg in $(jq -r '.[].GroupId' <<<"$sgs"); do
      aws ec2 delete-security-group --group-id "$sg" >/dev/null
    done
    for sn in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$sn"
    done
    aws ec2 delete-vpc --vpc-id "$vpc"
  done
}
cleanup

echo "== 1. 네트워크: VPC 10.40.0.0/16, 프라이빗 서브넷 2개(us-east-1a, 1b), NFS 보안 그룹"
VPC="$(aws ec2 create-vpc --cidr-block 10.40.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$TAG}]" --query Vpc.VpcId --output text)"
# CreateVpc 응답은 pending 이다. 서브넷을 만들기 전에 available 을 기다린다.
aws ec2 wait vpc-available --vpc-ids "$VPC"
SN_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.40.1.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text)"
SN_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.40.2.0/24 --availability-zone us-east-1b --query Subnet.SubnetId --output text)"
APP_SG="$(aws ec2 create-security-group --group-name todayorder-m04-app --description 'app servers' --vpc-id "$VPC" --query GroupId --output text)"
EFS_SG="$(aws ec2 create-security-group --group-name todayorder-m04-efs --description 'EFS mount targets' --vpc-id "$VPC" --query GroupId --output text)"
# 앱 서버 보안 그룹에서 오는 NFS(TCP 2049)만 허용
aws ec2 authorize-security-group-ingress --group-id "$EFS_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$APP_SG}]" >/dev/null
echo "VPC=$VPC  subnets=$SN_A,$SN_B  efs-sg=$EFS_SG"

echo "== 2. 파일 시스템 생성 (리전형=여러 AZ, 암호화, General Purpose, Elastic 처리량)"
FS="$(aws efs create-file-system --creation-token "$TOKEN" --performance-mode generalPurpose \
  --throughput-mode elastic --encrypted --tags "Key=Name,Value=$TAG" \
  --query FileSystemId --output text)"
aws efs describe-file-systems --file-system-id "$FS" \
  --query 'FileSystems[0].{Id: FileSystemId, State: LifeCycleState, Perf: PerformanceMode, Throughput: ThroughputMode, Encrypted: Encrypted}' --output json
poll "파일 시스템 available" 120 bash -c "[ \"\$(aws efs describe-file-systems --file-system-id $FS --query 'FileSystems[0].LifeCycleState' --output text)\" = available ]" || {
  echo "마지막 상태: $(aws efs describe-file-systems --file-system-id "$FS" --query 'FileSystems[0].LifeCycleState' --output text)"; exit 1; }
echo "→ available"

echo "== 3. 같은 CreationToken 으로 또 만들기 → FileSystemAlreadyExists (생성 요청의 멱등성 키)"
set +e
dup="$(aws efs create-file-system --creation-token "$TOKEN" 2>&1 >/dev/null)"
set -e
echo "$dup" | sed '/^$/d'

echo "== 4. AZ마다 마운트 타깃 하나씩"
aws efs create-mount-target --file-system-id "$FS" --subnet-id "$SN_A" --security-groups "$EFS_SG" \
  --query '{Id: MountTargetId, Subnet: SubnetId, State: LifeCycleState}' --output json
aws efs create-mount-target --file-system-id "$FS" --subnet-id "$SN_B" --security-groups "$EFS_SG" \
  --query '{Id: MountTargetId, Subnet: SubnetId, State: LifeCycleState}' --output json
# 마운트 타깃은 creating 으로 시작한다. 다음 단계(충돌 시험·삭제) 전에 available 을 기다린다.
poll "마운트 타깃 2개 available" 120 bash -c "[ \"\$(aws efs describe-mount-targets --file-system-id $FS --output json | jq '[.MountTargets[] | select(.LifeCycleState == \"available\")] | length')\" = 2 ]" || {
  aws efs describe-mount-targets --file-system-id "$FS" --query 'MountTargets[].[MountTargetId, LifeCycleState]' --output text; exit 1; }
echo "→ 마운트 타깃 2개 available"
echo "-- 같은 서브넷(us-east-1a)에 두 번째 마운트 타깃 → MountTargetConflict (AZ당 하나)"
# 주의: 에뮬레이터 1.0.322 는 같은 AZ의 "다른" 서브넷에는 두 번째 마운트 타깃을 만들어 버리고
# (AWS는 MountTargetConflict), 같은 서브넷일 때만 충돌을 낸다. 그래서 같은 서브넷으로 재현한다.
# 마운트 타깃의 AZ 표시도 서브넷의 AZ와 다를 수 있어 AZ는 출력하지 않는다.
set +e
conflict="$(aws efs create-mount-target --file-system-id "$FS" --subnet-id "$SN_A" --security-groups "$EFS_SG" 2>&1 >/dev/null)"
set -e
echo "$conflict" | sed '/^$/d'
mt_count="$(aws efs describe-mount-targets --file-system-id "$FS" --output json | jq '.MountTargets | length')"
mt_subnets="$(aws efs describe-mount-targets --file-system-id "$FS" --output json | jq -c '[.MountTargets[].SubnetId] | sort')"
echo "마운트 타깃 수: $mt_count"

echo "== 5. 액세스 포인트: 앱은 /uploads 를 루트로, UID/GID 1000 으로만 본다"
aws efs create-access-point --file-system-id "$FS" \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory 'Path=/uploads,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=750}' \
  --query '{Id: AccessPointId, Path: RootDirectory.Path, Uid: PosixUser.Uid}' --output json

echo "== 6. 수명 주기: 30일 미접근 → IA, 90일 → Archive, 한 번 읽으면 Standard 로 복귀"
aws efs put-lifecycle-configuration --file-system-id "$FS" --lifecycle-policies \
  TransitionToIA=AFTER_30_DAYS TransitionToArchive=AFTER_90_DAYS TransitionToPrimaryStorageClass=AFTER_1_ACCESS \
  --output json
lc_count="$(aws efs describe-lifecycle-configuration --file-system-id "$FS" --output json | jq '.LifecyclePolicies | length')"

echo "== 7. 자동 백업(AWS Backup) 켜기, TLS 아닌 마운트 거부 정책"
aws efs put-backup-policy --file-system-id "$FS" --backup-policy Status=ENABLED --query BackupPolicy.Status --output text
cat >"$WORK/efs-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"DenyNonTLSClients","Effect":"Deny","Principal":{"AWS":"*"},
 "Action":["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],
 "Resource":"arn:aws:elasticfilesystem:us-east-1:000000000000:file-system/$FS","Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
aws efs put-file-system-policy --file-system-id "$FS" \
  --policy "file://$WORK/efs-policy.json" --query FileSystemId --output text

echo "== 8. 마운트 타깃이 남은 파일 시스템 삭제 → FileSystemInUse"
set +e
inuse="$(aws efs delete-file-system --file-system-id "$FS" 2>&1 >/dev/null)"
set -e
echo "$inuse" | sed '/^$/d'

echo "== 9. 정리 (액세스 포인트 → 마운트 타깃 → 파일 시스템 → 네트워크)"
cleanup
left="$(aws efs describe-file-systems --output json | jq --arg t "$TOKEN" '[.FileSystems[] | select(.CreationToken == $t)] | length')"
echo "남은 파일 시스템: $left"

# ---- 단언
case "$dup" in *FileSystemAlreadyExists*) ;; *) echo "FAIL: 중복 CreationToken ($dup)"; exit 1 ;; esac
case "$conflict" in *MountTargetConflict*) ;; *) echo "FAIL: 같은 AZ 마운트 타깃 ($conflict)"; exit 1 ;; esac
case "$inuse" in *FileSystemInUse*) ;; *) echo "FAIL: FileSystemInUse 아님 ($inuse)"; exit 1 ;; esac
[ "$mt_count" = "2" ] || { echo "FAIL: 마운트 타깃 수 ($mt_count)"; exit 1; }
[ "$mt_subnets" = "$(jq -cn --arg a "$SN_A" --arg b "$SN_B" '[$a, $b] | sort')" ] || { echo "FAIL: 마운트 타깃 서브넷 ($mt_subnets)"; exit 1; }
[ "$lc_count" = "3" ] || { echo "FAIL: 수명 주기 정책 수 ($lc_count)"; exit 1; }
[ "$left" = "0" ] || { echo "FAIL: 파일 시스템이 남음"; exit 1; }
echo "LAB10 OK"
