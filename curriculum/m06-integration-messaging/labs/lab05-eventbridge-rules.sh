#!/usr/bin/env bash
# M06 lab05 — EventBridge 사용자 지정 버스, 규칙의 이벤트 패턴, SQS 대상 (🟢)
# + EventBridge Scheduler 일정 구성(구성만 확인 — 발화 시각은 에뮬레이터가 지키지 않는다)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BUS=todayorder-bus
RULE=todayorder-high-value-orders
Q=todayorder-vip-care
SCHED=todayorder-daily-settlement
SCHED_ROLE=todayorder-scheduler-role

# 이전 실행이 남긴 일정은 먼저 지운다 (같은 큐를 대상으로 하므로)
aws scheduler delete-schedule --name "$SCHED" >/dev/null 2>&1 || true

echo "== 1. 사용자 지정 이벤트 버스와 대상 큐"
aws events describe-event-bus --name "$BUS" >/dev/null 2>&1 || aws events create-event-bus --name "$BUS" --query EventBusArn --output text
URL="$(fresh_queue "$Q")"
# 큐 정책: 이 규칙(events.amazonaws.com, SourceArn=규칙 ARN)만 SendMessage 허용 — 없으면 전달되지 않는다
RULE_ARN="arn:aws:events:$REGION:$ACCOUNT:rule/$BUS/$RULE"
set_queue_policy "$URL" "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"events.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$(queue_arn "$Q")\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"$RULE_ARN\"}}}]}"

echo "== 2. 이벤트 패턴: 주문 서비스의 OrderPlaced 중 금액 10만 원 이상, 결제 수단이 card 인 것"
cat >"$WORK/pattern.json" <<'JSON'
{
  "source": ["todayorder.orders"],
  "detail-type": ["OrderPlaced"],
  "detail": {
    "total": [{"numeric": [">=", 100000]}],
    "payment": {"method": ["card"]}
  }
}
JSON
cat "$WORK/pattern.json"

echo "== 3. 규칙을 만들기 전에 test-event-pattern 으로 패턴을 시험"
event_json() { # event_json <source> <detail-type> <detail JSON>
  printf '{"id":"1","account":"%s","source":"%s","time":"2026-11-12T00:00:00Z","region":"%s","resources":[],"detail-type":"%s","detail":%s}' \
    "$ACCOUNT" "$1" "$REGION" "$2" "$3"
}
for d in '{"orderId":"A-5001","total":250000,"payment":{"method":"card"}}' \
         '{"orderId":"A-5002","total":9000,"payment":{"method":"card"}}' \
         '{"orderId":"A-5003","total":300000,"payment":{"method":"bank"}}'; do
  r="$(aws events test-event-pattern --event-pattern "file://$WORK/pattern.json" \
    --event "$(event_json todayorder.orders OrderPlaced "$d")" --query Result --output text)"
  echo "  $d → $r"
done

echo "== 4. 규칙 + 대상(SQS) 연결"
aws events put-rule --name "$RULE" --event-bus-name "$BUS" --event-pattern "file://$WORK/pattern.json" --query RuleArn --output text
aws events put-targets --rule "$RULE" --event-bus-name "$BUS" \
  --targets "Id=vip-queue,Arn=$(queue_arn "$Q")" --query FailedEntryCount

echo "== 5. 이벤트 4건 발행 (일치 1건 + 금액 미달 + 결제 수단 다름 + 다른 source)"
entry() { # entry <source> <detail-type> <detail JSON>
  local escaped
  escaped="$(printf '%s' "$3" | sed 's/"/\\"/g')"
  printf '{"EventBusName":"%s","Source":"%s","DetailType":"%s","Detail":"%s"}' "$BUS" "$1" "$2" "$escaped"
}
aws events put-events --entries "[
  $(entry todayorder.orders OrderPlaced '{"orderId":"A-5001","total":250000,"payment":{"method":"card"}}'),
  $(entry todayorder.orders OrderPlaced '{"orderId":"A-5002","total":9000,"payment":{"method":"card"}}'),
  $(entry todayorder.orders OrderPlaced '{"orderId":"A-5003","total":300000,"payment":{"method":"bank"}}'),
  $(entry todayorder.payments PaymentCaptured '{"orderId":"A-5001","total":250000,"payment":{"method":"card"}}')
]" --query '{FailedEntryCount: FailedEntryCount, Entries: length(Entries)}'

echo "== 6. 대상 큐에 무엇이 왔나"
got=()
collect() {
  aws sqs receive-message --queue-url "$URL" --max-number-of-messages 10 --wait-time-seconds 1 \
    --query 'Messages[].[ReceiptHandle, Body]' --output text >"$WORK/m"
  while read -r h b; do
    [ "$h" = None ] || [ -z "$h" ] && continue
    got+=("$b")
    aws sqs delete-message --queue-url "$URL" --receipt-handle "$h"
  done <"$WORK/m"
  [ "${#got[@]}" -ge 1 ]
}
poll 60 "일치 이벤트 도착" collect
# 늦게 오는 불일치 이벤트가 없는지 롱 폴링으로 한 번 더 확인 (없음을 '증명'하진 못하지만, 있다면 잡힌다)
aws sqs receive-message --queue-url "$URL" --max-number-of-messages 10 --wait-time-seconds 3 \
  --query 'Messages[].Body' --output text >"$WORK/late"
grep -v '^None$' "$WORK/late" | grep . && got+=("$(cat "$WORK/late")")
echo "받은 이벤트 ${#got[@]}건:"
printf '%s\n' "${got[0]}" | pretty

echo "== 7. EventBridge Scheduler: 매일 새벽 정산 작업을 큐에 넣는 일정 (구성)"
ensure_role "$SCHED_ROLE" scheduler.amazonaws.com
aws iam put-role-policy --role-name "$SCHED_ROLE" --policy-name send-to-queue --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$(queue_arn "$Q")\"}]}"
aws scheduler create-schedule --name "$SCHED" \
  --schedule-expression "cron(0 3 * * ? *)" --schedule-expression-timezone Asia/Seoul \
  --flexible-time-window '{"Mode":"FLEXIBLE","MaximumWindowInMinutes":15}' \
  --target "{\"Arn\":\"$(queue_arn "$Q")\",\"RoleArn\":\"arn:aws:iam::$ACCOUNT:role/$SCHED_ROLE\",\"Input\":\"{\\\"job\\\":\\\"daily-settlement\\\"}\"}" \
  --query ScheduleArn --output text
aws scheduler get-schedule --name "$SCHED" \
  --query '{Expression: ScheduleExpression, TZ: ScheduleExpressionTimezone, State: State, Window: FlexibleTimeWindow}'

# ---- 단언
[ "${#got[@]}" = 1 ] || fail "패턴과 일치하는 1건만 와야 함: ${#got[@]}건"
grep -q A-5001 <<<"${got[0]}" || fail "일치 이벤트가 아님"
[ "$(aws scheduler get-schedule --name "$SCHED" --query State --output text)" = ENABLED ] || fail "일정 상태"
echo "LAB05 OK"
