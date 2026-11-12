#!/usr/bin/env bash
# M13 lab02 — 수명 주기 규칙으로 영수증 저장 비용 계산하기 (🟢 규칙 구성 / 계산은 워크시트)
#
# 같은 버킷에 수명 주기 규칙 두 안을 차례로 설정하고, 설정값을 읽어 정상 상태 월 비용을 계산한다.
#   안 A: STANDARD → 30일 STANDARD_IA → 90일 GLACIER(Flexible Retrieval) → 360일 DEEP_ARCHIVE → 1800일 삭제
#   안 B: STANDARD → 30일 STANDARD_IA → 90일 DEEP_ARCHIVE → 1800일 삭제
# 에뮬레이터는 전환을 실제로 하지 않으므로(시간이 지나도 STANDARD 에 머문다) 숫자는 규칙에서 계산한다.
# ⚠️ 단가는 예시 숫자다 (sdk/lifecycle_cost.py 의 표). 실제 가격은 AWS Pricing Calculator 로.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
CALC="$ROOT/curriculum/m13-cost-optimization/sdk/lifecycle_cost.py"
BUCKET="todayorder-m13-receipts"
cd "$ROOT"

aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
aws s3 mb "s3://$BUCKET"
printf '{"orderId":"A-3001","total":15000}\n' | aws s3 cp - "s3://$BUCKET/receipts/A-3001.json"

put_rules() { aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration "$1"; }

echo "== 1. 안 A: 4단계"
put_rules '{"Rules":[{"ID":"plan-a-4-tiers","Status":"Enabled","Filter":{"Prefix":"receipts/"},
  "Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"},{"Days":90,"StorageClass":"GLACIER"},{"Days":360,"StorageClass":"DEEP_ARCHIVE"}],
  "Expiration":{"Days":1800}}]}'
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'Rules[0].Transitions'
a="$(uv run --quiet python "$CALC" "$BUCKET")"
echo "$a"

echo "== 2. 안 B: 단계를 줄여 전환 요청 요금 아끼기"
put_rules '{"Rules":[{"ID":"plan-b-3-tiers","Status":"Enabled","Filter":{"Prefix":"receipts/"},
  "Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"},{"Days":90,"StorageClass":"DEEP_ARCHIVE"}],
  "Expiration":{"Days":1800}}]}'
b="$(uv run --quiet python "$CALC" "$BUCKET")"
echo "$b"

echo "== 3. 에뮬레이터에서는 전환이 일어나지 않는다: 방금 올린 객체의 스토리지 클래스"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].{Key:Key,StorageClass:StorageClass}'

# ---- 단언: 레슨 03 워크시트 정답
grep -q '^RESULT rule=plan-a-4-tiers storage=67.00 transitions=110.00 total=177.00 all_standard=750.00$' <<<"$a" \
  || { echo "FAIL: 안 A 계산이 워크시트(177.00)와 다름"; exit 1; }
grep -q '^RESULT rule=plan-b-3-tiers storage=53.50 transitions=60.00 total=113.50 all_standard=750.00$' <<<"$b" \
  || { echo "FAIL: 안 B 계산이 워크시트(113.50)와 다름"; exit 1; }
echo "LAB02 OK"
