#!/usr/bin/env bash
# M01 lab03 — 권한 거부 재현 (IAM·EC2 🟢 / S3 대비 🟡)
# 1) 정책 없는 인턴: IAM·EC2 호출이 암묵적 Deny 로 거부된다
# 2) Allow 를 붙이면 통과한다
# 3) 명시적 Deny 를 더하면 Allow 가 있어도 거부된다 (명시적 Deny > Allow)
# 4) 권한 경계: 자격 증명 정책이 허용해도 경계 밖이면 거부된다
# 5) 같은 인턴이 S3에서는? — 에뮬레이터는 S3 버킷 관리 API(CreateBucket·ListBuckets·DeleteBucket)에
#    사용자 정책을 적용하지 않는다. 객체 API(PutObject 등)에는 적용한다. 실제 AWS는 모두 거부한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

INTERN=todayorder-intern
BUCKET=todayorder-intern-scratch
SEED_BUCKET=todayorder-m01-receipts

cleanup() {
  aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
  aws s3 rb "s3://$SEED_BUCKET" --force >/dev/null 2>&1 || true
  delete_user_fully "$INTERN"
}
cleanup

echo "== 1. 정책이 하나도 없는 인턴"
aws iam create-user --user-name "$INTERN" --query User.Arn --output text
read -r AK SK < <(aws iam create-access-key --user-name "$INTERN" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
as_intern() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws "$@"; }
echo "--- iam list-users"
expect_fail as_intern iam list-users
e_iam_implicit="$ERR"
echo "--- ec2 describe-vpcs"
expect_fail as_intern ec2 describe-vpcs
e_ec2_implicit="$ERR"

echo "== 2. Allow 정책을 붙인다 (iam:ListUsers, ec2:Describe*)"
aws iam put-user-policy --user-name "$INTERN" --policy-name allow-read --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": ["iam:ListUsers", "ec2:Describe*"], "Resource": "*"}]
}'
users="$(as_intern iam list-users --query 'length(Users)' --output text)"
vpcs="$(as_intern ec2 describe-vpcs --query 'length(Vpcs)' --output text)"
echo "iam list-users → 사용자 $users 명 · ec2 describe-vpcs → VPC $vpcs 개"

echo "== 3. 명시적 Deny 를 하나 더 붙인다 (ec2:DescribeVpcs)"
aws iam put-user-policy --user-name "$INTERN" --policy-name deny-vpcs --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Deny", "Action": "ec2:DescribeVpcs", "Resource": "*"}]
}'
expect_fail as_intern ec2 describe-vpcs
e_ec2_explicit="$ERR"
subnets="$(as_intern ec2 describe-subnets --query 'length(Subnets)' --output text)"
echo "ec2 describe-subnets (Deny 대상 아님) → 서브넷 $subnets 개"

echo "== 4. 권한 경계: AWS 관리형 IAMReadOnlyAccess 를 경계로 건다"
aws iam put-user-permissions-boundary --user-name "$INTERN" \
  --permissions-boundary arn:aws:iam::aws:policy/IAMReadOnlyAccess
aws iam get-user --user-name "$INTERN" --query User.PermissionsBoundary
expect_fail as_intern ec2 describe-subnets
e_boundary="$ERR"
users_b="$(as_intern iam list-users --query 'length(Users)' --output text)"
echo "iam list-users (정책 ∩ 경계 안) → 사용자 $users_b 명"

echo "== 5. 같은 인턴 + S3 (명시적 Deny s3:* 를 붙인 상태에서)"
aws iam put-user-policy --user-name "$INTERN" --policy-name deny-s3 --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Deny", "Action": "s3:*", "Resource": "*"}]
}'
aws s3 mb "s3://$SEED_BUCKET" >/dev/null
echo '{"orderId":"A-1001"}' | aws s3 cp - "s3://$SEED_BUCKET/receipts/A-1001.json"
echo "--- s3api create-bucket (실제 AWS: 거부)"
mb="$(as_intern s3api create-bucket --bucket "$BUCKET" --query Location --output text 2>&1)" && mb_rc=0 || mb_rc=$?
echo "$mb (종료 코드 $mb_rc)"
echo "--- s3api list-buckets (실제 AWS: 거부)"
lb="$(as_intern s3api list-buckets --query 'Buckets[].Name' --output text 2>&1)" && lb_rc=0 || lb_rc=$?
echo "$lb (종료 코드 $lb_rc)"
echo "--- s3api get-object (실제 AWS: 거부)"
expect_fail as_intern s3api get-object --bucket "$SEED_BUCKET" --key receipts/A-1001.json /dev/null
e_s3_get="$ERR"

# ---- 단언
must_contain "$e_iam_implicit" "AccessDenied" "IAM 암묵적 Deny"
must_contain "$e_iam_implicit" "no identity-based policy allows" "IAM 암묵적 Deny 사유"
must_contain "$e_ec2_implicit" "UnauthorizedOperation" "EC2 암묵적 Deny"
[ "$users" -ge 1 ] && [ "$vpcs" -ge 1 ] || { echo "FAIL: Allow 후에도 조회 실패"; exit 1; }
must_contain "$e_ec2_explicit" "explicit deny" "명시적 Deny 가 Allow 를 이김"
[ "$subnets" -ge 1 ] || { echo "FAIL: describe-subnets 가 허용돼야 함"; exit 1; }
must_contain "$e_boundary" "no permissions boundary allows" "권한 경계 밖 거부"
[ "$users_b" -ge 1 ] || { echo "FAIL: 경계 안 동작이 거부됨"; exit 1; }
must_contain "$e_s3_get" "AccessDenied" "S3 객체 API 는 사용자 정책을 평가"
# 에뮬레이터 한계 (🟡): 버킷 관리 API 는 통과. 바뀌면 README·FIDELITY 갱신이 필요하다.
[ "$mb_rc" -eq 0 ] || { echo "FAIL: S3 CreateBucket 이 거부됨 — 에뮬레이터가 바뀌었다. README '에뮬레이터 제약' 갱신 필요"; exit 1; }
must_contain "$lb" "$BUCKET" "S3 ListBuckets 통과(에뮬레이터 한계)"

cleanup
echo "LAB03 OK"
