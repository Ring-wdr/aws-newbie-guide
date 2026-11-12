#!/usr/bin/env bash
# M10 lab05 — 앱 스택(S3·SQS·DynamoDB)으로 변경 세트·드리프트·종료 보호 (🟢 변경 세트 / 🟡 드리프트)
#   v1: templates/app-stack.yaml      영수증 버킷 + 주문 큐 + 주문 테이블
#   v2: templates/app-stack-v2.yaml   + 주문 DLQ, 주문 큐에 RedrivePolicy
# IGW 연결이 없는 스택이라 에뮬레이터에서도 변경 세트가 끝까지 실행된다(lab04의 VPC 스택과 비교).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

DIR="$(cd "$(dirname "$0")" && pwd)/templates"
STACK="todayorder-app"

delete_stack_if_exists "$STACK"

echo "== 1. v1 스택 생성 (종료 보호 켜기)"
aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$DIR/app-stack.yaml" \
  --enable-termination-protection --query StackId --output text >/dev/null
status="$(wait_stack "$STACK")"
echo "스택 상태: $status"
[ "$status" = CREATE_COMPLETE ] || fail "생성 실패: $status"
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
BUCKET="$(out BucketName)"; QURL="$(out QueueUrl)"; TABLE="$(out TableName)"
echo "버킷=$BUCKET"
echo "큐=$QURL"
echo "테이블=$TABLE"

echo "== 2. 변경 세트 1: v2 템플릿 (DLQ 추가 + 큐에 RedrivePolicy) — 실행 전에 무엇이 바뀌는지 본다"
aws cloudformation create-change-set --stack-name "$STACK" --change-set-name add-dlq \
  --template-body "file://$DIR/app-stack-v2.yaml" --change-set-type UPDATE --query Id --output text >/dev/null
cs_status() { aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$1" --query Status --output text; }
export -f cs_status
export STACK
wait_until 60 1 "변경 세트 계산" bash -c '[[ "$(cs_status add-dlq)" =~ CREATE_COMPLETE|FAILED ]]'
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name add-dlq \
  --query 'Changes[].ResourceChange.[Action, LogicalResourceId, ResourceType, Replacement]' --output table
changes="$(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name add-dlq --output json | py -c '
import json, sys
print(",".join(sorted(c["ResourceChange"]["Action"] + ":" + c["ResourceChange"]["LogicalResourceId"] for c in json.load(sys.stdin)["Changes"])))')"

echo "== 3. 변경 세트 실행 → UPDATE_COMPLETE, 실제 큐에 RedrivePolicy가 붙었나"
aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name add-dlq
update_status="$(wait_stack "$STACK")"
echo "스택 상태: $update_status"
QURL="$(out QueueUrl)"
redrive="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names RedrivePolicy --query Attributes.RedrivePolicy --output text)"
echo "RedrivePolicy: $redrive"

echo "== 4. 변경 세트 2: 파라미터만 바꾸기 (QueueVisibility 45 → 60) — 계산만 하고 실행하지 않고 지운다"
aws cloudformation create-change-set --stack-name "$STACK" --change-set-name vis-60 --use-previous-template \
  --parameters ParameterKey=QueueVisibility,ParameterValue=60 --change-set-type UPDATE --query Id --output text >/dev/null
wait_until 60 1 "변경 세트 계산" bash -c '[[ "$(cs_status vis-60)" =~ CREATE_COMPLETE|FAILED ]]'
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name vis-60 \
  --query 'Changes[].ResourceChange.{Action: Action, Logical: LogicalResourceId, Replacement: Replacement, Scope: Scope}'
aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name vis-60
vis="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names VisibilityTimeout --query Attributes.VisibilityTimeout --output text)"
echo "실행하지 않았으므로 가시성 타임아웃은 그대로: $vis"

echo "== 5. 드리프트: 콘솔에서 누군가 버킷 버전 관리를 끄고, 큐 가시성 타임아웃을 5초로 바꿨다"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Suspended
aws sqs set-queue-attributes --queue-url "$QURL" --attributes VisibilityTimeout=5
DID="$(aws cloudformation detect-stack-drift --stack-name "$STACK" --query StackDriftDetectionId --output text)"
export DID
wait_until 60 1 "드리프트 감지 완료" bash -c \
  '[ "$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DID" --query DetectionStatus --output text)" != DETECTION_IN_PROGRESS ]'
aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DID" \
  --query '{Stack: StackDriftStatus, DriftedResources: DriftedStackResourceCount}'
aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" --output json | py -c '
import json, sys
for d in sorted(json.load(sys.stdin)["StackResourceDrifts"], key=lambda d: d["LogicalResourceId"]):
    print("  %-14s %s" % (d["LogicalResourceId"], d["StackResourceDriftStatus"]))
    for p in d.get("PropertyDifferences") or []:
        print("      %s: 기대 %s → 실제 %s" % (p["PropertyPath"], p["ExpectedValue"], p["ActualValue"]))'
drifted="$(aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" \
  --stack-resource-drift-status-filters MODIFIED --output json | py -c '
import json, sys
print(",".join(sorted(d["LogicalResourceId"] for d in json.load(sys.stdin)["StackResourceDrifts"])))')"
echo "   ↑ 에뮬레이터 1.0.322: OrdersTable 은 실제로 있는데도 DELETED 로 나온다(DynamoDB 드리프트 미지원으로 보임)."

echo "== 6. 드리프트 바로잡기: 실제 리소스를 템플릿 값으로 되돌린다"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws sqs set-queue-attributes --queue-url "$QURL" --attributes VisibilityTimeout=45
aws cloudformation detect-stack-resource-drift --stack-name "$STACK" --logical-resource-id OrdersQueue \
  --query 'StackResourceDrift.{Resource: LogicalResourceId, Drift: StackResourceDriftStatus}'
queue_after="$(aws cloudformation detect-stack-resource-drift --stack-name "$STACK" --logical-resource-id OrdersQueue \
  --query StackResourceDrift.StackResourceDriftStatus --output text)"

echo "== 7. 종료 보호: 켜져 있으면 delete-stack 이 거부된다"
set +e
denied="$(aws cloudformation delete-stack --stack-name "$STACK" 2>&1)"
set -e
echo "$denied"
aws cloudformation update-termination-protection --stack-name "$STACK" --no-enable-termination-protection \
  --query StackId --output text >/dev/null
aws cloudformation delete-stack --stack-name "$STACK"
wait_until 180 2 "스택 삭제" bash -c "! aws cloudformation describe-stacks --stack-name $STACK >/dev/null 2>&1"
set +e
gone="$(aws sqs get-queue-url --queue-name "${QURL##*/}" 2>&1)"
set -e
echo "삭제 후 주문 큐 조회: $(grep -o 'NonExistentQueue\|QueueDoesNotExist' <<<"$gone" | head -1)"

# ---- 단언
[ "$changes" = "Add:OrdersDlq,Modify:OrdersQueue" ] || fail "변경 세트 내용이 예상과 다름: $changes"
[ "$update_status" = UPDATE_COMPLETE ] || fail "변경 세트 실행 결과가 UPDATE_COMPLETE 가 아님: $update_status"
[[ "$redrive" == *maxReceiveCount* ]] || fail "RedrivePolicy 가 적용되지 않음"
[ "$vis" = 45 ] || fail "실행하지 않은 변경 세트가 적용됨: $vis"
[ "$drifted" = "OrdersQueue,ReceiptsBucket" ] || fail "MODIFIED 리소스가 예상과 다름: $drifted"
[ "$queue_after" = IN_SYNC ] || fail "되돌린 큐가 IN_SYNC 가 아님: $queue_after"
[[ "$denied" == *TerminationProtection* ]] || fail "종료 보호가 삭제를 막지 않음"
[[ "$gone" == *NonExistentQueue* || "$gone" == *QueueDoesNotExist* ]] || fail "스택 삭제 후에도 큐가 남음"
echo "LAB05 OK"
