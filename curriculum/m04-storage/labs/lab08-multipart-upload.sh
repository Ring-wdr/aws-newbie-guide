#!/usr/bin/env bash
# M04 lab08 — 멀티파트 업로드 (🟢)
# 1) 저수준: Create → UploadPart ×2 → ListParts → Complete (ETag 가 "-2" 로 끝남)
# 2) 마지막이 아닌 파트가 5 MiB 미만이면 EntityTooSmall
# 3) 완료하지 않은 업로드는 목록에 남아 (실제 AWS에서는) 요금이 나간다 → Abort
# 4) 고수준 aws s3 cp 는 큰 파일을 알아서 멀티파트로 올린다
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-videos"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null

echo "== 0. 6 MiB 짜리 '홍보 영상' 파일을 5 MiB + 1 MiB 로 자른다"
head -c $((6 * 1024 * 1024)) /dev/urandom >promo.mp4
split -b $((5 * 1024 * 1024)) promo.mp4 part-
ls -l part-* | awk '{print $5, $NF}'

echo "== 1. CreateMultipartUpload → UploadId"
UPLOAD_ID="$(aws s3api create-multipart-upload --bucket "$BUCKET" --key videos/promo.mp4 \
  --content-type video/mp4 --query UploadId --output text)"
echo "UploadId 길이: ${#UPLOAD_ID}"

echo "== 2. UploadPart (파트 번호 1, 2 — 병렬로 올려도 된다)"
E1="$(aws s3api upload-part --bucket "$BUCKET" --key videos/promo.mp4 --upload-id "$UPLOAD_ID" \
  --part-number 1 --body part-aa --query ETag --output text)"
E2="$(aws s3api upload-part --bucket "$BUCKET" --key videos/promo.mp4 --upload-id "$UPLOAD_ID" \
  --part-number 2 --body part-ab --query ETag --output text)"
echo "part1 ETag=$E1"
echo "part2 ETag=$E2"

echo "== 3. 완료 전: 진행 중인 업로드와 파트 목록 (객체는 아직 없다)"
aws s3api list-multipart-uploads --bucket "$BUCKET" --query 'Uploads[].Key' --output json
aws s3api list-parts --bucket "$BUCKET" --key videos/promo.mp4 --upload-id "$UPLOAD_ID" \
  --query 'Parts[].{N: PartNumber, Size: Size}' --output json
# HEAD 응답에는 본문이 없어 오류 코드 대신 HTTP 상태(404)만 보인다.
expect_error 404 aws s3api head-object --bucket "$BUCKET" --key videos/promo.mp4

echo "== 4. CompleteMultipartUpload → 하나의 객체"
cat >parts.json <<JSON
{"Parts":[{"PartNumber":1,"ETag":$E1},{"PartNumber":2,"ETag":$E2}]}
JSON
aws s3api complete-multipart-upload --bucket "$BUCKET" --key videos/promo.mp4 --upload-id "$UPLOAD_ID" \
  --multipart-upload file://parts.json --query '{Key: Key, ETag: ETag}' --output json
aws s3api head-object --bucket "$BUCKET" --key videos/promo.mp4 \
  --query '{Size: ContentLength, ETag: ETag, Type: ContentType}' --output json
mp_etag="$(aws s3api head-object --bucket "$BUCKET" --key videos/promo.mp4 --query ETag --output text)"
mp_size="$(aws s3api head-object --bucket "$BUCKET" --key videos/promo.mp4 --query ContentLength --output text)"
aws s3 cp "s3://$BUCKET/videos/promo.mp4" back.mp4 --no-progress >/dev/null
cmp promo.mp4 back.mp4 && echo "내려받은 파일이 원본과 같다"

echo "== 5. 첫 파트가 5 MiB 미만이면? (1 MiB + 1 MiB) → 완료 단계에서 EntityTooSmall"
SMALL_ID="$(aws s3api create-multipart-upload --bucket "$BUCKET" --key videos/small.mp4 --query UploadId --output text)"
S1="$(aws s3api upload-part --bucket "$BUCKET" --key videos/small.mp4 --upload-id "$SMALL_ID" --part-number 1 --body part-ab --query ETag --output text)"
S2="$(aws s3api upload-part --bucket "$BUCKET" --key videos/small.mp4 --upload-id "$SMALL_ID" --part-number 2 --body part-ab --query ETag --output text)"
echo "{\"Parts\":[{\"PartNumber\":1,\"ETag\":$S1},{\"PartNumber\":2,\"ETag\":$S2}]}" >small.json
expect_error EntityTooSmall aws s3api complete-multipart-upload --bucket "$BUCKET" --key videos/small.mp4 \
  --upload-id "$SMALL_ID" --multipart-upload file://small.json

echo "== 6. 완료 못 한 업로드는 남아 있다 → AbortMultipartUpload 로 파트까지 삭제"
aws s3api list-multipart-uploads --bucket "$BUCKET" --query 'Uploads[].Key' --output json
aws s3api abort-multipart-upload --bucket "$BUCKET" --key videos/small.mp4 --upload-id "$SMALL_ID"
left="$(aws s3api list-multipart-uploads --bucket "$BUCKET" --output json | jq '(.Uploads // []) | length')"
echo "남은 미완료 업로드: $left"

echo "== 7. 고수준 명령: aws s3 cp 는 8 MiB(기본 multipart_threshold) 이상이면 자동으로 멀티파트"
head -c $((20 * 1024 * 1024)) /dev/urandom >menu-video.mp4
aws s3 cp menu-video.mp4 "s3://$BUCKET/videos/menu-video.mp4" --no-progress
auto_etag="$(aws s3api head-object --bucket "$BUCKET" --key videos/menu-video.mp4 --query ETag --output text)"
echo "ETag=$auto_etag   (끝의 -N 이 파트 수: 20 MiB / 8 MiB 청크 = 3)"

echo "== 8. 정리"
purge_bucket "$BUCKET"

# ---- 단언
case "$mp_etag" in *-2\") ;; *) echo "FAIL: 멀티파트 ETag 형식 ($mp_etag)"; exit 1 ;; esac
[ "$mp_size" = "$((6 * 1024 * 1024))" ] || { echo "FAIL: 크기 ($mp_size)"; exit 1; }
[ "$left" = "0" ] || { echo "FAIL: 미완료 업로드가 남음 ($left)"; exit 1; }
case "$auto_etag" in *-3\") ;; *) echo "FAIL: 자동 멀티파트 ETag ($auto_etag)"; exit 1 ;; esac
echo "LAB08 OK"
