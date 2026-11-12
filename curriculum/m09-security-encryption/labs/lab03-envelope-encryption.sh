#!/usr/bin/env bash
# M09 lab03 — 봉투 암호화(envelope encryption): KMS 데이터 키 + 로컬 AES-256 (🟢)
# KMS 는 4 KiB 까지만 직접 암호화한다. 큰 데이터(영수증 PDF, 주문 내보내기 파일)는
#   ① GenerateDataKey 로 데이터 키(평문 + KMS 로 암호화된 사본)를 받고
#   ② 평문 데이터 키로 "내 컴퓨터에서" 데이터를 AES 로 암호화한 뒤 평문 키는 버리고
#   ③ 암호화된 데이터 키를 데이터 옆에 같이 저장한다.
# 여기서 로컬 AES 는 openssl 명령(aes-256-cbc)이 맡는다. (boto3 판은 sdk/envelope_encryption.py)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ALIAS="alias/todayorder-m09-exports"
BUCKET="todayorder-m09-exports"
WORK="$TMP_LIB"
cd "$WORK"
command -v openssl >/dev/null || fail "openssl 이 필요합니다 (macOS·Linux 기본 포함)"
reset_alias "$ALIAS"
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true

KEY="$(aws kms create-key --description "TodayOrder 내보내기 파일 키" --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"
aws s3 mb "s3://$BUCKET" >/dev/null

echo "== 0. 암호화할 데이터: 주문 1,000건 내보내기 (KMS Encrypt 한도 4096바이트보다 크다)"
for i in $(seq 1 1000); do printf '{"orderId":"A-%04d","total":%d,"card":"4111-****-****-%04d"}\n' "$i" $((i * 1000)) "$i"; done >orders.jsonl
echo "orders.jsonl: $(wc -c <orders.jsonl | tr -d ' ')바이트"

echo "== 1. GenerateDataKey — 평문 데이터 키와 암호화된 데이터 키를 한 번에 받는다"
aws kms generate-data-key --key-id "$ALIAS" --key-spec AES_256 --encryption-context file=orders-2026-11.jsonl \
  --output json >datakey.json
py 'import base64
d = json.load(sys.stdin)
open("key.plain", "wb").write(base64.b64decode(d["Plaintext"]))
open("key.enc", "wb").write(base64.b64decode(d["CiphertextBlob"]))
print("KeyId:", d["KeyId"])' <datakey.json
rm datakey.json
echo "평문 데이터 키 $(wc -c <key.plain | tr -d ' ')바이트(=256비트) · 암호화된 데이터 키 $(wc -c <key.enc | tr -d ' ')바이트"

echo "== 2. 평문 데이터 키로 로컬에서 AES-256 암호화 → 평문 키는 즉시 삭제"
hexkey() { od -An -tx1 "$1" | tr -d " \n"; }   # 키 파일 → 16진 문자열 (openssl -K 형식)
IV="$(openssl rand -hex 16)"
openssl enc -aes-256-cbc -K "$(hexkey key.plain)" -iv "$IV" -in orders.jsonl -out orders.jsonl.enc
rm -f key.plain
echo "암호문 $(wc -c <orders.jsonl.enc | tr -d ' ')바이트 · 평문 키 파일 남았나? $([ -e key.plain ] && echo 예 || echo 아니오)"

echo "== 3. S3 에 '암호문 + 암호화된 데이터 키 + IV' 를 함께 저장"
aws s3 cp orders.jsonl.enc "s3://$BUCKET/exports/orders-2026-11.jsonl.enc" --no-progress \
  --metadata "x-datakey=$(base64 <key.enc | tr -d '\n'),x-iv=$IV,x-ctx-file=orders-2026-11.jsonl" >/dev/null
aws s3api head-object --bucket "$BUCKET" --key exports/orders-2026-11.jsonl.enc \
  --query '{Size: ContentLength, Metadata: keys(Metadata)}'
rm -f orders.jsonl.enc key.enc

echo "== 4. 복호화: 메타데이터의 암호화된 키 → KMS Decrypt → 로컬 AES 복호화"
aws s3 cp "s3://$BUCKET/exports/orders-2026-11.jsonl.enc" downloaded.enc --no-progress >/dev/null
aws s3api head-object --bucket "$BUCKET" --key exports/orders-2026-11.jsonl.enc --query Metadata --output json >meta.json
py 'import base64; open("key.enc", "wb").write(base64.b64decode(json.load(sys.stdin)["x-datakey"]))' <meta.json
IV2="$(py 'print(json.load(sys.stdin)["x-iv"])' <meta.json)"
aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context file=orders-2026-11.jsonl \
  --query Plaintext --output text | base64 --decode >key.plain
openssl enc -d -aes-256-cbc -K "$(hexkey key.plain)" -iv "$IV2" -in downloaded.enc -out restored.jsonl
rm -f key.plain
head -2 restored.jsonl
cmp orders.jsonl restored.jsonl && echo "원본과 동일 ($(wc -l <restored.jsonl | tr -d ' ')줄)"
same=$?

echo "== 5. KMS 키를 비활성화하면 → 데이터 키를 못 풀어 파일도 못 연다 (= 키 하나로 모든 파일을 잠근다)"
aws kms disable-key --key-id "$KEY"
expect_error locked_err aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context file=orders-2026-11.jsonl
echo "$locked_err" | grep -m1 'error occurred'
aws kms enable-key --key-id "$KEY"

echo "== 6. GenerateDataKeyWithoutPlaintext — 지금 당장은 암호화하지 않을 쪽(예: 나중에 쓸 워커)에 넘길 키"
aws kms generate-data-key-without-plaintext --key-id "$ALIAS" --key-spec AES_256 --query 'keys(@)' --output text

# ---- 단언
assert_eq "$same" "0" "봉투 암호화 왕복"
grep -q DisabledException <<<"$locked_err" || fail "비활성 키로 데이터 키 복호화가 됨"
echo "LAB03 OK"
