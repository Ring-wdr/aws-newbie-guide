#!/usr/bin/env bash
# M09 lab02 — 키 정책과 IAM 정책의 관계, 키 정책의 명시적 Deny (🟢)
# ① 기본 키 정책(계정 root 에게 kms:*)만 있으면 "IAM 정책으로 위임" 상태 → IAM 정책 없는 사용자는 거부
# ② IAM 정책을 붙이면 허용 ③ 키 정책에 암호화 컨텍스트 조건 Deny 를 넣으면 IAM 허용과 무관하게 거부
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ALIAS="alias/todayorder-m09-payments"
USER_NAME="todayorder-m09-batch"
WORK="$TMP_LIB"
cd "$WORK"
reset_alias "$ALIAS"
delete_iam_user "$USER_NAME"

KEY="$(aws kms create-key --description "TodayOrder 결제 키" --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"
KEY_ARN="arn:aws:kms:us-east-1:000000000000:key/$KEY"
printf 'pg-token-123' >plain.txt

echo "== 1. 기본 키 정책 — 계정(root)에게 kms:* 를 준다 = 'IAM 정책으로 권한을 위임한다'는 뜻"
aws kms get-key-policy --key-id "$KEY" --policy-name default --query Policy --output text

echo "== 2. IAM 정책이 없는 배치 사용자로 Encrypt (실패해야 정상)"
aws iam create-user --user-name "$USER_NAME" --query User.Arn --output text
read -r AK SK < <(aws iam create-access-key --user-name "$USER_NAME" --query 'AccessKey.[AccessKeyId, SecretAccessKey]' --output text)
as_batch() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SHARED_CREDENTIALS_FILE=/dev/null aws "$@"; }
poll 30 "새 액세스 키 인식" as_batch sts get-caller-identity
expect_error noiam_err as_batch kms encrypt --key-id "$KEY_ARN" --plaintext fileb://plain.txt
echo "$noiam_err" | grep -m1 'error occurred'

echo "== 3. IAM 정책으로 이 키의 Encrypt/Decrypt 허용 → 성공"
aws iam put-user-policy --user-name "$USER_NAME" --policy-name use-payments-key --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{\"Effect\": \"Allow\", \"Action\": [\"kms:Encrypt\", \"kms:Decrypt\"], \"Resource\": \"$KEY_ARN\"}]}"
poll 30 "IAM 정책 반영" as_batch kms encrypt --key-id "$KEY_ARN" --plaintext fileb://plain.txt
as_batch kms encrypt --key-id "$KEY_ARN" --plaintext fileb://plain.txt --encryption-context app=batch \
  --query CiphertextBlob --output text | base64 --decode >batch.bin
as_batch kms encrypt --key-id "$KEY_ARN" --plaintext fileb://plain.txt --encryption-context app=orders-api \
  --query CiphertextBlob --output text | base64 --decode >api.bin
iam_ok="$(as_batch kms decrypt --ciphertext-blob fileb://batch.bin --encryption-context app=batch --query Plaintext --output text | base64 --decode)"
echo "IAM 정책 추가 후 배치 사용자 Decrypt: $iam_ok"

echo "== 4. 키 정책에 명시적 Deny: 컨텍스트 app=orders-api 가 아니면 누구도 Decrypt 불가"
cat >policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "EnableIAMUserPermissions", "Effect": "Allow",
     "Principal": {"AWS": "arn:aws:iam::000000000000:root"}, "Action": "kms:*", "Resource": "*"},
    {"Sid": "DenyDecryptOutsideOrdersApi", "Effect": "Deny",
     "Principal": {"AWS": "*"}, "Action": "kms:Decrypt", "Resource": "*",
     "Condition": {"StringNotEquals": {"kms:EncryptionContext:app": "orders-api"}}}
  ]
}
EOF
aws kms put-key-policy --key-id "$KEY" --policy-name default --policy file://policy.json
expect_error deny_err as_batch kms decrypt --ciphertext-blob fileb://batch.bin --encryption-context app=batch
echo "배치 사용자, app=batch  → $(grep -m1 -o 'AccessDeniedException.*' <<<"$deny_err")"
expect_error deny_admin_err aws kms decrypt --ciphertext-blob fileb://batch.bin --encryption-context app=batch
echo "관리자(emulator), app=batch → $(grep -m1 -o 'AccessDeniedException' <<<"$deny_admin_err")"
api_ok="$(as_batch kms decrypt --ciphertext-blob fileb://api.bin --encryption-context app=orders-api --query Plaintext --output text | base64 --decode)"
echo "배치 사용자, app=orders-api → $api_ok"

echo "== 5. 키 정책을 기본으로 되돌린다 (Deny 를 지운다)"
aws kms put-key-policy --key-id "$KEY" --policy-name default --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{\"Sid\": \"EnableIAMUserPermissions\", \"Effect\": \"Allow\",
    \"Principal\": {\"AWS\": \"arn:aws:iam::000000000000:root\"}, \"Action\": \"kms:*\", \"Resource\": \"*\"}]}"
restored="$(aws kms decrypt --ciphertext-blob fileb://batch.bin --encryption-context app=batch --query Plaintext --output text | base64 --decode)"
echo "Deny 제거 후 관리자 Decrypt(app=batch): $restored"
delete_iam_user "$USER_NAME"

# ---- 단언
grep -q 'no identity-based policy allows' <<<"$noiam_err" || fail "IAM 정책 없는 사용자가 거부되지 않음: $noiam_err"
assert_eq "$iam_ok" "pg-token-123" "IAM 정책 추가 후 복호화"
grep -q 'explicit deny in a resource-based policy' <<<"$deny_err" || fail "키 정책 Deny 가 집행되지 않음: $deny_err"
grep -q AccessDeniedException <<<"$deny_admin_err" || fail "관리자도 Deny 에 걸려야 함"
assert_eq "$api_ok" "pg-token-123" "조건을 만족하는 복호화"
assert_eq "$restored" "pg-token-123" "정책 복원 후 복호화"
echo "LAB02 OK"
