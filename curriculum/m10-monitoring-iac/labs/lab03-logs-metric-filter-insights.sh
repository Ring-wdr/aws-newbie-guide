#!/usr/bin/env bash
# M10 lab03 — 로그 그룹·이벤트·보존 기간·지표 필터·Logs Insights (🟢)
# 주문 API가 JSON 한 줄 로그(구조화 로그)를 남긴다고 보고,
#   ① 보존 기간을 정하고 ② 패턴으로 찾고 ③ ERROR 로그를 지표로 바꾸고 ④ Insights로 집계한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

GROUP="/todayorder/api"
STREAM="api-1"
MNS="TodayOrder/Logs"
# 지표 필터가 만드는 지표는 지울 수 없어(실제 AWS도 같다) 실행마다 다른 지표 이름을 쓴다.
SUFFIX="$(date +%s)"
ERR_METRIC="ApiErrors$SUFFIX"
LAT_METRIC="ApiLatency$SUFFIX"

aws logs delete-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true

echo "== 1. 로그 그룹 생성과 보존 기간"
aws logs create-log-group --log-group-name "$GROUP"
set +e
bad="$(aws logs put-retention-policy --log-group-name "$GROUP" --retention-in-days 10 2>&1)"
set -e
echo "보존 10일 시도 → $bad"
aws logs put-retention-policy --log-group-name "$GROUP" --retention-in-days 14
aws logs describe-log-groups --log-group-name-prefix "$GROUP" \
  --query 'logGroups[0].{Group: logGroupName, RetentionDays: retentionInDays}'

echo "== 2. 지표 필터 2개: ERROR 건수, 지연 시간 값"
aws logs put-metric-filter --log-group-name "$GROUP" --filter-name errors \
  --filter-pattern '{ $.level = "ERROR" }' \
  --metric-transformations "[{\"metricName\":\"$ERR_METRIC\",\"metricNamespace\":\"$MNS\",\"metricValue\":\"1\",\"defaultValue\":0}]"
aws logs put-metric-filter --log-group-name "$GROUP" --filter-name latency \
  --filter-pattern '{ $.latency_ms = * }' \
  --metric-transformations "[{\"metricName\":\"$LAT_METRIC\",\"metricNamespace\":\"$MNS\",\"metricValue\":\"\$.latency_ms\",\"unit\":\"Milliseconds\"}]"
aws logs describe-metric-filters --log-group-name "$GROUP" \
  --query 'metricFilters[].{Name: filterName, Pattern: filterPattern}' --output table

echo "== 3. 로그 스트림에 구조화 로그 5건 쓰기"
aws logs create-log-stream --log-group-name "$GROUP" --log-stream-name "$STREAM"
NOW=$(($(date +%s) * 1000))
EVENTS="$(py - "$NOW" <<'PY'
import json, sys
now = int(sys.argv[1])
logs = [
    {"level": "INFO",  "route": "POST /orders", "status": 201, "latency_ms": 120, "order_id": "A-1001"},
    {"level": "INFO",  "route": "GET /orders",  "status": 200, "latency_ms": 40},
    {"level": "ERROR", "route": "POST /orders", "status": 500, "latency_ms": 2300, "msg": "payment failed"},
    {"level": "ERROR", "route": "POST /orders", "status": 502, "latency_ms": 1800, "msg": "payment timeout"},
    {"level": "WARN",  "route": "GET /orders",  "status": 200, "latency_ms": 900},
]
print(json.dumps([{"timestamp": now + i, "message": json.dumps(e)} for i, e in enumerate(logs)]))
PY
)"
aws logs put-log-events --log-group-name "$GROUP" --log-stream-name "$STREAM" --log-events "$EVENTS" \
  --query '{Rejected: rejectedLogEventsInfo}'

echo "== 4. filter-log-events: 두 가지 패턴"
echo "-- (a) JSON 패턴 { \$.status >= 500 }"
aws logs filter-log-events --log-group-name "$GROUP" --filter-pattern '{ $.status >= 500 }' \
  --query 'events[].message' --output text
echo "-- (b) 구문(phrase) 패턴 \"payment failed\""
aws logs filter-log-events --log-group-name "$GROUP" --filter-pattern '"payment failed"' \
  --query 'events[].message' --output text
# 목록 명령은 페이지마다 --query 가 적용되므로 개수는 JSON으로 받아 센다 (M00 레슨 5의 함정)
five_xx="$(aws logs filter-log-events --log-group-name "$GROUP" --filter-pattern '{ $.status >= 500 }' \
  --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["events"]))')"

echo "== 5. 지표 필터가 만든 CloudWatch 지표"
START="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10 min' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u -v+2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ)"
metric_sum() {
  aws cloudwatch get-metric-statistics --namespace "$MNS" --metric-name "$1" \
    --start-time "$START" --end-time "$END" --period 3600 --statistics "$2" \
    --query "Datapoints[0].$2" --output text
}
export -f metric_sum
export MNS START END ERR_METRIC
wait_until 60 2 "ERROR 지표 합계 2" bash -c '[ "$(metric_sum "$ERR_METRIC" Sum)" = "2.0" ]'
errors="$(metric_sum "$ERR_METRIC" Sum)"
maxlat="$(metric_sum "$LAT_METRIC" Maximum)"
echo "$ERR_METRIC Sum=$errors   $LAT_METRIC Maximum=$maxlat"

echo "== 6. Logs Insights: 경로별 요청 수·평균·최대 지연"
insights() {
  local qid status
  qid="$(aws logs start-query --log-group-name "$GROUP" \
    --start-time $(($(date +%s) - 900)) --end-time $(($(date +%s) + 60)) \
    --query-string "$1" --query queryId --output text)"
  for _ in $(seq 1 30); do
    status="$(aws logs get-query-results --query-id "$qid" --query status --output text)"
    case "$status" in Complete | Failed | Cancelled | Timeout) break ;; esac
    sleep 1
  done
  [ "$status" = Complete ] || fail "Insights 쿼리 상태 $status: $1"
  aws logs get-query-results --query-id "$qid" --output json | py -c '
import json, sys
rows = [{f["field"]: f["value"] for f in r if f["field"] != "@ptr"} for r in json.load(sys.stdin)["results"]]
print(json.dumps(rows, ensure_ascii=False))'
}
by_route="$(insights 'stats count(*) as requests, avg(latency_ms) as avg_ms, max(latency_ms) as max_ms by route | sort requests desc')"
echo "$by_route" | py -m json.tool --no-ensure-ascii
echo "== 7. Logs Insights: 5xx 오류 메시지만"
errs="$(insights 'fields @timestamp, status, msg | filter status >= 500 | sort @timestamp desc')"
echo "$errs" | py -m json.tool --no-ensure-ascii

# ---- 단언
[[ "$bad" == *InvalidParameterException* ]] || fail "보존 10일이 거부되지 않음"
[ "$five_xx" = 2 ] || fail "5xx 로그가 2건이 아님: $five_xx"
[ "$errors" = "2.0" ] || fail "ERROR 지표 합계가 2가 아님: $errors"
[ "$maxlat" = "2300.0" ] || fail "지연 최댓값이 2300이 아님: $maxlat"
py -c "
import json,sys
rows={r['route']: r for r in json.loads('''$by_route''')}
assert rows['POST /orders']['requests']=='3' and rows['POST /orders']['max_ms']=='2300', rows
assert len(json.loads('''$errs'''))==2
" || fail "Insights 결과가 예상과 다름"
aws logs delete-log-group --log-group-name "$GROUP"
echo "LAB03 OK"
