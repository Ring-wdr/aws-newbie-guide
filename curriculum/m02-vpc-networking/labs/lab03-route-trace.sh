#!/usr/bin/env bash
# M02 lab03 — 경로 추적 워크시트: 라우팅 테이블을 읽고 패킷이 어디로 가는지 맞히기 (🟢)
# 에뮬레이터에서는 패킷이 실제로 흐르지 않는다. 대신 실제 AWS의 VPC 라우터가 하는 일
# (서브넷 → 적용되는 라우팅 테이블 → 최장 접두사 일치 → 다음 홉)을 describe-* 출력으로 똑같이 해 본다.
#
# 학습자: 각 문항의 "문제"를 보고 먼저 답을 적은 뒤, 아래 출력의 "정답"과 비교한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"

name_of() { # 리소스 ID → Name 태그 (없으면 ID 그대로)
  local n
  case "$1" in
    nat-*) n="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$1" --query 'NatGateways[0].Tags[?Key==`Name`].Value|[0]' --output text)" ;;
    igw-*) n="$(aws ec2 describe-internet-gateways --internet-gateway-ids "$1" --query 'InternetGateways[0].Tags[?Key==`Name`].Value|[0]' --output text)" ;;
    rtb-*) n="$(aws ec2 describe-route-tables --route-table-ids "$1" --query 'RouteTables[0].Tags[?Key==`Name`].Value|[0]' --output text)" ;;
    *) n="$1" ;;
  esac
  [ "$n" = "None" ] && n="$1"
  echo "$n"
}

# 서브넷에서 출발한 패킷을 홉 단위로 따라간다. NAT 게이트웨이를 만나면 NAT가 있는 서브넷의
# 라우팅 테이블에서 다시 찾는다 (NAT도 "그 서브넷 안의 ENI"이기 때문).
trace() {
  local subnet_name="$1" dst="$2" subnet rtb hop path guard=0
  subnet="$(subnet_id "$subnet_name")"
  path="$subnet_name"
  while [ $guard -lt 5 ]; do
    guard=$((guard + 1))
    rtb="$(effective_rtb "$subnet")"
    hop="$(next_hop "$rtb" "$dst")"
    path="$path —[$(name_of "$rtb")]→ "
    case "$hop" in
      local) path="${path}local(VPC 안에서 바로 전달)"; break ;;
      igw-*) path="${path}$(name_of "$hop") → 인터넷"; break ;;
      nat-*)
        path="${path}$(name_of "$hop")"
        subnet="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$hop" --query 'NatGateways[0].SubnetId' --output text)"
        ;;
      *) path="${path}${hop}"; break ;;
    esac
  done
  echo "$path"
}

echo "== 0. 재료: 서브넷별로 '실제로 적용되는' 라우팅 테이블과 그 경로"
echo "   (명시적으로 연결된 테이블이 없으면 VPC의 기본(main) 라우팅 테이블이 적용된다)"
for line in "${M02_SUBNETS[@]}"; do
  read -r name cidr _ _ <<<"$line"
  rtb="$(effective_rtb "$(subnet_id "$name")")"
  routes="$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[].join('->', [DestinationCidrBlock || DestinationPrefixListId, GatewayId || NatGatewayId || TransitGatewayId || VpcPeeringConnectionId])" --output text | tr '\t' ' ')"
  printf '   %-20s %-13s %-21s %s\n' "$name" "$cidr" "$(name_of "$rtb")" "$routes"
done

echo
echo "== 문제 1. 6개 서브넷 중 '퍼블릭 서브넷'은? (정의: 적용되는 라우팅 테이블에 0.0.0.0/0 → igw-* 경로가 있다)"
public_list=""
for line in "${M02_SUBNETS[@]}"; do
  read -r name _ _ _ <<<"$line"
  hop="$(next_hop "$(effective_rtb "$(subnet_id "$name")")" 0.0.0.0)"
  if [[ "$hop" == igw-* ]]; then public_list="$public_list $name"; fi
done
echo "   정답:$public_list"

echo "== 문제 2. 인터넷 사용자(203.0.113.7)에게 ALB(public-a)가 응답을 돌려보낼 때의 경로는?"
a2="$(trace todayorder-public-a 203.0.113.7)"; echo "   정답: $a2"

echo "== 문제 3. 주문 API(app-a, 10.0.10.25)가 DB(db-b, 10.0.21.10)에 접속할 때의 경로는?"
a3="$(trace todayorder-app-a 10.0.21.10)"; echo "   정답: $a3"

echo "== 문제 4. 주문 API(app-b)가 외부 결제 대행사 API(203.0.113.50)를 호출할 때의 경로는?"
a4="$(trace todayorder-app-b 203.0.113.50)"; echo "   정답: $a4"

echo "== 문제 5. DB(db-a)가 OS 패치를 받으려고 인터넷(203.0.113.80)에 나가려 하면?"
a5="$(trace todayorder-db-a 203.0.113.80)"; echo "   정답: $a5"

echo "== 문제 6. 10.0.0.0/16 과 0.0.0.0/0 이 둘 다 10.0.21.10 에 일치한다. 왜 local 이 이기는가?"
echo "   정답: 최장 접두사 일치 — /16 이 /0 보다 구체적(접두사가 길다)이므로 local 경로가 선택된다."

echo "== 문제 7. 연결이 없는 새 서브넷을 만들면 어느 라우팅 테이블을 쓰나? (실제로 만들어 확인)"
tmp_sn="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.99.0/28 --availability-zone us-east-1a \
  --tag-specifications "$(tags subnet todayorder-trace-tmp)" --query Subnet.SubnetId --output text)"
main_rt="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)"
a7="$(effective_rtb "$tmp_sn")"
echo "   정답: 기본(main) 라우팅 테이블 $a7 — 경로: $(next_hop "$a7" 8.8.8.8) (인터넷 경로가 없으니 '프라이빗'으로 시작한다)"
aws ec2 delete-subnet --subnet-id "$tmp_sn"

# ---- 단언
assert_eq "퍼블릭 서브넷" " todayorder-public-a todayorder-public-b" "$public_list"
case "$a2" in *"todayorder-igw → 인터넷") ;; *) die "문제 2: $a2" ;; esac
case "$a3" in *"local(VPC 안에서 바로 전달)") ;; *) die "문제 3: $a3" ;; esac
case "$a4" in "todayorder-app-b —[todayorder-app-rt-b]→ todayorder-nat-b —[todayorder-public-rt]→ todayorder-igw → 인터넷") ;; *) die "문제 4: $a4" ;; esac
case "$a5" in *"DROP(경로 없음)") ;; *) die "문제 5: $a5" ;; esac
assert_eq "새 서브넷에 적용되는 테이블 = main" "$main_rt" "$a7"
echo "LAB03 OK"
