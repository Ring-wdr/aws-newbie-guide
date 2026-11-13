# shellcheck shell=bash
# M14 캡스톤 lab 공용 도우미. 각 lab 이 scripts/env.sh 다음에 source 한다.
# (verify.sh 는 lab*.sh 만 실행하므로 이 파일은 단독으로 실행되지 않는다)

ROOT="$(git rev-parse --show-toplevel)"
MOD="$ROOT/curriculum/m14-capstone-exam"
LABS="$MOD/labs"
ACCOUNT=000000000000
REGION=us-east-1

# 캡스톤이 만드는 모든 이름 (다른 모듈의 리소스와 겹치지 않게 todayorder-cap- 접두사)
P=todayorder-cap
NET_STACK="$P-network"
DATA_STACK="$P-data"
MSG_STACK="$P-messaging"
KEY_ALIAS="alias/$P-data"
TABLE="$P-orders"
RECEIPTS="$P-receipts"
TRAIL_BUCKET="$P-audit-logs"
TRAIL="$P-trail"
SECRET="$P/payment-gateway"
PARAM_PREFIX="/todayorder-cap"
BUS="$P-orders"
EVENTS_TOPIC="$P-order-events"
OPS_TOPIC="$P-ops-alerts"
WORK_QUEUE="$P-fulfillment"
DLQ="$P-fulfillment-dlq"
NOTIFY_QUEUE="$P-notifications"
OPS_QUEUE="$P-ops-inbox"
API_FN="$P-order-api"
WORKER_FN="$P-order-worker"
API_ROLE="$P-order-api-role"
WORKER_ROLE="$P-order-worker-role"
API_NAME="$P-http-api"
ALB="$P-alb"
TG="$P-app-tg"
LT="$P-app-lt"
ASG="$P-app-asg"
DB_ID="$P-settlement-db"
DB_SUBNET_GROUP="$P-db-subnets"
ALARM="$P-order-failures"
METRIC_NS="TodayOrder/Capstone"
METRIC_NAME="OrderProcessingFailed"
CONFIG_ROLE="$P-config-role"
CONFIG_BUCKET="$P-config-logs"
BUDGET="$P-monthly"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (기대: '$2', 실제: '$1')"; }
ok() { printf '  ✔ %s\n' "$*"; }

# poll <상한 초> <설명> <명령...> — 명령이 성공할 때까지 1초 간격으로 다시 시도한다.
# "몇 초 뒤면 된다"를 가정하지 않는다. 상한을 넘기면 마지막 관찰을 보여 주고 실패한다.
poll() {
  local limit="$1" desc="$2" start=$SECONDS out
  shift 2
  until out="$("$@" 2>&1)"; do
    if ((SECONDS - start >= limit)); then
      fail "$desc: ${limit}초 안에 조건을 만족하지 못했다. 마지막 관찰: ${out:-없음}"
    fi
    sleep 1
  done
}

# JSON 가공용 파이썬 (저장소의 uv 환경 — jq 설치 불필요). json·sys 는 미리 import 됨.
py() {
  uv run --quiet --project "$ROOT" python -c "import json, sys
$1" "${@:2}"
}

# ---------- CloudFormation ----------
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE
}

# wait_stack <스택> [상한초] — 2초 간격 describe-stacks 폴링.
# `aws cloudformation wait stack-create-complete` 를 쓰지 않는 이유: 에뮬레이터는 describe-stacks 가 올 때만
# 스택을 진행시키고, NAT 게이트웨이를 기다리는 경로에 약 10초 마감이 있어 30초 간격 웨이터로는 롤백된다(M10 README).
wait_stack() {
  local name="$1" limit="${2:-240}" start=$SECONDS s
  while :; do
    s="$(stack_status "$name")"
    case "$s" in *_IN_PROGRESS) ;; *) echo "$s"; return 0 ;; esac
    ((SECONDS - start < limit)) || fail "스택 $name 이 ${limit}초 안에 끝나지 않음 (마지막 $s)"
    sleep 2
  done
}

stack_failures() {
  aws cloudformation describe-stack-events --stack-name "$1" \
    --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId, ResourceStatusReason]' --output text 2>/dev/null | head -5
}

delete_stack() {
  local name="$1"
  [ "$(stack_status "$name")" = NONE ] && return 0
  aws cloudformation delete-stack --stack-name "$name"
  local start=$SECONDS
  while [ "$(stack_status "$name")" != NONE ]; do
    case "$(stack_status "$name")" in DELETE_FAILED) fail "스택 $name 삭제 실패: $(stack_failures "$name")" ;; esac
    ((SECONDS - start < 240)) || fail "스택 $name 삭제가 240초 안에 끝나지 않음"
    sleep 2
  done
}

# deploy_stack <스택> <템플릿> [파라미터...] — 없으면 만들고, 있으면 그대로 둔다(같은 템플릿 재배포는 하지 않음).
# 실패·롤백 상태로 남아 있으면 지우고 다시 만든다. 결과 상태가 CREATE_COMPLETE 가 아니면 실패.
deploy_stack() {
  local name="$1" tpl="$2" s
  shift 2
  s="$(stack_status "$name")"
  case "$s" in
    CREATE_COMPLETE | UPDATE_COMPLETE) echo "스택 $name 이미 있음 ($s) — 재사용"; return 0 ;;
    NONE) ;;
    *) echo "스택 $name 이 $s 상태 — 지우고 다시 만든다"; delete_stack "$name" ;;
  esac
  local -a params=()
  [ "$#" -gt 0 ] && params=(--parameters "$@")
  aws cloudformation create-stack --stack-name "$name" --template-body "file://$tpl" \
    --capabilities CAPABILITY_NAMED_IAM --tags Key=Project,Value=todayorder Key=Capstone,Value=m14 \
    ${params[@]+"${params[@]}"} --query StackId --output text >/dev/null
  s="$(wait_stack "$name")"
  [ "$s" = CREATE_COMPLETE ] || fail "스택 $name: $s — $(stack_failures "$name")"
  echo "스택 $name: $s"
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# ---------- 기타 ----------
queue_url() { aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }
queue_arn() { echo "arn:aws:sqs:$REGION:$ACCOUNT:$1"; }
visible() {
  aws sqs get-queue-attributes --queue-url "$1" --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text
}

# nuke_bucket <버킷> — 모든 객체 버전·삭제 마커를 지우고 버킷을 지운다 (버전 관리 버킷 대응).
nuke_bucket() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1 || return 0
  local batch
  while :; do
    batch="$(aws s3api list-object-versions --bucket "$1" --max-items 500 --output json | py '
d = json.loads(sys.stdin.read() or "{}")
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in d.get("Versions", []) + d.get("DeleteMarkers", [])]
print(json.dumps({"Objects": objs, "Quiet": True}) if objs else "")')"
    [ -n "$batch" ] || break
    aws s3api delete-objects --bucket "$1" --delete "$batch" >/dev/null
  done
  aws s3api delete-bucket --bucket "$1"
}

delete_role() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || return 0
  local p
  for p in $(aws iam list-role-policies --role-name "$1" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$1" --policy-name "$p"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$1" --policy-arn "$p"
  done
  aws iam delete-role --role-name "$1"
}

# zip_function <파이썬 파일> <zip 경로>
zip_function() {
  uv run --quiet --project "$ROOT" python -c \
    'import sys, zipfile, os; z = zipfile.ZipFile(sys.argv[2], "w"); z.write(sys.argv[1], os.path.basename(sys.argv[1])); z.close()' "$1" "$2"
}

# HTTP API 호출 주소 (에뮬레이터 전용 경로). 실제 AWS: https://<apiId>.execute-api.us-east-1.amazonaws.com/<path>
api_base() { echo "https://127.0.0.1:$EMULATOR_PORT/_aws/execute-api/$1"; }
api_id() {
  aws apigatewayv2 get-apis --output json | py '
for a in json.load(sys.stdin).get("Items", []):
    if a["Name"] == sys.argv[1]:
        print(a["ApiId"])' "$API_NAME" | head -1
}
# call <METHOD> <URL> [curl 인자...] — 본문, 마지막 줄에 [HTTP 코드]
call() {
  local m="$1" u="$2"
  shift 2
  curl -s --cacert "$AWS_CA_BUNDLE" -X "$m" -w '\n[HTTP %{http_code}]\n' "$@" "$u"
}

# ---------- 계층 존재 확인 (다른 lab 이 선행 계층을 스스로 만들 때 사용) ----------
have_network() { [ "$(stack_status "$NET_STACK")" = CREATE_COMPLETE ] && aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text 2>/dev/null | grep -qx 1; }
have_data() { [ "$(stack_status "$DATA_STACK")" = CREATE_COMPLETE ] && aws s3api head-bucket --bucket "$RECEIPTS" >/dev/null 2>&1; }
have_pipeline() { [ "$(stack_status "$MSG_STACK")" = CREATE_COMPLETE ] && [ -n "$(api_id)" ] && aws lambda get-function --function-name "$WORKER_FN" >/dev/null 2>&1; }
have_ops() { aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'length(MetricAlarms)' --output text | grep -qx 1 && aws cloudtrail get-trail-status --name "$TRAIL" >/dev/null 2>&1; }

# ensure <확인 함수> <lab 스크립트> — 계층이 없으면 그 lab 을 실행해 만든다
ensure() {
  if "$1"; then
    echo "(선행 계층 있음: $(basename "$2"))"
  else
    echo "(선행 계층 없음 → $(basename "$2") 실행)"
    bash "$2" >/dev/null || fail "선행 lab $(basename "$2") 실패"
  fi
}
