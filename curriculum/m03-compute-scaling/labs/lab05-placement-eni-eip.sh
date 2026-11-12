#!/usr/bin/env bash
# M03 lab05 — 배치 그룹, ENI, 탄력적 IP, 최대 절전 (🟡)
# 배치 그룹 3종 만들기 → ENI 를 다른 인스턴스로 옮기기(고정 프라이빗 IP) → EIP 를 다른 인스턴스로 옮기기(고정 공인 IP)
# → 최대 절전(hibernation) 설정과 stop --hibernate
# 구성은 저장되지만 물리 배치·네트워크 트래픽·메모리 저장은 일어나지 않는다. 일부 AWS 검증도 빠져 있다(레슨 4 참고).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab05"
TAGS="ResourceType=instance,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]"
PGS="todayorder-pg-cluster todayorder-pg-spread todayorder-pg-partition"

cleanup() {
  local a e
  for a in $(aws ec2 describe-addresses --filters Name=tag:Lab,Values="$LAB" --query 'Addresses[].AllocationId' --output text); do
    for e in $(aws ec2 describe-addresses --allocation-ids "$a" --query 'Addresses[].AssociationId' --output text); do
      [ "$e" = "None" ] || aws ec2 disassociate-address --association-id "$e" >/dev/null 2>&1 || true
    done
    aws ec2 release-address --allocation-id "$a" >/dev/null 2>&1 || true
  done
  for e in $(aws ec2 describe-network-interfaces --filters Name=tag:Lab,Values="$LAB" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
    a="$(aws ec2 describe-network-interfaces --network-interface-ids "$e" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)"
    if [ -n "$a" ] && [ "$a" != "None" ]; then
      aws ec2 detach-network-interface --attachment-id "$a" --force >/dev/null 2>&1 || true
      poll 30 "ENI available" eni_available "$e" || true
    fi
    aws ec2 delete-network-interface --network-interface-id "$e" >/dev/null 2>&1 || true
  done
  m03_terminate_tagged "$LAB"
  for a in $PGS; do aws ec2 delete-placement-group --group-name "$a" >/dev/null 2>&1 || true; done
}
eni_available() { [ "$(aws ec2 describe-network-interfaces --network-interface-ids "$1" --query 'NetworkInterfaces[0].Status' --output text)" = available ]; }
cleanup
m03_network
AMI="$(m03_ami)"

echo "== 1. 배치 그룹 3종"
aws ec2 create-placement-group --group-name todayorder-pg-cluster --strategy cluster >/dev/null
aws ec2 create-placement-group --group-name todayorder-pg-spread --strategy spread --spread-level rack >/dev/null
aws ec2 create-placement-group --group-name todayorder-pg-partition --strategy partition --partition-count 3 >/dev/null
# shellcheck disable=SC2086
aws ec2 describe-placement-groups --group-names $PGS \
  --query 'PlacementGroups[].[GroupName,Strategy,State,PartitionCount,SpreadLevel]' --output table
echo "-- 파티션은 AZ당 최대 7개"
expect_error InvalidParameterValue aws ec2 create-placement-group --group-name todayorder-pg-too-many --strategy partition --partition-count 8

echo "== 2. 클러스터 배치 그룹에 같은 유형 2대를 한 번에 시작"
read -r C1 C2 < <(aws ec2 run-instances --image-id "$AMI" --instance-type c7i.large --count 2 \
  --subnet-id "$M03_SUBNET_A" --placement GroupName=todayorder-pg-cluster --tag-specifications "$TAGS" \
  --query 'Instances[].InstanceId' --output text)
aws ec2 describe-instances --instance-ids "$C1" "$C2" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.GroupName,Placement.AvailabilityZone]' --output text
pg_name="$(aws ec2 describe-instances --instance-ids "$C1" --query 'Reservations[0].Instances[0].Placement.GroupName' --output text)"

echo "== 3. ENI(보조 네트워크 인터페이스): 고정 프라이빗 IP 10.30.1.50 을 만들어 api-a 에 붙인다"
SG="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$M03_VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text)"
ENI="$(aws ec2 create-network-interface --subnet-id "$M03_SUBNET_A" --groups "$SG" --private-ip-address 10.30.1.50 \
  --description "todayorder floating ENI" \
  --tag-specifications "ResourceType=network-interface,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query NetworkInterface.NetworkInterfaceId --output text)"
aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --query 'NetworkInterfaces[0].[NetworkInterfaceId,Status,PrivateIpAddress,MacAddress]' --output text
read -r A B < <(aws ec2 run-instances --image-id "$AMI" --instance-type m7i.large --count 2 \
  --subnet-id "$M03_SUBNET_A" --tag-specifications "$TAGS" --query 'Instances[].InstanceId' --output text)
wait_for instance running "$A" "$B" >/dev/null
ATT="$(aws ec2 attach-network-interface --network-interface-id "$ENI" --instance-id "$A" --device-index 1 \
  --query AttachmentId --output text)"
aws ec2 describe-instances --instance-ids "$A" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[].[Attachment.DeviceIndex,NetworkInterfaceId,PrivateIpAddress]' --output text

echo "-- api-a 가 고장났다고 치고, ENI 를 떼어 api-b 에 붙인다 (IP·MAC 이 그대로 따라간다)"
aws ec2 detach-network-interface --attachment-id "$ATT"
poll 30 "ENI available" eni_available "$ENI"
aws ec2 attach-network-interface --network-interface-id "$ENI" --instance-id "$B" --device-index 1 --query AttachmentId --output text >/dev/null
aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --query 'NetworkInterfaces[0].[Status,Attachment.InstanceId,PrivateIpAddress,MacAddress]' --output text
eni_owner="$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)"

echo "== 4. 탄력적 IP(EIP): 고정 공인 IP 를 api-a → api-b 로 옮기기"
read -r ALLOC EIP < <(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query '[AllocationId,PublicIp]' --output text)
echo "할당: $ALLOC $EIP"
aws ec2 associate-address --allocation-id "$ALLOC" --instance-id "$A" --query AssociationId --output text >/dev/null
aws ec2 describe-instances --instance-ids "$A" --query 'Reservations[0].Instances[0].[PublicIpAddress,PublicDnsName]' --output text
aws ec2 associate-address --allocation-id "$ALLOC" --instance-id "$B" --allow-reassociation --query AssociationId --output text >/dev/null
aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].[PublicIp,InstanceId]' --output text
eip_owner="$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].InstanceId' --output text)"
echo "api-a 의 공인 IP: $(aws ec2 describe-instances --instance-ids "$A" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "== 5. 최대 절전(hibernation): 시작할 때 켜 둔 인스턴스만 가능"
HIB="$(aws ec2 run-instances --image-id "$AMI" --instance-type m7i.large --subnet-id "$M03_SUBNET_A" \
  --hibernation-options Configured=true \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={Encrypted=true,VolumeSize=20,VolumeType=gp3}' \
  --tag-specifications "$TAGS" --query 'Instances[0].InstanceId' --output text)"
wait_for instance running "$HIB" >/dev/null
aws ec2 describe-instances --instance-ids "$HIB" --query 'Reservations[0].Instances[0].HibernationOptions'
aws ec2 stop-instances --instance-ids "$HIB" --hibernate --query 'StoppingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
wait_for instance stopped "$HIB" >/dev/null
aws ec2 describe-instances --instance-ids "$HIB" --query 'Reservations[0].Instances[0].[State.Name,StateReason.Code]' --output text
hib_state="$(aws ec2 describe-instances --instance-ids "$HIB" --query 'Reservations[0].Instances[0].State.Name' --output text)"
echo "-- 최대 절전을 켜지 않은 인스턴스에 --hibernate → 거부"
expect_error UnsupportedHibernationConfiguration aws ec2 stop-instances --instance-ids "$A" --hibernate
echo "-- (에뮬레이터 차이) 루트 볼륨 설정(암호화·20GiB)이 반영되지 않았다"
aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$HIB" --query 'Volumes[].[Size,Encrypted]' --output text

echo "== 6. 정리"
cleanup
echo "정리 완료"

# ---- 단언
[ "$pg_name" = "todayorder-pg-cluster" ] || fail "배치 그룹이 인스턴스에 반영되지 않음 ($pg_name)"
[ "$eni_owner" = "$B" ] || fail "ENI 가 api-b 로 옮겨지지 않음 ($eni_owner)"
[ "$eip_owner" = "$B" ] || fail "EIP 가 api-b 로 옮겨지지 않음 ($eip_owner)"
[ "$hib_state" = "stopped" ] || fail "최대 절전 후 상태가 stopped 가 아님 ($hib_state)"
echo "LAB05 OK"
