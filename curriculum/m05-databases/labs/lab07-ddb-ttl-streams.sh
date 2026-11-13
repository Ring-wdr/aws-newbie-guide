#!/usr/bin/env bash
# M05 lab07 — TTL 로 장바구니 자동 만료, Streams 로 변경 이벤트 읽기 (🟢)
# Streams(NEW_AND_OLD_IMAGES) 켠 장바구니 테이블 → TTL 활성화(expires_at)
# → 만료된/안 된/문자열 TTL 장바구니 → 만료 항목이 지워질 때까지 폴링 → 스트림의 INSERT/MODIFY/REMOVE 읽기
# 주의: 에뮬레이터는 만료 항목을 수 초 안에 지운다. 실제 AWS는 "만료 후 보통 며칠 이내"이며 즉시가 아니다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

T=todayorder-m05-carts
ddb_delete_table "$T"

echo "== 1. 장바구니 테이블 + Streams (변경 전·후 이미지 모두)"
aws dynamodb create-table --table-name "$T" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=cart_id,AttributeType=S \
  --key-schema AttributeName=cart_id,KeyType=HASH \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --query 'TableDescription.{Status: TableStatus, Stream: StreamSpecification}'
wait_dynamodb_table_active "$T"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
STREAM_ARN="$(aws dynamodb describe-table --table-name "$T" --query 'Table.LatestStreamArn' --output text)"
echo "LatestStreamArn=$STREAM_ARN"

echo "== 2. TTL 켜기: expires_at 속성(Unix epoch 초, Number 타입)"
aws dynamodb update-time-to-live --table-name "$T" \
  --time-to-live-specification Enabled=true,AttributeName=expires_at
poll_until 120 "TTL ENABLED" bash -c \
  "[ \"\$(aws dynamodb describe-time-to-live --table-name $T --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)\" = ENABLED ]"
aws dynamodb describe-time-to-live --table-name "$T"

echo "== 3. 장바구니 3개 넣고 하나는 수정"
now=$(date +%s)
aws dynamodb put-item --table-name "$T" --item "{\"cart_id\":{\"S\":\"cart-expired\"},\"items\":{\"N\":\"1\"},\"expires_at\":{\"N\":\"$((now - 60))\"}}"
aws dynamodb put-item --table-name "$T" --item "{\"cart_id\":{\"S\":\"cart-active\"},\"items\":{\"N\":\"1\"},\"expires_at\":{\"N\":\"$((now + 86400))\"}}"
aws dynamodb put-item --table-name "$T" --item "{\"cart_id\":{\"S\":\"cart-string-ttl\"},\"items\":{\"N\":\"1\"},\"expires_at\":{\"S\":\"$((now - 60))\"}}"
aws dynamodb update-item --table-name "$T" --key '{"cart_id":{"S":"cart-active"}}' \
  --update-expression "SET #i = #i + :one" --expression-attribute-names '{"#i":"items"}' \
  --expression-attribute-values '{":one":{"N":"1"}}'
echo "cart-expired: 1분 전에 만료 / cart-active: 내일 만료 / cart-string-ttl: 만료 시각을 문자열(S)로 저장"

echo "== 4. 만료된 항목이 TTL 프로세스에 의해 지워질 때까지 폴링"
echo "-- 실제 AWS에서는 만료 후 며칠 동안 읽힐 수 있다. 그래서 읽기 쪽에서 '만료된 것'을 거른다:"
aws dynamodb scan --table-name "$T" \
  --filter-expression "NOT (attribute_type(expires_at, :num) AND expires_at <= :now)" \
  --expression-attribute-values "{\":num\":{\"S\":\"N\"},\":now\":{\"N\":\"$(date +%s)\"}}" --query 'Items[].cart_id.S'
start=$(date +%s)
poll_until 300 "cart-expired 삭제" bash -c \
  "[ \"\$(aws dynamodb get-item --table-name $T --key '{\"cart_id\":{\"S\":\"cart-expired\"}}' --query 'Item.cart_id.S' --output text)\" = None ]"
echo "cart-expired 삭제 확인 (폴링 시작 후 $(($(date +%s) - start))초. 에뮬레이터는 수 초, 실제 AWS는 보통 며칠 이내)"
aws dynamodb scan --table-name "$T" --query 'Items[].{cart: cart_id.S, expires_at: expires_at}'
string_ttl="$(aws dynamodb get-item --table-name "$T" --key '{"cart_id":{"S":"cart-string-ttl"}}' --query 'Item.cart_id.S' --output text)"

echo "== 5. 스트림 읽기: 샤드 → 샤드 이터레이터(TRIM_HORIZON = 처음부터) → 레코드"
SHARD="$(aws dynamodbstreams describe-stream --stream-arn "$STREAM_ARN" --query 'StreamDescription.Shards[0].ShardId' --output text)"
read_records() {
  local it
  it="$(aws dynamodbstreams get-shard-iterator --stream-arn "$STREAM_ARN" --shard-id "$SHARD" \
    --shard-iterator-type TRIM_HORIZON --query ShardIterator --output text)"
  aws dynamodbstreams get-records --shard-iterator "$it" "$@"
}
poll_until 120 "REMOVE 레코드 도착" bash -c \
  "$(declare -f read_records); STREAM_ARN=$STREAM_ARN SHARD=$SHARD; read_records --query 'Records[].eventName' --output text | grep -q REMOVE"
read_records --query 'Records[].{event: eventName, key: dynamodb.Keys.cart_id.S, old_items: dynamodb.OldImage.items.N, new_items: dynamodb.NewImage.items.N, userIdentity: userIdentity}' --output table
events="$(read_records --query 'Records[].eventName' --output text)"

echo "== 6. 정리"
ddb_delete_table "$T"

# ---- 단언
[ "$string_ttl" = "cart-string-ttl" ] || fail "문자열 TTL 항목이 지워짐(Number 가 아니면 무시되어야 함)"
grep -q INSERT <<<"$events" && grep -q MODIFY <<<"$events" && grep -q REMOVE <<<"$events" \
  || fail "스트림 이벤트가 부족함: $events"
echo "LAB07 OK"
