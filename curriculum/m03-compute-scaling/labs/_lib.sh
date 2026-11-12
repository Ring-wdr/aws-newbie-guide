# shellcheck shell=bash
# M03 lab 공용 함수. lab 스크립트가 env.sh 를 source 한 다음에 source 한다. 직접 실행하지 않는다.
#
# 이 모듈의 lab 은 서로에게 기대지 않는다. 대신 모두 아래 m03_network 로 "M03 전용 최소 VPC"를
# 찾거나(있으면 재사용) 만든다. M02의 스크립트에는 의존하지 않는다.
#
#   VPC 10.30.0.0/16 (Name=todayorder-m03-vpc)
#   ├── 서브넷 A 10.30.1.0/24  us-east-1a  (Name=todayorder-m03-public-a)
#   ├── 서브넷 B 10.30.2.0/24  us-east-1b  (Name=todayorder-m03-public-b)
#   └── 인터넷 게이트웨이 + 0.0.0.0/0 경로 (퍼블릭 서브넷)

M03_AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# 첫 번째 값만 꺼낸다 (없으면 빈 문자열). --output text 의 "None" 도 빈 값으로 본다.
_first() { awk 'NF && $1 != "None" {print $1; exit}'; }

# M03 전용 VPC·서브넷 2개·IGW·라우팅을 준비하고 M03_VPC, M03_SUBNET_A, M03_SUBNET_B 를 export 한다.
m03_network() {
  M03_VPC="$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=todayorder-m03-vpc \
    --query 'Vpcs[].VpcId' --output text | _first)"
  if [ -z "$M03_VPC" ]; then
    M03_VPC="$(aws ec2 create-vpc --cidr-block 10.30.0.0/16 \
      --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=todayorder-m03-vpc},{Key=Project,Value=todayorder}]' \
      --query Vpc.VpcId --output text)"
  fi
  M03_SUBNET_A="$(_m03_subnet todayorder-m03-public-a 10.30.1.0/24 us-east-1a)"
  M03_SUBNET_B="$(_m03_subnet todayorder-m03-public-b 10.30.2.0/24 us-east-1b)"

  local igw rtb
  igw="$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$M03_VPC" \
    --query 'InternetGateways[].InternetGatewayId' --output text | _first)"
  if [ -z "$igw" ]; then
    igw="$(aws ec2 create-internet-gateway \
      --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=todayorder-m03-igw},{Key=Project,Value=todayorder}]' \
      --query InternetGateway.InternetGatewayId --output text)"
    aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$M03_VPC"
  fi
  rtb="$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$M03_VPC" Name=association.main,Values=true \
    --query 'RouteTables[].RouteTableId' --output text | _first)"
  if ! aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query 'RouteTables[0].Routes[].DestinationCidrBlock' --output text | grep -q '0\.0\.0\.0/0'; then
    aws ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  fi
  export M03_VPC M03_SUBNET_A M03_SUBNET_B
}

_m03_subnet() {
  local name="$1" cidr="$2" az="$3" id
  id="$(aws ec2 describe-subnets --filters Name=tag:Name,Values="$name" Name=vpc-id,Values="$M03_VPC" \
    --query 'Subnets[].SubnetId' --output text | _first)"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$M03_VPC" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name},{Key=Project,Value=todayorder}]" \
      --query Subnet.SubnetId --output text)"
  fi
  printf '%s\n' "$id"
}

# 최신 Amazon Linux 2023 AMI ID (SSM 공개 파라미터 — 실제 AWS에서도 같은 방법을 쓴다)
m03_ami() {
  aws ssm get-parameter --name "$M03_AMI_PARAM" --query Parameter.Value --output text
}

# 이 lab 이 이전 실행에서 남긴 인스턴스(태그 Lab=<값>)를 모두 종료한다.
m03_terminate_tagged() {
  local lab="$1" ids
  ids="$(aws ec2 describe-instances \
    --filters Name=tag:Lab,Values="$lab" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [ -n "$ids" ] && [ "$ids" != "None" ]; then
    # shellcheck disable=SC2086 # 공백으로 구분된 ID 목록을 인자로 펼친다
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    wait_for instance terminated $ids >/dev/null
  fi
}

# poll <최대 초> <설명> <명령...> : 명령이 성공할 때까지 1초 간격으로 다시 실행한다.
# 실패하면 마지막 출력과 함께 1 을 돌려준다. ("몇 초 뒤"를 가정하지 않기 위해 쓴다)
poll() {
  local limit="$1" what="$2" i out=""
  shift 2
  for ((i = 0; i < limit; i++)); do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    sleep 1
  done
  echo "TIMEOUT(${limit}s): $what — 마지막 관찰: $out" >&2
  return 1
}

# expect_error <오류 코드> <명령...> : 명령이 실패하고 오류 메시지에 코드가 들어 있어야 한다.
# 오류 메시지를 출력하고, 기대와 다르면 1 을 돌려준다.
expect_error() {
  local code="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    echo "FAIL: 실패해야 할 호출이 성공했다 ($code 기대): $*" >&2
    echo "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed '/^$/d'
  case "$out" in
    *"$code"*) return 0 ;;
    *) echo "FAIL: 오류 코드가 $code 가 아니다" >&2; return 1 ;;
  esac
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# wait_for <instance|volume|snapshot> <목표 상태> <ID...> : 모든 ID가 목표 상태가 될 때까지 1초 간격으로 확인(최대 120초).
# `aws ec2 wait ...` 도 같은 일을 하지만 확인 간격이 15초라 실습이 느려진다. 실제 AWS에서는 waiter 를 써도 된다.
_all_in_state() {
  local kind="$1" goal="$2" got
  shift 2
  case "$kind" in
    instance) got="$(aws ec2 describe-instances --instance-ids "$@" --query 'Reservations[].Instances[].State.Name' --output text)" ;;
    volume) got="$(aws ec2 describe-volumes --volume-ids "$@" --query 'Volumes[].State' --output text)" ;;
    snapshot) got="$(aws ec2 describe-snapshots --snapshot-ids "$@" --query 'Snapshots[].State' --output text)" ;;
  esac
  echo "$got"
  [ -n "$got" ] && [ -z "$(printf '%s\n' $got | grep -vx "$goal")" ]
}
wait_for() {
  local kind="$1" goal="$2"
  shift 2
  poll 120 "$kind $* → $goal" _all_in_state "$kind" "$goal" "$@"
}
