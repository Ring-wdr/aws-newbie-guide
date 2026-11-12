# shellcheck shell=bash
# M11 실습 공용 도우미. 각 lab 이 scripts/env.sh 다음에 source 한다.
#   source "$(dirname "$0")/_lib.sh"

# fail "메시지" — 단언 실패
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# wait_until <상한초> <간격초> <설명> <명령...>
# 명령이 성공(종료 코드 0)할 때까지 폴링한다. 상한을 넘기면 마지막 출력을 보여 주고 실패한다.
# "몇 초 뒤"를 가정하지 않고 상태가 될 때까지 기다리기 위한 함수다.
wait_until() {
  local limit="$1" interval="$2" what="$3"
  shift 3
  local start out
  start=$(date +%s)
  while true; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if [ $(($(date +%s) - start)) -ge "$limit" ]; then
      echo "FAIL: ${limit}초 안에 '$what' 상태가 되지 않음. 마지막 관찰: $out" >&2
      exit 1
    fi
    sleep "$interval"
  done
}

# py — 저장소의 uv 가상 환경 Python (JSON 가공용). 시스템 python3 버전에 기대지 않는다.
py() {
  uv run --quiet --project "$(git rev-parse --show-toplevel)" python "$@"
}
export -f py

# empty_bucket <버킷> — 버킷이 있으면 비우고 지운다 (멱등성).
empty_bucket() {
  aws s3 rb "s3://$1" --force >/dev/null 2>&1 || true
}

# utc_day <오프셋일> — UTC 기준 날짜(YYYY-MM-DD). Firehose 의 !{timestamp:...} 도 UTC 를 쓴다.
utc_day() {
  py -c "import datetime as d,sys; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%d'))" "$1"
}

# athena <작업그룹> <데이터베이스> <SQL> — 쿼리를 실행하고 끝날 때까지 폴링한다.
# 성공하면 결과를 "열1 | 열2" 줄로 출력(첫 줄은 열 이름)하고, 실패하면 이유를 출력하고 1을 돌려준다.
# 마지막 쿼리 ID는 $ATHENA_QID_FILE 에 남긴다 (명령 치환 $(...) 안에서 실행되므로 변수로는 못 돌려준다).
ATHENA_QID_FILE="${TMPDIR:-/tmp}/todayorder-athena-qid-${EMULATOR_PORT:-x}"
export ATHENA_QID_FILE
athena() {
  local wg="$1" db="$2" sql="$3" qid state
  qid="$(aws athena start-query-execution --work-group "$wg" \
    --query-execution-context "Database=$db" --query-string "$sql" \
    --query QueryExecutionId --output text)"
  echo "$qid" >"$ATHENA_QID_FILE"
  for _ in $(seq 1 60); do
    state="$(aws athena get-query-execution --query-execution-id "$qid" --query QueryExecution.Status.State --output text)"
    case "$state" in SUCCEEDED | FAILED | CANCELLED) break ;; esac
    sleep 1
  done
  if [ "$state" != SUCCEEDED ]; then
    echo "[$state] $(aws athena get-query-execution --query-execution-id "$qid" --query QueryExecution.Status.StateChangeReason --output text)"
    return 1
  fi
  aws athena get-query-results --query-execution-id "$qid" --output json | py -c '
import json, sys
for row in json.load(sys.stdin)["ResultSet"]["Rows"]:
    print(" | ".join(c.get("VarCharValue", "NULL") for c in row["Data"]))'
}

# order_json <주문ID> <매장> <메뉴> <수량> <금액> <결제수단> <주문시각(ISO, UTC)> — 주문 이벤트 JSON 한 줄
order_json() {
  printf '{"order_id":"%s","store":"%s","menu":"%s","qty":%s,"amount":%s,"payment":"%s","ordered_at":"%s"}\n' "$@"
}

# history_orders <날짜> <1|2> — 실습용 과거 주문 (첫째 날 4건 42,500원, 둘째 날 3건 43,000원)
history_orders() {
  local d="$1"
  if [ "$2" = 1 ]; then
    order_json H-0001 gangnam bibimbap 2 18000 card "${d}T03:10:00Z"
    order_json H-0002 gangnam kimbap 1 3500 cash "${d}T04:22:00Z"
    order_json H-0003 mapo tteokbokki 2 12000 kakaopay "${d}T09:41:00Z"
    order_json H-0004 jamsil bibimbap 1 9000 card "${d}T11:05:00Z"
  else
    order_json H-0005 gangnam bibimbap 3 27000 card "${d}T02:55:00Z"
    order_json H-0006 mapo kimbap 2 7000 card "${d}T05:30:00Z"
    order_json H-0007 mapo bibimbap 1 9000 kakaopay "${d}T10:12:00Z"
  fi
}

# Glue 테이블 정의(JSON 줄 단위 SerDe, dt 파티션) — <테이블이름> <S3 위치>
orders_table_input() {
  cat <<JSON
{
  "Name": "$1",
  "Description": "TodayOrder 주문 이벤트 (JSON Lines, dt=YYYY-MM-DD 파티션)",
  "TableType": "EXTERNAL_TABLE",
  "Parameters": {"classification": "json", "EXTERNAL": "TRUE"},
  "PartitionKeys": [{"Name": "dt", "Type": "string"}],
  "StorageDescriptor": {
    "Columns": [
      {"Name": "order_id",   "Type": "string"},
      {"Name": "store",      "Type": "string"},
      {"Name": "menu",       "Type": "string"},
      {"Name": "qty",        "Type": "int"},
      {"Name": "amount",     "Type": "bigint"},
      {"Name": "payment",    "Type": "string"},
      {"Name": "ordered_at", "Type": "string"}
    ],
    "Location": "$2",
    "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
    "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
    "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}
  }
}
JSON
}

# partition_input <위치접두사> <날짜...> — BatchCreatePartition 의 PartitionInputList
# 실제 AWS에서 Athena 는 파티션마다 저장된 StorageDescriptor(SerDe·형식)로 읽으므로, 테이블 것을 복사하고 Location 만 바꾼다.
partition_input() {
  local loc="$1"
  shift
  orders_table_input orders "$loc" | py -c '
import json, sys
sd = json.load(sys.stdin)["StorageDescriptor"]
loc, days = sys.argv[1], sys.argv[2:]
print(json.dumps([{"Values": [d], "StorageDescriptor": dict(sd, Location=f"{loc}dt={d}/")} for d in days]))' "$loc" "$@"
}
