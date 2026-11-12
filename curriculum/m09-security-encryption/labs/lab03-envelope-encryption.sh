#!/usr/bin/env bash
# M09 lab03 — 봉투 암호화(envelope encryption): KMS 데이터 키 + 로컬 AES-256-GCM (🟢)
# KMS 는 4 KiB 까지만 직접 암호화한다. 큰 데이터(영수증 PDF, 주문 내보내기 파일)는
#   ① GenerateDataKey 로 데이터 키(평문 + KMS 로 암호화된 사본)를 받고
#   ② 평문 데이터 키로 "내 컴퓨터에서" 데이터를 AES 로 암호화한 뒤 평문 키는 버리고
#   ③ 암호화된 데이터 키를 데이터 옆에 같이 저장한다.
# 로컬 AES 는 짧은 파이썬(cryptography 의 AES-256-GCM)이 맡는다. 평문 데이터 키는 aws CLI 의 JSON 출력에서
# 파이프(표준 입력)로만 파이썬에 넘어간다 → 명령줄 인자(ps 에 보임)·셸 변수·디스크 어디에도 남지 않는다.
# (boto3 판은 sdk/envelope_encryption.py)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ALIAS="alias/todayorder-m09-exports"
BUCKET="todayorder-m09-exports"
CTX="file=orders-2026-11.jsonl"   # KMS 암호화 컨텍스트이자 GCM 의 AAD
WORK="$TMP_LIB"
cd "$WORK"
reset_alias "$ALIAS"
nuke_bucket "$BUCKET"

# gcm_seal <평문 파일> <출력 파일> <AAD>  — 표준 입력: GenerateDataKey JSON. 출력: nonce(12) || 암호문+태그
#   암호화된 데이터 키는 <출력 파일>.key 에 쓴다. 평문 키는 파이썬 프로세스 메모리에만 있다.
gcm_seal() {
  py '
import base64, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
d = json.load(sys.stdin)
src, dst, aad = sys.argv[1], sys.argv[2], sys.argv[3].encode()
nonce = os.urandom(12)  # 메시지마다 새 96비트 nonce
ct = AESGCM(base64.b64decode(d["Plaintext"])).encrypt(nonce, open(src, "rb").read(), aad)
open(dst, "wb").write(nonce + ct)
open(dst + ".key", "wb").write(base64.b64decode(d["CiphertextBlob"]))
print("KeyId:", d["KeyId"])' "$@"
}
# gcm_open <암호 파일> <출력 파일> <AAD>  — 표준 입력: Decrypt JSON(평문 데이터 키). 태그가 안 맞으면 실패
gcm_open() {
  py '
import base64
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = base64.b64decode(json.load(sys.stdin)["Plaintext"])
blob = open(sys.argv[1], "rb").read()
try:
    pt = AESGCM(key).decrypt(blob[:12], blob[12:], sys.argv[3].encode())
except InvalidTag:
    sys.exit("InvalidTag: 암호문·nonce·AAD 중 하나가 바뀌었다 (GCM 태그 검증 실패)")
open(sys.argv[2], "wb").write(pt)' "$@"
}

KEY="$(aws kms create-key --description "TodayOrder 내보내기 파일 키" --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"
aws s3 mb "s3://$BUCKET" >/dev/null

echo "== 0. 암호화할 데이터: 주문 1,000건 내보내기 (KMS Encrypt 한도 4096바이트보다 크다)"
for i in $(seq 1 1000); do printf '{"orderId":"A-%04d","total":%d,"card":"4111-****-****-%04d"}\n' "$i" $((i * 1000)) "$i"; done >orders.jsonl
echo "orders.jsonl: $(wc -c <orders.jsonl | tr -d ' ')바이트"

echo "== 1·2. GenerateDataKey → (파이프로) 로컬 AES-256-GCM 암호화. 평문 키는 파일·변수·명령줄에 남지 않는다"
aws kms generate-data-key --key-id "$ALIAS" --key-spec AES_256 --encryption-context "$CTX" --output json \
  | gcm_seal orders.jsonl orders.jsonl.enc "$CTX"
echo "암호문 $(wc -c <orders.jsonl.enc | tr -d ' ')바이트(= nonce 12 + 평문 + GCM 태그 16) · 암호화된 데이터 키 $(wc -c <orders.jsonl.enc.key | tr -d ' ')바이트"
ls "$WORK" | sed 's/^/  작업 폴더: /'

echo "== 3. S3 에 '암호문(nonce 포함) + 암호화된 데이터 키 + 컨텍스트' 를 함께 저장"
aws s3 cp orders.jsonl.enc "s3://$BUCKET/exports/orders-2026-11.jsonl.enc" --no-progress \
  --metadata "x-datakey=$(base64 <orders.jsonl.enc.key | tr -d '\n'),x-ctx=$CTX,x-alg=AES-256-GCM" >/dev/null
aws s3api head-object --bucket "$BUCKET" --key exports/orders-2026-11.jsonl.enc \
  --query '{Size: ContentLength, Metadata: keys(Metadata)}'
rm -f orders.jsonl.enc orders.jsonl.enc.key

echo "== 4. 복호화: 메타데이터의 암호화된 키 → KMS Decrypt →(파이프)→ 로컬 AES-GCM 복호화(태그 검증)"
aws s3 cp "s3://$BUCKET/exports/orders-2026-11.jsonl.enc" downloaded.enc --no-progress >/dev/null
aws s3api head-object --bucket "$BUCKET" --key exports/orders-2026-11.jsonl.enc --query Metadata --output json \
  | py 'import base64; open("key.enc", "wb").write(base64.b64decode(json.load(sys.stdin)["x-datakey"]))'
aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context "$CTX" --output json \
  | gcm_open downloaded.enc restored.jsonl "$CTX"
head -2 restored.jsonl
same=1
cmp -s orders.jsonl restored.jsonl && same=0
echo "원본과 동일: $([ "$same" = 0 ] && echo 예 || echo 아니오) ($(wc -l <restored.jsonl | tr -d ' ')줄)"

echo "== 5. 암호문 1바이트 변조 → GCM 태그 검증 실패 (CBC 와 달리 바꿔치기를 알아챈다)"
py 'b = bytearray(open("downloaded.enc", "rb").read()); b[100] ^= 1; open("tampered.enc", "wb").write(bytes(b))' </dev/null
set +e
tamper_out="$(aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context "$CTX" --output json \
  | gcm_open tampered.enc tampered.out "$CTX" 2>&1)"
set -e
echo "$tamper_out"

echo "== 6. KMS 키를 비활성화하면 → 데이터 키를 못 풀어 파일도 못 연다 (= 키 하나로 모든 파일을 잠근다)"
aws kms disable-key --key-id "$KEY"
expect_error locked_err aws kms decrypt --ciphertext-blob fileb://key.enc --encryption-context "$CTX"
echo "$locked_err" | grep -m1 'error occurred'
aws kms enable-key --key-id "$KEY"

echo "== 7. GenerateDataKeyWithoutPlaintext — 지금 당장은 암호화하지 않을 쪽(예: 나중에 쓸 워커)에 넘길 키"
aws kms generate-data-key-without-plaintext --key-id "$ALIAS" --key-spec AES_256 --query 'keys(@)' --output text

# ---- 단언
assert_eq "$same" "0" "봉투 암호화 왕복"
grep -q InvalidTag <<<"$tamper_out" || fail "변조가 탐지되지 않음: $tamper_out"
[ ! -e tampered.out ] || fail "변조된 파일이 복호화됨"
grep -q DisabledException <<<"$locked_err" || fail "비활성 키로 데이터 키 복호화가 됨"
echo "LAB03 OK"
