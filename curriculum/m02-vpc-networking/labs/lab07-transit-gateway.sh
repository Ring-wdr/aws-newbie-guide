#!/usr/bin/env bash
# M02 lab07 — Transit Gateway로 VPC 2개 연결: 주문 VPC(10.0.0.0/16) ↔ 정산 VPC(10.20.0.0/16) (🟢)
# 허브(TGW) 하나에 VPC를 '연결(attachment)'하고, TGW 라우팅 테이블에 연결·전파한 뒤,
# 각 VPC 라우팅 테이블에 "상대 CIDR → tgw-..." 경로를 넣는다. (패킷은 흐르지 않으므로 경로를 읽어 추적한다)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"

# 멱등성: 이 lab 은 "있으면 다시 쓰고, 없으면 만든다". 실제 AWS에서도 그대로 안전하다.
# (에뮬레이터는 TGW VPC 연결 삭제 DeleteTransitGatewayVpcAttachment 가 501 이라, 한 번 연결한 TGW를
#  지울 수 없다. 그래서 지우고 다시 만드는 대신 재사용한다 — README "에뮬레이터 제약" 참고)
first() { sed 's/^None$//' | awk 'NF{print $1; exit}'; }

echo "== 1. 정산 VPC 10.20.0.0/16 (서브넷 2개, 라우팅 테이블 1개) — 주문 VPC와 CIDR이 겹치지 않게 설계"
SVPC="$(vpc_id todayorder-settlement-vpc)"
if [ -z "$SVPC" ] || [ -z "$(rtb_id todayorder-settlement-rt)" ] || [ -z "$(subnet_id todayorder-settlement-a)" ] || [ -z "$(subnet_id todayorder-settlement-b)" ]; then
  teardown_vpc todayorder-settlement-vpc
  SVPC="$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 --tag-specifications "$(tags vpc todayorder-settlement-vpc)" --query Vpc.VpcId --output text)"
  wait_ec2_vpc_available "$SVPC"
  SA="$(aws ec2 create-subnet --vpc-id "$SVPC" --cidr-block 10.20.0.0/24 --availability-zone us-east-1a --tag-specifications "$(tags subnet todayorder-settlement-a)" --query Subnet.SubnetId --output text)"
  SB="$(aws ec2 create-subnet --vpc-id "$SVPC" --cidr-block 10.20.1.0/24 --availability-zone us-east-1b --tag-specifications "$(tags subnet todayorder-settlement-b)" --query Subnet.SubnetId --output text)"
  SRT="$(aws ec2 create-route-table --vpc-id "$SVPC" --tag-specifications "$(tags route-table todayorder-settlement-rt)" --query RouteTable.RouteTableId --output text)"
  for s in "$SA" "$SB"; do aws ec2 associate-route-table --route-table-id "$SRT" --subnet-id "$s" >/dev/null; done
else
  echo "   (이전 실행의 정산 VPC를 다시 씁니다)"
fi
SA="$(subnet_id todayorder-settlement-a)"; SB="$(subnet_id todayorder-settlement-b)"; SRT="$(rtb_id todayorder-settlement-rt)"
echo "   $SVPC  subnets=$SA,$SB  rt=$SRT"

echo "== 2. Transit Gateway (기본 연결·전파는 끄고, 라우팅 테이블을 직접 관리한다)"
TGW="$(aws ec2 describe-transit-gateways --filters Name=tag:Name,Values=todayorder-tgw Name=state,Values=pending,available \
  --query 'TransitGateways[].TransitGatewayId' --output text | first)"
if [ -z "$TGW" ]; then
  TGW="$(aws ec2 create-transit-gateway --description "TodayOrder hub" \
    --options DefaultRouteTableAssociation=disable,DefaultRouteTablePropagation=disable \
    --tag-specifications "$(tags transit-gateway todayorder-tgw)" --query TransitGateway.TransitGatewayId --output text)"
fi
poll_until available 300 aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW" --query 'TransitGateways[0].State' --output text
aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW" \
  --query 'TransitGateways[0].{Id: TransitGatewayId, State: State, Asn: Options.AmazonSideAsn, DefaultAssoc: Options.DefaultRouteTableAssociation, DefaultProp: Options.DefaultRouteTablePropagation}' \
  --output table

echo "== 3. TGW 라우팅 테이블"
TRT="$(aws ec2 describe-transit-gateway-route-tables --filters Name=transit-gateway-id,Values="$TGW" \
  --query "TransitGatewayRouteTables[?State!='deleted' && Tags[?Key=='Name' && Value=='todayorder-tgw-rt']].TransitGatewayRouteTableId" --output text | first)"
if [ -z "$TRT" ]; then
  TRT="$(aws ec2 create-transit-gateway-route-table --transit-gateway-id "$TGW" \
    --tag-specifications "$(tags transit-gateway-route-table todayorder-tgw-rt)" \
    --query TransitGatewayRouteTable.TransitGatewayRouteTableId --output text)"
fi
poll_until available 300 aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids "$TRT" --query 'TransitGatewayRouteTables[0].State' --output text
echo "   $TRT"

echo "== 4. VPC 연결(attachment): AZ마다 서브넷 하나씩 지정 (주문 VPC는 앱 서브넷, 정산 VPC는 자기 서브넷)"
# attach <vpc> <이름> <서브넷...> → 이 TGW에 이 VPC의 연결이 이미 있으면 그 ID, 없으면 새로 만든다
attach() {
  local vpc="$1" name="$2" id
  shift 2
  id="$(aws ec2 describe-transit-gateway-vpc-attachments --filters Name=transit-gateway-id,Values="$TGW" Name=vpc-id,Values="$vpc" \
    --query 'TransitGatewayVpcAttachments[?State==`available` || State==`pending`].TransitGatewayAttachmentId' --output text | first)"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-transit-gateway-vpc-attachment --transit-gateway-id "$TGW" --vpc-id "$vpc" --subnet-ids "$@" \
      --tag-specifications "$(tags transit-gateway-attachment "$name")" \
      --query TransitGatewayVpcAttachment.TransitGatewayAttachmentId --output text)"
  fi
  echo "$id"
}
A_ORDER="$(attach "$VPC" todayorder-tgw-attach-order "$(subnet_id todayorder-app-a)" "$(subnet_id todayorder-app-b)")"
A_SETTLE="$(attach "$SVPC" todayorder-tgw-attach-settlement "$SA" "$SB")"
for a in "$A_ORDER" "$A_SETTLE"; do
  poll_until available 300 aws ec2 describe-transit-gateway-vpc-attachments --transit-gateway-attachment-ids "$a" --query 'TransitGatewayVpcAttachments[0].State' --output text
done
echo "   order=$A_ORDER settlement=$A_SETTLE"

echo "== 5. 연결(association): 이 연결로 들어온 패킷은 이 TGW 라우팅 테이블로 길을 찾는다"
echo "      전파(propagation): 이 연결 뒤의 VPC CIDR을 TGW 라우팅 테이블에 자동으로 넣는다"
assoc_state() { aws ec2 get-transit-gateway-route-table-associations --transit-gateway-route-table-id "$TRT" \
  --query "Associations[?TransitGatewayAttachmentId=='$1'].State | [0]" --output text; }
prop_state() { aws ec2 get-transit-gateway-route-table-propagations --transit-gateway-route-table-id "$TRT" \
  --query "TransitGatewayRouteTablePropagations[?TransitGatewayAttachmentId=='$1'].State | [0]" --output text; }
for a in "$A_ORDER" "$A_SETTLE"; do
  [ "$(assoc_state "$a")" = "None" ] && aws ec2 associate-transit-gateway-route-table --transit-gateway-route-table-id "$TRT" --transit-gateway-attachment-id "$a" >/dev/null
  [ "$(prop_state "$a")" = "None" ] && aws ec2 enable-transit-gateway-route-table-propagation --transit-gateway-route-table-id "$TRT" --transit-gateway-attachment-id "$a" >/dev/null
  poll_until associated 120 assoc_state "$a"
  poll_until enabled 120 prop_state "$a"
done
for a in "$A_ORDER" "$A_SETTLE"; do
  aws ec2 get-transit-gateway-route-table-associations --transit-gateway-route-table-id "$TRT" \
    --query "Associations[?TransitGatewayAttachmentId=='$a'].[TransitGatewayAttachmentId, ResourceId, State]" --output text | sed 's/^/   연결  /'
done
for a in "$A_ORDER" "$A_SETTLE"; do
  aws ec2 get-transit-gateway-route-table-propagations --transit-gateway-route-table-id "$TRT" \
    --query "TransitGatewayRouteTablePropagations[?TransitGatewayAttachmentId=='$a'].[TransitGatewayAttachmentId, ResourceId, State]" --output text | sed 's/^/   전파  /'
done

echo "== 6. 각 VPC 라우팅 테이블에 '상대 CIDR → TGW' 경로 (TGW에 붙였다고 VPC가 저절로 길을 아는 것은 아니다)"
ensure_route() { # 같은 목적지 경로가 이미 이 TGW를 가리키면 그대로 둔다
  local rt="$1" dst="$2" cur
  cur="$(aws ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Routes[?DestinationCidrBlock=='$dst'].TransitGatewayId | [0]" --output text)"
  [ "$cur" = "$TGW" ] && return 0
  [ "$cur" != "None" ] && aws ec2 delete-route --route-table-id "$rt" --destination-cidr-block "$dst" >/dev/null
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block "$dst" --transit-gateway-id "$TGW" >/dev/null
}
for rt in todayorder-app-rt-a todayorder-app-rt-b; do ensure_route "$(rtb_id "$rt")" 10.20.0.0/16; done
ensure_route "$SRT" "$M02_VPC_CIDR"
aws ec2 describe-route-tables --route-table-ids "$(rtb_id todayorder-app-rt-a)" \
  --query "RouteTables[0].Routes[].join(' -> ', [DestinationCidrBlock || DestinationPrefixListId, GatewayId || NatGatewayId || TransitGatewayId])" --output json

echo "== 7. 추적"
t1="$(next_hop "$(effective_rtb "$(subnet_id todayorder-app-a)")" 10.20.0.15)"
t2="$(next_hop "$SRT" 10.0.10.25)"
t3="$(next_hop "$(effective_rtb "$(subnet_id todayorder-db-a)")" 10.20.0.15)"
t4="$(next_hop "$(effective_rtb "$(subnet_id todayorder-app-a)")" 10.0.21.10)"
echo "   app-a → 정산 10.20.0.15     : $t1"
echo "   정산  → app-a 10.0.10.25    : $t2   (돌아오는 길도 경로가 있어야 한다)"
echo "   db-a  → 정산 10.20.0.15     : $t3   (DB 라우팅 테이블에는 넣지 않았다 — 의도된 차단)"
echo "   app-a → db-b 10.0.21.10     : $t4   (VPC 안은 여전히 local 이 우선)"

# ---- 단언
assert_eq "app-a → 정산" "$TGW" "$t1"
assert_eq "정산 → app-a" "$TGW" "$t2"
assert_eq "db-a → 정산" "DROP(경로 없음)" "$t3"
assert_eq "app-a → db-b" local "$t4"
assert_eq "주문·정산 연결의 전파 상태" "enabled enabled" "$(prop_state "$A_ORDER") $(prop_state "$A_SETTLE")"
echo "LAB07 OK"
