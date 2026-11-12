#!/usr/bin/env bash
# M06 lab06 — Step Functions 주문 워크플로 (🟢)
# Choice/Fail, Lambda Task 의 Retry/Catch, SQS 서비스 통합(sqs:sendMessage), 실행 역할 권한 검사,
# EXPRESS 워크플로의 동기 실행(StartSyncExecution)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m06-integration-messaging"

SM=todayorder-order-workflow
QUOTE_SM=todayorder-shipping-quote
SFN_ROLE=todayorder-sfn-order-role
FN=todayorder-payment
FN_ROLE=todayorder-payment-fn-role
Q=todayorder-shipping-requests

echo "== 1. 결제 Lambda (재료) 와 배송 요청 큐"
ensure_role "$FN_ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$FN_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fresh_function "$FN" "$MOD/functions/payment.py" payment.handler "arn:aws:iam::$ACCOUNT:role/$FN_ROLE"
URL="$(fresh_queue "$Q")"

echo "== 2. Step Functions 실행 역할: 처음에는 Lambda 호출 권한만 준다 (SQS 권한 빠뜨림)"
ensure_role "$SFN_ROLE" states.amazonaws.com
aws iam delete-role-policy --role-name "$SFN_ROLE" --policy-name order-workflow >/dev/null 2>&1 || true
aws iam put-role-policy --role-name "$SFN_ROLE" --policy-name order-workflow --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"arn:aws:lambda:$REGION:$ACCOUNT:function:$FN*\"}]}"

echo "== 3. 상태 머신 정의 (Amazon States Language)"
cat >"$WORK/definition.json" <<JSON
{
  "Comment": "TodayOrder 주문 처리: 검증 → 결제(재시도/예외 처리) → 배송 요청",
  "StartAt": "ValidateOrder",
  "States": {
    "ValidateOrder": {
      "Type": "Choice",
      "Choices": [
        {"Variable": "\$.total", "NumericGreaterThan": 0, "Next": "ChargePayment"}
      ],
      "Default": "RejectOrder"
    },
    "RejectOrder": {"Type": "Fail", "Error": "InvalidOrder", "Cause": "total must be positive"},
    "ChargePayment": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {"FunctionName": "$FN", "Payload.\$": "\$"},
      "ResultSelector": {"approvalNo.\$": "\$.Payload.approvalNo"},
      "ResultPath": "\$.payment",
      "Retry": [
        {"ErrorEquals": ["GatewayTimeout"], "IntervalSeconds": 1, "MaxAttempts": 2, "BackoffRate": 2.0}
      ],
      "Catch": [
        {"ErrorEquals": ["PaymentDeclined"], "ResultPath": "\$.error", "Next": "MarkDeclined"},
        {"ErrorEquals": ["States.ALL"], "ResultPath": "\$.error", "Next": "PaymentUnavailable"}
      ],
      "Next": "RequestShipping"
    },
    "MarkDeclined": {"Type": "Pass", "Result": "DECLINED", "ResultPath": "\$.status", "End": true},
    "PaymentUnavailable": {"Type": "Fail", "Error": "PaymentUnavailable", "Cause": "payment gateway kept failing"},
    "RequestShipping": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage",
      "Parameters": {"QueueUrl": "$URL", "MessageBody.\$": "\$"},
      "ResultPath": null,
      "Next": "Done"
    },
    "Done": {"Type": "Succeed"}
  }
}
JSON
SM_ARN="arn:aws:states:$REGION:$ACCOUNT:stateMachine:$SM"
aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1 || true
gone() { ! aws stepfunctions describe-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1; }
poll 60 "이전 상태 머신 삭제" gone
aws stepfunctions create-state-machine --name "$SM" --type STANDARD --definition "file://$WORK/definition.json" \
  --role-arn "arn:aws:iam::$ACCOUNT:role/$SFN_ROLE" --query stateMachineArn --output text

# run <실행 이름 접두사> <입력 JSON> — 실행을 시작하고 끝날 때까지 기다린 뒤 실행 ARN 을 출력
run() {
  local arn status
  arn="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "$1-$RANDOM$RANDOM" --input "$2" \
    --query executionArn --output text)"
  finished() {
    status="$(aws stepfunctions describe-execution --execution-arn "$arn" --query status --output text)"
    [ "$status" != RUNNING ]
  }
  poll 120 "실행 종료" finished >&2
  echo "$arn"
}
show() { aws stepfunctions describe-execution --execution-arn "$1" --query '{status: status, error: error, cause: cause, output: output}'; }
history() { aws stepfunctions get-execution-history --execution-arn "$1" --query 'events[].type' --output text | tr '\t' '\n' | paste -sd' ' -; }

echo "== 4. 정상 주문 → 배송 요청 단계에서 실패한다 (역할에 sqs:SendMessage 없음)"
E1="$(run normal '{"orderId":"A-6001","total":32000,"paymentScenario":"ok"}')"
aws stepfunctions describe-execution --execution-arn "$E1" --query '{status: status, error: error}'
aws stepfunctions describe-execution --execution-arn "$E1" --query cause --output text | cut -c1-160
s1="$(aws stepfunctions describe-execution --execution-arn "$E1" --query status --output text)"

echo "== 5. 역할에 sqs:SendMessage 추가 → 다시 실행하면 성공, 큐에 배송 요청이 들어온다"
aws iam put-role-policy --role-name "$SFN_ROLE" --policy-name order-workflow --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"arn:aws:lambda:$REGION:$ACCOUNT:function:$FN*\"},{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$(queue_arn "$Q")\"}]}"
E2="$(run normal '{"orderId":"A-6001","total":32000,"paymentScenario":"ok"}')"
show "$E2"
arrived() { [ "$(visible_count "$URL")" -ge 1 ]; }
poll 30 "배송 요청 도착" arrived
echo "배송 요청 큐: $(aws sqs receive-message --queue-url "$URL" --query 'Messages[0].Body' --output text)"
s2="$(aws stepfunctions describe-execution --execution-arn "$E2" --query status --output text)"

echo "== 6. 금액 0원 주문 → Choice 가 RejectOrder(Fail)로 보낸다"
E3="$(run invalid '{"orderId":"A-6002","total":0,"paymentScenario":"ok"}')"
show "$E3"
e3="$(aws stepfunctions describe-execution --execution-arn "$E3" --query error --output text)"

echo "== 7. 카드 거절 → 재시도 없이 Catch 가 MarkDeclined 로 보낸다 (업무 결과로 정상 종료)"
E4="$(run declined '{"orderId":"A-6003","total":15000,"paymentScenario":"declined"}')"
aws stepfunctions describe-execution --execution-arn "$E4" --query status --output text
aws stepfunctions describe-execution --execution-arn "$E4" --query output --output text \
  | uv run --quiet --project "$ROOT" python -c 'import json,sys; o=json.load(sys.stdin); print(json.dumps({"status": o["status"], "error": o["error"]["Error"]}))'
echo "이벤트: $(history "$E4")"
s4="$(aws stepfunctions describe-execution --execution-arn "$E4" --query status --output text)"

echo "== 8. PG 장애 → Retry 로 2번 더 시도(총 3번) 후 Catch(States.ALL) → PaymentUnavailable(Fail)"
E5="$(run pgdown '{"orderId":"A-6004","total":15000,"paymentScenario":"pg-down"}')"
show "$E5"
echo "이벤트: $(history "$E5")"
attempts="$(aws stepfunctions get-execution-history --execution-arn "$E5" --query 'length(events[?type==`TaskFailed`])' --output text)"
echo "TaskFailed 이벤트 수(= 시도 횟수): $attempts"
e5="$(aws stepfunctions describe-execution --execution-arn "$E5" --query error --output text)"

echo "== 9. EXPRESS 워크플로: 배송비 견적을 동기로 계산 (start-sync-execution)"
QUOTE_ARN="arn:aws:states:$REGION:$ACCOUNT:stateMachine:$QUOTE_SM"
aws stepfunctions delete-state-machine --state-machine-arn "$QUOTE_ARN" >/dev/null 2>&1 || true
gone_q() { ! aws stepfunctions describe-state-machine --state-machine-arn "$QUOTE_ARN" >/dev/null 2>&1; }
poll 60 "이전 견적 상태 머신 삭제" gone_q
cat >"$WORK/quote.json" <<'JSON'
{"StartAt": "Quote", "States": {
  "Quote": {"Type": "Choice", "Choices": [
      {"Variable": "$.total", "NumericGreaterThanEquals": 50000, "Next": "Free"}], "Default": "Paid"},
  "Free": {"Type": "Pass", "Result": {"shippingFee": 0}, "End": true},
  "Paid": {"Type": "Pass", "Result": {"shippingFee": 3000}, "End": true}}}
JSON
aws stepfunctions create-state-machine --name "$QUOTE_SM" --type EXPRESS --definition "file://$WORK/quote.json" \
  --role-arn "arn:aws:iam::$ACCOUNT:role/$SFN_ROLE" --query stateMachineArn --output text
aws stepfunctions start-sync-execution --state-machine-arn "$QUOTE_ARN" --input '{"total":32000}' --query '{status: status, output: output}'
q="$(aws stepfunctions start-sync-execution --state-machine-arn "$QUOTE_ARN" --input '{"total":72000}' --query output --output text)"
echo "72000원 주문의 견적: $q"

# ---- 단언
[ "$s1" = FAILED ] || fail "SQS 권한 없는 실행이 FAILED 가 아님: $s1"
[ "$s2" = SUCCEEDED ] || fail "정상 실행이 SUCCEEDED 가 아님: $s2"
[ "$e3" = InvalidOrder ] || fail "0원 주문 오류: $e3"
[ "$s4" = SUCCEEDED ] || fail "거절 주문은 Catch 로 정상 종료돼야 함: $s4"
[ "$attempts" = 3 ] || fail "재시도 포함 시도 횟수가 3이 아님: $attempts"
[ "$e5" = PaymentUnavailable ] || fail "PG 장애 오류: $e5"
[ "$q" = '{"shippingFee":0}' ] || fail "견적 결과: $q"
echo "LAB06 OK"
