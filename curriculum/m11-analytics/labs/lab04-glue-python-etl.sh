#!/usr/bin/env bash
# M11 lab04 — Glue ETL 작업(Python shell)으로 raw → curated 변환 (🟢)
#   raw/orders/dt=.../*.json ──[Glue 작업: etl/daily_revenue.py, 역할 todayorder-glue-etl]──▶ curated/daily_revenue/dt=.../part-0000.json
# 에뮬레이터는 Python shell 작업의 스크립트를 실제로 실행하고, 스크립트 안의 S3 호출에 작업 역할의 IAM 정책을 적용한다.
# (Spark 작업(glueetl)은 awsglue 라이브러리가 없어 실패한다 — README "에뮬레이터 제약")
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-etl"
JOB="todayorder-daily-revenue"
ROLE="todayorder-glue-etl"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/etl/daily_revenue.py"
D1="$(utc_day -2)"
D2="$(utc_day -1)"

cleanup() {
  aws glue delete-job --job-name "$JOB" >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name lake-rw >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
  empty_bucket "$BUCKET"
}
cleanup

run_job() {
  local run state
  run="$(aws glue start-job-run --job-name "$JOB" --arguments "{\"--days\":\"$D1,$D2\"}" --query JobRunId --output text)"
  for _ in $(seq 1 90); do
    state="$(aws glue get-job-run --job-name "$JOB" --run-id "$run" --query JobRun.JobRunState --output text)"
    case "$state" in SUCCEEDED | FAILED | ERROR | TIMEOUT | STOPPED) break ;; esac
    sleep 1
  done
  aws glue get-job-run --job-name "$JOB" --run-id "$run" \
    --query 'JobRun.{State: JobRunState, Error: ErrorMessage, Arguments: Arguments}' --output json
}

echo "== 1. 레이크 버킷: 이틀치 원본 주문 + ETL 스크립트"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text
history_orders "$D1" 1 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D1/part-0000.json"
history_orders "$D2" 2 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D2/part-0000.json"
aws s3 cp "$SCRIPT" "s3://$BUCKET/scripts/daily_revenue.py" --no-progress

echo "== 2. Glue 작업 역할 (신뢰 정책만, 권한 정책은 아직 없음)"
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
echo "$ROLE_ARN"

echo "== 3. Python shell 작업 등록 (최소 용량 0.0625 DPU)"
aws glue create-job --name "$JOB" --role "$ROLE_ARN" \
  --command "Name=pythonshell,ScriptLocation=s3://$BUCKET/scripts/daily_revenue.py,PythonVersion=3.9" \
  --max-capacity 0.0625 --default-arguments "{\"--bucket\":\"$BUCKET\"}" --query Name --output text

echo "== 4. 실행 #1 — 역할에 S3 권한이 없으면?"
first="$(run_job)"
echo "$first"

echo "== 5. 역할에 최소 권한 부여: raw 읽기, curated 쓰기, scripts 읽기"
aws iam put-role-policy --role-name "$ROLE" --policy-name lake-rw --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$BUCKET\"},
   {\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":[\"arn:aws:s3:::$BUCKET/raw/*\",\"arn:aws:s3:::$BUCKET/scripts/*\"]},
   {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/curated/*\"}]}"

echo "== 6. 실행 #2"
second="$(run_job)"
echo "$second"

echo "== 7. curated 결과"
aws s3 ls "s3://$BUCKET/curated/" --recursive | awk '{print $3, $4}'
for d in "$D1" "$D2"; do
  aws s3 cp "s3://$BUCKET/curated/daily_revenue/dt=$d/part-0000.json" -
done
total="$(for d in "$D1" "$D2"; do aws s3 cp "s3://$BUCKET/curated/daily_revenue/dt=$d/part-0000.json" -; done |
  py -c 'import json,sys; print(sum(json.loads(l)["revenue"] for l in sys.stdin if l.strip()))')"
echo "이틀 매출 합계: $total"

cleanup

# ---- 단언
[[ "$first" == *'"FAILED"'* && "$first" == *AccessDenied* ]] || fail "권한 없는 실행이 AccessDenied 로 실패하지 않음"
[[ "$second" == *'"SUCCEEDED"'* ]] || fail "권한 부여 후 실행이 SUCCEEDED 가 아님"
[ "$total" = 85500 ] || fail "매출 합계가 85500 이 아님: $total"
echo "LAB04 OK"
