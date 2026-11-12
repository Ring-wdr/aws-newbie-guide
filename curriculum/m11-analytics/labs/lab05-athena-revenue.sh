#!/usr/bin/env bash
# M11 lab05 — 주문 분석 파이프라인 한 번에: Firehose → 파티션된 S3 → Glue 테이블 → Athena 매출 쿼리 (🟢)
#
#   과거 이틀치(백필) ──aws s3 cp──────────────┐
#   오늘 주문 ──PutRecordBatch──▶ Firehose ────┤──▶ s3://todayorder-analytics/raw/orders/dt=YYYY-MM-DD/
#                                              └──▶ Glue 테이블 todayorder_analytics.orders (+ 파티션 3개)
#                                                        └──▶ Athena 작업 그룹 todayorder-analytics ──▶ GetQueryResults
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-analytics"
DB="todayorder_analytics"
WG="todayorder-analytics"
STREAM="todayorder-analytics-orders"
ROLE="todayorder-analytics-firehose"
LOC="s3://$BUCKET/raw/orders/"
D1="$(utc_day -2)"
D2="$(utc_day -1)"
TODAY="$(utc_day 0)"

cleanup() {
  # 작업 그룹은 지우지 않는다: 에뮬레이터 1.0.322 는 DeleteWorkGroup 이 501 (아래 4단계에서 있으면 갱신)
  aws glue delete-database --name "$DB" >/dev/null 2>&1 || true
  aws firehose delete-delivery-stream --delivery-stream-name "$STREAM" >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name s3-write >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
  empty_bucket "$BUCKET"
  wait_until 60 1 "이전 전송 스트림 삭제" bash -c "! aws firehose describe-delivery-stream --delivery-stream-name $STREAM >/dev/null 2>&1"
}
cleanup

echo "== 1. 레이크 버킷 + 과거 이틀치 주문 백필 (dt=$D1, dt=$D2)"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text
history_orders "$D1" 1 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D1/backfill-0000.json"
history_orders "$D2" 2 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D2/backfill-0000.json"

echo "== 2. 오늘 주문은 Firehose 로 (접두사 raw/orders/dt=!{timestamp:yyyy-MM-dd}/)"
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name s3-write --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],
  \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]}]}"
aws firehose create-delivery-stream --delivery-stream-name "$STREAM" --delivery-stream-type DirectPut \
  --extended-s3-destination-configuration "{\"RoleARN\":\"$ROLE_ARN\",\"BucketARN\":\"arn:aws:s3:::$BUCKET\",
    \"Prefix\":\"raw/orders/dt=!{timestamp:yyyy-MM-dd}/\",\"ErrorOutputPrefix\":\"errors/!{firehose:error-output-type}/\",
    \"BufferingHints\":{\"IntervalInSeconds\":60,\"SizeInMBs\":1}}" --query DeliveryStreamARN --output text
wait_until 60 1 "전송 스트림 ACTIVE" bash -c \
  "[ \"\$(aws firehose describe-delivery-stream --delivery-stream-name $STREAM --query DeliveryStreamDescription.DeliveryStreamStatus --output text)\" = ACTIVE ]"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORDS="$( {
  order_json F-0001 gangnam bibimbap 2 18000 card "$NOW"
  order_json F-0002 gangnam tteokbokki 1 6000 kakaopay "$NOW"
  order_json F-0003 mapo bibimbap 1 9000 card "$NOW"
  order_json F-0004 mapo kimbap 3 10500 cash "$NOW"
  order_json F-0005 jamsil bibimbap 2 18000 card "$NOW"
} | py -c 'import json,sys; print(json.dumps([{"Data": l} for l in sys.stdin.read().splitlines(keepends=True)]))')"
aws firehose put-record-batch --delivery-stream-name "$STREAM" --cli-binary-format raw-in-base64-out \
  --records "$RECORDS" --query FailedPutCount --output text
wait_until 120 2 "Firehose 객체가 dt=$TODAY 에 도착" bash -c \
  "aws s3api list-objects-v2 --bucket $BUCKET --prefix raw/orders/dt=$TODAY/ --output json | grep -q '\"Key\"'"
aws s3 ls "s3://$BUCKET/raw/orders/" --recursive | awk '{print $3, $4}'

echo "== 3. Glue 카탈로그: 테이블 정의 + 파티션 3개 등록"
aws glue create-database --database-input "{\"Name\":\"$DB\"}"
aws glue create-table --database-name "$DB" --table-input "$(orders_table_input orders "$LOC")"
aws glue batch-create-partition --database-name "$DB" --table-name orders \
  --partition-input-list "$(partition_input "$LOC" "$D1" "$D2" "$TODAY")" --query '{Errors: Errors}'

echo "== 4. Athena 작업 그룹: 결과 위치 강제 + 쿼리당 스캔 상한 100 MB(비용 가드레일)"
if aws athena get-work-group --work-group "$WG" >/dev/null 2>&1; then
  echo "(이전 실행이 만든 작업 그룹이 있어 설정만 갱신 — 에뮬레이터는 DeleteWorkGroup 이 501)"
  aws athena update-work-group --work-group "$WG" --configuration-updates \
    "ResultConfigurationUpdates={OutputLocation=s3://$BUCKET/athena-results/},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true,BytesScannedCutoffPerQuery=104857600"
else
  aws athena create-work-group --name "$WG" --configuration "{
    \"ResultConfiguration\": {\"OutputLocation\": \"s3://$BUCKET/athena-results/\"},
    \"EnforceWorkGroupConfiguration\": true,
    \"PublishCloudWatchMetricsEnabled\": true,
    \"BytesScannedCutoffPerQuery\": 104857600}"
fi
aws athena get-work-group --work-group "$WG" \
  --query 'WorkGroup.{State: State, Output: Configuration.ResultConfiguration.OutputLocation, CutoffBytes: Configuration.BytesScannedCutoffPerQuery}'

echo "== 5. 주문 수와 총매출"
totals="$(athena "$WG" "$DB" 'SELECT count(*) AS orders, sum(amount) AS revenue FROM orders')"
echo "$totals"
QID="$(cat "$ATHENA_QID_FILE")"

echo "== 6. 일자별 매출 (주문 시각의 날짜 기준)"
by_day="$(athena "$WG" "$DB" 'SELECT substr(ordered_at, 1, 10) AS order_day, count(*) AS orders, sum(amount) AS revenue
FROM orders GROUP BY 1 ORDER BY 1')"
echo "$by_day"

echo "== 7. 매장별 매출 순위와 객단가"
by_store="$(athena "$WG" "$DB" 'SELECT store, count(*) AS orders, sum(amount) AS revenue, round(avg(amount)) AS avg_ticket
FROM orders GROUP BY store ORDER BY revenue DESC')"
echo "$by_store"

echo "== 8. 결제 수단 비중"
athena "$WG" "$DB" 'SELECT payment, count(*) AS orders, sum(amount) AS revenue FROM orders GROUP BY payment ORDER BY revenue DESC'

echo "== 9. 쿼리 실행 정보: 상태 전이 결과, 스캔한 바이트(= Athena 요금의 기준), 결과 위치"
aws athena get-query-execution --query-execution-id "$QID" --query 'QueryExecution.{
  State: Status.State, Engine: EngineVersion.EffectiveEngineVersion, ScannedBytes: Statistics.DataScannedInBytes,
  OutputLocation: ResultConfiguration.OutputLocation}'
OUT="$(aws athena get-query-execution --query-execution-id "$QID" --query QueryExecution.ResultConfiguration.OutputLocation --output text)"
set +e
result_file="$(aws s3 ls "$OUT" 2>&1)"
set -e
echo "결과 파일 확인 (aws s3 ls $OUT): ${result_file:-(없음)}"

echo "== 10. 파티션 열로 거르기: WHERE dt = '$TODAY' (실제 AWS: 그 날짜 폴더만 읽는 '파티션 프루닝')"
set +e
pruned="$(athena "$WG" "$DB" "SELECT count(*) AS orders, sum(amount) AS revenue FROM orders WHERE dt = '$TODAY'")"
set -e
echo "$pruned"

cleanup

# ---- 단언
[ "$(sed -n 2p <<<"$totals")" = "12 | 147000" ] || fail "총계가 12건 147000원이 아님: $totals"
grep -q "^$D1 | 4 | 42500$" <<<"$by_day" || fail "$D1 매출이 다름: $by_day"
grep -q "^$D2 | 3 | 43000$" <<<"$by_day" || fail "$D2 매출이 다름: $by_day"
[ "$(sed -n 2p <<<"$by_store")" = "gangnam | 5 | 72500 | 14500.0" ] || fail "1위 매장이 다름: $by_store"
if [[ "$pruned" == *"no such column: dt"* ]]; then
  echo "참고: 에뮬레이터 Athena 는 파티션 열 dt 를 모른다 (README 에뮬레이터 제약)"
elif [ "$(sed -n 2p <<<"$pruned")" = "5 | 61500" ]; then
  echo "참고: 에뮬레이터가 파티션 열을 지원하기 시작했다 — 레슨 4의 설명을 갱신할 것"
else
  fail "WHERE dt 쿼리 결과가 예상 밖: $pruned"
fi
echo "LAB05 OK"
