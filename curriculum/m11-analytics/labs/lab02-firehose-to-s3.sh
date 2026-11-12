#!/usr/bin/env bash
# M11 lab02 — Amazon Data Firehose 로 주문 이벤트를 S3 에 적재 (🟢)
#   (A) Direct PUT:          주문 API ──PutRecord(Batch)──▶ Firehose ──▶ s3://.../raw/orders/dt=YYYY-MM-DD/...
#   (B) Kinesis 를 소스로:   주문 API ──▶ Kinesis Data Streams ──▶ Firehose ──▶ s3://.../raw/kds-orders/...
# 주의: 에뮬레이터는 버퍼 시간(여기서는 60초)을 무시하고 거의 바로 쓴다. 실제 AWS의 타이밍으로 받아들이지 말 것.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-ingest"
STREAM="todayorder-orders-to-s3"
KDS="todayorder-order-events"
KDS_FH="todayorder-kds-to-s3"
ROLE="todayorder-firehose-delivery"
TODAY="$(utc_day 0)"

cleanup() {
  for s in "$STREAM" "$KDS_FH"; do
    aws firehose delete-delivery-stream --delivery-stream-name "$s" >/dev/null 2>&1 || true
  done
  aws kinesis delete-stream --stream-name "$KDS" --enforce-consumer-deletion >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name s3-and-kinesis >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
  empty_bucket "$BUCKET"
  wait_until 60 1 "이전 전송 스트림 삭제" bash -c \
    "! aws firehose describe-delivery-stream --delivery-stream-name $STREAM >/dev/null 2>&1 && ! aws firehose describe-delivery-stream --delivery-stream-name $KDS_FH >/dev/null 2>&1"
  wait_until 60 1 "이전 Kinesis 스트림 삭제" bash -c "! aws kinesis describe-stream-summary --stream-name $KDS >/dev/null 2>&1"
}
cleanup

echo "== 1. 대상 버킷과 Firehose 서비스 역할 (신뢰 정책: firehose.amazonaws.com)"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name s3-and-kinesis --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],
    \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]},
   {\"Effect\":\"Allow\",\"Action\":[\"kinesis:DescribeStream\",\"kinesis:GetShardIterator\",\"kinesis:GetRecords\",\"kinesis:ListShards\"],
    \"Resource\":\"arn:aws:kinesis:us-east-1:000000000000:stream/$KDS\"}]}"
echo "$ROLE_ARN"

echo "== 2. 신뢰 정책이 없는 역할을 주면? (Firehose가 역할을 맡을 수 없어 거부)"
set +e
bad_role="$(aws firehose create-delivery-stream --delivery-stream-name todayorder-bad-role \
  --extended-s3-destination-configuration "RoleARN=arn:aws:iam::000000000000:role/does-not-exist,BucketARN=arn:aws:s3:::$BUCKET" 2>&1)"
set -e
echo "$bad_role"

echo "== 3. (A) Direct PUT 전송 스트림: 날짜 파티션 접두사 + 오류 접두사 + 버퍼 60초/1MiB"
aws firehose create-delivery-stream --delivery-stream-name "$STREAM" --delivery-stream-type DirectPut \
  --extended-s3-destination-configuration "{
    \"RoleARN\": \"$ROLE_ARN\",
    \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
    \"Prefix\": \"raw/orders/dt=!{timestamp:yyyy-MM-dd}/\",
    \"ErrorOutputPrefix\": \"errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/\",
    \"BufferingHints\": {\"IntervalInSeconds\": 60, \"SizeInMBs\": 1},
    \"CompressionFormat\": \"UNCOMPRESSED\"}" --query DeliveryStreamARN --output text
wait_until 60 1 "전송 스트림 ACTIVE" bash -c \
  "[ \"\$(aws firehose describe-delivery-stream --delivery-stream-name $STREAM --query DeliveryStreamDescription.DeliveryStreamStatus --output text)\" = ACTIVE ]"
aws firehose describe-delivery-stream --delivery-stream-name "$STREAM" --query 'DeliveryStreamDescription.{
  Status: DeliveryStreamStatus, Type: DeliveryStreamType,
  Prefix: Destinations[0].ExtendedS3DestinationDescription.Prefix,
  Buffer: Destinations[0].ExtendedS3DestinationDescription.BufferingHints}'

echo "== 4. 주문 이벤트 보내기: PutRecord 1건 + PutRecordBatch 4건 (레코드 끝의 \\n 은 생산자가 붙인다)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ev() { printf '{"order_id":"%s","store":"%s","menu":"%s","qty":%s,"amount":%s,"payment":"%s","ordered_at":"%s"}\n' "$@" "$NOW"; }
aws firehose put-record --delivery-stream-name "$STREAM" --cli-binary-format raw-in-base64-out \
  --record "{\"Data\": $(ev F-0001 gangnam bibimbap 2 18000 card | py -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
  --query '{RecordId: RecordId, Encrypted: Encrypted}'
RECORDS="$( {
  ev F-0002 gangnam tteokbokki 1 6000 kakaopay
  ev F-0003 mapo bibimbap 1 9000 card
  ev F-0004 mapo kimbap 3 10500 cash
  ev F-0005 jamsil bibimbap 2 18000 card
} | py -c 'import json,sys; print(json.dumps([{"Data": l} for l in sys.stdin.read().splitlines(keepends=True)]))')"
aws firehose put-record-batch --delivery-stream-name "$STREAM" --cli-binary-format raw-in-base64-out \
  --records "$RECORDS" --query '{FailedPutCount: FailedPutCount, Records: length(RequestResponses)}'

echo "== 5. S3 에 객체가 생길 때까지 폴링 (실제 AWS: 버퍼 조건(60초 또는 1MiB)을 채운 뒤 전달)"
count_lines() {
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix raw/orders/ --output json | py -c '
import json, subprocess, sys
keys = [o["Key"] for o in json.load(sys.stdin).get("Contents", [])]
n = 0
for k in keys:
    n += subprocess.run(["aws", "s3", "cp", f"s3://'"$BUCKET"'/{k}", "-"], capture_output=True, text=True).stdout.count("\n")
print(n)'
}
export -f count_lines
export BUCKET
wait_until 120 2 "S3 에 주문 5건 도착" bash -c '[ "$(count_lines)" = 5 ]'
aws s3 ls "s3://$BUCKET/raw/orders/" --recursive | awk '{print $3, $4}'
FIRST_KEY="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix raw/orders/ --output json | py -c 'import json,sys; print(json.load(sys.stdin)["Contents"][0]["Key"])')"
echo "-- 첫 객체 내용"
aws s3 cp "s3://$BUCKET/$FIRST_KEY" - | head -5

echo "== 6. (B) Kinesis Data Streams 를 소스로 쓰는 전송 스트림"
aws kinesis create-stream --stream-name "$KDS" --shard-count 1
aws kinesis wait stream-exists --stream-name "$KDS"
KDS_ARN="$(aws kinesis describe-stream-summary --stream-name "$KDS" --query StreamDescriptionSummary.StreamARN --output text)"
aws firehose create-delivery-stream --delivery-stream-name "$KDS_FH" --delivery-stream-type KinesisStreamAsSource \
  --kinesis-stream-source-configuration "KinesisStreamARN=$KDS_ARN,RoleARN=$ROLE_ARN" \
  --extended-s3-destination-configuration "RoleARN=$ROLE_ARN,BucketARN=arn:aws:s3:::$BUCKET,Prefix=raw/kds-orders/" \
  --query DeliveryStreamARN --output text
wait_until 60 1 "KDS 소스 전송 스트림 ACTIVE" bash -c \
  "[ \"\$(aws firehose describe-delivery-stream --delivery-stream-name $KDS_FH --query DeliveryStreamDescription.DeliveryStreamStatus --output text)\" = ACTIVE ]"
aws kinesis put-record --stream-name "$KDS" --partition-key gangnam --cli-binary-format raw-in-base64-out \
  --data "$(ev K-0001 gangnam bibimbap 1 9000 card)" --query '{Shard: ShardId}'
echo "-- 이 전송 스트림에 직접 PutRecord 하면?"
set +e
direct="$(aws firehose put-record --delivery-stream-name "$KDS_FH" --cli-binary-format raw-in-base64-out --record Data=x 2>&1)"
set -e
echo "$direct"
wait_until 120 2 "KDS 경유 객체 도착" bash -c \
  "aws s3api list-objects-v2 --bucket $BUCKET --prefix raw/kds-orders/ --output json | grep -q '\"Key\"'"
aws s3 ls "s3://$BUCKET/raw/kds-orders/" --recursive | awk '{print $3, $4}'

lines="$(count_lines)"
cleanup

# ---- 단언
[[ "$bad_role" == *"unable to assume role"* ]] || fail "신뢰 정책 없는 역할이 거부되지 않음"
[[ "$FIRST_KEY" == "raw/orders/dt=$TODAY/"* ]] || fail "객체 키가 날짜 파티션 접두사를 따르지 않음: $FIRST_KEY"
[ "$lines" = 5 ] || fail "S3 에 쓰인 주문이 5건이 아님: $lines"
[[ "$direct" == *InvalidArgumentException* ]] || fail "KDS 소스 전송 스트림이 직접 PutRecord 를 받아 줌"
echo "LAB02 OK"
