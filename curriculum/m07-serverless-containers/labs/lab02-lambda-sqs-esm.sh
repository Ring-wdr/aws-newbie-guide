#!/usr/bin/env bash
# M07 lab02 — 이벤트 소스 매핑(SQS → Lambda): 큐 메시지를 Lambda 가 실제로 소비한다 (🟢)
# + 부분 배치 실패(ReportBatchItemFailures)와 DLQ, 비동기 호출의 실패 대상(destination) 구성(구성만, 🟡)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"

FN=todayorder-settlement-consumer
ROLE=todayorder-settlement-consumer-role
Q=todayorder-settlement-jobs
DLQ=todayorder-settlement-jobs-dlq
FAILQ=todayorder-async-failures

START_MS="$(now_ms)"

echo "== 1. 역할: SQS 에서 읽고 지울 권한 + 로그 권한 (폴링하는 주체는 Lambda 서비스지만, 함수의 실행 역할로 한다)"
ensure_role "$ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name "$ROLE" --policy-name consume-settlement-jobs --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$(queue_arn "$Q")\"},{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$(queue_arn "$FAILQ")\"}]}"

echo "== 2. 이전 실행의 매핑을 지우고, 함수(타임아웃 5초)와 큐를 새로 만든다"
for u in $(aws lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  aws lambda delete-event-source-mapping --uuid "$u" >/dev/null
done
fresh_function "$FN" "$MOD/functions/settlement_consumer.py" settlement_consumer.handler "arn:aws:iam::$ACCOUNT:role/$ROLE" --timeout 5
DLQ_URL="$(fresh_queue "$DLQ")"
URL="$(fresh_queue "$Q" "{\"VisibilityTimeout\":\"3\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$(queue_arn "$DLQ")\\\",\\\"maxReceiveCount\\\":\\\"2\\\"}\"}")"

echo "== 3. 큐 가시성 타임아웃(3초) < 함수 타임아웃(5초) 이면 매핑을 거부한다"
if aws lambda create-event-source-mapping --function-name "$FN" --event-source-arn "$(queue_arn "$Q")" >/dev/null 2>"$WORK/e"; then
  fail "가시성 타임아웃이 짧은데도 매핑이 만들어짐"
fi
cat "$WORK/e"

echo "== 4. 가시성 타임아웃을 10초로 늘리고 매핑 생성 (배치 10, 부분 배치 실패 보고 켬)"
aws sqs set-queue-attributes --queue-url "$URL" --attributes VisibilityTimeout=10
UUID="$(aws lambda create-event-source-mapping --function-name "$FN" --event-source-arn "$(queue_arn "$Q")" \
  --batch-size 10 --function-response-types ReportBatchItemFailures --query UUID --output text)"
enabled() { [ "$(aws lambda get-event-source-mapping --uuid "$UUID" --query State --output text)" = Enabled ]; }
poll 60 "매핑 Enabled" enabled
aws lambda get-event-source-mapping --uuid "$UUID" \
  --query '{State: State, BatchSize: BatchSize, Source: EventSourceArn, ResponseTypes: FunctionResponseTypes}'

echo "== 5. 정산 작업 4건(그중 1건은 통화 코드 오류)을 큐에 넣는다 — 워커 코드는 없다, Lambda 가 가져간다"
for o in '{"orderId":"A-2101","total":12000,"currency":"KRW"}' '{"orderId":"A-2102","total":8000,"currency":"KRW"}' \
         '{"orderId":"A-2103","total":5000,"currency":"KRWW"}' '{"orderId":"A-2104","total":30000,"currency":"KRW"}'; do
  aws sqs send-message --queue-url "$URL" --message-body "$o" --query MessageId --output text
done
settled() {
  local n d
  n="$(aws sqs get-queue-attributes --queue-url "$URL" --attribute-names All \
    --query '[Attributes.ApproximateNumberOfMessages, Attributes.ApproximateNumberOfMessagesNotVisible]' --output text | tr -s '\t' ' ')"
  d="$(visible_count "$DLQ_URL")"
  [ "$n" = "0 0" ] && [ "$d" = 1 ]
}
poll 120 "정상 3건 소비 + 실패 1건 DLQ 이동" settled
aws sqs get-queue-attributes --queue-url "$URL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
echo "DLQ: $(aws sqs receive-message --queue-url "$DLQ_URL" --visibility-timeout 0 --query 'Messages[0].Body' --output text)"

echo "== 6. 함수 로그: 무엇을 처리했나"
has_settled() { [ "$(log_lines "$FN" '"settled"' "$START_MS" | wc -l | tr -d ' ')" -ge 3 ]; }
poll 30 "로그 3건" has_settled
log_lines "$FN" '"result"' "$START_MS"
settled_n="$(log_lines "$FN" '"settled"' "$START_MS" | wc -l | tr -d ' ')"
failed_n="$(log_lines "$FN" '"failed"' "$START_MS" | wc -l | tr -d ' ')"

echo "== 7. 매핑 일시 중지 (배포·장애 대응 때 소비를 멈추는 스위치)"
aws lambda update-event-source-mapping --uuid "$UUID" --no-enabled --query State --output text
disabled() { [ "$(aws lambda get-event-source-mapping --uuid "$UUID" --query State --output text)" = Disabled ]; }
poll 60 "매핑 Disabled" disabled
aws lambda get-event-source-mapping --uuid "$UUID" --query State --output text

echo "== 8. (구성만) 비동기 호출의 실패 대상: 재시도 0회, 실패하면 SQS 로"
FAIL_URL="$(fresh_queue "$FAILQ")"
aws lambda put-function-event-invoke-config --function-name "$FN" --maximum-retry-attempts 0 \
  --maximum-event-age-in-seconds 3600 \
  --destination-config "{\"OnFailure\":{\"Destination\":\"$(queue_arn "$FAILQ")\"}}" \
  --query '{Retries: MaximumRetryAttempts, MaxAge: MaximumEventAgeInSeconds, OnFailure: DestinationConfig.OnFailure.Destination}'
echo "실패 대상 큐: $FAIL_URL (에뮬레이터는 실패 대상으로 전달하지 않는다 — README 의 에뮬레이터 제약 참고)"

# ---- 단언
[ "$settled_n" = 3 ] || fail "정산 로그가 정확히 3건이 아님(성공 메시지가 다시 처리됐나?): $settled_n"
[ "$failed_n" -ge 2 ] || fail "실패 메시지가 2번(maxReceiveCount) 시도되지 않음: $failed_n"
echo "LAB02 OK"
