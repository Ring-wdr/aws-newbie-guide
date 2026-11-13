#!/usr/bin/env bash
# M14 lab04 — 캡스톤 계층 4: 관측·감사·거버넌스
#   CloudWatch 알람(주문 처리 실패 지표 → SNS ops-alerts) + DLQ 깊이 알람(구성만)
#   CloudTrail 추적(멀티 리전, 로그 무결성 검증) → 감사 버킷
#   AWS Config 기록기 + 관리형 규칙 2개(버킷 암호화, 버킷 버전 관리)
#   AWS Budgets 월 예산 + 예측 초과 알림 → SNS ops-alerts
# 선행 계층: lab02(영수증 버킷), lab03(ops-alerts 토픽). 없으면 스스로 만든다.
# 등급: 🟢 알람·Config(S3 규칙) / 🟡 CloudTrail(IAM 이벤트만 조회됨)·Budgets(지출 항상 0)·DLQ 알람(AWS/SQS 지표 없음)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 0. 선행 계층"
ensure have_pipeline "$LABS/lab03-order-pipeline.sh"
OPS_TOPIC_ARN="$(stack_output "$MSG_STACK" OpsTopicArn)"

echo "== 1. 알람: 주문 처리 실패가 1분에 1건이라도 나면 ALARM → ops-alerts (복구되면 OK 알림도)"
aws cloudwatch put-metric-alarm --alarm-name "$ALARM" \
  --alarm-description "주문 처리 워커가 결제·저장에 실패했다. DLQ 와 워커 로그를 확인할 것" \
  --namespace "$METRIC_NS" --metric-name "$METRIC_NAME" --statistic Sum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --alarm-actions "$OPS_TOPIC_ARN" --ok-actions "$OPS_TOPIC_ARN"
echo "-- DLQ 에 메시지가 쌓이면 ALARM (실제 AWS 의 AWS/SQS 지표. 에뮬레이터는 이 지표를 내지 않아 구성만)"
aws cloudwatch put-metric-alarm --alarm-name "$P-dlq-not-empty" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible --dimensions "Name=QueueName,Value=$DLQ" \
  --statistic Maximum --period 300 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching --alarm-actions "$OPS_TOPIC_ARN"
aws cloudwatch describe-alarms --alarm-name-prefix "$P-" --query 'MetricAlarms[].[AlarmName, Namespace, MetricName, StateValue]' --output text

echo "== 2. CloudTrail: 감사 버킷(퍼블릭 차단·버전 관리·보존 400일·CloudTrail 전용 정책) + 멀티 리전 추적 + 무결성 검증"
TRAIL_ARN="arn:aws:cloudtrail:$REGION:$ACCOUNT:trail/$TRAIL"
aws cloudtrail delete-trail --name "$TRAIL" >/dev/null 2>&1 || true
aws s3api head-bucket --bucket "$TRAIL_BUCKET" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$TRAIL_BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$TRAIL_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$TRAIL_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$TRAIL_BUCKET" --tagging 'TagSet=[{Key=Project,Value=todayorder},{Key=DataClass,Value=audit}]'
# 보존 기간(NFR-S6 "1년 이상"): 90일 뒤 Glacier Flexible Retrieval, 400일(13개월) 뒤 만료. 버전 관리가 켜져 있으므로
# 이전 버전도 400일 뒤 지운다. 규제가 덮어쓰기·삭제 금지까지 요구하면 버킷 생성 시 객체 잠금(규정 준수 모드)을 켠다(레슨 02 결정 24).
aws s3api put-bucket-lifecycle-configuration --bucket "$TRAIL_BUCKET" --lifecycle-configuration '{"Rules": [{
  "ID": "audit-retention", "Status": "Enabled", "Filter": {"Prefix": ""},
  "Transitions": [{"Days": 90, "StorageClass": "GLACIER"}], "Expiration": {"Days": 400},
  "NoncurrentVersionExpiration": {"NoncurrentDays": 400}}]}' >/dev/null
cat >"$WORK/trail-policy.json" <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Sid": "AWSCloudTrailAclCheck", "Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"},
   "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::$TRAIL_BUCKET",
   "Condition": {"StringEquals": {"aws:SourceArn": "$TRAIL_ARN"}}},
  {"Sid": "AWSCloudTrailWrite", "Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"},
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/$ACCOUNT/*",
   "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control", "aws:SourceArn": "$TRAIL_ARN"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy "file://$WORK/trail-policy.json"
aws cloudtrail create-trail --name "$TRAIL" --s3-bucket-name "$TRAIL_BUCKET" --is-multi-region-trail \
  --enable-log-file-validation --include-global-service-events \
  --query '{MultiRegion: IsMultiRegionTrail, Validation: LogFileValidationEnabled}' --output json
aws cloudtrail start-logging --name "$TRAIL"
echo "-- 영수증 객체 쓰기·읽기(데이터 이벤트)도 기록 — 별도 과금이므로 이 버킷에만"
aws cloudtrail put-event-selectors --trail-name "$TRAIL" --event-selectors "[{\"ReadWriteType\": \"All\",
  \"IncludeManagementEvents\": true, \"DataResources\": [{\"Type\": \"AWS::S3::Object\", \"Values\": [\"arn:aws:s3:::$RECEIPTS/\"]}]}]" \
  --query 'EventSelectors[0].DataResources[0].Values' --output text

echo "== 3. AWS Config: 기록기 + 전달 채널(전용 버킷 정책) + 관리형 규칙 2개 (Project=todayorder 태그 범위)"
aws configservice stop-configuration-recorder --configuration-recorder-name default >/dev/null 2>&1 || true
aws configservice delete-delivery-channel --delivery-channel-name default >/dev/null 2>&1 || true
aws iam get-role --role-name "$CONFIG_ROLE" >/dev/null 2>&1 || aws iam create-role --role-name "$CONFIG_ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"config.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name "$CONFIG_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole
# 사용자 지정 역할이면 전달 버킷 쓰기 권한도 역할에 있어야 한다(AWS_ConfigRole 은 리소스 읽기 권한뿐).
# 서비스 연결 역할(AWSServiceRoleForConfig)을 쓰면 이 정책 대신 아래 버킷 정책이 쓰인다.
aws iam put-role-policy --role-name "$CONFIG_ROLE" --policy-name config-delivery --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Sid\":\"Deliver\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$CONFIG_BUCKET/AWSLogs/$ACCOUNT/*\",
   \"Condition\":{\"StringLike\":{\"s3:x-amz-acl\":\"bucket-owner-full-control\"}}},
  {\"Sid\":\"CheckAcl\",\"Effect\":\"Allow\",\"Action\":\"s3:GetBucketAcl\",\"Resource\":\"arn:aws:s3:::$CONFIG_BUCKET\"}]}"
aws configservice put-configuration-recorder --configuration-recorder "name=default,roleARN=arn:aws:iam::$ACCOUNT:role/$CONFIG_ROLE" \
  --recording-group allSupported=true,includeGlobalResourceTypes=true
aws s3api head-bucket --bucket "$CONFIG_BUCKET" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$CONFIG_BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$CONFIG_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
cat >"$WORK/config-policy.json" <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Sid": "AWSConfigBucketPermissionsCheck", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::$CONFIG_BUCKET", "Condition": {"StringEquals": {"AWS:SourceAccount": "$ACCOUNT"}}},
  {"Sid": "AWSConfigBucketExistenceCheck", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::$CONFIG_BUCKET", "Condition": {"StringEquals": {"AWS:SourceAccount": "$ACCOUNT"}}},
  {"Sid": "AWSConfigBucketDelivery", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::$CONFIG_BUCKET/AWSLogs/$ACCOUNT/Config/*",
   "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control", "AWS:SourceAccount": "$ACCOUNT"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$CONFIG_BUCKET" --policy "file://$WORK/config-policy.json"
aws configservice put-delivery-channel --delivery-channel "name=default,s3BucketName=$CONFIG_BUCKET"
aws configservice start-configuration-recorder --configuration-recorder-name default
# 이 에뮬레이터의 Config 는 S3 버킷만 리소스로 기록한다(DynamoDB·RDS 는 list-discovered-resources 에 없음).
# 그래서 평가가 실제로 일어나는 S3 규칙 2개를 쓰고, 테이블 PITR·RDS Multi-AZ 점검은 sdk/capstone_audit.py 가 한다.
# (실제 AWS 라면 DYNAMODB_PITR_ENABLED, RDS_MULTI_AZ_SUPPORT 관리형 규칙을 같은 방법으로 추가)
RULES="$P-s3-sse $P-s3-versioning"
put_rule() {  # <규칙 이름> <관리형 규칙 ID> <리소스 유형>
  aws configservice put-config-rule --config-rule "{\"ConfigRuleName\": \"$1\",
    \"Source\": {\"Owner\": \"AWS\", \"SourceIdentifier\": \"$2\"},
    \"Scope\": {\"ComplianceResourceTypes\": [\"$3\"], \"TagKey\": \"Project\", \"TagValue\": \"todayorder\"}}"
}
put_rule "$P-s3-sse" S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED AWS::S3::Bucket
put_rule "$P-s3-versioning" S3_BUCKET_VERSIONING_ENABLED AWS::S3::Bucket
# shellcheck disable=SC2086
aws configservice start-config-rules-evaluation --config-rule-names $RULES
result_of() {  # <규칙> <리소스 이름 일부> → COMPLIANT / NON_COMPLIANT / (빈 값)
  aws configservice get-compliance-details-by-config-rule --config-rule-name "$1" --output json | py '
for r in json.load(sys.stdin).get("EvaluationResults", []):
    rid = r["EvaluationResultIdentifier"]["EvaluationResultQualifier"]["ResourceId"]
    if sys.argv[1] in rid:
        print(r["ComplianceType"]); break' "$2"
}
has_result() { [ -n "$(result_of "$1" "$2")" ]; }
for pair in "$P-s3-sse:$RECEIPTS" "$P-s3-sse:$TRAIL_BUCKET" "$P-s3-versioning:$RECEIPTS" "$P-s3-versioning:$TRAIL_BUCKET"; do
  rule="${pair%%:*}" res="${pair#*:}"
  poll 120 "$rule 평가" has_result "$rule" "$res"
  printf '%-30s %-40s %s\n' "$rule" "$res" "$(result_of "$rule" "$res")"
done

echo "== 4. AWS Budgets: 월 200 USD, 예측이 80% 를 넘으면 ops-alerts"
aws budgets delete-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" >/dev/null 2>&1 || true
aws budgets create-budget --account-id "$ACCOUNT" \
  --budget "{\"BudgetName\": \"$BUDGET\", \"BudgetType\": \"COST\", \"TimeUnit\": \"MONTHLY\",
    \"BudgetLimit\": {\"Amount\": \"200\", \"Unit\": \"USD\"},
    \"CostFilters\": {\"TagKeyValue\": [\"user:Project\$todayorder\"]}}" \
  --notifications-with-subscribers "[{\"Notification\": {\"NotificationType\": \"FORECASTED\", \"ComparisonOperator\": \"GREATER_THAN\",
    \"Threshold\": 80, \"ThresholdType\": \"PERCENTAGE\"}, \"Subscribers\": [{\"SubscriptionType\": \"SNS\", \"Address\": \"$OPS_TOPIC_ARN\"}]}]"
aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --query 'Budget.{Name: BudgetName, Limit: BudgetLimit.Amount, Actual: CalculatedSpend.ActualSpend.Amount}' --output json

# ---- 단언
assert_eq "$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].AlarmActions[0]' --output text)" "$OPS_TOPIC_ARN" "알람 동작"
assert_eq "$(aws cloudtrail get-trail-status --name "$TRAIL" --query IsLogging --output text)" True "CloudTrail 로깅"
assert_eq "$(aws cloudtrail describe-trails --trail-name-list "$TRAIL" --query 'trailList[0].LogFileValidationEnabled' --output text)" True "로그 무결성 검증"
assert_eq "$(aws s3api get-bucket-lifecycle-configuration --bucket "$TRAIL_BUCKET" --query 'Rules[0].Expiration.Days' --output text)" 400 "감사 로그 보존 400일(≥ 1년)"
assert_eq "$(aws iam list-role-policies --role-name "$CONFIG_ROLE" --query 'PolicyNames[0]' --output text)" config-delivery "Config 역할 전달 권한"
assert_eq "$(aws configservice describe-configuration-recorder-status --query 'ConfigurationRecordersStatus[0].recording' --output text)" True "Config 기록 중"
assert_eq "$(result_of "$P-s3-sse" "$RECEIPTS")" COMPLIANT "영수증 버킷 암호화 규칙"
assert_eq "$(result_of "$P-s3-versioning" "$RECEIPTS")" COMPLIANT "영수증 버킷 버전 관리 규칙"
assert_eq "$(result_of "$P-s3-sse" "$TRAIL_BUCKET")" COMPLIANT "감사 버킷 암호화 규칙"
assert_eq "$(result_of "$P-s3-versioning" "$TRAIL_BUCKET")" COMPLIANT "감사 버킷 버전 관리 규칙"
echo "LAB04 OK"
