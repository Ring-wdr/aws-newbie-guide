#!/usr/bin/env bash
# M03 lab09 — 조정 정책·예약 작업·수명 주기 후크와 자가 치유 (🔴 501 · 자가 치유 없음)
#
# 에뮬레이터는 Auto Scaling 의 "조정" 기능이 모두 501 이다. 그래서 이 lab 은
#   1) 정책 JSON 을 직접 쓰고(labs/policies/*.json),
#   2) AWS CLI 의 파라미터 검증을 "문법 채점기"로 쓴다:
#        - JSON 모양이 틀리면 → 요청을 보내기 전에 CLI 가 ParamValidation 으로 거부
#        - 모양이 맞으면     → 에뮬레이터까지 가서 501 NotImplemented
#      즉 "NotImplemented 가 나오면 모양은 통과"다. (값의 의미가 맞는지는 레슨 6 워크시트로 손으로 판정)
#   3) 인스턴스를 죽여도 대체 인스턴스가 뜨지 않는 것(자가 치유 없음)을 관찰한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ASG="todayorder-policy-asg"
LT_NAME="todayorder-heal-lt"
POL="$(cd "$(dirname "$0")/policies" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cleanup() {
  local ids
  if [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text)" != "0" ]; then
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete
  fi
  ids="$(aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values="$ASG" \
    Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
  # shellcheck disable=SC2086
  [ -n "$ids" ] && wait_for instance terminated $ids >/dev/null
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null 2>&1 || true
  return 0
}
cleanup
m03_network
AMI="$(m03_ami)"

echo "== 0. 연습용 ASG (min 2 / max 10 / desired 2)"
aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
  --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\"}" >/dev/null
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
  --min-size 2 --max-size 10 --desired-capacity 2 --vpc-zone-identifier "$M03_SUBNET_A,$M03_SUBNET_B"
n_instances() { aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups[0].Instances)' --output text; }
has_2() { [ "$(n_instances)" = 2 ]; }
poll 60 "인스턴스 2대" has_2

echo "== 1. 정책 JSON 을 CLI 에 넣어 본다 (NotImplemented = 모양 통과)"
ok=0
for f in target-tracking-cpu50 target-tracking-alb-requests step-scaling-cpu simple-scaling predictive-cpu; do
  printf -- '-- %-34s → ' "$f.json"
  if out="$(expect_error NotImplemented aws autoscaling put-scaling-policy --cli-input-json "file://$POL/$f.json" 2>&1)"; then
    echo "NotImplemented (모양 통과)"; ok=$((ok + 1))
  else
    echo "$out"
  fi
done
printf -- '-- %-34s → ' "scheduled-lunch-peak.json"
expect_error NotImplemented aws autoscaling put-scheduled-update-group-action --cli-input-json "file://$POL/scheduled-lunch-peak.json" >/dev/null && { echo "NotImplemented (모양 통과)"; ok=$((ok + 1)); }
printf -- '-- %-34s → ' "lifecycle-hook-drain.json"
expect_error NotImplemented aws autoscaling put-lifecycle-hook --cli-input-json "file://$POL/lifecycle-hook-drain.json" >/dev/null && { echo "NotImplemented (모양 통과)"; ok=$((ok + 1)); }

echo "== 2. 일부러 틀린 JSON → CLI 가 보내기도 전에 거부 (ParamValidation)"
cat >"$WORK/broken-step.json" <<'EOF'
{
  "AutoScalingGroupName": "todayorder-policy-asg",
  "PolicyName": "broken",
  "PolicyTyp": "StepScaling",
  "StepAdjustments": [ { "MetricIntervalLowerBound": 0.0, "ScalingAdjustment": "one" } ]
}
EOF
expect_error ParamValidation aws autoscaling put-scaling-policy --cli-input-json "file://$WORK/broken-step.json"

echo "== 3. 조회 계열도 501"
expect_error NotImplemented aws autoscaling describe-policies --auto-scaling-group-name "$ASG"
expect_error NotImplemented aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG"

echo "== 4. 자가 치유: ASG 인스턴스 하나를 EC2 API 로 직접 종료"
VICTIM="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
aws ec2 terminate-instances --instance-ids "$VICTIM" --query 'TerminatingInstances[0].CurrentState.Name' --output text
wait_for instance terminated "$VICTIM" >/dev/null
echo "EC2 상태: $(aws ec2 describe-instances --instance-ids "$VICTIM" --query 'Reservations[0].Instances[0].State.Name' --output text)"
replaced() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text | grep -vq "$VICTIM" &&
    ! aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text | grep -q "$VICTIM"
}
echo "-- 30초 동안 대체 인스턴스가 뜨는지 지켜본다 (실제 AWS라면 헬스 체크 실패 → 교체)"
if poll 30 "대체 인스턴스" replaced 2>/dev/null; then healed=yes; else healed=no; fi
echo "자가 치유 일어남? $healed"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState,HealthStatus]' --output text | sort

echo "== 5. 수동으로 치유하려는 API 도 501"
expect_error NotImplemented aws autoscaling set-instance-health --instance-id "$VICTIM" --health-status Unhealthy
expect_error NotImplemented aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$VICTIM" --no-should-decrement-desired-capacity

echo "== 6. 정리"
cleanup
echo "정리 완료"

# ---- 단언
[ "$ok" = "7" ] || fail "정책 JSON 7개가 모두 '모양 통과(NotImplemented)'가 아님 ($ok/7) — 501 이 풀렸다면 레슨 갱신"
[ "$healed" = "no" ] || fail "자가 치유가 일어났다 — 에뮬레이터가 바뀌었을 수 있다 (레슨·README 갱신)"
echo "LAB09 OK"
