#!/usr/bin/env bash
# M09 lab08 — AWS Config: 기록기·전달 채널·관리형 규칙의 NON_COMPLIANT 판정과 수정 후 COMPLIANT (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ROLE="todayorder-m09-config-role"
FIX_ROLE="todayorder-m09-remediation-role"
LOG_BUCKET="todayorder-m09-config-logs"
# Config 는 지운 버킷의 평가 결과도 이름(리소스 ID)으로 기억한다. 다시 실행해도 옛 결과와 섞이지 않게
# 평가 대상 버킷 이름에 실행마다 다른 접미사를 붙인다.
RUN="$(date +%s)"
OK_BUCKET="todayorder-m09-versioned-$RUN"
BAD_BUCKET="todayorder-m09-unversioned-$RUN"
AUTO_BUCKET="todayorder-m09-autofix-$RUN"
RULE="todayorder-s3-versioning-enabled"
WORK="$TMP_LIB"
cd "$WORK"

# ---- 이전 실행 정리 (멱등). 기록기·전달 채널은 계정·리전에 하나씩이라 이름 default 를 재사용한다.
# 자동 수정(remediation)이 남아 있으면 새 버킷마다 버전 관리가 저절로 켜진다 → 규칙보다 먼저 지운다.
aws configservice delete-remediation-configuration --config-rule-name "$RULE" >/dev/null 2>&1 || true
aws configservice delete-config-rule --config-rule-name "$RULE" >/dev/null 2>&1 || true
aws configservice stop-configuration-recorder --configuration-recorder-name default >/dev/null 2>&1 || true
aws configservice delete-delivery-channel --delivery-channel-name default >/dev/null 2>&1 || true
for b in "$LOG_BUCKET" $(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `todayorder-m09-versioned-`) || starts_with(Name, `todayorder-m09-unversioned-`) || starts_with(Name, `todayorder-m09-autofix-`)].Name' --output text); do
  nuke_bucket "$b"
done
delete_role "$ROLE"
delete_role "$FIX_ROLE"

echo "== 1. 기록기(configuration recorder) — 무엇을 기록할지 + Config 가 쓸 서비스 역할"
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --query Role.Arn --output text --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"config.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole
aws configservice put-configuration-recorder --configuration-recorder "name=default,roleARN=$ROLE_ARN" \
  --recording-group allSupported=true,includeGlobalResourceTypes=true

echo "== 2. 전달 채널 — 구성 기록을 보낼 S3 버킷. 버킷 정책이 없으면? (실패해야 정상)"
aws s3 mb "s3://$LOG_BUCKET" >/dev/null
expect_error channel_err aws configservice put-delivery-channel --delivery-channel "name=default,s3BucketName=$LOG_BUCKET"
echo "$channel_err" | grep -m1 'error occurred'
cat >policy.json <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Sid": "AWSConfigBucketPermissionsCheck", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::$LOG_BUCKET",
   "Condition": {"StringEquals": {"AWS:SourceAccount": "000000000000"}}},
  {"Sid": "AWSConfigBucketExistenceCheck", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::$LOG_BUCKET",
   "Condition": {"StringEquals": {"AWS:SourceAccount": "000000000000"}}},
  {"Sid": "AWSConfigBucketDelivery", "Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::$LOG_BUCKET/AWSLogs/000000000000/Config/*",
   "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control", "AWS:SourceAccount": "000000000000"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$LOG_BUCKET" --policy file://policy.json
aws configservice put-delivery-channel --delivery-channel "name=default,s3BucketName=$LOG_BUCKET"
aws configservice start-configuration-recorder --configuration-recorder-name default
recording="$(aws configservice describe-configuration-recorder-status --query 'ConfigurationRecordersStatus[0].recording' --output text)"
echo "기록 중: $recording"

echo "== 3. 평가 대상: 버전 관리를 켠 버킷 1개, 끈 버킷 1개"
# 규칙 범위를 태그 lab=m09-lab08 인 버킷으로 좁힌다 — 자동 수정이 계정의 다른 버킷(로그 버킷 등)을 건드리지 않게
tag() { aws s3api put-bucket-tagging --bucket "$1" --tagging 'TagSet=[{Key=lab,Value=m09-lab08}]'; }
aws s3 mb "s3://$OK_BUCKET" >/dev/null && tag "$OK_BUCKET"
aws s3api put-bucket-versioning --bucket "$OK_BUCKET" --versioning-configuration Status=Enabled
aws s3 mb "s3://$BAD_BUCKET" >/dev/null && tag "$BAD_BUCKET"

echo "== 4. AWS 관리형 규칙 S3_BUCKET_VERSIONING_ENABLED"
aws configservice put-config-rule --config-rule "{
  \"ConfigRuleName\": \"$RULE\",
  \"Description\": \"영수증 버킷은 버전 관리가 켜져 있어야 한다\",
  \"Source\": {\"Owner\": \"AWS\", \"SourceIdentifier\": \"S3_BUCKET_VERSIONING_ENABLED\"},
  \"Scope\": {\"ComplianceResourceTypes\": [\"AWS::S3::Bucket\"], \"TagKey\": \"lab\", \"TagValue\": \"m09-lab08\"}}"
aws configservice start-config-rules-evaluation --config-rule-names "$RULE"
compliance_of() {
  aws configservice get-compliance-details-by-config-rule --config-rule-name "$RULE" --output json | py '
for r in json.load(sys.stdin).get("EvaluationResults", []):
    if r["EvaluationResultIdentifier"]["EvaluationResultQualifier"]["ResourceId"] == sys.argv[1]:
        print(r["ComplianceType"])' "$1"
}
poll 120 "규칙 평가" sh -c "aws configservice get-compliance-details-by-config-rule --config-rule-name '$RULE' --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' --output text | grep -q '$BAD_BUCKET'"
aws configservice get-compliance-details-by-config-rule --config-rule-name "$RULE" --output json | py '
for r in json.load(sys.stdin)["EvaluationResults"]:
    rid = r["EvaluationResultIdentifier"]["EvaluationResultQualifier"]["ResourceId"]
    if rid in sys.argv[1:]:
        ct = r["ComplianceType"]
        print(f"{rid:<40}{ct}")' "$OK_BUCKET" "$BAD_BUCKET"
echo "규칙 전체 판정(하나라도 위반이면 NON_COMPLIANT): $(aws configservice describe-compliance-by-config-rule --config-rule-names "$RULE" --query 'ComplianceByConfigRules[0].Compliance.ComplianceType' --output text)"
bad_before="$(compliance_of "$BAD_BUCKET")"
ok_before="$(compliance_of "$OK_BUCKET")"

echo "== 5. 고친다 → 다시 평가 → COMPLIANT"
aws s3api put-bucket-versioning --bucket "$BAD_BUCKET" --versioning-configuration Status=Enabled
aws configservice start-config-rules-evaluation --config-rule-names "$RULE"
poll 120 "재평가 후 COMPLIANT" sh -c "[ \"\$(aws configservice get-compliance-details-by-config-rule --config-rule-name '$RULE' --compliance-types COMPLIANT --query \"EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId=='$BAD_BUCKET'] | length(@)\" --output text)\" -ge 1 ]"
bad_after="$(compliance_of "$BAD_BUCKET")"
echo "$BAD_BUCKET: $bad_before → $bad_after"

echo "== 6. 구성 이력 — 이 버킷의 구성 항목(configuration item)이 시간순으로 쌓인다"
aws configservice get-resource-config-history --resource-type AWS::S3::Bucket --resource-id "$BAD_BUCKET" \
  --query 'configurationItems[].[configurationItemCaptureTime, configurationItemStatus]' --output text

echo "== 7. 자동 수정(remediation): 위반 리소스에 SSM Automation 문서 AWS-ConfigureS3BucketVersioning 실행"
# 자동 수정이 쓸 역할: SSM Automation 이 맡고(신뢰 정책), 버킷 버전 관리만 바꿀 수 있다(최소 권한)
FIX_ROLE_ARN="$(aws iam create-role --role-name "$FIX_ROLE" --query Role.Arn --output text --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ssm.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
aws iam put-role-policy --role-name "$FIX_ROLE" --policy-name s3-versioning-only --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutBucketVersioning","s3:GetBucketVersioning"],"Resource":"arn:aws:s3:::*"}]}'
aws configservice put-remediation-configurations --remediation-configurations "[{
  \"ConfigRuleName\": \"$RULE\", \"TargetType\": \"SSM_DOCUMENT\", \"TargetId\": \"AWS-ConfigureS3BucketVersioning\",
  \"Automatic\": true, \"MaximumAutomaticAttempts\": 3, \"RetryAttemptSeconds\": 60,
  \"Parameters\": {\"BucketName\": {\"ResourceValue\": {\"Value\": \"RESOURCE_ID\"}},
                   \"AutomationAssumeRole\": {\"StaticValue\": {\"Values\": [\"$FIX_ROLE_ARN\"]}}}}]" --query 'length(FailedBatches)' --output text
echo "-- 버전 관리 없이 새 버킷을 만든다: $AUTO_BUCKET"
aws s3 mb "s3://$AUTO_BUCKET" >/dev/null && tag "$AUTO_BUCKET"
aws configservice start-config-rules-evaluation --config-rule-names "$RULE"
poll 120 "자동 수정으로 버전 관리 켜짐" sh -c "aws s3api get-bucket-versioning --bucket '$AUTO_BUCKET' --query Status --output text | grep -qx Enabled"
aws configservice describe-remediation-execution-status --config-rule-name "$RULE" \
  --query "RemediationExecutionStatuses[?ResourceKey.resourceId=='$AUTO_BUCKET'].[ResourceKey.resourceId, State]" --output text
auto_versioning="$(aws s3api get-bucket-versioning --bucket "$AUTO_BUCKET" --query Status --output text)"
echo "$AUTO_BUCKET 버전 관리: $auto_versioning (사람이 켜지 않았다)"
log_versioning="$(aws s3api get-bucket-versioning --bucket "$LOG_BUCKET" --query Status --output text)"
echo "태그 없는 $LOG_BUCKET 버전 관리: $log_versioning (규칙 범위 밖이라 건드리지 않음)"
echo "-- 정리: 자동 수정 설정은 실습이 끝나면 지운다 (범위를 태그로 좁혔어도, 남겨 두면 이후 태그 붙은 버킷에 계속 손을 댄다)"
aws configservice delete-remediation-configuration --config-rule-name "$RULE"

# ---- 단언
grep -q InsufficientDeliveryPolicyException <<<"$channel_err" || fail "정책 없는 버킷으로 전달 채널이 만들어짐: $channel_err"
assert_eq "$recording" "True" "기록기 상태"
assert_eq "$bad_before" "NON_COMPLIANT" "버전 관리 꺼진 버킷"
assert_eq "$ok_before" "COMPLIANT" "버전 관리 켜진 버킷"
assert_eq "$bad_after" "COMPLIANT" "수정 후 재평가"
assert_eq "$auto_versioning" "Enabled" "자동 수정 결과"
assert_eq "$log_versioning" "None" "범위 밖 버킷은 자동 수정 대상이 아님"
echo "LAB08 OK"
