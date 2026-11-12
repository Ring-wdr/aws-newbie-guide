#!/usr/bin/env bash
# M06 lab02 — DLQ(배달 못 한 편지 큐)와 재처리(redrive) (🟢)
# 처리할 때마다 실패하는 "독 메시지"가 maxReceiveCount 를 넘으면 DLQ 로 옮겨지고,
# 버그를 고친 뒤 StartMessageMoveTask 로 원래 큐에 되돌려 다시 처리한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC=todayorder-settlement
DLQ=todayorder-settlement-dlq

echo "== 1. DLQ 를 먼저 만들고, 원본 큐에 RedrivePolicy(maxReceiveCount=2)를 건다"
# DLQ 보존 기간은 원본보다 길게 (14일 = 1209600초, SQS 최대값)
DLQ_URL="$(fresh_queue "$DLQ" '{"MessageRetentionPeriod":"1209600"}')"
SRC_URL="$(fresh_queue "$SRC" "{\"VisibilityTimeout\":\"2\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$(queue_arn "$DLQ")\\\",\\\"maxReceiveCount\\\":\\\"2\\\"}\"}")"
aws sqs get-queue-attributes --queue-url "$SRC_URL" --attribute-names RedrivePolicy VisibilityTimeout
aws sqs list-dead-letter-source-queues --queue-url "$DLQ_URL"

echo "== 2. 정산 워커가 처리하지 못하는 메시지(통화 코드 오류)를 보낸다"
aws sqs send-message --queue-url "$SRC_URL" --message-body '{"orderId":"A-2001","total":5000,"currency":"KRWW"}' --query MessageId --output text

echo "== 3. 워커: 받고 → 처리 실패 → 지우지 않음. 메시지가 원본 큐에서 사라질 때까지 반복"
receives=0
fail_once() {
  local out
  out="$(aws sqs receive-message --queue-url "$SRC_URL" --wait-time-seconds 1 --attribute-names ApproximateReceiveCount \
    --query 'Messages[0].Attributes.ApproximateReceiveCount' --output text)"
  if [ "$out" != None ]; then
    receives=$((receives + 1))
    echo "  수신 #$out → 처리 실패 (삭제하지 않음)"
  fi
  # 원본 큐에도 없고(보이는 것·처리 중 모두 0) DLQ 에 1건 있으면 끝
  [ "$(visible_count "$DLQ_URL")" = 1 ]
}
poll 90 "DLQ 로 이동" fail_once
echo "원본 큐 수신 횟수: $receives"
aws sqs get-queue-attributes --queue-url "$SRC_URL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages

echo "== 4. DLQ 의 메시지 들여다보기 (원인 조사)"
aws sqs receive-message --queue-url "$DLQ_URL" --visibility-timeout 0 --attribute-names ApproximateReceiveCount \
  --query 'Messages[0].{Body: Body, ReceiveCount: Attributes.ApproximateReceiveCount}'

echo "== 5. 버그를 고쳤다고 치고, DLQ → 원본 큐로 재처리(redrive) 시작"
task="$(aws sqs start-message-move-task --source-arn "$(queue_arn "$DLQ")" --destination-arn "$(queue_arn "$SRC")" --query TaskHandle --output text)"
echo "TaskHandle 받음 (${#task}자)"
moved() {
  aws sqs list-message-move-tasks --source-arn "$(queue_arn "$DLQ")" --max-results 1 \
    --query 'Results[0].[Status, ApproximateNumberOfMessagesMoved]' --output text >"$WORK/t"
  grep -q '^COMPLETED' "$WORK/t"
}
poll 60 "메시지 이동 작업 완료" moved
aws sqs list-message-move-tasks --source-arn "$(queue_arn "$DLQ")" --max-results 1 \
  --query 'Results[0].{Status: Status, Moved: ApproximateNumberOfMessagesMoved, Destination: DestinationArn}'

echo "== 6. 고친 워커가 원본 큐에서 다시 받아 처리하고 지운다"
fixed_once() {
  aws sqs receive-message --queue-url "$SRC_URL" --wait-time-seconds 1 --query 'Messages[0].[ReceiptHandle, Body]' --output text >"$WORK/m"
  ! grep -q '^None' "$WORK/m" && [ -s "$WORK/m" ]
}
poll 30 "재처리 메시지 수신" fixed_once
read -r handle body <"$WORK/m"
echo "처리 성공: $body"
aws sqs delete-message --queue-url "$SRC_URL" --receipt-handle "$handle"

# ---- 단언
[ "$receives" -ge 2 ] || fail "DLQ 로 가기 전 수신 횟수가 2 미만: $receives"
[ "$(visible_count "$DLQ_URL")" = 0 ] || fail "DLQ 가 비지 않음"
grep -q A-2001 <<<"$body" || fail "재처리된 메시지 본문이 다름"
echo "LAB02 OK"
