#!/usr/bin/env bash
# M00 lab02 — S3 버킷 왕복 (🟢)
# 버킷 만들기 → 영수증 파일 올리기 → 목록 → 메타데이터 → 내려받아 비교 → 정리
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

BUCKET="todayorder-m00-receipts"
KEY="receipts/2026/11/A-1001.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"   # 업로드·다운로드 로그에 짧은 경로가 찍히도록

# 이전 실행이 남긴 버킷이 있으면 지우고 시작한다 (멱등).
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true

echo "== 1. 버킷 만들기"
aws s3 mb "s3://$BUCKET"

echo "== 2. 영수증 업로드"
printf '{"orderId":"A-1001","total":12000,"currency":"KRW"}\n' >receipt.json
aws s3 cp receipt.json "s3://$BUCKET/$KEY" --no-progress

echo "== 3. 목록"
aws s3 ls "s3://$BUCKET" --recursive

echo "== 4. 객체 메타데이터 (s3api head-object)"
aws s3api head-object --bucket "$BUCKET" --key "$KEY" \
  --query '{Size: ContentLength, Type: ContentType, ETag: ETag}'

echo "== 5. 내려받아 원본과 비교"
aws s3 cp "s3://$BUCKET/$KEY" downloaded.json --no-progress
cmp receipt.json downloaded.json && echo "동일한 파일입니다"
size="$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text)"

echo "== 6. 정리 (객체 삭제 → 버킷 삭제)"
aws s3 rm "s3://$BUCKET/$KEY"
aws s3 rb "s3://$BUCKET"

# ---- 단언
[ "$size" = "$(wc -c <receipt.json | tr -d ' ')" ] || { echo "FAIL: 크기 불일치 ($size)"; exit 1; }
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "FAIL: 버킷이 아직 남아 있음"; exit 1
fi
echo "LAB02 OK"
