# shellcheck shell=bash
# M05 실습 공용 함수. 각 labNN-*.sh 가 env.sh 다음에 source 한다 (단독 실행용 아님).
#
#   source "$(dirname "$0")/_common.sh"
#
# 여기 있는 함수는 모두 "있으면 재사용, 없으면 만든다"(멱등) 또는 "있으면 지운다"(정리) 이다.

M05_VPC_NAME="todayorder-m05-vpc"
M05_VPC_CIDR="10.50.0.0/16"

# 실패 메시지를 출력하고 종료한다.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# poll_until <제한 초> <설명> <명령...>
#   명령이 0으로 끝날 때까지 1초 간격으로 다시 실행한다. 시간이 다 되면 마지막 출력을 보여 주고 실패한다.
#   "몇 초 뒤"를 가정하지 않기 위한 도구 (AUTHORING 3장 10번).
poll_until() {
  local limit="$1" desc="$2"
  shift 2
  local start out
  start=$(date +%s)
  while true; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if [ $(($(date +%s) - start)) -ge "$limit" ]; then
      echo "시간 초과(${limit}s): $desc" >&2
      echo "마지막 관찰: $(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')" >&2
      return 1
    fi
    sleep 1
  done
}

# ---- CLI waiter 대신 쓰는 1초 간격 대기: scripts/lab-wait.sh (모든 모듈이 같이 쓴다)
# RDS·DocumentDB waiter 는 30초, ElastiCache waiter 는 15초 간격으로 조회한다. 첫 조회는 생성 직후라
# 에뮬레이터가 아직 creating 을 돌려주는 경우가 많고(1초도 안 돼 available 이 되더라도), 그러면 다음 조회까지
# 한 간격을 통째로 기다린다. 그래서 lab 은 waiter 와 같은 성공·실패 조건을 1초 간격으로 확인하는
# wait_rds_instance_available · wait_rds_instance_deleted · wait_state · wait_gone 등을 쓴다.
# DynamoDB table-exists 는 빠르지만, ACTIVE 직후 VM 시계가 뒤로 옮겨지면 잠깐 "준비 안 됨"이 되므로
# 준비 직후 한 번 더 확인하는 wait_dynamodb_table_active 를 쓴다.
# 실제 AWS 에서는 waiter 가 정상 도구다.
source "$(git rev-parse --show-toplevel)/scripts/lab-wait.sh"

# expect_error <기대 오류 코드> <명령...>
#   명령이 실패하고, 출력에 기대한 오류 코드가 있어야 통과한다. 출력은 그대로 보여 준다.
expect_error() {
  local code="$1"
  shift
  local out
  if out="$("$@" 2>&1)"; then
    echo "$out"
    fail "실패해야 할 명령이 성공했다: $*"
  fi
  echo "$out" | sed '/^$/d'
  grep -q "$code" <<<"$out" || fail "기대한 오류 코드 $code 가 아니다"
}

# ensure_m05_vpc: 실습용 VPC(10.50.0.0/16)와 프라이빗 서브넷 2개(us-east-1a, 1b)를 준비하고
#   VPC_ID, SUBNET_A, SUBNET_B 변수를 채운다. 이미 있으면 재사용한다.
ensure_m05_vpc() {
  VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$M05_VPC_NAME" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    VPC_ID="$(aws ec2 create-vpc --cidr-block "$M05_VPC_CIDR" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$M05_VPC_NAME}]" \
      --query Vpc.VpcId --output text)"
  fi
  SUBNET_A="$(_ensure_subnet "$VPC_ID" 10.50.11.0/24 us-east-1a todayorder-m05-private-a)"
  SUBNET_B="$(_ensure_subnet "$VPC_ID" 10.50.12.0/24 us-east-1b todayorder-m05-private-b)"
  export VPC_ID SUBNET_A SUBNET_B
}

_ensure_subnet() {
  local vpc="$1" cidr="$2" az="$3" name="$4" id
  id="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" "Name=tag:Name,Values=$name" \
    --query 'Subnets[0].SubnetId' --output text)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name}]" \
      --query Subnet.SubnetId --output text)"
  fi
  echo "$id"
}

# ensure_db_sg: DB용 보안 그룹(같은 VPC 안에서만 5432 허용)을 준비하고 DB_SG 를 채운다.
ensure_db_sg() {
  DB_SG="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=todayorder-m05-db-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [ "$DB_SG" = "None" ] || [ -z "$DB_SG" ]; then
    DB_SG="$(aws ec2 create-security-group --group-name todayorder-m05-db-sg \
      --description "TodayOrder DB - VPC internal only" --vpc-id "$VPC_ID" --query GroupId --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$DB_SG" \
      --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=$M05_VPC_CIDR}]" >/dev/null
  fi
  export DB_SG
}

# ---- RDS 정리 도우미 (없으면 조용히 넘어간다)

rds_instance_exists() {
  aws rds describe-db-instances --db-instance-identifier "$1" >/dev/null 2>&1
}

rds_delete_instance() {
  local id="$1"
  rds_instance_exists "$id" || return 0
  aws rds modify-db-instance --db-instance-identifier "$id" --no-deletion-protection \
    --apply-immediately >/dev/null 2>&1 || true
  aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot \
    --delete-automated-backups >/dev/null 2>&1 || true
  wait_rds_instance_deleted "$id"
}

rds_delete_snapshot() {
  aws rds describe-db-snapshots --db-snapshot-identifier "$1" >/dev/null 2>&1 || return 0
  aws rds delete-db-snapshot --db-snapshot-identifier "$1" >/dev/null
  wait_rds_snapshot_deleted "$1"
}

# ---- DynamoDB 도우미

ddb_delete_table() {
  local out
  if ! out="$(aws dynamodb describe-table --table-name "$1" 2>&1 >/dev/null)"; then
    grep -q '(ResourceNotFoundException)' <<<"$out" && return 0   # 없다
    echo "$out" >&2; return 1                                       # 다른 오류는 "없다"로 치지 않는다
  fi
  aws dynamodb delete-table --table-name "$1" >/dev/null 2>&1 || true   # 이미 '삭제 중'이면 ResourceInUseException
  # CLI waiter(table-not-exists)는 20초 간격으로 확인하므로 1초 간격으로 기다린다(ResourceNotFoundException 만 "사라짐").
  wait_dynamodb_table_gone "$1"
}

# 주문 테이블 todayorder-m05-orders 를 새로 만든다 (lab04·lab05 공용).
#   파티션 키 customer_id(S) · 정렬 키 order_ts(S) = "주문시각#주문번호"
#   LSI customer-total-index: 같은 고객 안에서 금액(total, N) 순 정렬 — LSI는 테이블을 만들 때만 정의할 수 있다.
create_orders_table() {
  aws dynamodb create-table --table-name todayorder-m05-orders \
    --attribute-definitions AttributeName=customer_id,AttributeType=S \
                            AttributeName=order_ts,AttributeType=S \
                            AttributeName=total,AttributeType=N \
    --key-schema AttributeName=customer_id,KeyType=HASH AttributeName=order_ts,KeyType=RANGE \
    --local-secondary-indexes '[{"IndexName":"customer-total-index",
        "KeySchema":[{"AttributeName":"customer_id","KeyType":"HASH"},{"AttributeName":"total","KeyType":"RANGE"}],
        "Projection":{"ProjectionType":"KEYS_ONLY"}}]' \
    --billing-mode PAY_PER_REQUEST \
    --query 'TableDescription.{TableStatus: TableStatus, KeySchema: KeySchema, BillingMode: BillingModeSummary.BillingMode}'
  wait_dynamodb_table_active todayorder-m05-orders   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
}

# 고객 10명(c-001~c-010) × 주문 20건 = 200건을 BatchWriteItem(한 번에 최대 25건)으로 넣는다.
# 항목마다 약 900바이트짜리 memo 를 넣어 항목 하나가 약 1 KB 가 되게 한다 → 소비 용량 차이가 눈에 보인다.
load_orders() {
  local dir statuses pad c i n batch status total day hour
  dir="$(mktemp -d)"
  statuses=(PAID SHIPPED DELIVERED PAID CANCELLED)
  pad="$(printf 'x%.0s' $(seq 1 900))"
  n=0
  batch=0
  for c in $(seq 1 10); do
    for i in $(seq 1 20); do
      status="${statuses[$(((c + i) % 5))]}"
      total=$((((c * 7 + i * 13) % 50 + 1) * 1000))
      day=$(printf '%02d' "$i")
      hour=$(printf '%02d' $(((c + i) % 24)))
      if [ $((n % 25)) -eq 0 ]; then
        [ "$n" -gt 0 ] && printf ']}' >>"$dir/batch$batch.json"
        batch=$((batch + 1))
        printf '{"todayorder-m05-orders":[' >"$dir/batch$batch.json"
      else
        printf ',' >>"$dir/batch$batch.json"
      fi
      printf '{"PutRequest":{"Item":{"customer_id":{"S":"c-%03d"},"order_ts":{"S":"2026-11-%sT%s:00:00Z#A-%03d%02d"},"order_id":{"S":"A-%03d%02d"},"status":{"S":"%s"},"total":{"N":"%d"},"memo":{"S":"%s"}}}}' \
        "$c" "$day" "$hour" "$c" "$i" "$c" "$i" "$status" "$total" "$pad" >>"$dir/batch$batch.json"
      n=$((n + 1))
    done
  done
  printf ']}' >>"$dir/batch$batch.json"
  for f in "$dir"/batch*.json; do
    local left
    left="$(aws dynamodb batch-write-item --request-items "file://$f" --query 'length(UnprocessedItems)' --output text)"
    [ "$left" = "0" ] || fail "처리되지 않은 항목이 남았다 ($f)"
  done
  rm -rf "$dir"
  echo "주문 ${n}건을 BatchWriteItem ${batch}회로 적재"
}
