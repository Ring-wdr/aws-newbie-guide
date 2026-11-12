#!/usr/bin/env bash
# M04 lab01 — S3 기본: 버킷·객체·키·접두사·메타데이터 (🟢)
# 버킷 이름 규칙 → 객체 CRUD → "폴더"는 키의 접두사일 뿐 → 사용자 메타데이터·태그 → 덮어쓰기 직후 읽기(강한 일관성)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

BUCKET="todayorder-m04-products"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# 이전 실행이 남긴 버킷이 있으면 지우고 시작한다 (멱등).
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true

echo "== 1. 버킷 이름 규칙: 대문자는 안 된다"
set +e
bad_name="$(aws s3api create-bucket --bucket TodayOrder-Images 2>&1 >/dev/null)"
set -e
echo "$bad_name"

echo "== 2. 버킷 만들기"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text

echo "== 3. 객체 올리기 (키에 '/'가 들어가도 폴더가 생기는 게 아니다)"
printf 'fake-jpeg-bytes-1' >p1.jpg
printf 'fake-jpeg-bytes-2' >p2.jpg
printf '{"sku":"P-001","name":"김치볶음밥"}' >p1.json
aws s3api put-object --bucket "$BUCKET" --key products/P-001/main.jpg --body p1.jpg \
  --content-type image/jpeg --metadata uploaded-by=admin,origin=seller-portal \
  --tagging 'team=catalog' --query ETag --output text
aws s3api put-object --bucket "$BUCKET" --key products/P-001/info.json --body p1.json \
  --content-type application/json --query ETag --output text
aws s3api put-object --bucket "$BUCKET" --key products/P-002/main.jpg --body p2.jpg \
  --content-type image/jpeg --query ETag --output text

echo "== 4. 접두사(Prefix)와 구분자(Delimiter)로 '폴더처럼' 보기"
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix products/ --delimiter / \
  --query '{Folders: CommonPrefixes[].Prefix, Files: Contents[].Key}' --output json
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix products/P-001/ \
  --query 'Contents[].{Key: Key, Size: Size}' --output json

echo "== 5. 메타데이터는 HEAD로, 태그는 별도 API로"
aws s3api head-object --bucket "$BUCKET" --key products/P-001/main.jpg \
  --query '{ContentType: ContentType, Length: ContentLength, Metadata: Metadata, SSE: ServerSideEncryption}' --output json
aws s3api get-object-tagging --bucket "$BUCKET" --key products/P-001/main.jpg --query TagSet --output json

echo "== 6. 덮어쓰기 직후 바로 읽기 — 새 내용이 나온다 (강한 read-after-write 일관성)"
for i in 1 2 3 4 5; do
  printf 'price-v%s' "$i" >price.txt
  aws s3api put-object --bucket "$BUCKET" --key products/P-001/price.txt --body price.txt >/dev/null
  got="$(aws s3 cp "s3://$BUCKET/products/P-001/price.txt" - )"
  echo "쓰기 price-v$i → 읽기 $got"
  [ "$got" = "price-v$i" ] || { echo "FAIL: 일관성 위반"; exit 1; }
done

echo "== 7. 서버 쪽 복사 (CopyObject) 와 삭제"
aws s3api copy-object --bucket "$BUCKET" --key archive/P-002/main.jpg \
  --copy-source "$BUCKET/products/P-002/main.jpg" --query CopyObjectResult.ETag --output text
aws s3 rm "s3://$BUCKET/products/P-002/main.jpg"

echo "== 8. 없는 키 읽기 → NoSuchKey"
set +e
nokey="$(aws s3api get-object --bucket "$BUCKET" --key products/P-002/main.jpg out.bin 2>&1 >/dev/null)"
set -e
echo "$nokey"

echo "== 9. 비어 있지 않은 버킷 삭제 → BucketNotEmpty"
set +e
notempty="$(aws s3api delete-bucket --bucket "$BUCKET" 2>&1 >/dev/null)"
set -e
echo "$notempty"

keys_json="$(aws s3api list-objects-v2 --bucket "$BUCKET" --output json)"
meta="$(aws s3api head-object --bucket "$BUCKET" --key products/P-001/main.jpg --query 'Metadata."uploaded-by"' --output text)"

echo "== 10. 정리"
aws s3 rb "s3://$BUCKET" --force >/dev/null

# ---- 단언
case "$bad_name" in *InvalidBucketName*) ;; *) echo "FAIL: 대문자 버킷 이름이 거부되지 않음"; exit 1 ;; esac
case "$nokey" in *NoSuchKey*) ;; *) echo "FAIL: NoSuchKey 가 아님"; exit 1 ;; esac
case "$notempty" in *BucketNotEmpty*) ;; *) echo "FAIL: BucketNotEmpty 가 아님"; exit 1 ;; esac
[ "$meta" = "admin" ] || { echo "FAIL: 사용자 메타데이터 불일치 ($meta)"; exit 1; }
n="$(jq '.Contents | length' <<<"$keys_json")"
[ "$n" = "4" ] || { echo "FAIL: 객체 수가 4가 아님 ($n)"; exit 1; }
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "FAIL: 버킷이 아직 남아 있음"; exit 1
fi
echo "LAB01 OK"
