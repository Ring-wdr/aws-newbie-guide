#!/usr/bin/env bash
# M04 lab05 — 버킷 보안: 기본값, ACL 비활성화, 퍼블릭 액세스 차단, 버킷 정책 명시적 Deny, SSE-S3/KMS/C (🟢)
# (KMS 키를 비활성화해도 SSE-KMS 객체가 읽히는 에뮬레이터 한계 때문에 "키 의존성" 시연은 하지 않는다 → M09)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-receipts-sec"
ALIAS="alias/todayorder-m04-receipts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null
printf '{"orderId":"A-2001","total":15000}' >r.json

echo "== 1. 새 버킷의 기본 보안 설정 3종"
echo "-- (a) 퍼블릭 액세스 차단: 4개 모두 true"
aws s3api get-public-access-block --bucket "$BUCKET" --output json
echo "-- (b) 객체 소유권: BucketOwnerEnforced = ACL 비활성화"
aws s3api get-bucket-ownership-controls --bucket "$BUCKET" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text
echo "-- (c) 기본 암호화: SSE-S3(AES256), SSE-C 는 차단 목록에"
aws s3api get-bucket-encryption --bucket "$BUCKET" --output json

echo "== 2. 퍼블릭 정책은 퍼블릭 액세스 차단(BlockPublicPolicy)에 막힌다"
cat >public.json <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"PublicRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/*"}]}
JSON
expect_error AccessDenied aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://public.json

echo "== 3. 퍼블릭 ACL 도 막힌다 (BlockPublicAcls)"
aws s3api put-object --bucket "$BUCKET" --key receipts/A-2001.json --body r.json >/dev/null
expect_error AccessDenied aws s3api put-object-acl --bucket "$BUCKET" --key receipts/A-2001.json --acl public-read

echo "== 4. 고객 관리형 KMS 키 + 별칭"
aws kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
KEY_ID="$(aws kms create-key --description 'TodayOrder receipts' --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID"
echo "KeyId=$KEY_ID"

echo "== 5. 버킷 정책: (1) SSE-KMS 가 아닌 업로드 거부 (2) receipts/ 삭제 거부 (3) HTTPS 아닌 요청 거부"
cat >policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonKmsUploads",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/*",
      "Condition": { "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" } }
    },
    {
      "Sid": "DenyReceiptDelete",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:DeleteObject",
      "Resource": "arn:aws:s3:::$BUCKET/receipts/*"
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://policy.json
aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text | jq -c '[.Statement[].Sid]'

echo "-- 암호화 헤더 없이 업로드 → 명시적 Deny"
expect_error AccessDenied aws s3api put-object --bucket "$BUCKET" --key receipts/A-2002.json --body r.json
echo "-- SSE-KMS(내 키)로 업로드 → 통과"
aws s3api put-object --bucket "$BUCKET" --key receipts/A-2002.json --body r.json \
  --server-side-encryption aws:kms --ssekms-key-id "$ALIAS" \
  --query '{SSE: ServerSideEncryption, KeyId: SSEKMSKeyId}' --output json
kms_head="$(aws s3api head-object --bucket "$BUCKET" --key receipts/A-2002.json --query '[ServerSideEncryption, SSEKMSKeyId]' --output text)"
echo "-- receipts/ 삭제 → 명시적 Deny (관리자라도)"
expect_error AccessDenied aws s3api delete-object --bucket "$BUCKET" --key receipts/A-2002.json
echo "-- 읽기는 Deny 대상이 아니므로 통과 (에뮬레이터 연결은 항상 HTTPS)"
aws s3api get-object --bucket "$BUCKET" --key receipts/A-2002.json got.json --query ServerSideEncryption --output text

echo "== 6. 정책을 걷어내고, 버킷 기본 암호화를 SSE-KMS + S3 버킷 키로"
aws s3api delete-bucket-policy --bucket "$BUCKET"
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$ALIAS\"},\"BucketKeyEnabled\":true}]}"
aws s3api put-object --bucket "$BUCKET" --key receipts/A-2003.json --body r.json >/dev/null
aws s3api head-object --bucket "$BUCKET" --key receipts/A-2003.json \
  --query '{SSE: ServerSideEncryption, KeyId: SSEKMSKeyId, BucketKey: BucketKeyEnabled}' --output json
default_sse="$(aws s3api head-object --bucket "$BUCKET" --key receipts/A-2003.json --query ServerSideEncryption --output text)"

echo "== 7. SSE-C: 키를 내가 들고 다닌다 (실습을 위해 차단 목록을 비운다)"
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BlockedEncryptionTypes":{"EncryptionType":["NONE"]}}]}'
head -c 32 /dev/urandom >customer.key
aws s3api put-object --bucket "$BUCKET" --key private/A-2004.json --body r.json \
  --sse-customer-algorithm AES256 --sse-customer-key fileb://customer.key --query SSECustomerAlgorithm --output text
echo "-- 키 없이 읽기 → 거부"
expect_error InvalidRequest aws s3api get-object --bucket "$BUCKET" --key private/A-2004.json out.json
echo "-- 같은 키로 읽기 → 통과"
aws s3api get-object --bucket "$BUCKET" --key private/A-2004.json out.json \
  --sse-customer-algorithm AES256 --sse-customer-key fileb://customer.key --query ContentLength --output text
cmp r.json out.json && echo "SSE-C 왕복 성공"

echo "== 8. 정리"
purge_bucket "$BUCKET"
aws kms delete-alias --alias-name "$ALIAS"
aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 --query KeyState --output text

# ---- 단언
# 실제 AWS는 SSEKMSKeyId 에 키 ARN 을 돌려준다. 에뮬레이터 1.0.322 는 요청에 쓴 별칭을 그대로 돌려준다.
case "$kms_head" in aws:kms*"$KEY_ID"* | aws:kms*"$ALIAS"*) ;; *) echo "FAIL: SSE-KMS 헤더 ($kms_head)"; exit 1 ;; esac
[ "$default_sse" = "aws:kms" ] || { echo "FAIL: 기본 암호화 SSE-KMS 미적용 ($default_sse)"; exit 1; }
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then echo "FAIL: 버킷이 남아 있음"; exit 1; fi
echo "LAB05 OK"
