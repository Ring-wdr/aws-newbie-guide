#!/usr/bin/env bash
# M13 lab04 — AWS Budgets 예산·알림 (🟡: 저장·조회는 되지만 지출은 항상 0, 알림이 울리지 않음)
#             + Cost Explorer (🔴: GetCostAndUsage·GetCostForecast 501) + 비용 이상 탐지 모니터 (🟡: 생성만)
#
# TodayOrder 의 월 예산 300 USD(project=todayorder 태그 비용만): 실제 80% 초과 → 이메일+SNS, 예측 100% 초과 → 이메일
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUDGET="todayorder-monthly"
TOPIC_NAME="todayorder-budget-alerts"
MONITOR="todayorder-service-monitor"

aws budgets delete-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" 2>/dev/null || true
for arn in $(aws ce get-anomaly-monitors --query "AnomalyMonitors[?MonitorName=='$MONITOR'].MonitorArn" --output text 2>/dev/null); do
  aws ce delete-anomaly-monitor --monitor-arn "$arn"
done

echo "== 1. 알림을 받을 SNS 주제 (Budgets 가 게시할 수 있게 주제 정책 허용)"
TOPIC="$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)"
POLICY="$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"AllowBudgets","Effect":"Allow",
 "Principal":{"Service":"budgets.amazonaws.com"},"Action":"SNS:Publish","Resource":"$TOPIC",
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT"}}}]}
EOF
)"
aws sns set-topic-attributes --topic-arn "$TOPIC" --attribute-name Policy --attribute-value "$POLICY"
echo "$TOPIC"

echo "== 2. 월 비용 예산 300 USD (태그 project=todayorder) + 알림 2개"
aws budgets create-budget --account-id "$ACCOUNT" \
  --budget '{"BudgetName":"'"$BUDGET"'","BudgetLimit":{"Amount":"300","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST",
             "CostFilters":{"TagKeyValue":["user:project$todayorder"]}}' \
  --notifications-with-subscribers '[
    {"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},
     "Subscribers":[{"SubscriptionType":"EMAIL","Address":"ops@todayorder.example"},{"SubscriptionType":"SNS","Address":"'"$TOPIC"'"}]},
    {"Notification":{"NotificationType":"FORECASTED","ComparisonOperator":"GREATER_THAN","Threshold":100,"ThresholdType":"PERCENTAGE"},
     "Subscribers":[{"SubscriptionType":"EMAIL","Address":"ops@todayorder.example"}]}]'
aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --query 'Budget.{Name:BudgetName,Limit:BudgetLimit.Amount,TimeUnit:TimeUnit,Filter:CostFilters.TagKeyValue[0],ActualSpend:CalculatedSpend.ActualSpend.Amount}'
aws budgets describe-notifications-for-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --query 'Notifications[].[NotificationType,Threshold,NotificationState]' --output text

echo "== 3. 이 예산의 구독자"
aws budgets describe-subscribers-for-notification --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=80,ThresholdType=PERCENTAGE \
  --query 'Subscribers[].[SubscriptionType,Address]' --output text

echo "== 4. Cost Explorer: 이번 달 비용 조회와 예측"
# 기간은 오늘 날짜로 계산한다: 조회 = 이번 달 1일 ~ 내일(End 는 포함 안 됨), 예측 = 내일 ~ 다음 달 1일
read -r MONTH_START TOMORROW NEXT_MONTH < <(python3 -c 'import datetime as d
t = d.date.today(); n = (t.replace(day=28) + d.timedelta(days=4)).replace(day=1)
print(t.replace(day=1), t + d.timedelta(days=1), n)')
echo "조회 기간 $MONTH_START ~ $TOMORROW · 예측 기간 $TOMORROW ~ $NEXT_MONTH"
set +e
ce_out="$(aws ce get-cost-and-usage --time-period "Start=$MONTH_START,End=$TOMORROW" --granularity MONTHLY --metrics UnblendedCost 2>&1)"
fc_out="$(aws ce get-cost-forecast --time-period "Start=$TOMORROW,End=$NEXT_MONTH" --granularity MONTHLY --metric UNBLENDED_COST 2>&1)"
set -e
echo "$ce_out"
echo "$fc_out"

echo "== 5. 비용 이상 탐지(Cost Anomaly Detection) 모니터: 서비스별"
MON_ARN="$(aws ce create-anomaly-monitor --anomaly-monitor "{\"MonitorName\":\"$MONITOR\",\"MonitorType\":\"DIMENSIONAL\",\"MonitorDimension\":\"SERVICE\"}" --query MonitorArn --output text)"
aws ce get-anomaly-monitors --monitor-arn-list "$MON_ARN" --query 'AnomalyMonitors[].[MonitorName,MonitorType,MonitorDimension]' --output text

# ---- 단언
[ "$(aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" --query 'Budget.CalculatedSpend.ActualSpend.Amount' --output text)" = "0" ] \
  || echo "참고: ActualSpend 가 0 이 아니다 — 에뮬레이터가 지출을 계산하기 시작함(문서 갱신 필요)"
[ "$(aws budgets describe-notifications-for-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" --query 'length(Notifications)' --output text)" = "2" ] \
  || { echo "FAIL: 알림 2개가 저장되지 않음"; exit 1; }
grep -q 'NotImplemented' <<<"$ce_out" || { echo "FAIL: GetCostAndUsage 가 501 이 아님 → 문서 갱신 필요"; exit 1; }
grep -q 'NotImplemented' <<<"$fc_out" || { echo "FAIL: GetCostForecast 가 501 이 아님 → 문서 갱신 필요"; exit 1; }
echo "LAB04 OK"
