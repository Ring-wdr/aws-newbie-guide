#!/usr/bin/env bash
# M06 lab04 — SNS → SQS 팬아웃과 필터 정책 (🟢)
# 먼저 "큐 정책 없이 구독"하면 아무 오류 없이 전달만 안 된다는 것(조용한 실패)을 보고, 정책을 넣어 고친다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TOPIC_NAME=todayorder-order-events
NOTIFY=todayorder-notify          # 알림 워커: 모든 이벤트 (SNS 봉투 그대로)
SETTLE=todayorder-settle-paid     # 정산 워커: order_paid 만 (필터 정책 + 원문 전달)
ANALYTICS=todayorder-analytics    # 분석 적재: 모든 이벤트 (원문 전달) — 대조군

# 큐 정책: 이 토픽(sns.amazonaws.com, SourceArn=토픽)만 이 큐에 SendMessage 를 허용
queue_policy() { # queue_policy <큐 이름> <토픽 ARN>
  cat <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"AllowOrderEventsTopic","Effect":"Allow",
 "Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":"$(queue_arn "$1")",
 "Condition":{"ArnEquals":{"aws:SourceArn":"$2"}}}]}
JSON
}
set_policy() { set_queue_policy "$1" "$(queue_policy "$2" "$3")"; } # set_policy <큐 URL> <큐 이름> <토픽 ARN>

echo "== 1. 토픽과 큐 3개"
TOPIC="$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)"
echo "$TOPIC"
# 이전 실행의 구독을 지운다 (멱등)
for s in $(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --query 'Subscriptions[].SubscriptionArn' --output text); do
  aws sns unsubscribe --subscription-arn "$s"
done
N_URL="$(fresh_queue "$NOTIFY")"
S_URL="$(fresh_queue "$SETTLE")"
A_URL="$(fresh_queue "$ANALYTICS")"

echo "== 2. [조용한 실패] 알림 큐는 정책 없이, 분석 큐는 정책을 넣고 구독"
set_policy "$A_URL" "$ANALYTICS" "$TOPIC"
aws sns subscribe --topic-arn "$TOPIC" --protocol sqs --notification-endpoint "$(queue_arn "$NOTIFY")" --query SubscriptionArn --output text
A_SUB="$(aws sns subscribe --topic-arn "$TOPIC" --protocol sqs --notification-endpoint "$(queue_arn "$ANALYTICS")" \
  --attributes RawMessageDelivery=true --query SubscriptionArn --output text)"
echo "$A_SUB"
aws sns publish --topic-arn "$TOPIC" --message '{"orderId":"A-4001","total":15000}' \
  --message-attributes 'eventType={DataType=String,StringValue=order_created}' --query MessageId --output text
arrived() { [ "$(visible_count "$1")" -ge "$2" ]; }
poll 60 "분석 큐(정책 있음) 도착" arrived "$A_URL" 1
echo "분석 큐(정책 있음): $(visible_count "$A_URL")건   알림 큐(정책 없음): $(visible_count "$N_URL")건"
silent="$(visible_count "$N_URL")"
echo "→ subscribe 도 publish 도 성공했는데 알림 큐에는 아무것도 없다. 오류는 어디에도 없었다."

echo "== 3. 알림 큐에 정책을 넣어 고치고, 정산 큐는 필터 정책 + 원문 전달로 구독"
set_policy "$N_URL" "$NOTIFY" "$TOPIC"
set_policy "$S_URL" "$SETTLE" "$TOPIC"
aws sqs get-queue-attributes --queue-url "$N_URL" --attribute-names Policy --query Attributes.Policy --output text | pretty
aws sns subscribe --topic-arn "$TOPIC" --protocol sqs --notification-endpoint "$(queue_arn "$SETTLE")" \
  --attributes '{"RawMessageDelivery":"true","FilterPolicy":"{\"eventType\":[\"order_paid\"]}"}' --query SubscriptionArn --output text
aws sqs purge-queue --queue-url "$A_URL"
empty_a() { [ "$(visible_count "$A_URL")" = 0 ]; }
poll 30 "분석 큐 비움" empty_a

echo "== 4. 이벤트 2건 발행: order_created, order_paid"
aws sns publish --topic-arn "$TOPIC" --message '{"orderId":"A-4002","total":22000}' \
  --message-attributes 'eventType={DataType=String,StringValue=order_created}' --query MessageId --output text
aws sns publish --topic-arn "$TOPIC" --message '{"orderId":"A-4002","total":22000}' \
  --message-attributes 'eventType={DataType=String,StringValue=order_paid}' --query MessageId --output text
poll 60 "알림 큐 2건" arrived "$N_URL" 2
poll 60 "분석 큐 2건" arrived "$A_URL" 2
poll 60 "정산 큐 1건" arrived "$S_URL" 1
echo "알림 큐: $(visible_count "$N_URL")건  분석 큐: $(visible_count "$A_URL")건  정산 큐(order_paid 만): $(visible_count "$S_URL")건"

echo "== 5. 같은 이벤트가 큐마다 어떻게 보이나"
echo "-- 알림 큐 (SNS 봉투 JSON):"
aws sqs receive-message --queue-url "$N_URL" --query 'Messages[0].Body' --output text | pretty
echo "-- 정산 큐 (원문 그대로):"
aws sqs receive-message --queue-url "$S_URL" --message-attribute-names All \
  --query 'Messages[0].{Body: Body, eventType: MessageAttributes.eventType.StringValue}'
aws sns get-subscription-attributes --subscription-arn "$A_SUB" --query 'Attributes.{Raw: RawMessageDelivery, Endpoint: Endpoint}'

# ---- 단언
[ "$silent" = 0 ] || fail "정책 없는 큐에 메시지가 도착함 (예상: 0)"
[ "$(visible_count "$S_URL")" -le 1 ] || fail "정산 큐에 필터 밖 메시지가 옴"
echo "LAB04 OK"
