#!/usr/bin/env bash
# M07 lab03 — API Gateway: REST API(MOCK 통합 + Lambda 프록시)와 HTTP API(Lambda 프록시)를 HTTPS 로 실제 호출 (🟢)
# 호출 주소(에뮬레이터 전용): https://127.0.0.1:$EMULATOR_PORT/_aws/execute-api/<apiId>/<stage>/<path>
#   HTTP API 의 $default 스테이지는 스테이지 경로가 없다: .../_aws/execute-api/<apiId>/<path>
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"

FN=todayorder-api-echo
ROLE=todayorder-api-echo-role
REST_NAME=todayorder-rest-api
HTTP_NAME=todayorder-http-api

echo "== 0. 이전 실행의 API 지우기 (이름으로 찾기 — 목록은 --output json 으로 받아 가공)"
for id in $(aws apigateway get-rest-apis --output json --query "items[?name=='$REST_NAME'].id" | tr -d '[]", ' | grep . || true); do
  aws apigateway delete-rest-api --rest-api-id "$id"
done
for id in $(aws apigatewayv2 get-apis --output json --query "Items[?Name=='$HTTP_NAME'].ApiId" | tr -d '[]", ' | grep . || true); do
  aws apigatewayv2 delete-api --api-id "$id"
done

echo "== 1. 백엔드 Lambda"
ensure_role "$ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fresh_function "$FN" "$MOD/functions/api_echo.py" api_echo.handler "arn:aws:iam::$ACCOUNT:role/$ROLE"
FN_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FN"

echo "== 2. REST API: /health (MOCK 통합 — 백엔드 없이 API Gateway 가 직접 응답)"
REST="$(aws apigateway create-rest-api --name "$REST_NAME" --endpoint-configuration types=REGIONAL --query id --output text)"
ROOT_ID="$(aws apigateway get-resources --rest-api-id "$REST" --no-paginate --query 'items[0].id' --output text)"
HEALTH="$(aws apigateway create-resource --rest-api-id "$REST" --parent-id "$ROOT_ID" --path-part health --query id --output text)"
aws apigateway put-method --rest-api-id "$REST" --resource-id "$HEALTH" --http-method GET --authorization-type NONE >/dev/null
aws apigateway put-integration --rest-api-id "$REST" --resource-id "$HEALTH" --http-method GET --type MOCK \
  --request-templates '{"application/json":"{\"statusCode\": 200}"}' >/dev/null
aws apigateway put-method-response --rest-api-id "$REST" --resource-id "$HEALTH" --http-method GET --status-code 200 >/dev/null
aws apigateway put-integration-response --rest-api-id "$REST" --resource-id "$HEALTH" --http-method GET --status-code 200 \
  --response-templates '{"application/json":"{\"status\":\"ok\",\"service\":\"todayorder\"}"}' >/dev/null

echo "== 3. REST API: /orders/{orderId} (AWS_PROXY → Lambda)"
ORDERS="$(aws apigateway create-resource --rest-api-id "$REST" --parent-id "$ROOT_ID" --path-part orders --query id --output text)"
ORDER="$(aws apigateway create-resource --rest-api-id "$REST" --parent-id "$ORDERS" --path-part '{orderId}' --query id --output text)"
aws apigateway put-method --rest-api-id "$REST" --resource-id "$ORDER" --http-method GET --authorization-type NONE >/dev/null
aws apigateway put-integration --rest-api-id "$REST" --resource-id "$ORDER" --http-method GET --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$FN_ARN/invocations" >/dev/null
aws apigateway get-resources --rest-api-id "$REST" --no-paginate --query 'items[].path' --output text | tr '\t' '\n' | sort

echo "== 4. 배포 → 스테이지 dev"
aws apigateway create-deployment --rest-api-id "$REST" --stage-name dev --description "first deploy" --query id --output text >/dev/null
RB="$(api_base "$REST")/dev"
echo "REST 기본 주소: $RB   (실제 AWS: https://$REST.execute-api.$REGION.amazonaws.com/dev)"
call GET "$RB/health" | tee "$WORK/health"

echo "== 5. Lambda 리소스 정책(add-permission) 없이 /orders/A-3001 호출"
call GET "$RB/orders/A-3001" | tee "$WORK/noperm"
echo "-- 에뮬레이터 로그에 남은 이유:"
docker logs "aws-emulator-$EMULATOR_PORT" 2>&1 | grep -o '"reason":"the AWS_PROXY integration[^"]*"' | tail -1 || true

echo "== 6. add-permission: apigateway.amazonaws.com 이 이 API 의 GET /orders/* 에서만 함수를 호출하도록 허용"
aws lambda add-permission --function-name "$FN" --statement-id rest-get-order --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$REST/*/GET/orders/*" \
  --query Statement --output text | uv run --quiet --project "$ROOT" python -m json.tool
call GET "$RB/orders/A-3001" | tee "$WORK/rest"

echo "== 7. 스테이지 설정: 스로틀링(초당 100건, 버스트 200)"
aws apigateway update-stage --rest-api-id "$REST" --stage-name dev --patch-operations \
  op=replace,path=/*/*/throttling/rateLimit,value=100 op=replace,path=/*/*/throttling/burstLimit,value=200 \
  --query 'methodSettings."*/*".{Rate: throttlingRateLimit, Burst: throttlingBurstLimit}'

echo "== 8. HTTP API: GET /orders/{orderId} → 같은 Lambda (페이로드 2.0), \$default 스테이지 자동 배포"
HTTP="$(aws apigatewayv2 create-api --name "$HTTP_NAME" --protocol-type HTTP --query ApiId --output text)"
INTEG="$(aws apigatewayv2 create-integration --api-id "$HTTP" --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
  --payload-format-version 2.0 --query IntegrationId --output text)"
aws apigatewayv2 create-route --api-id "$HTTP" --route-key 'GET /orders/{orderId}' --target "integrations/$INTEG" --query RouteKey --output text
aws apigatewayv2 create-stage --api-id "$HTTP" --stage-name '$default' --auto-deploy --query StageName --output text
# 실제 AWS 에 필요한 권한. (이 에뮬레이터의 HTTP API 는 이 권한 없이도 함수를 호출한다 — 그래도 넣는다)
aws lambda add-permission --function-name "$FN" --statement-id http-get-order --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$HTTP/*/*/orders/*" >/dev/null
aws apigatewayv2 get-api --api-id "$HTTP" --query ApiEndpoint --output text
HB="$(api_base "$HTTP")"
call GET "$HB/orders/A-3002" | tee "$WORK/http"
echo "-- 없는 경로"
call GET "$HB/nope" | tee "$WORK/nope"

# ---- 단언
grep -q '"status":"ok"' "$WORK/health" || fail "MOCK 응답"
grep -q 'HTTP 500' "$WORK/noperm" || fail "권한 없는 REST 프록시 호출이 500 이 아님"
grep -q '"api": "REST API (payload 1.0)"' "$WORK/rest" && grep -q 'HTTP 200' "$WORK/rest" || fail "REST 프록시"
grep -q '"orderId": "A-3001"' "$WORK/rest" || fail "REST 경로 파라미터"
grep -q '"api": "HTTP API (payload 2.0)"' "$WORK/http" && grep -q '"orderId": "A-3002"' "$WORK/http" || fail "HTTP API 프록시"
grep -q 'HTTP 404' "$WORK/nope" || fail "없는 경로가 404 가 아님"
echo "LAB03 OK"
