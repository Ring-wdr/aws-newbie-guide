#!/usr/bin/env bash
# M06 lab01 — SQS 송수신과 가시성 타임아웃 관찰 (🟢)
# 1) 소비자가 멈춘 동안 주문이 큐에 쌓인다(버퍼링)  2) 받은 메시지는 잠시 "안 보인다"
# 3) 지우지 않으면 가시성 타임아웃 뒤 다시 나타난다  4) 롱 폴링  5) 지연 전송
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

Q=todayorder-orders
echo "== 0. 큐 만들기 (가시성 타임아웃 5초 — 관찰용으로 짧게)"
URL="$(fresh_queue "$Q" '{"VisibilityTimeout":"5"}')"
echo "$URL"
aws sqs get-queue-attributes --queue-url "$URL" \
  --attribute-names VisibilityTimeout MessageRetentionPeriod MaximumMessageSize ReceiveMessageWaitTimeSeconds DelaySeconds

echo "== 1. 워커가 멈춘 동안 주문 3건 도착 → 큐에 쌓인다"
for id in A-1001 A-1002 A-1003; do
  aws sqs send-message --queue-url "$URL" --message-body "{\"orderId\":\"$id\",\"total\":12000}" \
    --message-attributes 'eventType={DataType=String,StringValue=order_created}' --query MessageId --output text
done
has3() { [ "$(visible_count "$URL")" = 3 ]; }
poll 30 "큐 길이 3" has3
echo "ApproximateNumberOfMessages=$(visible_count "$URL")"

echo "== 2. 한 건 받기 (아직 지우지 않음)"
aws sqs receive-message --queue-url "$URL" --max-number-of-messages 1 \
  --message-attribute-names All --attribute-names ApproximateReceiveCount \
  --query 'Messages[0].{Body: Body, ReceiveCount: Attributes.ApproximateReceiveCount, EventType: MessageAttributes.eventType.StringValue}'
aws sqs get-queue-attributes --queue-url "$URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

echo "== 3. 나머지 2건을 받아 처리하고 지운다"
for _ in 1 2; do
  read -r handle body < <(aws sqs receive-message --queue-url "$URL" --max-number-of-messages 1 \
    --query 'Messages[0].[ReceiptHandle, Body]' --output text)
  echo "처리: $body"
  aws sqs delete-message --queue-url "$URL" --receipt-handle "$handle"
done

echo "== 4. 지우지 않은 첫 메시지: 가시성 타임아웃(5초)이 지나면 다시 보인다"
# 1초 간격으로 receive 를 반복한다. 메시지가 오면 WORK/msg 에 "핸들<TAB>수신횟수" 를 남긴다.
recv_once() {
  aws sqs receive-message --queue-url "$URL" --attribute-names ApproximateReceiveCount \
    --query 'Messages[0].[ReceiptHandle, Attributes.ApproximateReceiveCount]' --output text >"$WORK/msg"
  ! grep -q '^None' "$WORK/msg" && [ -s "$WORK/msg" ]
}
poll 60 "가시성 타임아웃 뒤 재등장" recv_once
read -r handle rc <"$WORK/msg"
echo "다시 받음: ApproximateReceiveCount=$rc  (기다린 시간은 환경마다 다르므로 단언하지 않는다)"
[ "$rc" = 2 ] || fail "ApproximateReceiveCount 가 2가 아님: $rc"

echo "== 5. 처리 실패를 알리고 즉시 돌려놓기: change-message-visibility --visibility-timeout 0"
aws sqs change-message-visibility --queue-url "$URL" --receipt-handle "$handle" --visibility-timeout 0
poll 30 "가시성 0 후 재수신" recv_once
read -r handle rc <"$WORK/msg"
echo "곧바로 다시 받음: ApproximateReceiveCount=$rc → 이번에는 처리 성공, 삭제"
aws sqs delete-message --queue-url "$URL" --receipt-handle "$handle"
queue_empty() {
  [ "$(aws sqs get-queue-attributes --queue-url "$URL" --attribute-names All \
    --query '[Attributes.ApproximateNumberOfMessages, Attributes.ApproximateNumberOfMessagesNotVisible]' --output text | tr -s '\t' ' ')" = '0 0' ]
}
poll 30 "큐 비움" queue_empty
aws sqs get-queue-attributes --queue-url "$URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

echo "== 6. 롱 폴링: 빈 큐에서 --wait-time-seconds 3 은 메시지가 오거나 3초가 될 때까지 기다린다"
t0=$SECONDS
empty="$(aws sqs receive-message --queue-url "$URL" --wait-time-seconds 3 --query 'length(Messages || `[]`)' --output text)"
echo "받은 메시지 ${empty}건, 기다린 시간 약 $((SECONDS - t0))초"

echo "== 7. 지연 전송: --delay-seconds 3"
aws sqs send-message --queue-url "$URL" --message-body '{"orderId":"A-1004","note":"delayed"}' --delay-seconds 3 --query MessageId --output text
now="$(aws sqs receive-message --queue-url "$URL" --query 'length(Messages || `[]`)' --output text)"
echo "보낸 직후 받은 메시지: ${now}건"
got_delayed() {
  aws sqs receive-message --queue-url "$URL" --wait-time-seconds 2 --query 'Messages[0].Body' --output text >"$WORK/msg"
  ! grep -q '^None' "$WORK/msg"
}
poll 60 "지연 메시지 도착" got_delayed
echo "나중에 받음: $(cat "$WORK/msg")"

# ---- 단언
[ "$empty" = 0 ] || fail "빈 큐 롱 폴링에서 메시지가 나옴"
[ "$now" = 0 ] || fail "지연 메시지가 즉시 보임"
echo "LAB01 OK"
