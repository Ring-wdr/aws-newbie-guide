#!/usr/bin/env bash
# M00 lab05 — 에뮬레이터가 AWS와 다른 곳 엿보기 (🟢 관찰 자체는 재현됨)
# 1) 미구현 오퍼레이션은 501 NotImplemented 를 돌려준다.
# 2) IAM 정책은 서비스마다 다르게 평가된다: 권한 없는 사용자가 IAM API는 거부당하지만 S3 버킷은 만들 수 있다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

USER_NAME="todayorder-intern"
BUCKET="todayorder-intern-bucket"

cleanup() {
  aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
  for k in $(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$k" || true
  done
  aws iam delete-user --user-name "$USER_NAME" >/dev/null 2>&1 || true
}
cleanup

echo "== 1. 미구현 오퍼레이션: Organizations CreatePolicy (SCP 만들기)"
set +e
err501="$(aws organizations create-policy --name todayorder-scp --type SERVICE_CONTROL_POLICY \
  --description demo --content '{"Version":"2012-10-17","Statement":[]}' 2>&1 >/dev/null)"
set -e
echo "$err501"

echo "== 2. 정책이 하나도 없는 IAM 사용자 '인턴'과 액세스 키"
aws iam create-user --user-name "$USER_NAME" --query User.Arn --output text
read -r AK SK < <(aws iam create-access-key --user-name "$USER_NAME" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
as_intern() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws "$@"; }

echo "== 3. 인턴으로 iam list-users (실제 AWS: 거부)"
set +e
err_iam="$(as_intern iam list-users 2>&1 >/dev/null)"
set -e
echo "$err_iam"

echo "== 4. 인턴으로 s3 mb (실제 AWS: 거부)"
mb_out="$(as_intern s3 mb "s3://$BUCKET" 2>&1)" || true
echo "$mb_out"

cleanup

# ---- 단언: 관찰한 동작이 FIDELITY.md 와 같은지
case "$err501" in *NotImplemented*) ;; *) echo "FAIL: 501이 아님 (구현되었을 수 있다 → FIDELITY.md 갱신 필요)"; exit 1 ;; esac
case "$err_iam" in *AccessDenied*) ;; *) echo "FAIL: IAM 거부가 일어나지 않음"; exit 1 ;; esac
case "$mb_out" in *make_bucket*) ;; *) echo "FAIL: S3가 정책을 평가하기 시작했다 (FIDELITY.md 갱신 필요)"; exit 1 ;; esac
echo "LAB05 OK"
