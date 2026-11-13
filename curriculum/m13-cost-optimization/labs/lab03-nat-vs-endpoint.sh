#!/usr/bin/env bash
# M13 lab03 — NAT 게이트웨이 vs S3 게이트웨이 엔드포인트: 경로를 바꾸고 비용을 비교한다 (🟢 경로 구성 / 비용은 워크시트)
#
# 2-AZ 프라이빗 서브넷이 AZ 별 NAT 게이트웨이로 나가는 구성에 S3 게이트웨이 엔드포인트를 붙인다.
# 라우팅 테이블에 "S3 접두사 목록(pl-…) → vpce-…" 경로가 생기는 것을 확인하고, 같은 트래픽의 월 비용을 계산한다.
# 트래픽은 실제로 흐르지 않는다. 경로 선택 규칙(가장 구체적인 경로 우선)은 실제 AWS와 같다.
# ⚠️ 단가는 예시 숫자다. 실제 가격은 AWS Pricing Calculator 로.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
P="todayorder-m13-net"

teardown() {
  local vpc id
  for vpc in $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P" --query 'Vpcs[].VpcId' --output text); do
    for id in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
      aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$id" >/dev/null
    done
    for id in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text); do
      aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null
    done
    for _ in $(seq 120); do
      [ -z "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text)" ] && break
      sleep 1
    done
    for id in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
      aws ec2 delete-internet-gateway --internet-gateway-id "$id"
    done
    for id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$id"
    done
    for id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
      aws ec2 delete-route-table --route-table-id "$id"
    done
    aws ec2 delete-vpc --vpc-id "$vpc"
  done
  for id in $(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$P-nat" --query 'Addresses[].AllocationId' --output text); do
    aws ec2 release-address --allocation-id "$id"
  done
}
teardown

echo "== 1. 2-AZ VPC: AZ 별 NAT 게이트웨이(고가용성 NAT)"
VPC="$(aws ec2 create-vpc --cidr-block 10.32.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$P}]" --query Vpc.VpcId --output text)"
IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
PRIV_RTS=()
i=0
for az in us-east-1a us-east-1b; do
  pub="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.32.$i.0/24" --availability-zone "$az" --query Subnet.SubnetId --output text)"
  priv="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.32.$((i + 10)).0/24" --availability-zone "$az" --query Subnet.SubnetId --output text)"
  eip="$(aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$P-nat}]" --query AllocationId --output text)"
  nat="$(aws ec2 create-nat-gateway --subnet-id "$pub" --allocation-id "$eip" --query NatGateway.NatGatewayId --output text)"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat"
  rt="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat" >/dev/null
  aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$priv" >/dev/null
  PRIV_RTS+=("$rt")
  i=$((i + 1))
done
echo "프라이빗 라우팅 테이블 (엔드포인트 전):"
aws ec2 describe-route-tables --route-table-ids "${PRIV_RTS[0]}" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock||DestinationPrefixListId,Target:NatGatewayId||GatewayId}' --output table

echo "== 2. S3 게이트웨이 엔드포인트를 두 프라이빗 라우팅 테이블에 연결"
VPCE="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" --vpc-endpoint-type Gateway --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids "${PRIV_RTS[@]}" --query VpcEndpoint.VpcEndpointId --output text)"
echo "$VPCE"
PL="$(aws ec2 describe-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.us-east-1.s3 --query 'PrefixLists[0].PrefixListId' --output text)"
echo "S3 접두사 목록: $PL"
echo "프라이빗 라우팅 테이블 (엔드포인트 후):"
aws ec2 describe-route-tables --route-table-ids "${PRIV_RTS[0]}" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock||DestinationPrefixListId,Target:NatGatewayId||GatewayId}' --output table

echo "== 3. 월 비용 비교 (예시 단가: NAT 시간당 0.05 + NAT의 퍼블릭 IPv4 시간당 0.005, NAT 처리 GB당 0.05, 인터페이스 엔드포인트 AZ·시간당 0.01 + GB당 0.01)"
NAT_COUNT=2; S3_GB=3000; OTHER_GB=200
costs="$(awk -v n="$NAT_COUNT" -v s3="$S3_GB" -v o="$OTHER_GB" 'BEGIN {
  # NAT 마다 퍼블릭 IPv4 주소(EIP) 하나 — 실제 AWS 는 NAT 요금과 별도로 청구한다(레슨 2, lab01 과 같은 방식)
  h = 730; nat_h = 0.05; ip_h = 0.005; nat_gb = 0.05; ie_h = 0.01; ie_gb = 0.01
  nat_fixed = n*h*(nat_h + ip_h)
  before = nat_fixed + (s3+o)*nat_gb
  gw     = nat_fixed + o*nat_gb
  iface  = nat_fixed + o*nat_gb + n*h*ie_h + s3*ie_gb
  printf "A. 전부 NAT 경유            %8.2f\n", before
  printf "B. S3 게이트웨이 엔드포인트  %8.2f\n", gw
  printf "C. S3 인터페이스 엔드포인트  %8.2f\n", iface
  printf "COSTS %.2f %.2f %.2f\n", before, gw, iface
}')"
echo "$costs"

# ---- 단언
for rt in "${PRIV_RTS[@]}"; do
  got="$(aws ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Routes[?DestinationPrefixListId=='$PL'].GatewayId" --output text)"
  [ "$got" = "$VPCE" ] || { echo "FAIL: $rt 에 S3 접두사 목록 경로가 없음 ($got)"; exit 1; }
  nat_route="$(aws ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" --output text)"
  case "$nat_route" in nat-*) ;; *) echo "FAIL: 기본 경로(NAT)가 사라짐"; exit 1 ;; esac
done
grep -q '^COSTS 240.30 90.30 134.90$' <<<"$costs" || { echo "FAIL: 비용 계산이 워크시트와 다름"; exit 1; }
echo "LAB03 OK"
