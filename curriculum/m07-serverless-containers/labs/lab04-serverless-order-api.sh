#!/usr/bin/env bash
# M07 lab04 — 서버리스 주문 API: HTTP API + Lambda + DynamoDB (🟢)
# Lambda 안의 boto3 가 실행 역할의 권한으로 DynamoDB 를 호출한다. 권한이 없으면 실제로 AccessDenied 가 난다.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"
START_MS="$(now_ms)"

TABLE=todayorder-orders-api
FN=todayorder-order-api
ROLE=todayorder-order-api-role
API_NAME=todayorder-order-api
TABLE_ARN="arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TABLE"

echo "== 0. 이전 실행 정리 (API, 표)"
for id in $(aws apigatewayv2 get-apis --output json --query "Items[?Name=='$API_NAME'].ApiId" | tr -d '[]", ' | grep . || true); do
  aws apigatewayv2 delete-api --api-id "$id"
done
if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$TABLE" >/dev/null
  wait_dynamodb_table_gone "$TABLE"
fi

echo "== 1. DynamoDB 주문 표 (파티션 키 orderId, 온디맨드)"
aws dynamodb create-table --table-name "$TABLE" --attribute-definitions AttributeName=orderId,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH --billing-mode PAY_PER_REQUEST --query TableDescription.TableStatus --output text
wait_dynamodb_table_active "$TABLE"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)

echo "== 2. 실행 역할: 우선 로그 권한만 (DynamoDB 권한을 일부러 빠뜨린다)"
ensure_role "$ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role-policy --role-name "$ROLE" --policy-name orders-table-rw >/dev/null 2>&1 || true

echo "== 3. 함수 (환경 변수 TABLE_NAME) + HTTP API 라우트 2개"
fresh_function "$FN" "$MOD/functions/order_api.py" order_api.handler "arn:aws:iam::$ACCOUNT:role/$ROLE" \
  --timeout 10 --environment "Variables={TABLE_NAME=$TABLE}"
API="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --query ApiId --output text)"
INTEG="$(aws apigatewayv2 create-integration --api-id "$API" --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT:function:$FN" --payload-format-version 2.0 --query IntegrationId --output text)"
aws apigatewayv2 create-route --api-id "$API" --route-key 'POST /orders' --target "integrations/$INTEG" --query RouteKey --output text
aws apigatewayv2 create-route --api-id "$API" --route-key 'GET /orders/{orderId}' --target "integrations/$INTEG" --query RouteKey --output text
aws apigatewayv2 create-stage --api-id "$API" --stage-name '$default' --auto-deploy >/dev/null
# 실제 AWS 에서는 이 권한이 없으면 API Gateway 가 함수를 부르지 못한다(에뮬레이터의 HTTP API 는 검사하지 않음)
aws lambda add-permission --function-name "$FN" --statement-id http-api-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API/*/*/orders*" >/dev/null
B="$(api_base "$API")"
echo "API: $B   (실제 AWS: https://$API.execute-api.$REGION.amazonaws.com)"

ORDER='{"orderId":"A-4001","customerId":"C-77","total":32000}'
echo "== 4. 주문 생성 — 실행 역할에 DynamoDB 권한이 없다"
call POST "$B/orders" -H 'content-type: application/json' -d "$ORDER" | tee "$WORK/denied"
denied_log() { log_lines "$FN" '"AccessDeniedException"' "$START_MS" | grep -q .; }
poll 30 "AccessDenied 로그" denied_log
echo "-- 함수 로그:"
log_lines "$FN" '"AccessDeniedException"' "$START_MS" | head -1 | cut -c1-260

echo "== 5. 최소 권한 정책: 이 표에 PutItem·GetItem 만"
aws iam put-role-policy --role-name "$ROLE" --policy-name orders-table-rw --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\"],\"Resource\":\"$TABLE_ARN\"}]}"
created() { call POST "$B/orders" -H 'content-type: application/json' -d "$ORDER" >"$WORK/created"; grep -q 'HTTP 201' "$WORK/created"; }
poll 60 "권한 반영 후 201" created   # 실제 AWS 에서는 IAM 변경이 반영되는 데 몇 초 걸릴 수 있다
cat "$WORK/created"

echo "== 6. 같은 주문을 다시 POST (클라이언트 재시도) → 409, 표에는 1건"
call POST "$B/orders" -H 'content-type: application/json' -d "$ORDER" | tee "$WORK/dup"

echo "== 7. 잘못된 요청 → 400"
call POST "$B/orders" -H 'content-type: application/json' -d '{"orderId":"A-4002"}' | tee "$WORK/bad"

echo "== 8. 조회 → 200 / 없는 주문 → 404"
call GET "$B/orders/A-4001" | tee "$WORK/get"
call GET "$B/orders/A-9999" | tee "$WORK/missing"

echo "== 9. DynamoDB 에 실제로 저장됐나 (CLI 로 직접 확인)"
aws dynamodb get-item --table-name "$TABLE" --key '{"orderId":{"S":"A-4001"}}' \
  --query 'Item.{orderId: orderId.S, customerId: customerId.S, total: total.N, status: status.S}'
count="$(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text)"
echo "표의 항목 수: $count"

# ---- 단언
grep -q 'HTTP 500' "$WORK/denied" || fail "권한 없을 때 500 이 아님"
grep -q 'HTTP 409' "$WORK/dup" || fail "중복 생성이 409 가 아님"
grep -q 'HTTP 400' "$WORK/bad" || fail "잘못된 요청이 400 이 아님"
grep -q '"total": 32000' "$WORK/get" && grep -q 'HTTP 200' "$WORK/get" || fail "조회"
grep -q 'HTTP 404' "$WORK/missing" || fail "없는 주문이 404 가 아님"
[ "$count" = 1 ] || fail "표 항목 수: $count"
echo "LAB04 OK"
