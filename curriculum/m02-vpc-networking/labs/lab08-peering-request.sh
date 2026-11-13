#!/usr/bin/env bash
# M02 lab08 — VPC 피어링: 요청(pending-acceptance)까지 🟡 / 수락·라우팅은 🔴(501)
#   주문 VPC(10.0.0.0/16) → 분석 VPC(10.30.0.0/16)  : 요청 성공, 수락 대기
#   주문 VPC(10.0.0.0/16) → 레거시 VPC(10.0.0.0/16) : CIDR이 겹쳐 failed
# 에뮬레이터 1.0.322 는 피어링 수락·거절·삭제가 모두 501 이라, 이 lab 은 "있으면 다시 쓰고, 없으면 만든다".
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"

ensure_vpc() { # ensure_vpc <이름> <cidr> → VPC ID
  local id
  id="$(vpc_id "$1")"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-vpc --cidr-block "$2" --tag-specifications "$(tags vpc "$1")" --query Vpc.VpcId --output text)"
    wait_ec2_vpc_available "$id"
  fi
  echo "$id"
}
# 두 VPC 사이의 (삭제되지 않은) 피어링 연결을 찾는다
find_pcx() {
  aws ec2 describe-vpc-peering-connections \
    --filters "Name=requester-vpc-info.vpc-id,Values=$1" "Name=accepter-vpc-info.vpc-id,Values=$2" \
    --query 'VpcPeeringConnections[?Status.Code!=`deleted` && Status.Code!=`rejected` && Status.Code!=`expired`].VpcPeeringConnectionId | [0]' \
    --output text | sed 's/^None$//'
}
pcx_status() { aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$1" --query 'VpcPeeringConnections[0].Status.Code' --output text; }

echo "== 1. 상대 VPC 2개: 분석 VPC(10.30.0.0/16), 레거시 VPC(10.0.0.0/16 — 주문 VPC와 겹침)"
AVPC="$(ensure_vpc todayorder-analytics-vpc 10.30.0.0/16)"
LVPC="$(ensure_vpc todayorder-legacy-vpc 10.0.0.0/16)"
echo "   analytics=$AVPC legacy=$LVPC"

echo "== 2. 피어링 요청: 주문 → 분석"
PCX="$(find_pcx "$VPC" "$AVPC")"
if [ -z "$PCX" ]; then
  aws ec2 create-vpc-peering-connection --vpc-id "$VPC" --peer-vpc-id "$AVPC" \
    --tag-specifications "$(tags vpc-peering-connection todayorder-order-to-analytics)" \
    --query 'VpcPeeringConnection.{Id: VpcPeeringConnectionId, Status: Status.Code, Requester: RequesterVpcInfo.CidrBlock, Accepter: AccepterVpcInfo.VpcId}' \
    --output table
  PCX="$(find_pcx "$VPC" "$AVPC")"
else
  echo "   (이전 실행의 요청 $PCX 를 다시 씁니다)"
fi
poll_until pending-acceptance 120 pcx_status "$PCX"
aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX" \
  --query 'VpcPeeringConnections[0].{Id: VpcPeeringConnectionId, Status: Status, Expires: ExpirationTime}' --output json

echo "== 3. 수락 (실제 AWS에서는 상대 VPC 소유자가 accept-vpc-peering-connection 을 호출한다)"
e_accept="$(expect_error aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX")"
echo "$e_accept"
echo "   → 수락이 안 되므로 상태는 계속 $(pcx_status "$PCX"). 수락 뒤의 일(양쪽 라우팅 테이블에 경로 추가)은 레슨 6의 다이어그램으로."

echo "== 4. CIDR이 겹치는 VPC끼리 피어링: 주문(10.0.0.0/16) → 레거시(10.0.0.0/16)"
OVL="$(aws ec2 describe-vpc-peering-connections \
  --filters "Name=requester-vpc-info.vpc-id,Values=$VPC" "Name=accepter-vpc-info.vpc-id,Values=$LVPC" \
  --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text | sed 's/^None$//')"
if [ -z "$OVL" ]; then
  OVL="$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC" --peer-vpc-id "$LVPC" \
    --tag-specifications "$(tags vpc-peering-connection todayorder-order-to-legacy)" \
    --query VpcPeeringConnection.VpcPeeringConnectionId --output text)"
fi
poll_until failed 120 pcx_status "$OVL"
aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$OVL" --query 'VpcPeeringConnections[0].Status' --output json

# ---- 단언
assert_eq "주문→분석 피어링 상태" pending-acceptance "$(pcx_status "$PCX")"
assert_eq "겹치는 CIDR 피어링 상태" failed "$(pcx_status "$OVL")"
case "$e_accept" in
  *NotImplemented*) echo "  ✔ 수락은 에뮬레이터 미구현(501) — FIDELITY.md 와 같다" ;;
  *) die "피어링 수락이 501이 아님 (구현되었을 수 있다 → 등급·문서 갱신 필요): $e_accept" ;;
esac
echo "LAB08 OK"
