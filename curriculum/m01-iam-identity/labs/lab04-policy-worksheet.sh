#!/usr/bin/env bash
# M01 lab04 — 정책 평가 워크시트를 손으로 풀고 iam simulate-principal-policy 로 채점 (🟢)
#
# 문제는 레슨 03 "정책 평가 워크시트" 절에 있다. 손으로 먼저 풀고 답을 넣어 실행하면 채점해 준다.
#   MY_ANSWERS="A D D A D I I I I A" bash curriculum/m01-iam-identity/labs/lab04-policy-worksheet.sh
#   (A = allowed, D = explicitDeny, I = implicitDeny — 10문항, 공백으로 구분)
# MY_ANSWERS 없이 실행하면 정답표와 시뮬레이터 결과가 일치하는지만 확인한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ACCOUNT=000000000000
USER_NAME=todayorder-dev-park
GROUP=todayorder-ws-developers
BASE_ARN="arn:aws:iam::$ACCOUNT:policy/todayorder-ws-dev-base"
BOUNDARY_ARN="arn:aws:iam::$ACCOUNT:policy/todayorder-ws-boundary"
POL_DIR="$(cd "$(dirname "$0")" && pwd)/policies"

cleanup() {
  delete_user_fully "$USER_NAME"
  delete_group_fully "$GROUP"
  delete_policy_fully "$BASE_ARN"
  delete_policy_fully "$BOUNDARY_ARN"
}
cleanup

echo "== 1. 워크시트 환경 만들기 (정책 원문: labs/policies/ws-*.json)"
aws iam create-policy --policy-name todayorder-ws-dev-base --policy-document "file://$POL_DIR/ws-dev-base.json" --query Policy.Arn --output text
aws iam create-policy --policy-name todayorder-ws-boundary --policy-document "file://$POL_DIR/ws-boundary.json" --query Policy.Arn --output text
aws iam create-group --group-name "$GROUP" --query Group.Arn --output text
aws iam attach-group-policy --group-name "$GROUP" --policy-arn "$BASE_ARN"
aws iam create-user --user-name "$USER_NAME" --query User.Arn --output text
aws iam add-user-to-group --group-name "$GROUP" --user-name "$USER_NAME"
aws iam put-user-policy --user-name "$USER_NAME" --policy-name guardrail --policy-document "file://$POL_DIR/ws-guardrail.json"
aws iam put-user-permissions-boundary --user-name "$USER_NAME" --permissions-boundary "$BOUNDARY_ARN"

# 문항: "액션 리소스ARN 정답"
QUESTIONS=(
  "s3:GetObject arn:aws:s3:::todayorder-receipts/2026/11/A-1001.json A"
  "s3:PutObject arn:aws:s3:::todayorder-receipts/archive/2025.json D"
  "s3:DeleteObject arn:aws:s3:::todayorder-receipts/2026/11/A-1001.json D"
  "dynamodb:PutItem arn:aws:dynamodb:us-east-1:$ACCOUNT:table/todayorder-orders A"
  "dynamodb:DeleteTable arn:aws:dynamodb:us-east-1:$ACCOUNT:table/todayorder-orders D"
  "dynamodb:PutItem arn:aws:dynamodb:us-east-1:$ACCOUNT:table/todayorder-payments I"
  "ec2:DescribeInstances * I"
  "s3:GetObject arn:aws:s3:::todayorder-images/logo.png I"
  "sqs:SendMessage arn:aws:sqs:us-east-1:$ACCOUNT:todayorder-orders I"
  "s3:PutObject arn:aws:s3:::todayorder-receipts/2026/11/A-1002.json A"
)
code() { case "$1" in allowed) echo A ;; explicitDeny) echo D ;; implicitDeny) echo I ;; *) echo "?" ;; esac; }

read -r -a MINE <<<"${MY_ANSWERS:-}"
if [ "${#MINE[@]}" -gt 0 ] && [ "${#MINE[@]}" -ne "${#QUESTIONS[@]}" ]; then
  echo "MY_ANSWERS 는 ${#QUESTIONS[@]}개여야 합니다 (지금 ${#MINE[@]}개)"; exit 2
fi

echo "== 2. 시뮬레이터로 채점"
printf '%-3s %-22s %-64s %-6s %-6s %s\n' "#" "Action" "Resource" "정답" "시뮬" "내 답"
mismatch=0
score=0
for i in "${!QUESTIONS[@]}"; do
  read -r action resource expect <<<"${QUESTIONS[$i]}"
  decision="$(aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::$ACCOUNT:user/$USER_NAME" \
    --action-names "$action" --resource-arns "$resource" \
    --query 'EvaluationResults[0].EvalDecision' --output text)"
  got="$(code "$decision")"
  [ "$got" = "$expect" ] || mismatch=$((mismatch + 1))
  mine="-"
  if [ "${#MINE[@]}" -gt 0 ]; then
    mine="${MINE[$i]}"
    if [ "$mine" = "$got" ]; then score=$((score + 1)); mine="$mine ✔"; else mine="$mine ✘"; fi
  fi
  printf '%-3s %-22s %-64s %-6s %-6s %s\n' "Q$((i + 1))" "$action" "$resource" "$expect" "$got" "$mine"
done
[ "${#MINE[@]}" -gt 0 ] && echo "내 점수: $score / ${#QUESTIONS[@]}"

echo "== 3. 근거 보기: Q2 는 어떤 정책 때문에 거부됐나 (MatchedStatements)"
aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT:user/$USER_NAME" \
  --action-names s3:PutObject --resource-arns arn:aws:s3:::todayorder-receipts/archive/2025.json \
  --query 'EvaluationResults[0].{Decision: EvalDecision, Matched: MatchedStatements[].SourcePolicyId}'

# ---- 단언: 정답표 = 시뮬레이터
[ "$mismatch" -eq 0 ] || { echo "FAIL: 정답표와 시뮬레이터가 $mismatch 문항에서 다르다"; exit 1; }
cleanup
echo "LAB04 OK"
