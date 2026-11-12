#!/usr/bin/env bash
# M01 lab01 — 사용자·그룹·정책 생성과 연결 (🟢, MFA 활성화만 🔴)
# 계정 암호 정책 → 그룹 + 고객 관리형 정책 → 사용자 2명을 그룹에 → 인라인 정책(정책 변수)
# → 사용자 키로 "자기 자신만" 조회되는지 확인 → 액세스 키 2개 한도 → 자격 증명 보고서 → MFA(501)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ACCOUNT=000000000000
GROUP=todayorder-developers
POLICY_NAME=todayorder-receipts-read
POLICY_ARN="arn:aws:iam::$ACCOUNT:policy/$POLICY_NAME"
KIM=todayorder-dev-kim
LEE=todayorder-dev-lee
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 이전 실행이 남긴 것을 지우고 시작한다 (멱등).
delete_user_fully "$KIM"
delete_user_fully "$LEE"
delete_group_fully "$GROUP"
delete_policy_fully "$POLICY_ARN"

echo "== 1. 계정 암호 정책 (콘솔 로그인 암호 규칙)"
aws iam update-account-password-policy --minimum-password-length 14 \
  --require-symbols --require-numbers --require-uppercase-characters --require-lowercase-characters \
  --max-password-age 90 --password-reuse-prevention 5
echo "암호 정책 설정 완료"

echo "== 2. 그룹과 고객 관리형 정책"
aws iam create-group --group-name "$GROUP" --query 'Group.Arn' --output text
cat >"$WORK/receipts-read.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadReceipts",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::todayorder-receipts", "arn:aws:s3:::todayorder-receipts/*"]
    }
  ]
}
EOF
aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$WORK/receipts-read.json" \
  --query 'Policy.{Arn: Arn, DefaultVersionId: DefaultVersionId, AttachmentCount: AttachmentCount}'
aws iam attach-group-policy --group-name "$GROUP" --policy-arn "$POLICY_ARN"

echo "== 3. 그룹 인라인 정책: 자기 자신의 사용자 정보·키만 다루기 (정책 변수 \${aws:username})"
cat >"$WORK/self-service.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageOwnUserOnly",
      "Effect": "Allow",
      "Action": ["iam:GetUser", "iam:ListAccessKeys", "iam:CreateAccessKey", "iam:DeleteAccessKey"],
      "Resource": "arn:aws:iam::000000000000:user/${aws:username}"
    }
  ]
}
EOF
aws iam put-group-policy --group-name "$GROUP" --policy-name self-service \
  --policy-document "file://$WORK/self-service.json"

echo "== 4. 사용자 2명을 만들고 그룹에 넣기"
for u in "$KIM" "$LEE"; do
  aws iam create-user --user-name "$u" --query 'User.Arn' --output text
  aws iam add-user-to-group --group-name "$GROUP" --user-name "$u"
done
aws iam get-group --group-name "$GROUP" --query 'Users[].UserName'
aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.AttachmentCount'

echo "== 5. 콘솔 암호: 정책보다 짧은 암호는 거부된다"
expect_fail aws iam create-login-profile --user-name "$KIM" --password 'Short1!' --password-reset-required
err_pw="$ERR"
aws iam create-login-profile --user-name "$KIM" --password 'Todayorder-Pass-2026!' --password-reset-required \
  --query 'LoginProfile.{User: UserName, PasswordResetRequired: PasswordResetRequired}'

echo "== 6. 김 개발자의 액세스 키로: 자기 정보는 보이고, 남의 정보는 거부"
read -r AK SK < <(aws iam create-access-key --user-name "$KIM" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
as_kim() { AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws "$@"; }
self="$(as_kim iam get-user --query 'User.Arn' --output text)"
echo "자기 자신: $self"
expect_fail as_kim iam get-user --user-name "$LEE"
err_other="$ERR"

echo "== 7. 액세스 키는 사용자당 2개까지"
aws iam create-access-key --user-name "$KIM" --query 'AccessKey.Status' --output text
expect_fail aws iam create-access-key --user-name "$KIM"
err_quota="$ERR"

echo "== 8. 자격 증명 보고서 (생성이 끝날 때까지 폴링)"
# 에뮬레이터는 4시간(14400초) 안에 다시 생성을 요청하면 LimitExceeded 로 거부한다.
# 그때는 이미 만들어 둔 보고서를 그대로 읽는다(내용은 그 시점 기준이다).
state=""
for _ in $(seq 1 30); do
  if ! state="$(aws iam generate-credential-report --query State --output text 2>/dev/null)"; then
    aws iam get-credential-report --query GeneratedTime --output text >/dev/null 2>&1 && state="COMPLETE(기존 보고서)"
  fi
  case "$state" in COMPLETE*) break ;; esac
  sleep 1
done
echo "보고서 상태: $state"
case "$state" in
  *기존*) echo "(주의: 이전 실행 때 만든 보고서다 — 사용자 행이 지금 상태와 다를 수 있다. 생성 시각: $(aws iam get-credential-report --query GeneratedTime --output text))" ;;
esac
report="$(aws iam get-credential-report --query Content --output text | base64 --decode)"
printf '%s\n' "$report" | cut -d, -f1,4,8,9 | grep -E '^(user|<root_account>|todayorder-dev-)'

echo "== 9. 가상 MFA 장치 (만들기는 되지만, 사용자에게 활성화하는 API는 미구현)"
SERIAL="arn:aws:iam::$ACCOUNT:mfa/$KIM"
if aws iam list-virtual-mfa-devices --query 'VirtualMFADevices[].SerialNumber' --output text | grep -qw "$SERIAL"; then
  echo "가상 MFA 장치가 이미 있음: $SERIAL (에뮬레이터는 DeleteVirtualMFADevice 가 501이라 지울 수 없다)"
else
  aws iam create-virtual-mfa-device --virtual-mfa-device-name "$KIM" \
    --outfile "$WORK/mfa-seed.txt" --bootstrap-method Base32StringSeed
fi
expect_fail aws iam enable-mfa-device --user-name "$KIM" --serial-number "$SERIAL" \
  --authentication-code1 123456 --authentication-code2 654321
err_mfa="$ERR"

echo "== 10. 그룹에 사용자가 남아 있으면 그룹을 지울 수 없다"
expect_fail aws iam delete-group --group-name "$GROUP"
err_conflict="$ERR"

# ---- 단언
must_contain "$err_pw" "PasswordPolicyViolation" "짧은 암호 거부"
must_contain "$self" ":user/$KIM" "자기 자신 조회"
must_contain "$err_other" "AccessDenied" "다른 사용자 조회 거부"
must_contain "$err_quota" "LimitExceeded" "액세스 키 한도"
case "$state" in COMPLETE*) ;; *) echo "FAIL: 자격 증명 보고서가 COMPLETE가 아님 ($state)"; exit 1 ;; esac
must_contain "$report" "<root_account>" "보고서의 루트 행"
must_contain "$err_mfa" "NotImplemented" "EnableMFADevice 501 (구현되면 FIDELITY 갱신)"
must_contain "$err_conflict" "DeleteConflict" "그룹 삭제 충돌"
[ "$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.AttachmentCount --output text)" = "1" ] \
  || { echo "FAIL: 정책 연결 수가 1이 아님"; exit 1; }

# 정리: 사용자·그룹·정책은 남겨 두지 않는다 (가상 MFA 장치는 지울 수 없어 남는다)
delete_user_fully "$KIM"
delete_user_fully "$LEE"
delete_group_fully "$GROUP"
delete_policy_fully "$POLICY_ARN"
echo "LAB01 OK"
