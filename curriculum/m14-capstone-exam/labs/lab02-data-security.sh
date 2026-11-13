#!/usr/bin/env bash
# M14 lab02 — 캡스톤 계층 2: 데이터·보안
#   CloudFormation: KMS 키(자동 교체)·주문 테이블(GSI·PITR·SSE-KMS)·결제 비밀(Secrets Manager)·설정(Parameter Store)
#   CLI:            영수증 버킷(퍼블릭 차단·SSE-KMS + 버킷 키·버전 관리·수명 주기·HTTPS 강제)
# 등급: 🟢 (S3 수명 주기 "전환" 자체는 일어나지 않음 — 규칙 구성까지)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. 데이터 스택 (CloudFormation)"
deploy_stack "$DATA_STACK" "$LABS/templates/data.yaml"
KEY_ARN="$(stack_output "$DATA_STACK" KeyArn)"
echo "KMS 키: $KEY_ARN"
aws kms get-key-rotation-status --key-id "$KEY_ARN" --query '{Rotation: KeyRotationEnabled, PeriodDays: RotationPeriodInDays}' --output json
aws dynamodb describe-table --table-name "$TABLE" --query 'Table.{Billing: BillingModeSummary.BillingMode, Key: KeySchema[0].AttributeName,
  GSI: GlobalSecondaryIndexes[0].IndexName, GSIKeys: GlobalSecondaryIndexes[0].KeySchema[].AttributeName, SSE: SSEDescription.SSEType}' --output json
aws dynamodb describe-continuous-backups --table-name "$TABLE" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text

echo "== 2. 영수증 버킷 (CLI) — 퍼블릭 차단 → 기본 암호화 SSE-KMS + 버킷 키 → 버전 관리"
if ! aws s3api head-bucket --bucket "$RECEIPTS" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "$RECEIPTS" >/dev/null
fi
aws s3api put-public-access-block --bucket "$RECEIPTS" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$RECEIPTS" --server-side-encryption-configuration "{\"Rules\": [{
  \"ApplyServerSideEncryptionByDefault\": {\"SSEAlgorithm\": \"aws:kms\", \"KMSMasterKeyID\": \"$KEY_ARN\"},
  \"BucketKeyEnabled\": true, \"BlockedEncryptionTypes\": {\"EncryptionType\": [\"SSE-C\"]}}]}"
aws s3api put-bucket-versioning --bucket "$RECEIPTS" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$RECEIPTS" --tagging 'TagSet=[{Key=Project,Value=todayorder},{Key=DataClass,Value=receipt}]'

echo "== 3. 수명 주기: 30일 → Standard-IA, 365일 → Deep Archive, 5년(1825일) 뒤 만료, 이전 버전 30일, 미완료 멀티파트 7일"
aws s3api put-bucket-lifecycle-configuration --bucket "$RECEIPTS" --lifecycle-configuration '{"Rules": [
  {"ID": "receipts-5y", "Status": "Enabled", "Filter": {"Prefix": "receipts/"},
   "Transitions": [{"Days": 30, "StorageClass": "STANDARD_IA"}, {"Days": 365, "StorageClass": "DEEP_ARCHIVE"}],
   "Expiration": {"Days": 1825},
   "NoncurrentVersionExpiration": {"NoncurrentDays": 30}},
  {"ID": "abort-mpu", "Status": "Enabled", "Filter": {"Prefix": ""},
   "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}}]}'
aws s3api get-bucket-lifecycle-configuration --bucket "$RECEIPTS" --output json | py '
for r in json.load(sys.stdin)["Rules"]:
    t = ", ".join("{}d→{}".format(x["Days"], x["StorageClass"]) for x in r.get("Transitions", [])) or "-"
    e = r.get("Expiration", {}).get("Days", "-")
    print("{:<12} 전환[{}] 만료 {}일".format(r["ID"], t, e))'

echo "== 4. 버킷 정책: HTTPS 가 아닌 요청 거부 (aws:SecureTransport=false)"
cat >"$WORK/policy.json" <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
   "Resource": ["arn:aws:s3:::$RECEIPTS", "arn:aws:s3:::$RECEIPTS/*"],
   "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$RECEIPTS" --policy "file://$WORK/policy.json"

echo "== 5. 확인: 객체를 하나 올리면 기본 암호화(SSE-KMS)가 적용된다"
echo '{"orderId":"lab02-probe"}' >"$WORK/probe.json"
aws s3api put-object --bucket "$RECEIPTS" --key receipts/lab02-probe.json --body "$WORK/probe.json" \
  --query '{SSE: ServerSideEncryption, BucketKey: BucketKeyEnabled}' --output json
sse="$(aws s3api head-object --bucket "$RECEIPTS" --key receipts/lab02-probe.json --query ServerSideEncryption --output text)"
aws s3api delete-object --bucket "$RECEIPTS" --key receipts/lab02-probe.json >/dev/null

echo "== 6. 비밀과 설정: 비밀은 Secrets Manager(KMS), 비밀 아닌 설정은 Parameter Store"
aws secretsmanager describe-secret --secret-id "$SECRET" --query '{Name: Name, Kms: KmsKeyId, Rotation: RotationEnabled}' --output json
merchant="$(aws secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text | py 'print(json.load(sys.stdin)["merchantId"])')"
echo "비밀의 merchantId: $merchant (apiKey 는 출력하지 않는다)"
aws ssm get-parameters-by-path --path "$PARAM_PREFIX" --recursive --query 'Parameters[].[Name, Value]' --output text | sort

# ---- 단언
assert_eq "$(aws kms get-key-rotation-status --key-id "$KEY_ARN" --query KeyRotationEnabled --output text)" True "키 자동 교체"
assert_eq "$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.GlobalSecondaryIndexes[0].IndexName' --output text)" byCustomer "GSI"
assert_eq "$(aws dynamodb describe-continuous-backups --table-name "$TABLE" --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text)" ENABLED "PITR"
assert_eq "$(aws s3api get-bucket-encryption --bucket "$RECEIPTS" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" aws:kms "버킷 기본 암호화"
assert_eq "$(aws s3api get-bucket-encryption --bucket "$RECEIPTS" --query 'ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled' --output text)" True "S3 버킷 키"
assert_eq "$sse" aws:kms "업로드 객체 암호화"
assert_eq "$(aws s3api get-bucket-versioning --bucket "$RECEIPTS" --query Status --output text)" Enabled "버전 관리"
assert_eq "$(aws s3api get-public-access-block --bucket "$RECEIPTS" --query 'PublicAccessBlockConfiguration.RestrictPublicBuckets' --output text)" True "퍼블릭 차단"
assert_eq "$merchant" todayorder-test "비밀 내용"
echo "LAB02 OK"
