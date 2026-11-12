#!/usr/bin/env bash
# M07 lab01 — Lambda 함수 생성·구성·버전·별칭과 Invoke (동기/비동기/DryRun, 오류 응답, 타임아웃) (🟢)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"

FN=todayorder-order-status
FN_NOLOG=todayorder-order-status-nolog
ROLE=todayorder-lambda-basic-role
ROLE_NOLOG=todayorder-lambda-nolog-role

echo "== 1. 실행 역할 2개: 하나는 CloudWatch Logs 권한(AWSLambdaBasicExecutionRole) 있음, 하나는 없음"
ensure_role "$ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
ensure_role "$ROLE_NOLOG" lambda.amazonaws.com
aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyName' --output text

echo "== 2. 함수 만들기 (python3.12, 128MB, 타임아웃 3초 = 기본값)"
aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
zip_function "$MOD/functions/order_status.py" "$WORK/fn.zip"
aws lambda create-function --function-name "$FN" --runtime python3.12 --handler order_status.handler \
  --role "arn:aws:iam::$ACCOUNT:role/$ROLE" --zip-file "fileb://$WORK/fn.zip" \
  --query '{State: State, Runtime: Runtime, Memory: MemorySize, Timeout: Timeout, Handler: Handler}'
aws lambda wait function-active-v2 --function-name "$FN"
aws lambda get-function --function-name "$FN" --query 'Configuration.State' --output text

echo "== 3. 동기 호출 (RequestResponse — 기본값)"
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"A-1001"}' "$WORK/out.json"
cat "$WORK/out.json"; echo

echo "== 4. 핸들러가 예외를 던지면? — HTTP 200 이지만 FunctionError 가 붙는다"
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out --payload '{}' "$WORK/err.json"
cat "$WORK/err.json"; echo
ferr="$(aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out --payload '{}' \
  --query FunctionError --output text "$WORK/err2.json")"

echo "== 5. 비동기 호출 (Event) → 202, DryRun → 204 (실행 없이 권한·파라미터만 확인)"
aws lambda invoke --function-name "$FN" --invocation-type Event --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"A-1002"}' "$WORK/ev.json"
aws lambda invoke --function-name "$FN" --invocation-type DryRun --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"A-1003"}' "$WORK/dry.json"

echo "== 6. 구성 변경: 환경 변수, 메모리 256MB, 타임아웃 2초"
aws lambda update-function-configuration --function-name "$FN" --memory-size 256 --timeout 2 \
  --environment 'Variables={APP_VERSION=1.0}' --query '{Memory: MemorySize, Timeout: Timeout, Env: Environment.Variables}'
aws lambda wait function-updated-v2 --function-name "$FN"
echo "-- 타임아웃 901초는 거부된다 (최대 900초 = 15분)"
if aws lambda update-function-configuration --function-name "$FN" --timeout 901 >/dev/null 2>"$WORK/e"; then fail "901초가 허용됨"; fi
cat "$WORK/e"

echo "== 7. 타임아웃(2초)보다 오래 걸리면? (3초 잠자기)"
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"A-1004","sleepSeconds":3}' "$WORK/to.json"
cat "$WORK/to.json"; echo
to_type="$(grep -o '"errorType":"[^"]*"' "$WORK/to.json")"

echo "== 8. 버전 발행: 지금 코드+구성을 v1 으로 고정 → APP_VERSION=2.0 으로 바꿔 v2 발행"
v1="$(aws lambda publish-version --function-name "$FN" --description "first release" --query Version --output text)"
aws lambda update-function-configuration --function-name "$FN" --environment 'Variables={APP_VERSION=2.0}' >/dev/null
aws lambda wait function-updated-v2 --function-name "$FN"
v2="$(aws lambda publish-version --function-name "$FN" --description "new status logic" --query Version --output text)"
aws lambda list-versions-by-function --function-name "$FN" --query 'Versions[].{Version: Version, AppVersion: Environment.Variables.APP_VERSION}' --output table

echo "== 9. 별칭 live → v1 (90%) + v2 (10%) — 카나리 배포"
aws lambda create-alias --function-name "$FN" --name live --function-version "$v1" \
  --routing-config "{\"AdditionalVersionWeights\":{\"$v2\":0.1}}" \
  --query '{Alias: Name, Version: FunctionVersion, Routing: RoutingConfig}'
echo "-- 별칭으로 20번 호출해 실행된 버전 세기 (비율은 단언하지 않는다)"
for _ in $(seq 1 20); do
  aws lambda invoke --function-name "$FN" --qualifier live --cli-binary-format raw-in-base64-out \
    --payload '{"orderId":"A-1005"}' --query ExecutedVersion --output text "$WORK/a.json"
done | sort | uniq -c
echo "-- 검증이 끝났다고 치고 live 를 v2 100% 로 승격"
aws lambda update-alias --function-name "$FN" --name live --function-version "$v2" --routing-config '{}' \
  --query '{Alias: Name, Version: FunctionVersion}'
aws lambda invoke --function-name "$FN" --qualifier live --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"A-1006"}' "$WORK/live.json" >/dev/null
cat "$WORK/live.json"; echo
live_ver="$(grep -o '"appVersion": *"[^"]*"' "$WORK/live.json")"

echo "== 10. 예약 동시성 5 — 이 함수가 계정 동시성을 최대 5까지만 쓰게 (다른 함수 보호)"
aws lambda put-function-concurrency --function-name "$FN" --reserved-concurrent-executions 5
aws lambda get-account-settings --query 'AccountLimit.{ConcurrentExecutions: ConcurrentExecutions, UnreservedConcurrentExecutions: UnreservedConcurrentExecutions}'

echo "== 11. 로그: logs 권한이 없는 역할로 만든 함수는 로그 그룹이 생기지 않는다"
fresh_function "$FN_NOLOG" "$MOD/functions/order_status.py" order_status.handler "arn:aws:iam::$ACCOUNT:role/$ROLE_NOLOG" >/dev/null
aws lambda invoke --function-name "$FN_NOLOG" --cli-binary-format raw-in-base64-out --payload '{"orderId":"A-1007"}' "$WORK/n.json" >/dev/null
poll 30 "로그 그룹 생성($FN)" has_log_group "$FN"
echo "$FN 로그 그룹: $(has_log_group "$FN" && echo 있음 || echo 없음)"
echo "$FN_NOLOG 로그 그룹: $(has_log_group "$FN_NOLOG" && echo 있음 || echo 없음)"
echo "-- $FN 의 로그 한 토막 (START / print 출력 / END / REPORT):"
aws logs filter-log-events --log-group-name "/aws/lambda/$FN" --limit 4 --query 'events[].message' --output text | tr '\t' '\n' | cut -c1-150

# ---- 단언
grep -q '"status": "PAID"' "$WORK/out.json" || fail "동기 호출 결과"
[ "$ferr" = Unhandled ] || fail "FunctionError: $ferr"
grep -q Timedout <<<"$to_type" || fail "타임아웃 오류 유형: $to_type"
[ "$live_ver" = '"appVersion": "2.0"' ] || fail "승격 후 live 버전: $live_ver"
has_log_group "$FN_NOLOG" && fail "logs 권한 없는 함수에 로그 그룹이 생김"
echo "LAB01 OK"
