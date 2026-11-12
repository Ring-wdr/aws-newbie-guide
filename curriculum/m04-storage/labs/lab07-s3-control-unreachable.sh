#!/usr/bin/env bash
# M04 lab07 — 액세스 포인트·계정 수준 퍼블릭 액세스 차단 (🔴 S3 Control API 가 에뮬레이터에 도달하지 않음)
# 1) S3 Control 호출이 어디로 가는지 관찰 → 2) 대체: 버킷 수준 퍼블릭 액세스 차단 읽기·쓰기
# 3) 대체: 액세스 포인트 정책과 "버킷 정책 위임" JSON 을 써 보고 jq 로 구조를 검사
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-shared-data"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null

echo "== 1. S3 Control: 액세스 포인트 만들기 → 호스트명에 계정 ID 가 붙어 에뮬레이터에 닿지 않는다"
set +e
ap_err="$(aws s3control create-access-point --account-id 000000000000 --name todayorder-analytics \
  --bucket "$BUCKET" --cli-connect-timeout 3 --cli-read-timeout 5 2>&1 >/dev/null)"
echo "$ap_err" | sed '/^$/d'
echo "== 2. S3 Control: 계정 수준 퍼블릭 액세스 차단 조회 → 같은 이유로 실패"
acct_err="$(aws s3control get-public-access-block --account-id 000000000000 \
  --cli-connect-timeout 3 --cli-read-timeout 5 2>&1 >/dev/null)"
set -e
echo "$acct_err" | sed '/^$/d'

echo "== 3. 대체 실습 (a): 버킷 수준 퍼블릭 액세스 차단은 일반 S3 API 라 동작한다"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api get-public-access-block --bucket "$BUCKET" --query PublicAccessBlockConfiguration --output json
bpa_all="$(aws s3api get-public-access-block --bucket "$BUCKET" --output json | jq '[.PublicAccessBlockConfiguration[]] | all')"

echo "== 4. 대체 실습 (b): 액세스 포인트 설계를 JSON 으로 — 분석팀 전용 액세스 포인트(읽기, analytics/ 만)"
cat >ap-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AnalyticsReadOnly",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::000000000000:role/todayorder-analytics" },
    "Action": ["s3:GetObject"],
    "Resource": "arn:aws:s3:us-east-1:000000000000:accesspoint/todayorder-analytics/object/analytics/*"
  }]
}
JSON
echo "-- 버킷 정책: '이 계정의 액세스 포인트를 거쳐 온 요청'에 권한을 위임 (s3:DataAccessPointAccount)"
cat >bucket-delegation.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DelegateToAccessPoints",
    "Effect": "Allow",
    "Principal": { "AWS": "*" },
    "Action": "*",
    "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
    "Condition": { "StringEquals": { "s3:DataAccessPointAccount": "000000000000" } }
  }]
}
JSON
jq -c '.Statement[] | {Sid, Resource}' ap-policy.json
jq -c '.Statement[] | {Sid, Condition}' bucket-delegation.json
echo "-- 위임 정책은 Principal \"*\" 지만 조건이 있어 '퍼블릭'이 아니다 → BlockPublicPolicy 를 통과하는지 확인"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-delegation.json
aws s3api get-bucket-policy-status --bucket "$BUCKET" --query PolicyStatus --output json
is_public="$(aws s3api get-bucket-policy-status --bucket "$BUCKET" --query PolicyStatus.IsPublic --output text)"

echo "== 5. 정리"
purge_bucket "$BUCKET"

# ---- 단언: S3 Control 이 여전히 도달 불가인지 (도달하기 시작하면 실습 등급을 올려야 한다)
case "$ap_err" in *'000000000000.127.0.0.1'*) ;; *) echo "FAIL: S3 Control 동작이 바뀜 → 레슨 4·README 갱신 필요: $ap_err"; exit 1 ;; esac
case "$acct_err" in *'000000000000.127.0.0.1'*) ;; *) echo "FAIL: S3 Control 동작이 바뀜: $acct_err"; exit 1 ;; esac
[ "$bpa_all" = "true" ] || { echo "FAIL: 버킷 수준 BPA"; exit 1; }
[ "$is_public" = "False" ] || { echo "FAIL: 위임 정책이 퍼블릭으로 판정됨 ($is_public)"; exit 1; }
echo "LAB07 OK"
