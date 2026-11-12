# shellcheck shell=bash
# M02 실습 공용 함수. lab 스크립트가 env.sh 다음에 source 한다. 단독 실행하지 않는다.
#
#   source "$(dirname "$0")/_lib.sh"
#
# 이 파일이 아는 "3-티어 VPC 설계"는 README.md 의 CIDR 계획표와 같다. 바꾸면 둘 다 바꾼다.

# ---- 설계값 (README "CIDR 계획"과 동일) ---------------------------------------------
M02_VPC_NAME="todayorder-vpc"
M02_VPC_CIDR="10.0.0.0/16"
# 이름 CIDR AZ 티어
M02_SUBNETS=(
  "todayorder-public-a 10.0.0.0/24  us-east-1a public"
  "todayorder-public-b 10.0.1.0/24  us-east-1b public"
  "todayorder-app-a    10.0.10.0/24 us-east-1a app"
  "todayorder-app-b    10.0.11.0/24 us-east-1b app"
  "todayorder-db-a     10.0.20.0/24 us-east-1a db"
  "todayorder-db-b     10.0.21.0/24 us-east-1b db"
)

# ---- 작은 도구 ------------------------------------------------------------------------

# 태그 지정 문자열: tags vpc todayorder-vpc
tags() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=todayorder}]' "$1" "$2"; }

die() { echo "FAIL: $*" >&2; exit 1; }

# 값이 기대와 같은지 단언: assert_eq "설명" 기대 실제
assert_eq() {
  if [ "$2" != "$3" ]; then die "$1 — 기대 '$2', 실제 '$3'"; fi
  echo "  ✔ $1: $3"
}

# 명령 출력이 기대값이 될 때까지 폴링한다. 넉넉한 상한(초)을 두고, 실패하면 마지막 관찰값을 출력한다.
#   poll_until <기대값> <상한초> <명령...>
poll_until() {
  local want="$1" limit="$2"
  shift 2
  local got="" start=$SECONDS
  while :; do
    got="$("$@" 2>/dev/null || true)"
    [ "$got" = "$want" ] && return 0
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      echo "FAIL: ${limit}초 안에 '$want' 가 되지 않음. 마지막 관찰값: '${got}'" >&2
      return 1
    fi
    sleep 2
  done
}

# 실패해야 하는 명령을 실행하고 오류 메시지(stderr)를 돌려준다. 성공하면 "UNEXPECTED_SUCCESS".
expect_error() {
  local out
  if out="$("$@" 2>&1 >/dev/null)"; then echo "UNEXPECTED_SUCCESS"; else echo "$out" | sed '/^[[:space:]]*$/d'; fi
}

# Name 태그로 ID 찾기 (없으면 빈 문자열)
vpc_id() { aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$1" --query 'Vpcs[0].VpcId' --output text | sed 's/^None$//'; }
subnet_id() { aws ec2 describe-subnets --filters "Name=tag:Name,Values=$1" --query 'Subnets[0].SubnetId' --output text | sed 's/^None$//'; }
rtb_id() { aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$1" --query 'RouteTables[0].RouteTableId' --output text | sed 's/^None$//'; }
sg_id() { aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$1" "Name=group-name,Values=$2" --query 'SecurityGroups[0].GroupId' --output text | sed 's/^None$//'; }

# ---- IPv4 계산 (레슨 1에서 손으로 하는 계산을 셸로) --------------------------------------
ip2int() {
  local IFS=.
  # shellcheck disable=SC2206
  local o=($1)
  echo $(((o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3]))
}
# in_cidr 10.0.10.25 10.0.10.0/24 → 참/거짓
in_cidr() {
  local ip net bits mask
  ip="$(ip2int "$1")"
  net="$(ip2int "${2%/*}")"
  bits="${2#*/}"
  if [ "$bits" -eq 0 ]; then return 0; fi
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  [ $((ip & mask)) -eq $((net & mask)) ]
}

# 서브넷에 실제로 적용되는 라우팅 테이블: 명시적 연결이 없으면 VPC의 기본(main) 라우팅 테이블
effective_rtb() {
  local subnet="$1" vpc rtb
  rtb="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [ "$rtb" = "None" ] || [ -z "$rtb" ]; then
    vpc="$(aws ec2 describe-subnets --subnet-ids "$subnet" --query 'Subnets[0].VpcId' --output text)"
    rtb="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)"
  fi
  echo "$rtb"
}

# 최장 접두사 일치(longest prefix match)로 다음 홉(target)을 찾는다.
#   next_hop <rtb-id> <목적지 IP>  → "igw-..." / "nat-..." / "local" / "vpce-..." / "tgw-..." / "DROP(경로 없음)"
# 접두사 목록(pl-...) 경로는 describe-prefix-lists 의 CIDR로 펼쳐 비교한다.
next_hop() {
  local rtb="$1" dst="$2" best_len=-1 best="DROP(경로 없음)" dest target len cidr
  while read -r dest target; do
    [ -z "$dest" ] && continue
    if [[ "$dest" == pl-* ]]; then
      for cidr in $(aws ec2 describe-prefix-lists --prefix-list-ids "$dest" --query 'PrefixLists[0].Cidrs[]' --output text); do
        len="${cidr#*/}"
        if in_cidr "$dst" "$cidr" && [ "$len" -gt "$best_len" ]; then best_len="$len"; best="$target"; fi
      done
    else
      len="${dest#*/}"
      if in_cidr "$dst" "$dest" && [ "$len" -gt "$best_len" ]; then best_len="$len"; best="$target"; fi
    fi
  done < <(aws ec2 describe-route-tables --route-table-ids "$rtb" --query \
    'RouteTables[0].Routes[].[DestinationCidrBlock || DestinationPrefixListId, GatewayId || NatGatewayId || TransitGatewayId || VpcPeeringConnectionId || NetworkInterfaceId]' \
    --output text)
  echo "$best"
}

# ---- 3-티어 VPC 만들기/지우기 ---------------------------------------------------------

# VPC 하나를 의존 리소스까지 모두 지운다 (이름으로 찾음). 없으면 아무것도 안 한다.
teardown_vpc() {
  local name="$1" vpc ids id
  vpc="$(vpc_id "$name")"
  [ -z "$vpc" ] && return 0
  echo "  (정리) $name ($vpc) 와 의존 리소스를 지웁니다"

  # Network Firewall
  for id in $(aws network-firewall list-firewalls --vpc-ids "$vpc" --query 'Firewalls[].FirewallName' --output text 2>/dev/null); do
    aws network-firewall delete-firewall --firewall-name "$id" >/dev/null
    poll_until "0" 180 bash -c "aws network-firewall list-firewalls --vpc-ids $vpc --query 'length(Firewalls)' --output text"
  done
  # Flow Logs (VPC 대상)
  ids="$(aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$vpc" --query 'FlowLogs[].FlowLogId' --output text)"
  [ -n "$ids" ] && aws ec2 delete-flow-logs --flow-log-ids $ids >/dev/null
  # VPC 엔드포인트
  ids="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text)"
  if [ -n "$ids" ]; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ids >/dev/null
    poll_until "0" 180 bash -c "aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$vpc --query 'length(VpcEndpoints[?State!=\`deleted\`])' --output text"
  fi
  # Transit Gateway VPC 연결
  ids="$(aws ec2 describe-transit-gateway-vpc-attachments --filters "Name=vpc-id,Values=$vpc" \
    --query 'TransitGatewayVpcAttachments[?State!=`deleted`].TransitGatewayAttachmentId' --output text)"
  # (에뮬레이터 1.0.322: DeleteTransitGatewayVpcAttachment 가 501. 연결은 남겨 두고 넘어간다 —
  #  서브넷·VPC 삭제는 막지 않는다. 실제 AWS에서는 연결이 deleted 가 될 때까지 기다린다)
  local deleted_any=""
  for id in $ids; do
    if aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id "$id" >/dev/null 2>&1; then deleted_any=1; fi
  done
  if [ -n "$deleted_any" ]; then
    poll_until "0" 180 bash -c "aws ec2 describe-transit-gateway-vpc-attachments --filters Name=vpc-id,Values=$vpc Name=state,Values=pending,available,deleting --query 'length(TransitGatewayVpcAttachments)' --output text" || true
  fi
  # NAT 게이트웨이 → 다 지워진 뒤 EIP 반환
  local eips
  eips="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" \
    --query 'NatGateways[?State!=`deleted`].NatGatewayAddresses[].AllocationId' --output text)"
  ids="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)"
  for id in $ids; do aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null; done
  if [ -n "$ids" ]; then
    poll_until "0" 300 bash -c "aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$vpc --query 'length(NatGateways[?State!=\`deleted\`])' --output text"
  fi
  for id in $eips; do aws ec2 release-address --allocation-id "$id" >/dev/null 2>&1 || true; done
  # 인터넷 게이트웨이 / 가상 프라이빗 게이트웨이
  for id in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
    aws ec2 delete-internet-gateway --internet-gateway-id "$id"
  done
  for id in $(aws ec2 describe-vpn-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'VpnGateways[].VpnGatewayId' --output text); do
    aws ec2 detach-vpn-gateway --vpn-gateway-id "$id" --vpc-id "$vpc" >/dev/null 2>&1 || true
  done
  # 서브넷
  for id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$id"
  done
  # 기본이 아닌 라우팅 테이블 / NACL
  for id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
    --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$id"
  done
  for id in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc" "Name=default,Values=false" --query 'NetworkAcls[].NetworkAclId' --output text); do
    aws ec2 delete-network-acl --network-acl-id "$id"
  done
  # 보안 그룹: 서로 참조하는 규칙을 먼저 모두 걷어 낸 뒤 삭제
  local sgs sg rules
  sgs="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  for sg in $sgs; do
    rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text)"
    [ -n "$rules" ] && aws ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids $rules >/dev/null
  done
  for sg in $sgs; do aws ec2 delete-security-group --group-id "$sg" >/dev/null; done
  aws ec2 delete-vpc --vpc-id "$vpc"
}

# 3-티어 VPC를 처음부터 만든다 (lab02 의 본체). 진행 상황을 출력한다.
build_three_tier() {
  local vpc igw line name cidr az tier sn
  echo "== VPC $M02_VPC_NAME ($M02_VPC_CIDR)"
  vpc="$(aws ec2 create-vpc --cidr-block "$M02_VPC_CIDR" --tag-specifications "$(tags vpc "$M02_VPC_NAME")" --query Vpc.VpcId --output text)"
  aws ec2 wait vpc-available --vpc-ids "$vpc"
  aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
  echo "   $vpc"

  echo "== 서브넷 6개 (2 AZ × 3 티어)"
  for line in "${M02_SUBNETS[@]}"; do
    read -r name cidr az tier <<<"$line"
    sn="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "$(tags subnet "$name")" --query Subnet.SubnetId --output text)"
    if [ "$tier" = public ]; then
      aws ec2 modify-subnet-attribute --subnet-id "$sn" --map-public-ip-on-launch
    fi
    printf '   %-20s %-13s %s %s\n' "$name" "$cidr" "$az" "$sn"
  done

  echo "== 인터넷 게이트웨이 + 퍼블릭 라우팅 테이블 (0.0.0.0/0 → IGW)"
  igw="$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway todayorder-igw)" --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
  local pub_rt
  pub_rt="$(aws ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tags route-table todayorder-public-rt)" --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$pub_rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  for name in todayorder-public-a todayorder-public-b; do
    aws ec2 associate-route-table --route-table-id "$pub_rt" --subnet-id "$(subnet_id "$name")" >/dev/null
  done
  echo "   $igw → $pub_rt"

  echo "== NAT 게이트웨이 2개 (AZ마다 하나, 각자 퍼블릭 서브넷에)"
  local s eip nat nats=()
  for s in a b; do
    eip="$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip "todayorder-nat-$s-eip")" --query AllocationId --output text)"
    nat="$(aws ec2 create-nat-gateway --subnet-id "$(subnet_id "todayorder-public-$s")" --allocation-id "$eip" \
      --tag-specifications "$(tags natgateway "todayorder-nat-$s")" --query NatGateway.NatGatewayId --output text)"
    nats+=("$nat")
    echo "   todayorder-nat-$s $nat (EIP $eip)"
  done
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${nats[@]}"

  echo "== 앱 라우팅 테이블 (AZ별: 0.0.0.0/0 → 같은 AZ의 NAT)"
  local i=0 app_rt
  for s in a b; do
    app_rt="$(aws ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tags route-table "todayorder-app-rt-$s")" --query RouteTable.RouteTableId --output text)"
    aws ec2 create-route --route-table-id "$app_rt" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${nats[$i]}" >/dev/null
    aws ec2 associate-route-table --route-table-id "$app_rt" --subnet-id "$(subnet_id "todayorder-app-$s")" >/dev/null
    echo "   todayorder-app-rt-$s $app_rt → ${nats[$i]}"
    i=$((i + 1))
  done

  echo "== DB 라우팅 테이블 (local 경로만 — 인터넷으로 나가는 길이 없다)"
  local db_rt
  db_rt="$(aws ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tags route-table todayorder-db-rt)" --query RouteTable.RouteTableId --output text)"
  for name in todayorder-db-a todayorder-db-b; do
    aws ec2 associate-route-table --route-table-id "$db_rt" --subnet-id "$(subnet_id "$name")" >/dev/null
  done
  echo "   todayorder-db-rt $db_rt"

  # 다른 lab 이 "완성된 3-티어 VPC"인지 알아볼 수 있도록 마지막에 표시한다.
  aws ec2 create-tags --resources "$vpc" --tags Key=todayorder:m02,Value=three-tier-complete
}

# 완성된 3-티어 VPC가 있으면 그대로 쓰고, 없거나 반쯤 만들어졌으면 다시 만든다 (lab03~ 에서 사용).
ensure_three_tier() {
  local vpc mark
  vpc="$(vpc_id "$M02_VPC_NAME")"
  if [ -n "$vpc" ]; then
    mark="$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].Tags[?Key==`todayorder:m02`].Value | [0]' --output text)"
    if [ "$mark" = "three-tier-complete" ]; then
      echo "(준비) 3-티어 VPC $vpc 를 그대로 씁니다"
      return 0
    fi
    teardown_vpc "$M02_VPC_NAME"
  fi
  echo "(준비) 3-티어 VPC가 없어 새로 만듭니다 (lab02 와 같은 작업)"
  build_three_tier >/dev/null
}
