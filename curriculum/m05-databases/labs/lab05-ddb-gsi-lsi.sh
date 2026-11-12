#!/usr/bin/env bash
# M05 lab05 — 새 접근 패턴에 GSI 추가, LSI 와 비교 (🟢)
# "배송 대기(SHIPPED) 주문을 날짜순으로" — 파티션 키가 customer_id 인 테이블로는 Query 불가
# → 운영 중인 테이블에 GSI(status-index) 추가 → 백필 후 ACTIVE 까지 폴링 → GSI Query
# → GSI 의 제약(강력 일관 읽기 불가, 투영하지 않은 속성) → LSI(customer-total-index)로 "고객의 고액 주문"
# → 인덱스가 쓰기 비용에 미치는 영향
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

T=todayorder-m05-orders
ddb_delete_table "$T"
create_orders_table >/dev/null
load_orders

echo "== 1. 지금 테이블의 인덱스: LSI 하나 (테이블을 만들 때 정의했다)"
aws dynamodb describe-table --table-name "$T" --query 'Table.{
  LSI: LocalSecondaryIndexes[].{Name: IndexName, Keys: KeySchema[].AttributeName, Projection: Projection.ProjectionType},
  GSI: GlobalSecondaryIndexes}'

echo "== 2. GSI 추가: 파티션 키 status, 정렬 키 order_ts, customer_id·total 만 투영(INCLUDE)"
aws dynamodb update-table --table-name "$T" \
  --attribute-definitions AttributeName=status,AttributeType=S AttributeName=order_ts,AttributeType=S \
  --global-secondary-index-updates '[{"Create":{"IndexName":"status-index",
     "KeySchema":[{"AttributeName":"status","KeyType":"HASH"},{"AttributeName":"order_ts","KeyType":"RANGE"}],
     "Projection":{"ProjectionType":"INCLUDE","NonKeyAttributes":["customer_id","total"]}}}]' \
  --query 'TableDescription.{TableStatus: TableStatus, GSI: GlobalSecondaryIndexes[].{Name: IndexName, Status: IndexStatus}}'

echo "-- 인덱스가 ACTIVE 가 될 때까지 폴링 (table-exists waiter 는 인덱스 상태를 보지 않는다)"
poll_until 300 "status-index ACTIVE" bash -c \
  "[ \"\$(aws dynamodb describe-table --table-name $T --query 'Table.GlobalSecondaryIndexes[0].IndexStatus' --output text)\" = ACTIVE ]"
aws dynamodb describe-table --table-name "$T" --query 'Table.{TableStatus: TableStatus, GSI: GlobalSecondaryIndexes[].{Name: IndexName, Status: IndexStatus}}'

echo "== 3. GSI Query: 11월 1~9일의 SHIPPED 주문 (모든 고객)"
aws dynamodb query --table-name "$T" --index-name status-index \
  --key-condition-expression "#s = :s AND order_ts BETWEEN :from AND :to" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"SHIPPED"},":from":{"S":"2026-11-01"},":to":{"S":"2026-11-10"}}' \
  --return-consumed-capacity INDEXES \
  --query '{Count: Count, First3: Items[0:3].[customer_id.S, order_ts.S, total.N], Consumed: ConsumedCapacity}'
gsi_count="$(aws dynamodb query --table-name "$T" --index-name status-index \
  --key-condition-expression "#s = :s" --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"SHIPPED"}}' --query 'Count' --output json)"
echo "SHIPPED 주문 전체: $gsi_count 건 (백필 덕분에 GSI 를 만들기 전에 넣은 항목도 나온다)"

echo "== 4. GSI 에는 강력 일관 읽기가 없다"
expect_error ValidationException aws dynamodb query --table-name "$T" --index-name status-index \
  --key-condition-expression "#s = :s" --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"SHIPPED"}}' --consistent-read

echo "== 5. 투영하지 않은 속성(memo 등)까지 달라고 하면?"
expect_error ValidationException aws dynamodb query --table-name "$T" --index-name status-index \
  --key-condition-expression "#s = :s" --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"SHIPPED"}}' --select ALL_ATTRIBUTES

echo "== 6. LSI Query: 고객 c-003 의 주문 중 40,000원 이상 (같은 파티션 키, 다른 정렬 키)"
aws dynamodb query --table-name "$T" --index-name customer-total-index \
  --key-condition-expression "customer_id = :c AND #t >= :min" \
  --expression-attribute-names '{"#t":"total"}' \
  --expression-attribute-values '{":c":{"S":"c-003"},":min":{"N":"40000"}}' \
  --query '{Count: Count, Items: Items[].[total.N, order_ts.S]}'
lsi_count="$(aws dynamodb query --table-name "$T" --index-name customer-total-index \
  --key-condition-expression "customer_id = :c AND #t >= :min" --expression-attribute-names '{"#t":"total"}' \
  --expression-attribute-values '{":c":{"S":"c-003"},":min":{"N":"40000"}}' --query 'Count' --output json)"
echo "-- LSI 는 강력 일관 읽기가 된다"
aws dynamodb query --table-name "$T" --index-name customer-total-index --consistent-read \
  --key-condition-expression "customer_id = :c AND #t >= :min" --expression-attribute-names '{"#t":"total"}' \
  --expression-attribute-values '{":c":{"S":"c-003"},":min":{"N":"40000"}}' --query 'Count'

echo "== 7. 인덱스의 대가: 새 주문 1건 쓰기가 테이블 + 인덱스마다 WCU 를 쓴다"
aws dynamodb put-item --table-name "$T" --return-consumed-capacity INDEXES --item '{
  "customer_id":{"S":"c-011"},"order_ts":{"S":"2026-11-12T09:00:00Z#A-01101"},
  "order_id":{"S":"A-01101"},"status":{"S":"PAID"},"total":{"N":"15000"}}' \
  --query 'ConsumedCapacity'
echo "-- 같은 내용으로 한 번 더 덮어쓰면? (인덱스 키·투영 속성이 그대로라 인덱스 쓰기가 없다)"
aws dynamodb put-item --table-name "$T" --return-consumed-capacity INDEXES --item '{
  "customer_id":{"S":"c-011"},"order_ts":{"S":"2026-11-12T09:00:00Z#A-01101"},
  "order_id":{"S":"A-01101"},"status":{"S":"PAID"},"total":{"N":"15000"}}' \
  --query 'ConsumedCapacity.{Total: CapacityUnits, Table: Table.CapacityUnits, LSI: LocalSecondaryIndexes, GSI: GlobalSecondaryIndexes}'
put_cu="$(aws dynamodb put-item --table-name "$T" --return-consumed-capacity TOTAL --item '{
  "customer_id":{"S":"c-012"},"order_ts":{"S":"2026-11-12T10:00:00Z#A-01201"},
  "order_id":{"S":"A-01201"},"status":{"S":"PAID"},"total":{"N":"9000"}}' --query 'ConsumedCapacity.CapacityUnits' --output text)"

echo "== 8. 정리"
ddb_delete_table "$T"

# ---- 단언
[ "$gsi_count" = "40" ] || fail "SHIPPED 주문 수가 40이 아님: $gsi_count"
[ "$lsi_count" -ge 1 ] || fail "LSI 결과 없음"
[ "$put_cu" = "3.0" ] || fail "새 항목 쓰기 비용이 3.0(테이블+LSI+GSI)이 아님: $put_cu"
echo "LAB05 OK"
