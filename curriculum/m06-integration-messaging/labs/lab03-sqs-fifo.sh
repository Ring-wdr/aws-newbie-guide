#!/usr/bin/env bash
# M06 lab03 — FIFO 큐: 메시지 그룹 안의 순서, 중복 제거 (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

Q=todayorder-order-status.fifo   # FIFO 큐 이름은 반드시 .fifo 로 끝난다

echo "== 1. FIFO 큐 만들기"
URL="$(fresh_queue "$Q" '{"FifoQueue":"true","ContentBasedDeduplication":"false","VisibilityTimeout":"30"}')"
aws sqs get-queue-attributes --queue-url "$URL" --attribute-names FifoQueue ContentBasedDeduplication

echo "== 2. MessageGroupId 없이 보내면?"
if aws sqs send-message --queue-url "$URL" --message-body x 2>"$WORK/err"; then fail "그룹 ID 없이 전송이 성공함"; fi
cat "$WORK/err"

echo "== 3. 주문 A-3001 의 상태 변경 3건 + 주문 B-3002 의 1건 (그룹 = 주문 ID)"
send() { # send <그룹> <중복 제거 ID> <본문>
  aws sqs send-message --queue-url "$URL" --message-group-id "$1" --message-deduplication-id "$2" \
    --message-body "$3" --query '[MessageId, SequenceNumber]' --output text
}
send A-3001 A-3001-created '{"orderId":"A-3001","status":"CREATED"}'
send A-3001 A-3001-paid    '{"orderId":"A-3001","status":"PAID"}'
send B-3002 B-3002-created '{"orderId":"B-3002","status":"CREATED"}'
send A-3001 A-3001-shipped '{"orderId":"A-3001","status":"SHIPPED"}'

echo "== 4. 네트워크 오류로 생산자가 'PAID' 를 한 번 더 보냈다 (같은 중복 제거 ID)"
send A-3001 A-3001-paid '{"orderId":"A-3001","status":"PAID"}'
sleep_free_count() { aws sqs get-queue-attributes --queue-url "$URL" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text; }
echo "큐에 있는 메시지 수: $(sleep_free_count)  (5번 보냈지만 중복 1건은 버려짐)"

echo "== 5. 그룹 A 의 첫 메시지를 받고 아직 지우지 않으면, 같은 그룹의 다음 메시지는 나오지 않는다"
aws sqs receive-message --queue-url "$URL" --max-number-of-messages 1 --attribute-names MessageGroupId \
  --query 'Messages[0].[ReceiptHandle, Attributes.MessageGroupId, Body]' --output text >"$WORK/first"
read -r h1 g1 b1 <"$WORK/first"
echo "1번째 수신: $g1 $b1"
aws sqs receive-message --queue-url "$URL" --max-number-of-messages 10 --attribute-names MessageGroupId \
  --query 'Messages[].[ReceiptHandle, Attributes.MessageGroupId, Body]' --output text >"$WORK/second"
echo "A 가 처리 중일 때 받은 것:"; cut -f2- "$WORK/second"
order=("$b1")
while read -r h g b; do
  [ "$g" = A-3001 ] && fail "처리 중인 그룹 A 의 다음 메시지가 나옴"
  order+=("$b")
  aws sqs delete-message --queue-url "$URL" --receipt-handle "$h"   # 그룹 B 는 바로 처리 완료
done <"$WORK/second"
echo "그룹 A 의 첫 메시지 처리 완료 → 삭제"
aws sqs delete-message --queue-url "$URL" --receipt-handle "$h1"

echo "== 6. 그룹 A 의 나머지를 차례로 받아 처리하고 지운다"
drain_one() {
  aws sqs receive-message --queue-url "$URL" --max-number-of-messages 1 --wait-time-seconds 1 \
    --query 'Messages[0].[ReceiptHandle, Body]' --output text >"$WORK/m"
  if ! grep -q '^None' "$WORK/m" && [ -s "$WORK/m" ]; then
    read -r h b <"$WORK/m"
    order+=("$b")
    aws sqs delete-message --queue-url "$URL" --receipt-handle "$h"
  fi
  [ "${#order[@]}" -ge 4 ]
}
poll 90 "4건 모두 수신" drain_one
echo "-- 처리를 끝낸 전체 순서 (5단계에서 처리한 2건 포함):"
printf '  %s\n' "${order[@]}"
a_order="$(printf '%s\n' "${order[@]}" | grep A-3001 | sed 's/.*"status":"\([A-Z]*\)".*/\1/' | tr '\n' ' ')"
echo "주문 A-3001 상태 순서: $a_order"

# ---- 단언
[ "$a_order" = "CREATED PAID SHIPPED " ] || fail "그룹 내 순서가 다름: $a_order"
[ "$(printf '%s\n' "${order[@]}" | grep -c PAID)" = 1 ] || fail "중복 PAID 가 전달됨"
echo "LAB03 OK"
