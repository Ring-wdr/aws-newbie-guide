#!/usr/bin/env bash
# M14 lab05 — 캡스톤 종단 간(end-to-end) 스모크 테스트. 빠진 계층이 있으면 lab01~04 를 먼저 실행한다
# (= 깨끗한 에뮬레이터에서 이 스크립트 하나로 전체를 짓고 시험한다).
#   고객 로그인(Cognito) → HTTP API 로 주문 → DynamoDB 항목 → EventBridge → SNS 팬아웃
#   → (a) 워커 Lambda: 상태 CONFIRMED + 영수증 S3(SSE-KMS)  (b) 고액 주문만 알림 큐(필터 정책)
#   → 결제 대행사 장애 주문: 재시도 → DLQ, 실패 지표 → CloudWatch 알람 ALARM → SNS → 운영 큐
# 등급: 🟢
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUN="$(date +%s)"

echo "== 0. 전체 계층 확인 (없으면 짓는다)"
ensure have_network "$LABS/lab01-network-web-tier.sh"
ensure have_data "$LABS/lab02-data-security.sh"
ensure have_pipeline "$LABS/lab03-order-pipeline.sh"
ensure have_ops "$LABS/lab04-observability-governance.sh"
API="$(api_id)"
B="$(api_base "$API")"
NOTIFY_URL="$(queue_url "$NOTIFY_QUEUE")"
DLQ_URL="$(queue_url "$DLQ")"
OPS_URL="$(queue_url "$OPS_QUEUE")"

# drain <큐 URL> — 남은 메시지를 모두 받아 지운다(이전 실행의 흔적 제거. PurgeQueue 는 60초에 한 번만 가능)
drain() {
  local out
  while :; do
    out="$(aws sqs receive-message --queue-url "$1" --max-number-of-messages 10 --wait-time-seconds 1 \
      --query 'Messages[].ReceiptHandle' --output text)"
    [ -z "$out" ] || [ "$out" = None ] && return 0
    for h in $out; do aws sqs delete-message --queue-url "$1" --receipt-handle "$h"; done
  done
}
# find_in_queue <큐 URL> <문자열> — 그 문자열이 든 메시지를 찾으면 출력하고 지운다(못 찾으면 실패)
find_in_queue() {
  aws sqs receive-message --queue-url "$1" --max-number-of-messages 10 --wait-time-seconds 2 --output json >"$WORK/m.json"
  py '
d = json.load(open(sys.argv[1]))
for m in d.get("Messages", []):
    if sys.argv[2] in m["Body"]:
        print(m["ReceiptHandle"]); print(m["Body"]); sys.exit(0)
sys.exit(1)' "$WORK/m.json" "$2" >"$WORK/found" || return 1
  aws sqs delete-message --queue-url "$1" --receipt-handle "$(head -1 "$WORK/found")"
  tail -n +2 "$WORK/found"
}
drain "$NOTIFY_URL"
drain "$OPS_URL"

echo "== 1. 고객 로그인 (Cognito 사용자 풀 → ID 토큰)"
POOL="$(aws cognito-idp list-user-pools --max-results 60 --output json | py '
for p in json.load(sys.stdin)["UserPools"]:
    if p["Name"] == sys.argv[1]:
        print(p["Id"])' "$P-customers" | head -1)"
CLIENT="$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL" --query "UserPoolClients[?ClientName=='todayorder-app'].ClientId | [0]" --output text)"
USER="smoke-customer@todayorder.example.com"
PW='Smoke-Passw0rd!'
aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$USER" >/dev/null 2>&1 || {
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$USER" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$USER" Name=email_verified,Value=true >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$USER" --password "$PW" --permanent
}
TOKEN="$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USER,PASSWORD=$PW" --query AuthenticationResult.IdToken --output text)"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'content-type: application/json')
echo "토큰 길이: ${#TOKEN}자"

BIG="A-$RUN"
SMALL="B-$RUN"
BAD="GW-DOWN-$RUN"
echo "== 2. 주문 $BIG (62,000원) → 201, 같은 주문 재전송 → 409, 잘못된 주문 → 400"
call POST "$B/orders" "${AUTH[@]}" -d "{\"orderId\":\"$BIG\",\"items\":3,\"total\":62000}" | tee "$WORK/big"
call POST "$B/orders" "${AUTH[@]}" -d "{\"orderId\":\"$BIG\",\"items\":3,\"total\":62000}" | tee "$WORK/dup"
call POST "$B/orders" "${AUTH[@]}" -d "{\"orderId\":\"X-$RUN\",\"items\":99,\"total\":1000}" | tee "$WORK/bad"

echo "== 3. 워커의 결과: DynamoDB 상태 PENDING → CONFIRMED, 영수증 객체(SSE-KMS)"
status_of() { aws dynamodb get-item --table-name "$TABLE" --key "{\"orderId\":{\"S\":\"$1\"}}" --query 'Item.status.S' --output text; }
poll 60 "$BIG CONFIRMED" sh -c "[ \"\$(aws dynamodb get-item --table-name '$TABLE' --key '{\"orderId\":{\"S\":\"$BIG\"}}' --query 'Item.status.S' --output text)\" = CONFIRMED ]"
aws dynamodb get-item --table-name "$TABLE" --key "{\"orderId\":{\"S\":\"$BIG\"}}" \
  --query 'Item.{orderId: orderId.S, status: status.S, total: total.N, receiptKey: receiptKey.S}' --output json
RKEY="$(aws dynamodb get-item --table-name "$TABLE" --key "{\"orderId\":{\"S\":\"$BIG\"}}" --query 'Item.receiptKey.S' --output text)"
aws s3api head-object --bucket "$RECEIPTS" --key "$RKEY" --query '{SSE: ServerSideEncryption, BucketKey: BucketKeyEnabled, Type: ContentType}' --output json
SSE="$(aws s3api head-object --bucket "$RECEIPTS" --key "$RKEY" --query ServerSideEncryption --output text)"
# "aws:kms" 만 보면 AWS 관리형 키(aws/s3)로도 통과한다. NFR-S2 는 고객 관리형 키이므로 키 ARN 까지 비교한다.
SSE_KEY="$(aws s3api head-object --bucket "$RECEIPTS" --key "$RKEY" --query SSEKMSKeyId --output text)"
KEY_ARN="$(stack_output "$DATA_STACK" KeyArn)"
echo "영수증 KMS 키: $SSE_KEY"

echo "== 4. 팬아웃 + 필터 정책: 고액 주문은 알림 큐에도 도착"
poll 30 "알림 큐에 $BIG" find_in_queue "$NOTIFY_URL" "$BIG"
echo "(알림 큐에서 $BIG 확인)"

echo "== 5. 주문 $SMALL (9,000원) → 처리는 되지만 알림 큐에는 오지 않는다"
call POST "$B/orders" "${AUTH[@]}" -d "{\"orderId\":\"$SMALL\",\"items\":1,\"total\":9000}" | tee "$WORK/small"
poll 60 "$SMALL CONFIRMED" sh -c "[ \"\$(aws dynamodb get-item --table-name '$TABLE' --key '{\"orderId\":{\"S\":\"$SMALL\"}}' --query 'Item.status.S' --output text)\" = CONFIRMED ]"
small_notified=no
find_in_queue "$NOTIFY_URL" "$SMALL" >/dev/null 2>&1 && small_notified=yes
echo "알림 큐에 $SMALL: $small_notified"

echo "== 6. API 로 조회: 단건(내 주문) + 내 주문 목록(GSI byCustomer)"
call GET "$B/orders/$BIG" "${AUTH[@]}" | tee "$WORK/get"
call GET "$B/me/orders" "${AUTH[@]}" >"$WORK/list"
mine="$(head -1 "$WORK/list" | py '
ids = [o["orderId"] for o in json.load(sys.stdin)["orders"]]
print(sum(1 for i in ids if i in sys.argv[1:]))' "$BIG" "$SMALL")"
echo "내 주문 목록에서 이번 실행의 주문: ${mine}건"

echo "== 6-1. FR-2: 다른 고객은 남의 주문을 볼 수 없다 (단건 404, 목록에는 자기 주문만)"
OTHER="smoke-other@todayorder.example.com"
aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$OTHER" >/dev/null 2>&1 || {
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$OTHER" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$OTHER" Name=email_verified,Value=true >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$OTHER" --password "$PW" --permanent
}
TOKEN2="$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$OTHER,PASSWORD=$PW" --query AuthenticationResult.IdToken --output text)"
AUTH2=(-H "Authorization: Bearer $TOKEN2" -H 'content-type: application/json')
THEIRS="C-$RUN"
call POST "$B/orders" "${AUTH2[@]}" -d "{\"orderId\":\"$THEIRS\",\"items\":1,\"total\":5000}" | tee "$WORK/theirs"
call GET "$B/orders/$BIG" "${AUTH2[@]}" | tee "$WORK/peek"
call GET "$B/me/orders" "${AUTH2[@]}" >"$WORK/list2"
call GET "$B/me/orders" "${AUTH[@]}" >"$WORK/list1"
# 목록에 이번 실행의 주문 중 무엇이 보이는가: 다른 고객 → C 만, 첫 고객 → A·B 만
seen() { head -1 "$1" | py '
ids = {o["orderId"] for o in json.load(sys.stdin)["orders"]}
print(",".join(i for i in sys.argv[1:] if i in ids))' "$BIG" "$SMALL" "$THEIRS"; }
seen2="$(seen "$WORK/list2")"
seen1="$(seen "$WORK/list1")"
echo "다른 고객의 목록: $seen2 · 첫 고객의 목록: $seen1"

echo "== 7. 장애 경로: 결제 대행사 장애 주문 $BAD → 재시도(maxReceiveCount 2) → DLQ, 실패 지표 → 알람 → 운영 큐"
# 인과를 증명하려면: 알람이 "이번 장애 주문 전"에는 ALARM 이 아니었고, ALARM 전환과 운영 알림이 "이번 주문 뒤"에
# 일어났으며, 그 전환을 만든 데이터 포인트가 이전 실행의 것이 아니어야 한다. set-alarm-state OK 로 되돌리면
# 몇 초 뒤 이전 실행의 데이터 포인트로 다시 ALARM 이 될 수 있으므로(같은 환경에서 연달아 실행할 때) 쓰지 않는다.
# (1) 이전 실행이 남긴 실패 데이터 포인트 중 가장 늦은 것(분 단위)을 찾고, 그 분이 평가 창에서 완전히 빠질 때까지
#     (+180초 — 이 에뮬레이터는 1~2분 늦게 평가한다) 기다린 뒤 알람이 스스로 OK 가 되는 것을 본다.
LAST_STALE="$(aws cloudwatch get-metric-statistics --namespace "$METRIC_NS" --metric-name "$METRIC_NAME" \
  --start-time "$(py 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=15)).isoformat())')" \
  --end-time "$(py 'import datetime as d; print(d.datetime.now(d.timezone.utc).isoformat())')" \
  --period 60 --statistics Sum --output json | py '
import datetime as d
ts = [d.datetime.fromisoformat(p["Timestamp"].replace("Z", "+00:00")) for p in json.load(sys.stdin)["Datapoints"] if p["Sum"] > 0]
print(max(ts).timestamp() if ts else 0)')"
stale_gone() { py 'import time; sys.exit(0 if time.time() >= float(sys.argv[1]) + 180 else 1)' "$LAST_STALE"; }
not_alarm() { [ "$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)" != ALARM ]; }
poll 240 "이전 실행의 실패 데이터 포인트가 평가 창에서 빠짐" stale_gone
poll 120 "알람이 스스로 ALARM 이 아님(장애 주문 전)" not_alarm
BEFORE="$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)"
echo "장애 주문 전 알람 상태: $BEFORE (이전 실행의 실패 지표: $([ "$LAST_STALE" = 0 ] && echo 없음 || echo '있었음 — 창에서 빠질 때까지 기다림'))"
drain "$OPS_URL"
T0="$(py 'import time; print(time.time())')"
call POST "$B/orders" "${AUTH[@]}" -d "{\"orderId\":\"$BAD\",\"items\":2,\"total\":15000}" | tee "$WORK/badgw"
# (2) ALARM 전환 시각 > T0, 그리고 전환을 만든 데이터 포인트의 분 >= T0 의 분(시계 차이 5초 여유)
alarm_after_t0() {
  aws cloudwatch describe-alarms --alarm-names "$ALARM" --output json | py '
import datetime as d
a = json.load(sys.stdin)["MetricAlarms"][0]
t0 = float(sys.argv[1])
if a["StateValue"] != "ALARM":
    sys.exit(1)
changed = d.datetime.fromisoformat(a["StateUpdatedTimestamp"]).timestamp()
pts = json.loads(a.get("StateReasonData") or "{}").get("evaluatedDatapoints", [])
fresh = [p for p in pts if p.get("value", 0) >= 1 and
         d.datetime.strptime(p["timestamp"], "%Y-%m-%dT%H:%M:%S.%f%z").timestamp() >= (t0 - 5) // 60 * 60]
sys.exit(0 if changed > t0 and fresh else 1)' "$T0"
}
poll 150 "이번 장애 주문으로 알람 ALARM" alarm_after_t0
aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].[StateValue, StateReason]' --output text
# 운영 큐의 메시지는 SNS 봉투(JSON) 안에 알람 JSON 이 문자열로 들어 있다. NewStateValue 가 ALARM 이고
# StateChangeTime 이 T0 뒤인 것을 찾는다(그 밖의 알림은 꺼내서 버린다).
ops_has_alarm() {
  find_in_queue "$OPS_URL" "$ALARM" >"$WORK/ops" || return 1
  py '
import datetime as d
m = json.loads(json.load(open(sys.argv[1]))["Message"])
t = d.datetime.strptime(m["StateChangeTime"], "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
sys.exit(0 if m["NewStateValue"] == "ALARM" and t > float(sys.argv[2]) else 1)' "$WORK/ops" "$T0"
}
poll 60 "운영 큐에 이번 ALARM 알림" ops_has_alarm
py '
body = json.load(open(sys.argv[1]))
msg = json.loads(body["Message"])
print("운영 알림:", body["Subject"]); print("  ", msg["AlarmName"], msg["OldStateValue"], "→", msg["NewStateValue"])' "$WORK/ops"
poll 150 "DLQ 에 $BAD" find_in_queue "$DLQ_URL" "$BAD"
echo "(DLQ 에서 $BAD 확인 — 실제 운영이면 원인을 고친 뒤 start-message-move-task 로 재처리)"
bad_status="$(status_of "$BAD")"
echo "$BAD 상태: $bad_status (결제가 안 됐으므로 PENDING 에 머문다)"

# ---- 단언
grep -q 'HTTP 201' "$WORK/big" || fail "주문 생성 201 아님"
grep -q 'HTTP 409' "$WORK/dup" || fail "중복 주문 409 아님"
grep -q 'HTTP 400' "$WORK/bad" || fail "잘못된 주문 400 아님"
grep -q 'HTTP 201' "$WORK/small" || fail "소액 주문 201 아님"
grep -q '"status": "CONFIRMED"' "$WORK/get" && grep -q 'HTTP 200' "$WORK/get" || fail "주문 조회"
assert_eq "$SSE" aws:kms "영수증 암호화"
assert_eq "$SSE_KEY" "$KEY_ARN" "영수증 암호화 키 = 캡스톤 고객 관리형 키"
grep -q 'HTTP 201' "$WORK/theirs" || fail "다른 고객의 주문 생성 201 아님"
grep -q 'HTTP 404' "$WORK/peek" || fail "남의 주문 조회가 404 아님(FR-2)"
assert_eq "$seen2" "$THEIRS" "다른 고객의 목록에는 자기 주문만(FR-2)"
assert_eq "$seen1" "$BIG,$SMALL" "첫 고객의 목록에는 자기 주문만(FR-2)"
[ "$BEFORE" != ALARM ] || fail "장애 주문 전에 알람이 이미 ALARM"
assert_eq "$small_notified" no "소액 주문은 알림 큐에 오지 않음(필터 정책)"
assert_eq "$mine" 2 "GSI 로 내 주문 2건"
assert_eq "$bad_status" PENDING "장애 주문 상태"
echo "SMOKE OK — 주문 → 저장 → 이벤트 → 팬아웃 → 처리·영수증(고객 관리형 키) → 남의 주문 404 → 장애 시 DLQ·알람·운영 알림까지 확인"
echo "LAB05 OK"
