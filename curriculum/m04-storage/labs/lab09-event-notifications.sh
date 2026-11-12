#!/usr/bin/env bash
# M04 lab09 — S3 이벤트 알림 → SQS 에 실제 도착 (🟢) + 버킷 기능 설정(정적 웹 호스팅·Transfer Acceleration·요청자 지불)
# 1) 큐 정책 없이 알림 설정 → InvalidArgument (S3가 큐에 보낼 권한을 검증)
# 2) 큐 정책(s3.amazonaws.com 허용, aws:SourceArn 으로 내 버킷만) → 알림 설정 → s3:TestEvent
# 3) uploads/*.jpg 만 이벤트가 오고, 다른 접두사·확장자는 안 온다
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

BUCKET="todayorder-m04-uploads"
DOTTED="todayorder.m04.static"
QUEUE="todayorder-m04-thumbnail-jobs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$BUCKET"
purge_bucket "$DOTTED"
old_q="$(aws sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null || true)"
[ -n "$old_q" ] && aws sqs delete-queue --queue-url "$old_q"

# 에뮬레이터는 같은 이름의 큐를 지운 직후 다시 만들어도 된다 (실제 AWS는 60초 대기)
create_queue() {
  for _ in $(seq 1 30); do
    aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

# drain_until <큐 URL> <찾을 문자열> <최대 초> : 메시지를 받아 본문을 bodies.jsonl 에 쌓고 삭제한다.
# "찾을 문자열"(S3 키 또는 s3:TestEvent)이 담긴 메시지를 받으면 멈춘다. 고정 시간 대기 대신 도착을 기다린다.
drain_until() {
  local url="$1" want="$2" deadline=$((SECONDS + $3)) msgs
  while [ "$SECONDS" -lt "$deadline" ]; do
    msgs="$(aws sqs receive-message --queue-url "$url" --max-number-of-messages 10 --wait-time-seconds 2 --output json)"
    [ -z "$msgs" ] && continue
    jq -c '.Messages[]?.Body | fromjson' <<<"$msgs" >>bodies.jsonl
    jq -r '.Messages[]?.ReceiptHandle' <<<"$msgs" | while read -r h; do
      aws sqs delete-message --queue-url "$url" --receipt-handle "$h"
    done
    grep -qF "\"$want\"" bodies.jsonl && return 0
  done
  echo "FAIL: $3초 안에 '$want' 이벤트가 오지 않음. 지금까지 받은 것:"; cat bodies.jsonl 2>/dev/null
  return 1
}
# 받은 본문을 "이벤트명 키" 한 줄씩으로 요약
summarize() {
  jq -r 'if .Event then .Event else (.Records[] | "\(.eventName) \(.s3.object.key)") end' bodies.jsonl
}

aws s3api create-bucket --bucket "$BUCKET" >/dev/null
Q_URL="$(create_queue)"
Q_ARN="$(aws sqs get-queue-attributes --queue-url "$Q_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
echo "큐: $Q_ARN"

cat >notify.json <<JSON
{
  "QueueConfigurations": [{
    "Id": "thumbnail-on-upload",
    "QueueArn": "$Q_ARN",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": { "Key": { "FilterRules": [
      { "Name": "prefix", "Value": "uploads/" },
      { "Name": "suffix", "Value": ".jpg" }
    ] } }
  }]
}
JSON

echo "== 1. 큐 정책 없이 알림 설정 → S3가 목적지를 검증하다 실패"
expect_error InvalidArgument aws s3api put-bucket-notification-configuration --bucket "$BUCKET" \
  --notification-configuration file://notify.json

echo "== 2. 큐 정책: s3.amazonaws.com 이 '내 버킷에서 온 경우에만' SendMessage 가능"
cat >queue-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowS3FromMyBucket",
    "Effect": "Allow",
    "Principal": { "Service": "s3.amazonaws.com" },
    "Action": "sqs:SendMessage",
    "Resource": "$Q_ARN",
    "Condition": {
      "ArnLike": { "aws:SourceArn": "arn:aws:s3:::$BUCKET" },
      "StringEquals": { "aws:SourceAccount": "000000000000" }
    }
  }]
}
JSON
jq -n --rawfile p queue-policy.json '{Policy: $p}' >attrs.json
aws sqs set-queue-attributes --queue-url "$Q_URL" --attributes file://attrs.json

echo "== 3. 이제 알림 설정 성공 → S3가 확인용 s3:TestEvent 를 보낸다"
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration file://notify.json
aws s3api get-bucket-notification-configuration --bucket "$BUCKET" \
  --query 'QueueConfigurations[].{Id: Id, Events: Events, Filter: Filter.Key.FilterRules}' --output json
: >bodies.jsonl
drain_until "$Q_URL" s3:TestEvent 60
summarize | tee test-event.txt

echo "== 4. 객체 5개 업로드 (규칙에 맞는 것은 uploads/*.jpg 세 개뿐, 마지막 P-004 가 도착하면 수집 종료)"
printf 'img' >a.jpg
: >bodies.jsonl
for k in uploads/P-001.jpg uploads/readme.txt products/P-003.jpg uploads/P-002.jpg uploads/P-004.jpg; do
  aws s3api put-object --bucket "$BUCKET" --key "$k" --body a.jpg >/dev/null
  echo "PUT $k"
done

echo "== 5. 큐에서 받은 이벤트 (P-004 가 올 때까지, 최대 60초)"
drain_until "$Q_URL" uploads/P-004.jpg 60
summarize | sort | tee events.txt

echo "== 6. 메시지 본문 구조 (P-004 이벤트)"
body="$(grep -F '"uploads/P-004.jpg"' bodies.jsonl | head -1)"
jq '.Records[0] | {eventSource, eventName, awsRegion, bucket: .s3.bucket.name, key: .s3.object.key, size: .s3.object.size}' <<<"$body"

echo "== 7. 그 밖의 버킷 기능 — 설정만 (동작은 레슨 5 '실제 AWS에서는')"
echo "-- 정적 웹 사이트 호스팅"
aws s3api put-bucket-website --bucket "$BUCKET" --website-configuration \
  '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}'
aws s3api get-bucket-website --bucket "$BUCKET" --output json
echo "-- 요청자 지불(Requester Pays)"
aws s3api put-bucket-request-payment --bucket "$BUCKET" --request-payment-configuration Payer=Requester
payer="$(aws s3api get-bucket-request-payment --bucket "$BUCKET" --query Payer --output text)"
echo "Payer=$payer"
echo "-- Transfer Acceleration"
aws s3api put-bucket-accelerate-configuration --bucket "$BUCKET" --accelerate-configuration Status=Enabled
accel="$(aws s3api get-bucket-accelerate-configuration --bucket "$BUCKET" --query Status --output text)"
echo "Accelerate=$accel"
echo "-- 이름에 점(.)이 있는 버킷은 Transfer Acceleration 불가"
aws s3api create-bucket --bucket "$DOTTED" >/dev/null
expect_error InvalidRequest aws s3api put-bucket-accelerate-configuration --bucket "$DOTTED" \
  --accelerate-configuration Status=Enabled

echo "== 8. 정리"
purge_bucket "$BUCKET"
purge_bucket "$DOTTED"
aws sqs delete-queue --queue-url "$Q_URL"

# ---- 단언
grep -q 's3:TestEvent' test-event.txt || { echo "FAIL: TestEvent 가 오지 않음"; exit 1; }
expected=$'ObjectCreated:Put uploads/P-001.jpg\nObjectCreated:Put uploads/P-002.jpg\nObjectCreated:Put uploads/P-004.jpg'
[ "$(cat events.txt)" = "$expected" ] || { echo "FAIL: 받은 이벤트가 기대와 다름:"; cat events.txt; exit 1; }
[ "$(jq -r '.Records[0].s3.object.key' <<<"$body")" = "uploads/P-004.jpg" ] || { echo "FAIL: 본문 키"; exit 1; }
[ "$payer" = "Requester" ] || { echo "FAIL: 요청자 지불 ($payer)"; exit 1; }
[ "$accel" = "Enabled" ] || { echo "FAIL: 가속 ($accel)"; exit 1; }
echo "LAB09 OK"
