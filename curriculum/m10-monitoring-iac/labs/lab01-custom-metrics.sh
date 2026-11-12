#!/usr/bin/env bash
# M10 lab01 — 사용자 지정 지표 게시·조회 (🟢)
# 주문 API의 지연 시간(Latency)과 주문 수(OrdersPlaced)를 TodayOrder/Api 네임스페이스에 게시하고
# list-metrics / get-metric-statistics / get-metric-data 로 다시 읽는다.
# 마지막으로 "EC2 기본 지표(AWS/EC2)는 저절로 생기는가?"를 확인한다(에뮬레이터: 없음).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

NS="TodayOrder/Api"
DIM="Name=Route,Value=POST /orders"
# 이 lab 전용 차원 값으로 실행마다 새 지표를 만든다 (CloudWatch 지표는 지울 수 없다 — 실제 AWS도 같다).
RUN="run-$(date +%s)"

echo "== 1. 지연 시간 3건(120·250·900 ms)과 주문 수 3건을 게시"
for v in 120 250 900; do
  aws cloudwatch put-metric-data --namespace "$NS" --metric-name Latency --unit Milliseconds \
    --dimensions "Route=POST /orders,Run=$RUN" --value "$v"
done
aws cloudwatch put-metric-data --namespace "$NS" --metric-data \
  "[{\"MetricName\":\"OrdersPlaced\",\"Unit\":\"Count\",\"Value\":3,\"Dimensions\":[{\"Name\":\"Run\",\"Value\":\"$RUN\"}]}]"
echo "게시 완료 (응답 본문 없음)"

echo "== 2. list-metrics: 네임스페이스에 어떤 지표가 있나"
wait_until 30 1 "지표가 목록에 나타남" bash -c \
  "aws cloudwatch list-metrics --namespace '$NS' --dimensions Name=Run,Value=$RUN --output json | grep -q Latency"
aws cloudwatch list-metrics --namespace "$NS" --dimensions "Name=Run,Value=$RUN" \
  --query 'Metrics[].{Metric: MetricName, Dims: join(`, `, Dimensions[].Name)}' --output table

echo "== 3. get-metric-statistics: 최근 구간(Period 3600초) 평균·최댓값·표본 수"
START="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10 min' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u -v+2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ)"
stats() {
  aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name Latency \
    --dimensions "$DIM" "Name=Run,Value=$RUN" --start-time "$START" --end-time "$END" \
    --period 3600 --statistics Average Maximum SampleCount --output json
}
export NS DIM RUN START END
export -f stats
wait_until 30 1 "표본 3건 집계" bash -c 'stats | grep -q "\"SampleCount\": 3.0"'
stats
avg="$(stats | py -c 'import json,sys; d=json.load(sys.stdin)["Datapoints"]; print(int(d[0]["Average"]))')"
max="$(stats | py -c 'import json,sys; d=json.load(sys.stdin)["Datapoints"]; print(int(d[0]["Maximum"]))')"

echo "== 4. get-metric-data: 지표 수학(metric math)으로 '주문 1건당 평균 지연'"
QUERIES='[
 {"Id":"lat","MetricStat":{"Metric":{"Namespace":"'"$NS"'","MetricName":"Latency","Dimensions":[{"Name":"Route","Value":"POST /orders"},{"Name":"Run","Value":"'"$RUN"'"}]},"Period":3600,"Stat":"Sum"},"ReturnData":false},
 {"Id":"orders","MetricStat":{"Metric":{"Namespace":"'"$NS"'","MetricName":"OrdersPlaced","Dimensions":[{"Name":"Run","Value":"'"$RUN"'"}]},"Period":3600,"Stat":"Sum"},"ReturnData":false},
 {"Id":"perOrder","Expression":"lat / orders","Label":"LatencyPerOrder","ReturnData":true}]'
per="$(aws cloudwatch get-metric-data --metric-data-queries "$QUERIES" --start-time "$START" --end-time "$END" \
  --query 'MetricDataResults[0].Values[0]' --output text)"
aws cloudwatch get-metric-data --metric-data-queries "$QUERIES" --start-time "$START" --end-time "$END" \
  --query 'MetricDataResults[].{Label: Label, Values: Values}'

echo "== 5. EC2 기본 지표(AWS/EC2)가 있나? (실제 AWS: 인스턴스가 돌면 CPUUtilization 등이 저절로 생김)"
ec2_metrics="$(aws cloudwatch list-metrics --namespace AWS/EC2 --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["Metrics"]))')"
echo "AWS/EC2 지표 개수: $ec2_metrics"

# ---- 단언
[ "$avg" = "423" ] || fail "평균이 423이 아님: $avg"
[ "$max" = "900" ] || fail "최댓값이 900이 아님: $max"
py -c "import sys; sys.exit(0 if abs(float('$per') - 423.33) < 0.01 else 1)" || fail "LatencyPerOrder 가 423.33이 아님: $per"
echo "LAB01 OK"
