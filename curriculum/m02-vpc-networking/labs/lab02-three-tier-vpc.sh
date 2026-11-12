#!/usr/bin/env bash
# M02 lab02 — 2-AZ 3-티어 VPC 구축 (🟢)
# VPC 1 · 서브넷 6 · IGW 1 · NAT GW 2(AZ별) · 라우팅 테이블 4(퍼블릭 1, 앱 2, DB 1)
# 설계값은 README.md 의 "CIDR 계획"과 labs/_lib.sh 의 M02_SUBNETS 에 있다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

# 이전 실행이 남긴 VPC(와 다른 lab 이 붙인 SG·엔드포인트·TGW 연결 등)를 지우고 처음부터 만든다 (멱등).
teardown_vpc "$M02_VPC_NAME"

build_three_tier

VPC="$(vpc_id "$M02_VPC_NAME")"

echo "== 결과 1. 서브넷 (이름·CIDR·AZ·사용 가능 IP·퍼블릭 IP 자동 할당)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'sort_by(Subnets, &CidrBlock)[].[Tags[?Key==`Name`].Value|[0], CidrBlock, AvailabilityZone, AvailableIpAddressCount, MapPublicIpOnLaunch]' \
  --output table

echo "== 결과 2. 라우팅 테이블별 경로와 연결된 서브넷"
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
  --query "RouteTables[].{Name: Tags[?Key=='Name'].Value|[0], Main: Associations[0].Main, Routes: Routes[].join(' -> ', [DestinationCidrBlock || DestinationPrefixListId, GatewayId || NatGatewayId || TransitGatewayId]), Subnets: length(Associations[?SubnetId])}" \
  --output json

echo "== 결과 3. NAT 게이트웨이 (어느 서브넷·AZ에, 어떤 공인 IP로)"
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" \
  --query 'NatGateways[].[Tags[?Key==`Name`].Value|[0], State, SubnetId, NatGatewayAddresses[0].AvailabilityZone, NatGatewayAddresses[0].PublicIp]' \
  --output table

# ---- 단언
n_sub="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'length(Subnets)' --output text)"
assert_eq "서브넷 수" 6 "$n_sub"
assert_eq "/24 서브넷의 사용 가능 IP (256 - 예약 5)" 251 \
  "$(aws ec2 describe-subnets --subnet-ids "$(subnet_id todayorder-db-a)" --query 'Subnets[0].AvailableIpAddressCount' --output text)"
assert_eq "NAT 게이트웨이 available 수" 2 \
  "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available" --query 'length(NatGateways)' --output text)"
assert_eq "public-a 의 기본 경로" "$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[0].InternetGatewayId' --output text)" \
  "$(next_hop "$(effective_rtb "$(subnet_id todayorder-public-a)")" 8.8.8.8)"
nat_a="$(aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=todayorder-nat-a" "Name=state,Values=available" --query 'NatGateways[0].NatGatewayId' --output text)"
assert_eq "app-a 의 기본 경로 = 같은 AZ의 NAT(nat-a)" "$nat_a" "$(next_hop "$(effective_rtb "$(subnet_id todayorder-app-a)")" 8.8.8.8)"
assert_eq "db-a 에서 인터넷으로" "DROP(경로 없음)" "$(next_hop "$(effective_rtb "$(subnet_id todayorder-db-a)")" 8.8.8.8)"
echo "LAB02 OK"
