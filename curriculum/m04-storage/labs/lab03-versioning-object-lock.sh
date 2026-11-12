#!/usr/bin/env bash
# M04 lab03 — 버전 관리·삭제 마커·객체 잠금(WORM) (🟢) · MFA Delete 는 저장만 (🟡)
# 1) 버전 관리 켜기 → 덮어쓰기 → 삭제(삭제 마커) → 이전 버전 읽기 → 삭제 마커 지워 되살리기
# 2) MFA Delete: 설정은 저장되지만 에뮬레이터는 MFA 없는 버전 삭제를 막지 않는다
# 3) 객체 잠금: 거버넌스(우회 가능) / 규정 준수(아무도 못 지움) / 법적 보존(legal hold)
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-menu"
LOCK_BUCKET="todayorder-m04-audit-lock"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
purge_bucket "$LOCK_BUCKET"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null

echo "== 1. 버전 관리 전: 응답에 VersionId 가 없다 (목록에서는 \"null\" 버전으로 보인다)"
printf 'menu v0' >m.txt
aws s3api put-object --bucket "$BUCKET" --key menu.txt --body m.txt --query VersionId --output text

echo "== 2. 버전 관리 켜기"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api get-bucket-versioning --bucket "$BUCKET" --output json

echo "== 3. 같은 키에 두 번 쓰기 → 쓸 때마다 새 VersionId"
printf 'menu v1 (김치볶음밥 8000원)' >m.txt
V1="$(aws s3api put-object --bucket "$BUCKET" --key menu.txt --body m.txt --query VersionId --output text)"
printf 'menu v2 (김치볶음밥 9000원)' >m.txt
V2="$(aws s3api put-object --bucket "$BUCKET" --key menu.txt --body m.txt --query VersionId --output text)"
echo "V1=$V1"
echo "V2=$V2"

echo "== 4. 실수로 삭제 → 실제로는 '삭제 마커'가 최신 버전이 된다"
aws s3api delete-object --bucket "$BUCKET" --key menu.txt --output json
expect_error NoSuchKey aws s3api get-object --bucket "$BUCKET" --key menu.txt out.txt

echo "== 5. 버전 목록: 버전 3개(null 포함) + 삭제 마커 1개"
aws s3api list-object-versions --bucket "$BUCKET" --prefix menu.txt --output json |
  jq -c '((.Versions // []) | map({type: "version", VersionId, IsLatest})) + ((.DeleteMarkers // []) | map({type: "delete-marker", VersionId, IsLatest})) | .[]'

echo "== 6. 이전 버전은 VersionId 로 읽을 수 있다"
aws s3api get-object --bucket "$BUCKET" --key menu.txt --version-id "$V1" v1.txt >/dev/null
echo "V1 내용: $(cat v1.txt)"

echo "== 7. 삭제 마커를 '버전 지정 삭제'하면 객체가 되살아난다"
DM="$(aws s3api list-object-versions --bucket "$BUCKET" --prefix menu.txt --output json | jq -r '.DeleteMarkers[0].VersionId')"
aws s3api delete-object --bucket "$BUCKET" --key menu.txt --version-id "$DM" --output json
aws s3api get-object --bucket "$BUCKET" --key menu.txt now.txt >/dev/null
echo "현재 내용: $(cat now.txt)"
restored="$(cat now.txt)"

echo "== 8. 버전 지정 삭제는 '영구 삭제'다 (V1 을 지우면 되돌릴 수 없다)"
aws s3api delete-object --bucket "$BUCKET" --key menu.txt --version-id "$V1" --output json
expect_error NoSuchVersion aws s3api get-object --bucket "$BUCKET" --key menu.txt --version-id "$V1" out.txt

echo "== 9. 버전 관리는 끌 수 없고 '일시 중지(Suspended)'만 된다"
expect_error MalformedXML aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Disabled
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Suspended
aws s3api get-bucket-versioning --bucket "$BUCKET" --output json

echo "== 10. MFA Delete: x-amz-mfa 헤더 없이 켜려 하면 거부"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
expect_error IllegalVersioningConfigurationException \
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled,MFADelete=Enabled
echo "-- MFA 장치 ARN + 코드를 주면 저장된다 (에뮬레이터는 코드를 검증하지 않는다)"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::000000000000:mfa/root-account-mfa-device 123456"
mfa_state="$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query MFADelete --output text)"
echo "MFADelete=$mfa_state"
echo "-- 에뮬레이터 한계: MFA 없이 버전 지정 삭제가 통과한다 (실제 AWS는 거부)"
aws s3api delete-object --bucket "$BUCKET" --key menu.txt --version-id "$V2" --output json

echo "== 11. 객체 잠금 버킷 만들기 (만들 때 켜면 버전 관리도 자동으로 켜진다)"
aws s3api create-bucket --bucket "$LOCK_BUCKET" --object-lock-enabled-for-bucket >/dev/null
aws s3api get-bucket-versioning --bucket "$LOCK_BUCKET" --output json
aws s3api put-object-lock-configuration --bucket "$LOCK_BUCKET" --object-lock-configuration \
  '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":1}}}'
aws s3api get-object-lock-configuration --bucket "$LOCK_BUCKET" --output json

echo "== 12. 기본 보존(거버넌스 1일)이 새 객체에 자동 적용"
printf '2026-11 정산 내역' >s.txt
GV="$(aws s3api put-object --bucket "$LOCK_BUCKET" --key settlements/2026-11.csv --body s.txt --query VersionId --output text)"
aws s3api head-object --bucket "$LOCK_BUCKET" --key settlements/2026-11.csv \
  --query '{Mode: ObjectLockMode, Until: ObjectLockRetainUntilDate}' --output json
gov_mode="$(aws s3api head-object --bucket "$LOCK_BUCKET" --key settlements/2026-11.csv --query ObjectLockMode --output text)"
expect_error AccessDenied aws s3api delete-object --bucket "$LOCK_BUCKET" --key settlements/2026-11.csv --version-id "$GV"
echo "-- 거버넌스 모드는 s3:BypassGovernanceRetention 권한 + 우회 헤더로 지울 수 있다"
aws s3api delete-object --bucket "$LOCK_BUCKET" --key settlements/2026-11.csv --version-id "$GV" \
  --bypass-governance-retention --output json

echo "== 13. 규정 준수(COMPLIANCE) 모드: 우회 헤더도, 보존 기간 단축도 안 된다"
CV="$(aws s3api put-object --bucket "$LOCK_BUCKET" --key audit/2026-11.log --body s.txt --query VersionId --output text)"
UNTIL="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(seconds=15)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
# 기본 보존(거버넌스 1일)보다 짧게 바꾸는 것이므로 거버넌스 우회 헤더가 필요하다.
aws s3api put-object-retention --bucket "$LOCK_BUCKET" --key audit/2026-11.log --version-id "$CV" \
  --retention "{\"Mode\":\"COMPLIANCE\",\"RetainUntilDate\":\"$UNTIL\"}" --bypass-governance-retention
expect_error AccessDenied aws s3api delete-object --bucket "$LOCK_BUCKET" --key audit/2026-11.log \
  --version-id "$CV" --bypass-governance-retention
expect_error AccessDenied aws s3api put-object-retention --bucket "$LOCK_BUCKET" --key audit/2026-11.log \
  --version-id "$CV" --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$UNTIL\"}" --bypass-governance-retention
echo "-- (실습용으로 보존 기한을 15초 뒤로 잡았다. 기한이 지나면 지울 수 있다 — 최대 120초 폴링)"
deleted_after=no
for _ in $(seq 1 60); do
  if aws s3api delete-object --bucket "$LOCK_BUCKET" --key audit/2026-11.log --version-id "$CV" >/dev/null 2>&1; then
    deleted_after=yes; break
  fi
  sleep 2
done
echo "보존 기한 뒤 삭제: $deleted_after"

echo "== 14. 법적 보존(Legal Hold): 기한 없음, 해제할 때까지 삭제 불가"
HV="$(aws s3api put-object --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf --body s.txt --query VersionId --output text)"
aws s3api put-object-legal-hold --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf --version-id "$HV" --legal-hold Status=ON
aws s3api get-object-legal-hold --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf --version-id "$HV" --output json
expect_error AccessDenied aws s3api delete-object --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf \
  --version-id "$HV" --bypass-governance-retention
aws s3api put-object-legal-hold --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf --version-id "$HV" --legal-hold Status=OFF
aws s3api delete-object --bucket "$LOCK_BUCKET" --key evidence/claim-77.pdf --version-id "$HV" \
  --bypass-governance-retention >/dev/null && echo "해제 후 삭제됨"

echo "== 15. 정리"
purge_bucket "$BUCKET"
purge_bucket "$LOCK_BUCKET"

# ---- 단언
[ "$restored" = "menu v2 (김치볶음밥 9000원)" ] || { echo "FAIL: 삭제 마커 제거 후 복구 실패 ($restored)"; exit 1; }
[ "$mfa_state" = "Enabled" ] || { echo "FAIL: MFADelete 상태 ($mfa_state)"; exit 1; }
[ "$gov_mode" = "GOVERNANCE" ] || { echo "FAIL: 기본 보존 미적용 ($gov_mode)"; exit 1; }
[ "$deleted_after" = "yes" ] || { echo "FAIL: 보존 기한 뒤에도 삭제 안 됨"; exit 1; }
for b in "$BUCKET" "$LOCK_BUCKET"; do
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then echo "FAIL: $b 가 남아 있음"; exit 1; fi
done
echo "LAB03 OK"
