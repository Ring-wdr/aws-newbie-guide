#!/usr/bin/env bash
# M06 lab07 — Kinesis Data Streams: 파티션 키 → 샤드, 샤드 안의 순서, 여러 소비자가 같은 데이터를 읽기 (🟢)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

S=todayorder-order-stream

echo "== 1. 샤드 2개짜리 스트림 (프로비저닝 모드)"
if aws kinesis describe-stream-summary --stream-name "$S" >/dev/null 2>&1; then
  aws kinesis delete-stream --stream-name "$S"
  aws kinesis wait stream-not-exists --stream-name "$S"
fi
aws kinesis create-stream --stream-name "$S" --shard-count 2
aws kinesis describe-stream-summary --stream-name "$S" --query StreamDescriptionSummary.StreamStatus --output text
aws kinesis wait stream-exists --stream-name "$S"
aws kinesis describe-stream-summary --stream-name "$S" \
  --query 'StreamDescriptionSummary.{Status: StreamStatus, OpenShards: OpenShardCount, RetentionHours: RetentionPeriodHours, Mode: StreamModeDetails.StreamMode}'

echo "== 2. 샤드마다 맡은 해시 키 범위 (0 ~ 2^128-1 을 나눠 가진다)"
aws kinesis list-shards --stream-name "$S" --query 'Shards[].{Shard: ShardId, Start: HashKeyRange.StartingHashKey, End: HashKeyRange.EndingHashKey}' --output table
aws kinesis list-shards --stream-name "$S" --query 'Shards[].[ShardId, HashKeyRange.StartingHashKey, HashKeyRange.EndingHashKey]' --output text >"$WORK/shards"

echo "== 3. 같은 주문(파티션 키 A-7001)의 이벤트 3건 → 같은 샤드, 시퀀스 번호 증가"
for st in CREATED PAID SHIPPED; do
  aws kinesis put-record --stream-name "$S" --partition-key A-7001 \
    --cli-binary-format raw-in-base64-out --data "{\"orderId\":\"A-7001\",\"status\":\"$st\"}" \
    --query '[ShardId, SequenceNumber]' --output text
done | tee "$WORK/a7001"
[ "$(cut -f1 "$WORK/a7001" | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "같은 파티션 키가 여러 샤드로 감"

echo "== 4. 파티션 키의 MD5 해시로 샤드를 직접 계산해 보기"
uv run --quiet --project "$ROOT" python - "$WORK/shards" A-7001 B-7002 C-7003 D-7004 E-7005 <<'PY' | tee "$WORK/expected"
import hashlib, sys
shards = [line.split("\t") for line in open(sys.argv[1]).read().split("\n") if line]
for key in sys.argv[2:]:
    h = int(hashlib.md5(key.encode()).hexdigest(), 16)
    shard = next(s for s, lo, hi in shards if int(lo) <= h <= int(hi))
    print(f"{key}\t{shard}")
PY

echo "== 5. 여러 주문을 put-records 로 한 번에 → 실제 샤드가 계산과 같은가"
entries=""
for k in B-7002 C-7003 D-7004 E-7005; do
  entries+="{\"PartitionKey\":\"$k\",\"Data\":\"$(printf '{"orderId":"%s","status":"CREATED"}' "$k" | base64)\"},"
done
aws kinesis put-records --stream-name "$S" --records "[${entries%,}]" --output json >"$WORK/put.json"
uv run --quiet --project "$ROOT" python - "$WORK/put.json" B-7002 C-7003 D-7004 E-7005 <<'PY' | tee "$WORK/actual"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["FailedRecordCount"] == 0, r
for key, rec in zip(sys.argv[2:], r["Records"]):
    print(f"{key}\t{rec['ShardId']}")
PY
grep -v A-7001 "$WORK/expected" | diff - "$WORK/actual" && echo "계산한 샤드와 실제 샤드가 모두 같다"

echo "== 6. 소비자: 샤드마다 처음(TRIM_HORIZON)부터 읽는다"
read_shard() { # read_shard <샤드 ID> — 데이터(base64)를 풀어 한 줄씩
  local it
  it="$(aws kinesis get-shard-iterator --stream-name "$S" --shard-id "$1" --shard-iterator-type TRIM_HORIZON --query ShardIterator --output text)"
  aws kinesis get-records --shard-iterator "$it" --limit 100 --query 'Records[].Data' --output text | tr '\t' '\n' | grep . \
    | while read -r d; do printf '%s' "$d" | base64 --decode; echo; done
}
total=0
for sh in $(cut -f1 "$WORK/shards"); do
  read_shard "$sh" >"$WORK/$sh.txt"
  n="$(wc -l <"$WORK/$sh.txt" | tr -d ' ')"
  total=$((total + n))
  echo "-- $sh: ${n}건"
  sed 's/^/   /' "$WORK/$sh.txt"
done
a_order="$(cat "$WORK"/shardId-*.txt | grep A-7001 | sed 's/.*"status":"\([A-Z]*\)".*/\1/' | tr '\n' ' ')"
echo "주문 A-7001 의 순서: $a_order"

echo "== 7. 두 번째 소비자(예: 분석팀)도 같은 데이터를 처음부터 다시 읽을 수 있다 — 읽어도 지워지지 않는다"
again="$(read_shard "$(cut -f1 "$WORK/a7001" | head -1)" | grep -c A-7001)"
echo "두 번째로 읽은 A-7001 이벤트: ${again}건"

# ---- 단언
[ "$a_order" = "CREATED PAID SHIPPED " ] || fail "샤드 안 순서: $a_order"
[ "$total" = 7 ] || fail "전체 레코드 수(3 + 4 = 7)가 아님: $total"
[ "$again" = 3 ] || fail "재독 결과: $again"
echo "LAB07 OK"
