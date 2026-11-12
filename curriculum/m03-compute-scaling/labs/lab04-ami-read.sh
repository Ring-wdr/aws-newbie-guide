#!/usr/bin/env bash
# M03 lab04 — AMI 읽기 (🔴 AMI 생성·등록·복사는 501 → 기존 AMI를 "읽는" 실습으로 대체)
# 소유자·이름·아키텍처로 AMI 고르기 → 가장 최신 것 찾기 → 루트 스냅샷·부팅 모드·IMDS 지원·공개 여부 읽기
# → SSM 공개 파라미터와 비교 → CreateImage / RegisterImage / CopyImage 가 501 인 것 확인
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab04"
m03_terminate_tagged "$LAB"
m03_network

echo "== 1. Amazon 소유, 이름이 al2023-ami-2023.*-x86_64 인 AMI를 만든 날짜순으로 (최신 3개)"
aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-kernel-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-3:].[ImageId,Name,CreationDate]' --output text
NEWEST="$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-kernel-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"

echo "== 2. 같은 답을 SSM 공개 파라미터로 (실무에서 권장하는 방법)"
FROM_SSM="$(m03_ami)"
echo "describe-images 최신: $NEWEST / SSM 파라미터: $FROM_SSM"

echo "== 3. AMI 한 개를 자세히 읽기"
aws ec2 describe-images --image-ids "$NEWEST" --query 'Images[0].{
  Name:Name, Owner:OwnerId, Public:Public, Arch:Architecture, Virtualization:VirtualizationType,
  RootDeviceType:RootDeviceType, RootDevice:RootDeviceName, BootMode:BootMode, ImdsSupport:ImdsSupport,
  Platform:PlatformDetails, RootSnapshot:BlockDeviceMappings[0].Ebs.SnapshotId,
  RootSizeGiB:BlockDeviceMappings[0].Ebs.VolumeSize, RootType:BlockDeviceMappings[0].Ebs.VolumeType,
  RootEncrypted:BlockDeviceMappings[0].Ebs.Encrypted}'
aws ec2 describe-image-attribute --image-id "$NEWEST" --attribute launchPermission \
  --query 'LaunchPermissions' --output json

echo "== 4. 루트 디바이스 유형별 AMI 수: EBS 기반 vs 인스턴스 스토어 기반"
aws ec2 describe-images --owners amazon --query 'Images[].RootDeviceType' --output text | tr '\t' '\n' | sort | uniq -c

echo "== 5. 아키텍처별 (x86_64 vs arm64 = Graviton)"
aws ec2 describe-images --owners amazon --query 'Images[].Architecture' --output text | tr '\t' '\n' | sort | uniq -c

echo "== 6. 내 계정이 만든 AMI (owners=self)"
mine="$(aws ec2 describe-images --owners self --query 'length(Images)' --output text)"
echo "내 AMI 수: $mine"

echo "== 7. 인스턴스에서 AMI 만들기(CreateImage) — 에뮬레이터 미구현"
IID="$(aws ec2 run-instances --image-id "$NEWEST" --instance-type t3.micro --subnet-id "$M03_SUBNET_A" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[0].InstanceId' --output text)"
wait_for instance running "$IID" >/dev/null
expect_error NotImplemented aws ec2 create-image --instance-id "$IID" --name todayorder-api-v1 --no-reboot

echo "== 8. 스냅샷으로 AMI 등록(RegisterImage) — 에뮬레이터 미구현"
ROOT_SNAP="$(aws ec2 describe-images --image-ids "$NEWEST" --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)"
expect_error NotImplemented aws ec2 register-image --name todayorder-api-v1 --architecture x86_64 \
  --root-device-name /dev/xvda --virtualization-type hvm \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$ROOT_SNAP}"

echo "== 9. 다른 리전으로 AMI 복사(CopyImage) — 에뮬레이터 미구현"
expect_error NotImplemented aws ec2 copy-image --source-image-id "$NEWEST" --source-region us-east-1 --name todayorder-api-v1-copy

m03_terminate_tagged "$LAB"

# ---- 단언
[ "$NEWEST" = "$FROM_SSM" ] || fail "describe-images 최신($NEWEST)과 SSM 파라미터($FROM_SSM)가 다름"
[ "$mine" = "0" ] || fail "owners=self AMI 가 0이 아님 ($mine) — CreateImage 가 구현됐을 수 있다 (FIDELITY 갱신)"
echo "LAB04 OK"
