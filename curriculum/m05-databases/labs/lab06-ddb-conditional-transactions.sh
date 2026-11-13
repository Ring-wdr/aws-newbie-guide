#!/usr/bin/env bash
# M05 lab06 — 조건부 쓰기로 재고 차감, 트랜잭션으로 "주문 생성 + 재고 차감" 원자화 (🟢)
# 원자적 감소(SET stock = stock - :q) + 조건(stock >= :q) → 재고 부족이면 ConditionalCheckFailedException
# → attribute_not_exists 로 같은 주문의 중복 생성 막기 → TransactWriteItems 성공/전체 취소
# → ClientRequestToken 으로 재시도를 안전하게(멱등). 동시성 시연은 sdk/stock_concurrency.py
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

P=todayorder-m05-products
O=todayorder-m05-order-ledger
ddb_delete_table "$P"
ddb_delete_table "$O"

aws dynamodb create-table --table-name "$P" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=product_id,AttributeType=S \
  --key-schema AttributeName=product_id,KeyType=HASH --query 'TableDescription.TableStatus'
aws dynamodb create-table --table-name "$O" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=order_id,AttributeType=S \
  --key-schema AttributeName=order_id,KeyType=HASH --query 'TableDescription.TableStatus'
wait_dynamodb_table_active "$P"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
wait_dynamodb_table_active "$O"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)

stock() {
  aws dynamodb get-item --table-name "$P" --key '{"product_id":{"S":"P-100"}}' --consistent-read \
    --query 'Item.stock.N' --output text
}

echo "== 1. 상품 P-100 (한정판 텀블러) 재고 3개"
aws dynamodb put-item --table-name "$P" --item '{"product_id":{"S":"P-100"},"name":{"S":"limited tumbler"},"stock":{"N":"3"}}'
echo "stock=$(stock)"

echo "== 2. 조건부 차감: 2개 주문 (조건 stock >= 2 를 만족 → 성공)"
aws dynamodb update-item --table-name "$P" --key '{"product_id":{"S":"P-100"}}' \
  --update-expression "SET stock = stock - :q" --condition-expression "stock >= :q" \
  --expression-attribute-values '{":q":{"N":"2"}}' --return-values UPDATED_NEW \
  --query 'Attributes'

echo "== 3. 한 번 더 2개 주문 (남은 재고 1 → 조건 실패, 아무것도 바뀌지 않는다)"
expect_error ConditionalCheckFailedException aws dynamodb update-item --cli-error-format json --table-name "$P" \
  --key '{"product_id":{"S":"P-100"}}' \
  --update-expression "SET stock = stock - :q" --condition-expression "stock >= :q" \
  --expression-attribute-values '{":q":{"N":"2"}}' \
  --return-values-on-condition-check-failure ALL_OLD
after_fail="$(stock)"
echo "stock=$after_fail"

echo "== 4. 같은 주문번호로 두 번 생성 막기 (attribute_not_exists)"
aws dynamodb put-item --table-name "$O" --condition-expression "attribute_not_exists(order_id)" \
  --item '{"order_id":{"S":"A-5001"},"customer_id":{"S":"c-001"},"status":{"S":"PLACED"}}'
echo "첫 번째 생성 성공"
expect_error ConditionalCheckFailedException aws dynamodb put-item --table-name "$O" \
  --condition-expression "attribute_not_exists(order_id)" \
  --item '{"order_id":{"S":"A-5001"},"customer_id":{"S":"c-001"},"status":{"S":"PLACED"}}'

# 멱등 토큰은 약 10분 동안 기억된다(테이블을 지웠다 다시 만들어도). 다시 실행해도 겹치지 않게 실행마다 새 토큰.
TOKEN="tok-A-5002-$(date +%s)"
echo "== 5. 트랜잭션: 주문 A-5002 생성 + 재고 1 차감을 한 번에 (둘 다 되거나 둘 다 안 되거나)"
tx_items() { # $1=주문번호 $2=수량
  cat <<EOF
[
  {"Put": {"TableName": "$O",
           "Item": {"order_id": {"S": "$1"}, "customer_id": {"S": "c-002"}, "status": {"S": "PLACED"}, "qty": {"N": "$2"}},
           "ConditionExpression": "attribute_not_exists(order_id)"}},
  {"Update": {"TableName": "$P", "Key": {"product_id": {"S": "P-100"}},
              "UpdateExpression": "SET stock = stock - :q",
              "ConditionExpression": "stock >= :q",
              "ExpressionAttributeValues": {":q": {"N": "$2"}}}}
]
EOF
}
aws dynamodb transact-write-items --transact-items "$(tx_items A-5002 1)" \
  --client-request-token "$TOKEN" --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity[].{Table: TableName, WCU: WriteCapacityUnits}'
echo "stock=$(stock)  A-5002=$(aws dynamodb get-item --table-name "$O" --key '{"order_id":{"S":"A-5002"}}' --query 'Item.status.S' --output text)"

echo "== 6. 같은 요청을 같은 토큰으로 재시도 (네트워크 타임아웃 뒤 재시도 상황) → 성공 응답, 두 번 차감되지 않음"
aws dynamodb transact-write-items --transact-items "$(tx_items A-5002 1)" \
  --client-request-token "$TOKEN" --return-consumed-capacity TOTAL \
  --query 'ConsumedCapacity[].{Table: TableName, RCU: ReadCapacityUnits, WCU: WriteCapacityUnits}'
after_retry="$(stock)"
echo "stock=$after_retry"

echo "== 7. 같은 토큰에 다른 내용을 실으면 거부"
expect_error IdempotentParameterMismatchException aws dynamodb transact-write-items \
  --transact-items "$(tx_items A-5003 1)" --client-request-token "$TOKEN"

echo "== 8. 재고가 0인데 주문 A-5004: 재고 조건이 실패하면 주문 Put 까지 전부 취소"
expect_error TransactionCanceledException aws dynamodb transact-write-items --cli-error-format json --transact-items "$(tx_items A-5004 1)"
a5004="$(aws dynamodb get-item --table-name "$O" --key '{"order_id":{"S":"A-5004"}}' --query 'Item.order_id.S' --output text)"
echo "A-5004 주문 항목: $a5004 (None 이면 없음 = 원자성)"

echo "== 9. TransactGetItems: 주문과 재고를 같은 시점의 값으로 함께 읽기"
aws dynamodb transact-get-items --transact-items "[
  {\"Get\": {\"TableName\": \"$O\", \"Key\": {\"order_id\": {\"S\": \"A-5002\"}}}},
  {\"Get\": {\"TableName\": \"$P\", \"Key\": {\"product_id\": {\"S\": \"P-100\"}}, \"ProjectionExpression\": \"stock\"}}]" \
  --query 'Responses[].Item'

echo "== 10. 정리"
ddb_delete_table "$P"
ddb_delete_table "$O"

# ---- 단언
[ "$after_fail" = "1" ] || fail "조건 실패 후 재고가 1이 아님: $after_fail"
[ "$after_retry" = "0" ] || fail "멱등 재시도 후 재고가 0이 아님: $after_retry"
[ "$a5004" = "None" ] || fail "취소된 트랜잭션의 주문이 남음: $a5004"
echo "LAB06 OK"
