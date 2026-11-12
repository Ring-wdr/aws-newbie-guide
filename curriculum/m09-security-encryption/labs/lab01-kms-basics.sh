#!/usr/bin/env bash
# M09 lab01 — KMS 키 생성·Encrypt/Decrypt·암호화 컨텍스트·비활성화·교체·삭제 예약·다중 리전 키 (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ALIAS="alias/todayorder-m09-orders"
WORK="$TMP_LIB"
cd "$WORK"
reset_alias "$ALIAS"

echo "== 1. 고객 관리형 키 만들기 + 별칭"
KEY="$(aws kms create-key --description "TodayOrder 주문 데이터 키" --tags TagKey=app,TagValue=todayorder \
  --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"
aws kms describe-key --key-id "$ALIAS" \
  --query 'KeyMetadata.{KeyState: KeyState, KeySpec: KeySpec, KeyUsage: KeyUsage, KeyManager: KeyManager, Origin: Origin, MultiRegion: MultiRegion}'

echo "== 2. Encrypt → Decrypt (암호화 컨텍스트 orderId=A-1001)"
printf 'card=4111-1111-1111-1111' >plain.txt
aws kms encrypt --key-id "$ALIAS" --plaintext fileb://plain.txt --encryption-context orderId=A-1001 \
  --query CiphertextBlob --output text | base64 --decode >cipher.bin
echo "평문 $(wc -c <plain.txt | tr -d ' ')바이트 → 암호문 $(wc -c <cipher.bin | tr -d ' ')바이트"
# 대칭 키의 암호문에는 키 ID 가 들어 있어 Decrypt 에 --key-id 를 주지 않아도 된다.
aws kms decrypt --ciphertext-blob fileb://cipher.bin --encryption-context orderId=A-1001 --output json \
  --query '{KeyId: KeyId, Plaintext: Plaintext}' >dec.json
cat dec.json
roundtrip="$(py 'import base64; print(base64.b64decode(json.load(sys.stdin)["Plaintext"]).decode())' <dec.json)"
echo "복호화 결과: $roundtrip"

echo "== 3. 암호화 컨텍스트가 다르면? (실패해야 정상)"
expect_error ctx_err aws kms decrypt --ciphertext-blob fileb://cipher.bin --encryption-context orderId=A-9999
echo "$ctx_err" | grep -m1 'error occurred'

echo "== 4. 키를 비활성화하면 Decrypt 도 실패한다"
aws kms disable-key --key-id "$KEY"
echo "KeyState: $(aws kms describe-key --key-id "$KEY" --query KeyMetadata.KeyState --output text)"
expect_error disabled_err aws kms decrypt --ciphertext-blob fileb://cipher.bin --encryption-context orderId=A-1001
echo "$disabled_err" | grep -m1 'error occurred'
aws kms enable-key --key-id "$KEY"
after_enable="$(aws kms decrypt --ciphertext-blob fileb://cipher.bin --encryption-context orderId=A-1001 --query Plaintext --output text | base64 --decode)"
echo "다시 활성화 후 복호화: $after_enable"

echo "== 5. Encrypt 는 4 KiB(4096바이트)까지 — 더 크면 봉투 암호화(lab03)"
head -c 4097 /dev/zero >big.bin
expect_error big_err aws kms encrypt --key-id "$ALIAS" --plaintext fileb://big.bin
echo "$big_err" | grep -m1 'error occurred'

echo "== 6. 자동 교체(rotation)와 즉시 교체 — 옛 암호문은 그대로 복호화된다"
aws kms enable-key-rotation --key-id "$KEY"
aws kms get-key-rotation-status --key-id "$KEY" --query '{Enabled: KeyRotationEnabled, PeriodDays: RotationPeriodInDays}'
aws kms rotate-key-on-demand --key-id "$KEY" >/dev/null
aws kms list-key-rotations --key-id "$KEY" --query 'Rotations[].[RotationType, KeyMaterialState]' --output text
after_rotate="$(aws kms decrypt --ciphertext-blob fileb://cipher.bin --encryption-context orderId=A-1001 --query Plaintext --output text | base64 --decode)"
echo "교체 후 옛 암호문 복호화: $after_rotate"

echo "== 7. 삭제 예약(최소 7일) — 대기 중인 키는 쓸 수 없다"
TMPKEY="$(aws kms create-key --description "todayorder-m09 삭제 연습용" --query KeyMetadata.KeyId --output text)"
aws kms encrypt --key-id "$TMPKEY" --plaintext fileb://plain.txt --query CiphertextBlob --output text | base64 --decode >tmp-cipher.bin
expect_error window_err aws kms schedule-key-deletion --key-id "$TMPKEY" --pending-window-in-days 3
echo "대기 3일 → $(grep -o 'ValidationException' <<<"$window_err")"
aws kms schedule-key-deletion --key-id "$TMPKEY" --pending-window-in-days 7 --query '{KeyState: KeyState, PendingWindowInDays: PendingWindowInDays}'
expect_error pending_err aws kms decrypt --ciphertext-blob fileb://tmp-cipher.bin
echo "$pending_err" | grep -m1 'error occurred'
aws kms cancel-key-deletion --key-id "$TMPKEY" >/dev/null
cancel_state="$(aws kms describe-key --key-id "$TMPKEY" --query KeyMetadata.KeyState --output text)"
echo "삭제 취소 후 KeyState: $cancel_state  (취소하면 '비활성' 상태로 돌아온다)"
aws kms schedule-key-deletion --key-id "$TMPKEY" --pending-window-in-days 7 >/dev/null # 연습용 키 정리

echo "== 8. 다중 리전 키 — 같은 키 ID(mrk-)를 다른 리전에 복제"
MRK="$(aws kms create-key --multi-region --description "todayorder-m09 다중 리전" --query KeyMetadata.KeyId --output text)"
aws kms replicate-key --key-id "$MRK" --replica-region ap-northeast-2 --query ReplicaKeyMetadata.Arn --output text
aws kms describe-key --key-id "$MRK" --query 'KeyMetadata.MultiRegionConfiguration.{Type: MultiRegionKeyType, Replicas: ReplicaKeys[].Region}'
aws kms schedule-key-deletion --key-id "arn:aws:kms:ap-northeast-2:000000000000:key/$MRK" --pending-window-in-days 7 >/dev/null 2>&1 || true
aws kms schedule-key-deletion --key-id "$MRK" --pending-window-in-days 7 >/dev/null 2>&1 || true

echo "== 9. AWS 관리형 키 이름(alias/aws/…)은 고객이 쓸 수 없다"
expect_error alias_err aws kms create-alias --alias-name alias/aws/todayorder --target-key-id "$KEY"
echo "$alias_err" | grep -m1 'error occurred'

# ---- 단언
assert_eq "$roundtrip" "card=4111-1111-1111-1111" "Encrypt→Decrypt 왕복"
grep -q InvalidCiphertextException <<<"$ctx_err" || fail "다른 컨텍스트로 복호화가 됨: $ctx_err"
grep -q DisabledException <<<"$disabled_err" || fail "비활성 키로 복호화가 됨: $disabled_err"
assert_eq "$after_enable" "card=4111-1111-1111-1111" "재활성화 후 복호화"
grep -q ValidationException <<<"$big_err" || fail "4097바이트 Encrypt 가 거부되지 않음"
assert_eq "$after_rotate" "card=4111-1111-1111-1111" "교체 후 옛 암호문 복호화"
grep -q ValidationException <<<"$window_err" || fail "삭제 대기 3일이 거부되지 않음"
grep -q KMSInvalidStateException <<<"$pending_err" || fail "삭제 대기 키로 복호화가 됨: $pending_err"
assert_eq "$cancel_state" "Disabled" "삭제 취소 후 상태"
case "$MRK" in mrk-*) ;; *) fail "다중 리전 키 ID 가 mrk- 로 시작하지 않음: $MRK" ;; esac
grep -q NotAuthorizedException <<<"$alias_err" || fail "alias/aws/ 별칭이 만들어짐"
echo "LAB01 OK"
