#!/usr/bin/env bash
# M05 lab04 — DynamoDB 주문 테이블 설계와 Query vs Scan (🟢)
# 접근 패턴 "고객의 주문 목록(최신순)" → 파티션 키 customer_id + 정렬 키 order_ts
# → 200건 적재 → GetItem / Query / Scan / FilterExpression 의 소비 용량(RCU) 비교 → 페이지네이션 → 일관성 비용
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

T=todayorder-m05-orders
ddb_delete_table "$T"

echo "== 1. 테이블 생성 (응답 상태는 CREATING — 반드시 waiter 로 ACTIVE 를 기다린다)"
create_orders_table
aws dynamodb describe-table --table-name "$T" --query 'Table.{Status: TableStatus, Items: ItemCount}'

echo "== 2. 주문 200건 적재 (고객 10명 × 20건, 항목당 약 1 KB)"
load_orders

echo "== 3. GetItem: 키를 전부 알면 1건을 바로 (최종 일관 0.5 RCU / 강력 일관 1 RCU)"
KEY='{"customer_id":{"S":"c-003"},"order_ts":{"S":"2026-11-05T08:00:00Z#A-00305"}}'
aws dynamodb get-item --table-name "$T" --key "$KEY" --projection-expression "order_id, #s, #t" \
  --expression-attribute-names '{"#s":"status","#t":"total"}' --return-consumed-capacity TOTAL \
  --query '{Item: Item, Consumed: ConsumedCapacity.CapacityUnits}'
get_cu="$(aws dynamodb get-item --table-name "$T" --key "$KEY" --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"
get_strong_cu="$(aws dynamodb get-item --table-name "$T" --key "$KEY" --consistent-read --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"
echo "GetItem 최종 일관=$get_cu RCU, 강력 일관=$get_strong_cu RCU"

echo "== 4. Query: 고객 c-003 의 주문 전부 (한 파티션만 읽는다)"
aws dynamodb query --table-name "$T" --key-condition-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --return-consumed-capacity TOTAL \
  --query '{Count: Count, ScannedCount: ScannedCount, Consumed: ConsumedCapacity.CapacityUnits}'
q_cu="$(aws dynamodb query --table-name "$T" --key-condition-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"
q_strong_cu="$(aws dynamodb query --table-name "$T" --key-condition-expression "customer_id = :c" --consistent-read \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"
echo "같은 Query 를 강력 일관 읽기로: $q_strong_cu RCU"

echo "== 5. Query + 정렬 키 조건: c-003 의 11월 1~9일 주문 중 최신 3건 (역순, Limit 3)"
aws dynamodb query --table-name "$T" \
  --key-condition-expression "customer_id = :c AND order_ts BETWEEN :from AND :to" \
  --expression-attribute-values '{":c":{"S":"c-003"},":from":{"S":"2026-11-01"},":to":{"S":"2026-11-10"}}' \
  --no-scan-index-forward --limit 3 --no-paginate --projection-expression "order_ts, #s, #t" \
  --expression-attribute-names '{"#s":"status","#t":"total"}' \
  --query 'Items[].[order_ts.S, status.S, total.N]' --output table

echo "== 6. Scan: 테이블 전체를 읽는다"
aws dynamodb scan --table-name "$T" --return-consumed-capacity TOTAL \
  --query '{Count: Count, ScannedCount: ScannedCount, Consumed: ConsumedCapacity.CapacityUnits}'
s_cu="$(aws dynamodb scan --table-name "$T" --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"

echo "== 7. Scan + FilterExpression: 결과는 20건이지만 읽은 양(=비용)은 그대로"
aws dynamodb scan --table-name "$T" --filter-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --return-consumed-capacity TOTAL \
  --query '{Count: Count, ScannedCount: ScannedCount, Consumed: ConsumedCapacity.CapacityUnits}'
sf_count="$(aws dynamodb scan --table-name "$T" --filter-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --query 'Count' --output text)"
sf_cu="$(aws dynamodb scan --table-name "$T" --filter-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --return-consumed-capacity TOTAL --query 'ConsumedCapacity.CapacityUnits' --output text)"

echo "== 8. 페이지네이션: Limit=8 이면 응답에 LastEvaluatedKey 가 붙는다 (CLI 자동 페이지네이션 끄고 확인)"
aws dynamodb query --table-name "$T" --key-condition-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --limit 8 --no-paginate \
  --query '{Count: Count, LastEvaluatedKey: LastEvaluatedKey}'
pages="$(aws dynamodb query --table-name "$T" --key-condition-expression "customer_id = :c" \
  --expression-attribute-values '{":c":{"S":"c-003"}}' --page-size 8 --output json --query 'Count')"
echo "--page-size 8 로 CLI 가 페이지를 따라가 합친 결과: $pages 건"

echo "== 9. 키가 아닌 속성으로는 Query 할 수 없다"
expect_error ValidationException aws dynamodb query --table-name "$T" \
  --key-condition-expression "#s = :s" --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"PAID"}}'

echo "== 10. 정리"
ddb_delete_table "$T"

# ---- 단언 (항목 크기·개수가 고정이므로 소비 용량도 고정이다)
[ "$get_cu" = "0.5" ] && [ "$get_strong_cu" = "1.0" ] || fail "GetItem 소비 용량: $get_cu / $get_strong_cu"
[ "$q_cu" = "2.5" ] || fail "Query 소비 용량이 2.5가 아님: $q_cu"
[ "$q_strong_cu" = "5.0" ] || fail "강력 일관 Query 소비 용량이 5.0이 아님: $q_strong_cu"
[ "$sf_count" = "20" ] || fail "필터 Scan 결과가 20건이 아님: $sf_count"
awk -v s="$s_cu" -v q="$q_cu" 'BEGIN { exit !(s >= 5 * q) }' || fail "Scan($s_cu)이 Query($q_cu)보다 충분히 비싸지 않음"
[ "$s_cu" = "$sf_cu" ] || fail "필터가 Scan 비용을 바꿈: $s_cu → $sf_cu"
[ "$pages" = "20" ] || fail "페이지 합계가 20이 아님: $pages"
echo "LAB04 OK"
