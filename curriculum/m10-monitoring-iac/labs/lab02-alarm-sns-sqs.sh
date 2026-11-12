#!/usr/bin/env bash
# M10 lab02 — 알람이 데이터로 스스로 ALARM 전이 → SNS → SQS 도착, set-alarm-state, 복합 알람 (🟢)
#
#   PutMetricData(지연 900ms) ──▶ 알람 todayorder-api-latency-high ──ALARM──▶ SNS todayorder-alerts ──▶ SQS todayorder-oncall
#
# 실제 AWS와 같이 SQS 큐 정책(sns.amazonaws.com 의 SendMessage 허용)이 없으면 알림이 조용히 버려진다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

TOPIC_NAME="todayorder-alerts"
QUEUE_NAME="todayorder-oncall"
ALARM="todayorder-api-latency-high"
ERR_ALARM="todayorder-api-5xx-high"
COMPOSITE="todayorder-api-degraded"
NS="TodayOrder/Api"

cleanup() {
  aws cloudwatch delete-alarms --alarm-names "$COMPOSITE" >/dev/null 2>&1 || true   # 복합 알람을 먼저 지운다
  aws cloudwatch delete-alarms --alarm-names "$ALARM" "$ERR_ALARM" >/dev/null 2>&1 || true
  local t q
  t="$(aws sns list-topics --output json | py -c "import json,sys; print(next((x['TopicArn'] for x in json.load(sys.stdin)['Topics'] if x['TopicArn'].endswith(':$TOPIC_NAME')), ''))")"
  [ -n "$t" ] && aws sns delete-topic --topic-arn "$t"
  q="$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text 2>/dev/null || true)"
  [ -n "$q" ] && aws sqs delete-queue --queue-url "$q"
  return 0
}
cleanup

echo "== 1. 알림 경로: SNS 토픽 + 당직 SQS 큐 + 큐 정책 + 구독"
TOPIC="$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)"
QURL="$(aws sqs create-queue --queue-name "$QUEUE_NAME" --query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
POLICY="$(py -c "import json; print(json.dumps({'Policy': json.dumps({'Version':'2012-10-17','Statement':[{'Sid':'AllowAlertsTopic','Effect':'Allow','Principal':{'Service':'sns.amazonaws.com'},'Action':'sqs:SendMessage','Resource':'$QARN','Condition':{'ArnEquals':{'aws:SourceArn':'$TOPIC'}}}]})}))")"
aws sqs set-queue-attributes --queue-url "$QURL" --attributes "$POLICY"
aws sns subscribe --topic-arn "$TOPIC" --protocol sqs --notification-endpoint "$QARN" \
  --attributes RawMessageDelivery=true --query SubscriptionArn --output text

echo "== 2. 알람: POST /orders 평균 지연 > 500ms 가 10초 구간 1개에서 관측되면 ALARM"
# 고해상도(StorageResolution=1) 지표에만 10초·30초 Period 알람을 걸 수 있다.
aws cloudwatch put-metric-alarm --alarm-name "$ALARM" \
  --alarm-description "주문 API 지연 시간 경보 (당직 호출)" \
  --namespace "$NS" --metric-name Latency --dimensions "Name=Route,Value=POST /orders" \
  --statistic Average --period 10 --evaluation-periods 1 --datapoints-to-alarm 1 \
  --threshold 500 --comparison-operator GreaterThanThreshold --treat-missing-data missing \
  --alarm-actions "$TOPIC" --ok-actions "$TOPIC"
aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].{State: StateValue, Period: Period, Threshold: Threshold}'

echo "== 3. 느린 요청 지연(800·900·1000ms)을 고해상도로 게시 — ALARM 이 될 때까지 계속 게시"
publish_slow() {
  aws cloudwatch put-metric-data --namespace "$NS" --metric-data \
    '[{"MetricName":"Latency","Unit":"Milliseconds","StorageResolution":1,"Values":[800,900,1000],"Dimensions":[{"Name":"Route","Value":"POST /orders"}]}]'
  [ "$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)" = ALARM ]
}
export -f publish_slow
export NS ALARM
wait_until 120 3 "알람 ALARM" bash -c publish_slow
aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].{State: StateValue, Reason: StateReason}'

echo "== 4. 당직 큐에 도착한 SNS 알림 (원문 전달 RawMessageDelivery=true)"
MSG=""
deadline=$(($(date +%s) + 60))
while [ -z "$MSG" ]; do
  MSG="$(aws sqs receive-message --queue-url "$QURL" --wait-time-seconds 5 --max-number-of-messages 10 \
    --query 'Messages[].Body' --output json | py -c '
import json, sys
for body in json.load(sys.stdin) or []:
    m = json.loads(body)
    if m.get("NewStateValue") == "ALARM":
        print(json.dumps({k: m[k] for k in ("AlarmName", "OldStateValue", "NewStateValue", "NewStateReason")}, ensure_ascii=False, indent=2))
        break')"
  [ "$(date +%s)" -lt "$deadline" ] || fail "60초 안에 SQS에 ALARM 알림이 오지 않음"
done
echo "$MSG"

echo "== 5. 알람 이력 (상태 변경과 액션 실행)"
aws cloudwatch describe-alarm-history --alarm-name "$ALARM" \
  --query 'AlarmHistoryItems[].[HistoryItemType, HistorySummary]' --output table
actions="$(aws cloudwatch describe-alarm-history --alarm-name "$ALARM" --history-item-type Action \
  --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["AlarmHistoryItems"]))')"

echo "== 6. set-alarm-state: 데이터 없이 상태를 강제로 바꿔 알림 경로를 시험한다"
aws cloudwatch put-metric-alarm --alarm-name "$ERR_ALARM" --alarm-description "5xx 오류 수 경보" \
  --namespace "$NS" --metric-name Http5xx --statistic Sum --period 60 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching
aws cloudwatch set-alarm-state --alarm-name "$ERR_ALARM" --state-value ALARM --state-reason "lab02: 알림 경로 점검"
aws cloudwatch describe-alarms --alarm-names "$ERR_ALARM" --query 'MetricAlarms[0].{State: StateValue, Reason: StateReason}'

echo "== 7. 복합 알람: 지연 경보 AND 5xx 경보 → '주문 API 저하'"
aws cloudwatch put-composite-alarm --alarm-name "$COMPOSITE" \
  --alarm-rule "ALARM(\"$ALARM\") AND ALARM(\"$ERR_ALARM\")" --alarm-actions "$TOPIC"
composite_state() {
  aws cloudwatch describe-alarms --alarm-names "$COMPOSITE" --alarm-types CompositeAlarm \
    --query 'CompositeAlarms[0].StateValue' --output text
}
export -f composite_state
export COMPOSITE
wait_until 60 1 "복합 알람 ALARM" bash -c '[ "$(composite_state)" = ALARM ]'
aws cloudwatch describe-alarms --alarm-names "$COMPOSITE" --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[0].{State: StateValue, Rule: AlarmRule}'

echo "== 8. 5xx 경보를 OK 로 되돌리면 복합 알람도 OK"
aws cloudwatch set-alarm-state --alarm-name "$ERR_ALARM" --state-value OK --state-reason "lab02: 복구"
wait_until 60 1 "복합 알람 OK" bash -c '[ "$(composite_state)" = OK ]'
echo "복합 알람: $(composite_state)"

cleanup

# ---- 단언
grep -q "\"AlarmName\": \"$ALARM\"" <<<"$MSG" || fail "받은 알림의 AlarmName 이 다름"
[ "$actions" -ge 1 ] || fail "알람 액션(SNS) 실행 이력이 없음"
echo "LAB02 OK"
