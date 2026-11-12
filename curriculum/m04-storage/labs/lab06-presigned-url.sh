#!/usr/bin/env bash
# M04 lab06 — 미리 서명된 URL(presigned URL)을 curl 로 검증 (🟢)
# 버킷은 비공개 그대로 두고, "이 객체를 N초 동안만" 열어 주는 URL 을 만든다.
# 1) 서명 없는 GET 403 → 2) presigned GET 200 → 3) 서명 변조 403 → 4) 만료 후 403 → 5) presigned PUT 으로 업로드
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-receipts-url"
KEY="receipts/A-3001.pdf"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null
printf '%%PDF-1.4 fake receipt A-3001' >receipt.pdf
aws s3api put-object --bucket "$BUCKET" --key "$KEY" --body receipt.pdf --content-type application/pdf >/dev/null

# 에뮬레이터는 자체 CA 로 서명한 HTTPS 인증서를 쓴다 → curl 에 CA 를 알려 준다.
CURL=(curl -s --cacert "$AWS_CA_BUNDLE")

echo "== 1. 서명 없이 객체 URL 로 GET → 403 (버킷은 비공개)"
plain_code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$AWS_ENDPOINT_URL/$BUCKET/$KEY")"
echo "HTTP $plain_code"

echo "== 2. 5분짜리 presigned GET URL"
URL="$(aws s3 presign "s3://$BUCKET/$KEY" --expires-in 300)"
# 쿼리 문자열의 서명 관련 파라미터 이름만 보여 준다 (값은 실행마다 다름)
sed 's/^[^?]*?//; s/&/\n/g' <<<"$URL" | cut -d= -f1
get_code="$("${CURL[@]}" -o got.pdf -w '%{http_code}' "$URL")"
echo "HTTP $get_code, 내용: $(cat got.pdf)"

echo "== 3. URL 의 키를 다른 객체로 바꾸면 → 서명 불일치 403"
TAMPERED="${URL/A-3001.pdf/A-9999.pdf}"
tamper_body="$("${CURL[@]}" -w ' HTTP %{http_code}' "$TAMPERED")"
echo "$tamper_body" | grep -o '<Code>[^<]*</Code>\|HTTP [0-9]*'

echo "== 4. 1초짜리 URL → 만료되면 403 (최대 60초 폴링)"
SHORT="$(aws s3 presign "s3://$BUCKET/$KEY" --expires-in 1)"
expired_body=""
for _ in $(seq 1 30); do
  sleep 2
  expired_body="$("${CURL[@]}" -w ' HTTP %{http_code}' "$SHORT")"
  case "$expired_body" in *'HTTP 403'*) break ;; esac
done
echo "$expired_body" | grep -o '<Code>[^<]*</Code>\|<Message>[^<]*</Message>\|HTTP [0-9]*'

echo "== 5. presigned PUT URL (CLI 에는 PUT 서명 기능이 없어 boto3 로 만든다) → curl 로 업로드"
PUT_URL="$(cd "$ROOT" && uv run --quiet python - "$BUCKET" receipts/A-3002.pdf <<'PY'
import sys
from emulator_guard import require_emulator
require_emulator()  # 클라이언트를 만들기 전에 에뮬레이터인지 확인
import boto3
bucket, key = sys.argv[1], sys.argv[2]
print(boto3.client("s3").generate_presigned_url(
    "put_object", Params={"Bucket": bucket, "Key": key, "ContentType": "application/pdf"}, ExpiresIn=300))
PY
)"
printf '%%PDF-1.4 fake receipt A-3002' >upload.pdf
put_code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/pdf' \
  --data-binary @upload.pdf "$PUT_URL")"
echo "HTTP $put_code"
echo "-- 서명에 포함된 Content-Type 과 다르게 보내면 → 403"
bad_ct_code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: image/png' \
  --data-binary @upload.pdf "$PUT_URL")"
echo "HTTP $bad_ct_code"
aws s3api head-object --bucket "$BUCKET" --key receipts/A-3002.pdf \
  --query '{Type: ContentType, Size: ContentLength}' --output json
put_size="$(aws s3api head-object --bucket "$BUCKET" --key receipts/A-3002.pdf --query ContentLength --output text)"

echo "== 6. 정리"
purge_bucket "$BUCKET"

# ---- 단언
[ "$plain_code" = "403" ] || { echo "FAIL: 서명 없는 GET 이 403 이 아님 ($plain_code)"; exit 1; }
[ "$get_code" = "200" ] || { echo "FAIL: presigned GET ($get_code)"; exit 1; }
cmp -s receipt.pdf got.pdf || { echo "FAIL: 내려받은 내용이 다름"; exit 1; }
case "$tamper_body" in *SignatureDoesNotMatch*'HTTP 403') ;; *) echo "FAIL: 변조 URL ($tamper_body)"; exit 1 ;; esac
case "$expired_body" in *'Request has expired'*'HTTP 403') ;; *) echo "FAIL: 만료 URL ($expired_body)"; exit 1 ;; esac
[ "$put_code" = "200" ] || { echo "FAIL: presigned PUT ($put_code)"; exit 1; }
[ "$bad_ct_code" = "403" ] || { echo "FAIL: Content-Type 변조 PUT 이 거부되지 않음 ($bad_ct_code)"; exit 1; }
[ "$put_size" = "$(wc -c <upload.pdf | tr -d ' ')" ] || { echo "FAIL: 업로드 크기"; exit 1; }
echo "LAB06 OK"
