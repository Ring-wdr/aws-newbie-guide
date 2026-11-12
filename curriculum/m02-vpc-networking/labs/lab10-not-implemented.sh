#!/usr/bin/env bash
# M02 lab10 — 에뮬레이터로는 볼 수 없는 네트워크 기능 확인 (🔴 관찰) + Direct Connect 위치 읽기 (🟢)
# 실제 AWS에서 쓰는 명령을 그대로 보내 보고 501 NotImplemented 를 확인한다. 개념은 레슨 3·6·7 의 다이어그램으로 배운다.
# 단언은 "501 이 그대로인지"를 본다 — 통과하지 못하면 에뮬레이터가 기능을 구현한 것이니 등급·문서를 갱신할 때다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

NAME="todayorder-501-lab"
cleanup() {
  local id
  for id in $(aws ec2 describe-vpn-gateways --filters "Name=tag:Name,Values=todayorder-501-vgw" --query 'VpnGateways[?State!=`deleted`].VpnGatewayId' --output text); do
    for v in $(aws ec2 describe-vpn-gateways --vpn-gateway-ids "$id" --query 'VpnGateways[0].VpcAttachments[?State==`attached`].VpcId' --output text); do
      aws ec2 detach-vpn-gateway --vpn-gateway-id "$id" --vpc-id "$v" >/dev/null || true
    done
    aws ec2 delete-vpn-gateway --vpn-gateway-id "$id" >/dev/null 2>&1 || true
  done
  for id in $(aws ec2 describe-customer-gateways --filters "Name=tag:Name,Values=todayorder-501-cgw" --query 'CustomerGateways[?State!=`deleted`].CustomerGatewayId' --output text); do
    aws ec2 delete-customer-gateway --customer-gateway-id "$id" >/dev/null 2>&1 || true
  done
  for id in $(aws ec2 describe-transit-gateways --filters "Name=tag:Name,Values=todayorder-501-tgw" "Name=state,Values=pending,available" --query 'TransitGateways[].TransitGatewayId' --output text); do
    for r in $(aws ec2 describe-transit-gateway-route-tables --filters "Name=transit-gateway-id,Values=$id" --query 'TransitGatewayRouteTables[?State!=`deleted`].TransitGatewayRouteTableId' --output text); do
      aws ec2 delete-transit-gateway-route-table --transit-gateway-route-table-id "$r" >/dev/null || true
    done
    aws ec2 delete-transit-gateway --transit-gateway-id "$id" >/dev/null || true
  done
  teardown_vpc "$NAME"
}
cleanup

VPC="$(aws ec2 create-vpc --cidr-block 10.98.0.0/16 --tag-specifications "$(tags vpc "$NAME")" --query Vpc.VpcId --output text)"
aws ec2 wait vpc-available --vpc-ids "$VPC"
RT="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null

results=()
check() { # check <레슨> <설명> <명령...>
  local lesson="$1" what="$2" out
  shift 2
  out="$(expect_error "$@")"
  echo "== [$lesson] $what"
  echo "$out" | sed 's/^/   /'
  case "$out" in *NotImplemented*) results+=("501") ;; *) results+=("NOT-501:$what") ;; esac
}

check "레슨 3" "Egress-only 인터넷 게이트웨이 (IPv6 전용 아웃바운드)" \
  aws ec2 create-egress-only-internet-gateway --vpc-id "$VPC"
check "레슨 3" "리전 NAT 게이트웨이 (--availability-mode regional)" \
  aws ec2 create-nat-gateway --vpc-id "$VPC" --availability-mode regional
check "레슨 2" "경로 교체 (replace-route: 0.0.0.0/0 의 다음 홉 바꾸기)" \
  aws ec2 replace-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"

CGW="$(aws ec2 create-customer-gateway --type ipsec.1 --public-ip 203.0.113.10 --bgp-asn 65010 \
  --tag-specifications "$(tags customer-gateway todayorder-501-cgw)" --query CustomerGateway.CustomerGatewayId --output text)"
VGW="$(aws ec2 create-vpn-gateway --type ipsec.1 --tag-specifications "$(tags vpn-gateway todayorder-501-vgw)" --query VpnGateway.VpnGatewayId --output text)"
aws ec2 attach-vpn-gateway --vpn-gateway-id "$VGW" --vpc-id "$VPC" >/dev/null
echo "== [레슨 6] 고객 게이트웨이 $CGW, 가상 프라이빗 게이트웨이 $VGW 는 만들어진다 (VGW는 VPC에 연결까지)"
check "레슨 6" "Site-to-Site VPN 연결 (CGW ↔ VGW)" \
  aws ec2 create-vpn-connection --type ipsec.1 --customer-gateway-id "$CGW" --vpn-gateway-id "$VGW"
check "레슨 6" "VGW 경로 전파 (온프레미스 경로를 VPC 라우팅 테이블에 자동 추가)" \
  aws ec2 enable-vgw-route-propagation --route-table-id "$RT" --gateway-id "$VGW"
check "레슨 6" "Client VPN 엔드포인트" \
  aws ec2 create-client-vpn-endpoint --client-cidr-block 172.16.0.0/22 \
  --server-certificate-arn arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000 \
  --authentication-options 'Type=certificate-authentication,MutualAuthentication={ClientRootCertificateChainArn=arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000}' \
  --connection-log-options Enabled=false

TGW="$(aws ec2 create-transit-gateway --tag-specifications "$(tags transit-gateway todayorder-501-tgw)" \
  --options DefaultRouteTableAssociation=disable,DefaultRouteTablePropagation=disable --query TransitGateway.TransitGatewayId --output text)"
poll_until available 300 aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW" --query 'TransitGateways[0].State' --output text
TRT="$(aws ec2 create-transit-gateway-route-table --transit-gateway-id "$TGW" --query TransitGatewayRouteTable.TransitGatewayRouteTableId --output text)"
poll_until available 300 aws ec2 describe-transit-gateway-route-tables --transit-gateway-route-table-ids "$TRT" --query 'TransitGatewayRouteTables[0].State' --output text
check "레슨 6" "TGW 정적 경로 (create-transit-gateway-route)" \
  aws ec2 create-transit-gateway-route --transit-gateway-route-table-id "$TRT" --destination-cidr-block 0.0.0.0/0 --blackhole
check "레슨 6" "TGW 경로 검색 (search-transit-gateway-routes)" \
  aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$TRT" --filters Name=state,Values=active
check "레슨 7" "Session Manager 세션 시작 (ssm start-session)" \
  aws ssm start-session --target i-0123456789abcdef0

echo "== [레슨 6] 대신 읽을 수 있는 것: Direct Connect 위치와 포트 속도 (🟢)"
aws directconnect describe-locations --query 'locations[0:3].[locationCode, join(`,`, availablePortSpeeds)]' --output table
n_loc="$(aws directconnect describe-locations --query 'length(locations)' --output text)"

cleanup

# ---- 단언
n501=0
for r in "${results[@]}"; do [ "$r" = 501 ] && n501=$((n501 + 1)) || echo "  ! $r"; done
assert_eq "501 을 돌려준 오퍼레이션 수" "${#results[@]}" "$n501"
[ "$n_loc" -gt 0 ] || die "Direct Connect 위치가 비어 있음"
echo "  ✔ Direct Connect 위치 수: $n_loc"
[ -z "$(vpc_id "$NAME")" ] || die "실습용 VPC가 남아 있음"
echo "LAB10 OK"
