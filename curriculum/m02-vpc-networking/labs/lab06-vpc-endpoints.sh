#!/usr/bin/env bash
# M02 lab06 — VPC 엔드포인트: S3 게이트웨이 엔드포인트(라우팅 테이블에 prefix list 경로) +
#             SQS 인터페이스 엔드포인트(서브넷에 ENI, 보안 그룹, 사설 DNS) (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"
APP_RT_A="$(rtb_id todayorder-app-rt-a)"
APP_RT_B="$(rtb_id todayorder-app-rt-b)"
DB_RT="$(rtb_id todayorder-db-rt)"

# 이전 실행의 엔드포인트·SG 정리
ids="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=todayorder-s3-gw,todayorder-sqs-if" \
  --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text)"
if [ -n "$ids" ]; then
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ids >/dev/null
  poll_until "0" 180 bash -c "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC Name=tag:Name,Values=todayorder-s3-gw,todayorder-sqs-if --query 'length(VpcEndpoints[?State!=\`deleted\`])' --output text"
fi
old_sg="$(sg_id "$VPC" todayorder-endpoint-sg)"
[ -n "$old_sg" ] && aws ec2 delete-security-group --group-id "$old_sg" >/dev/null

echo "== 0. 엔드포인트가 없을 때: app-a 에서 S3(의 공인 IP)로 가는 길은 NAT 게이트웨이"
S3_PL="$(aws ec2 describe-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.us-east-1.s3 --query 'PrefixLists[0].PrefixListId' --output text)"
S3_CIDR="$(aws ec2 describe-prefix-lists --prefix-list-ids "$S3_PL" --query 'PrefixLists[0].Cidrs[0]' --output text)"
S3_IP="$(echo "$S3_CIDR" | awk -F'[./]' '{print $1"."$2"."$3"."($4+10)}')"
echo "   S3 접두사 목록 $S3_PL = $S3_CIDR  (예로 쓸 S3 주소: $S3_IP)"
before="$(next_hop "$APP_RT_A" "$S3_IP")"
echo "   app-rt-a 에서 $S3_IP 의 다음 홉: $before"

echo "== 1. 어떤 서비스가 '게이트웨이' 엔드포인트를 지원하나?"
aws ec2 describe-vpc-endpoint-services \
  --service-names com.amazonaws.us-east-1.s3 com.amazonaws.us-east-1.dynamodb com.amazonaws.us-east-1.sqs \
  --query 'ServiceDetails[].[ServiceName, join(`,`, ServiceType[].ServiceType)]' --output table

echo "== 2. S3 게이트웨이 엔드포인트를 앱 라우팅 테이블 2개에 연결"
GW="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" --vpc-endpoint-type Gateway --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids "$APP_RT_A" "$APP_RT_B" --tag-specifications "$(tags vpc-endpoint todayorder-s3-gw)" \
  --query VpcEndpoint.VpcEndpointId --output text)"
poll_until available 120 aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$GW" --query 'VpcEndpoints[0].State' --output text
echo "   $GW"
aws ec2 describe-route-tables --route-table-ids "$APP_RT_A" --query 'RouteTables[0].Routes' --output json

echo "== 3. 다시 추적: 같은 S3 주소로 가는 다음 홉"
after="$(next_hop "$APP_RT_A" "$S3_IP")"
other="$(next_hop "$APP_RT_A" 203.0.113.50)"
db_s3="$(next_hop "$DB_RT" "$S3_IP")"
echo "   app-rt-a → $S3_IP : $after   (prefix list 경로가 0.0.0.0/0 보다 구체적)"
echo "   app-rt-a → 203.0.113.50 : $other   (S3가 아닌 곳은 여전히 NAT)"
echo "   db-rt    → $S3_IP : $db_s3   (엔드포인트를 연결하지 않은 라우팅 테이블에는 경로가 안 생긴다)"

echo "== 4. SQS는 게이트웨이 엔드포인트가 없다 (S3·DynamoDB 둘뿐)"
e_gw="$(expect_error aws ec2 create-vpc-endpoint --vpc-id "$VPC" --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.us-east-1.sqs --route-table-ids "$APP_RT_A")"
echo "$e_gw"

echo "== 5. SQS 인터페이스 엔드포인트: 앱 서브넷마다 ENI 하나, 보안 그룹은 VPC 안에서 오는 443만 허용"
routes_before_if="$(aws ec2 describe-route-tables --route-table-ids "$APP_RT_A" --query 'length(RouteTables[0].Routes)' --output text)"
EP_SG="$(aws ec2 create-security-group --vpc-id "$VPC" --group-name todayorder-endpoint-sg \
  --description "Interface endpoints - 443 from VPC" --tag-specifications "$(tags security-group todayorder-endpoint-sg)" \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$EP_SG" --protocol tcp --port 443 --cidr "$M02_VPC_CIDR" >/dev/null
IF="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" --vpc-endpoint-type Interface --service-name com.amazonaws.us-east-1.sqs \
  --subnet-ids "$(subnet_id todayorder-app-a)" "$(subnet_id todayorder-app-b)" --security-group-ids "$EP_SG" \
  --private-dns-enabled --tag-specifications "$(tags vpc-endpoint todayorder-sqs-if)" \
  --query VpcEndpoint.VpcEndpointId --output text)"
poll_until available 120 aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$IF" --query 'VpcEndpoints[0].State' --output text
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$IF" \
  --query 'VpcEndpoints[0].{Type: VpcEndpointType, State: State, PrivateDns: PrivateDnsEnabled, ENIs: NetworkInterfaceIds, DnsNames: DnsEntries[].DnsName}' \
  --output json
echo "   ENI 가 놓인 서브넷과 사설 IP:"
n_eni="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$IF" --query 'length(VpcEndpoints[0].NetworkInterfaceIds)' --output text)"
eni_subnets="$(for e in $(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$IF" --query 'VpcEndpoints[0].NetworkInterfaceIds' --output text); do
  aws ec2 describe-network-interfaces --network-interface-ids "$e" --query 'NetworkInterfaces[0].[SubnetId,PrivateIpAddress]' --output text; done)"
echo "$eni_subnets" | sed 's/^/   /'

echo "== 6. 라우팅 테이블은? 인터페이스 엔드포인트는 경로를 추가하지 않는다 (DNS가 ENI의 사설 IP를 돌려준다)"
n_routes="$(aws ec2 describe-route-tables --route-table-ids "$APP_RT_A" --query 'length(RouteTables[0].Routes)' --output text)"
n_vpce="$(aws ec2 describe-route-tables --route-table-ids "$APP_RT_A" --query "length(RouteTables[0].Routes[?starts_with(GatewayId || '', 'vpce-')])" --output text)"
echo "   app-rt-a 경로 수: 인터페이스 엔드포인트 생성 전 $routes_before_if → 후 $n_routes (변화 없음)"
echo "   그중 vpce-* 를 가리키는 경로: $n_vpce 개 (S3 게이트웨이 엔드포인트의 prefix list 경로 하나뿐)"

# ---- 단언
case "$before" in nat-*) ;; *) die "엔드포인트 전 다음 홉이 NAT가 아님: $before" ;; esac
assert_eq "엔드포인트 후 S3 다음 홉" "$GW" "$after"
case "$other" in nat-*) ;; *) die "S3 외 목적지가 NAT가 아님: $other" ;; esac
assert_eq "db-rt 의 S3 경로" "DROP(경로 없음)" "$db_s3"
case "$e_gw" in *InvalidServiceName*) ;; *) die "SQS 게이트웨이 엔드포인트가 거부되지 않음: $e_gw" ;; esac
assert_eq "인터페이스 엔드포인트 ENI 수(서브넷 2개)" 2 "$n_eni"
assert_eq "인터페이스 엔드포인트 생성 전후 app-rt-a 경로 수" "$routes_before_if" "$n_routes"
assert_eq "app-rt-a 에서 vpce-* 를 가리키는 경로 수" 1 "$n_vpce"
echo "LAB06 OK"
