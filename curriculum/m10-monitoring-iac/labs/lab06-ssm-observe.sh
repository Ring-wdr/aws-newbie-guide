#!/usr/bin/env bash
# M10 lab06 — Systems Manager 관찰 (🔴 Session Manager / 🟡 Run Command / 🟢 Parameter Store)
# 에뮬레이터의 EC2 인스턴스는 부팅하지 않으므로 SSM Agent도 없다. 그래서
#   - Session Manager(StartSession)는 501
#   - Run Command(SendCommand)는 요청은 받지만 대상 인스턴스가 0개라 Pending에 머문다
#   - 관리형 노드 목록(DescribeInstanceInformation)은 비어 있다
# 반대로 에이전트가 필요 없는 Parameter Store 는 실제처럼 동작한다(자세한 실습은 M09).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

PARAM="/todayorder/prod/api/log-level"
aws ssm delete-parameter --name "$PARAM" >/dev/null 2>&1 || true

echo "== 1. 관리형 노드(SSM Agent가 등록한 인스턴스) 목록"
aws ssm describe-instance-information --query 'InstanceInformationList'
nodes="$(aws ssm describe-instance-information --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["InstanceInformationList"]))')"

echo "== 2. Session Manager: SSH 없이 셸 열기 (StartSession)"
set +e
session="$(aws ssm start-session --target i-0123456789abcdef0 2>&1)"
set -e
echo "$session"

echo "== 3. Run Command: 태그 app=todayorder 인 모든 서버에서 uptime"
CMD_ID="$(aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:app,Values=todayorder --parameters 'commands=["uptime"]' \
  --comment "todayorder lab06" --query Command.CommandId --output text)"
aws ssm list-commands --command-id "$CMD_ID" \
  --query 'Commands[0].{Document: DocumentName, Status: Status, Targets: TargetCount, Completed: CompletedCount}'
cmd_status="$(aws ssm list-commands --command-id "$CMD_ID" --query 'Commands[0].Status' --output text)"

echo "== 4. Patch Manager: 패치 기준선 목록 (DescribePatchBaselines)"
set +e
patch="$(aws ssm describe-patch-baselines 2>&1)"
set -e
echo "$patch"

echo "== 5. Parameter Store (에이전트 불필요 — 동작함)"
aws ssm put-parameter --name "$PARAM" --type String --value INFO --query Version --output text
aws ssm put-parameter --name "$PARAM" --type String --value DEBUG --overwrite --query Version --output text
aws ssm get-parameter --name "$PARAM" --query 'Parameter.{Name: Name, Value: Value, Version: Version}'
value="$(aws ssm get-parameter --name "$PARAM" --query Parameter.Value --output text)"
aws ssm delete-parameter --name "$PARAM"

# ---- 단언
[ "$nodes" = 0 ] || echo "참고: 관리형 노드가 $nodes 개 — 에뮬레이터가 바뀐 듯하다"
[[ "$session" == *NotImplemented* ]] || echo "참고: StartSession 이 501이 아님 — 에뮬레이터가 바뀐 듯하다. 레슨 4 등급을 다시 확인할 것"
[ -n "$cmd_status" ] || fail "SendCommand 상태를 읽지 못함"
[ "$value" = DEBUG ] || fail "파라미터 값이 DEBUG 가 아님: $value"
echo "LAB06 OK"
