#!/usr/bin/env bash
# M01 lab06 — SCP 워크시트: "SCP ∩ IAM" 을 손으로 판정하고 iam simulate-custom-policy 로 채점 (🔴 대체 실습)
#
# 에뮬레이터는 SCP API(CreatePolicy·AttachPolicy …)가 501이라 SCP를 실제로 붙여 볼 수 없다.
# 대신 SCP JSON(labs/policies/scp-*.json)을 직접 쓰고, 각 계층의 SCP와 IAM 정책을 시뮬레이터로
# "따로" 평가한 뒤 교집합을 계산한다. 이것이 실제 AWS가 하는 일과 같은 논리다:
#
#   최종 허용 = (모든 계층의 SCP가 허용) AND (IAM 정책이 허용) AND (어디에도 명시적 Deny 없음)
#
# 문제는 레슨 05 "SCP 워크시트" 절에 있다. 손으로 먼저 풀고 답을 넣어 실행하면 채점한다.
#   MY_ANSWERS="D A D A I A I I A D" bash curriculum/m01-iam-identity/labs/lab06-scp-worksheet.sh
#   (A = 허용, D = 명시적 Deny 로 거부, I = 암묵적 Deny 로 거부)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

POL="$(cd "$(dirname "$0")" && pwd)/policies"
doc() { cat "$POL/$1.json"; }

# 조직 구조와 계층별로 붙은 SCP (실제로는 Organizations 가 저장한다)
#   Root                 : scp-full-aws-access
#   └ workloads OU       : scp-full-aws-access
#     └ prod OU          : scp-full-aws-access + scp-prod-guardrails
#   └ sandbox OU         : scp-sandbox-allow-list   (FullAWSAccess 를 떼고 허용 목록만)
levels_for() {
  case "$1" in
    prod) echo "scp-full-aws-access scp-full-aws-access scp-full-aws-access,scp-prod-guardrails" ;;
    sandbox) echo "scp-full-aws-access scp-sandbox-allow-list" ;;
    management) echo "" ;; # 관리 계정에는 SCP가 적용되지 않는다
    *) echo "unknown"; return 1 ;;
  esac
}

# 시나리오: 계정위치 | IAM 정책 | 액션 | 요청 리전 | 정답
SCENARIOS=(
  "prod|iam-admin|cloudtrail:StopLogging|ap-northeast-2|D"
  "prod|iam-admin|ec2:RunInstances|ap-northeast-2|A"
  "prod|iam-admin|ec2:RunInstances|eu-west-1|D"
  "prod|iam-admin|iam:CreateRole|eu-west-1|A"
  "sandbox|iam-admin|ec2:RunInstances|ap-northeast-2|I"
  "sandbox|iam-admin|s3:PutObject|ap-northeast-2|A"
  "sandbox|iam-orders-dev|s3:PutObject|ap-northeast-2|I"
  "prod|none|dynamodb:Query|ap-northeast-2|I"
  "management|iam-admin|cloudtrail:StopLogging|ap-northeast-2|A"
  "prod|iam-admin|organizations:LeaveOrganization|us-east-1|D"
)

# 정책 묶음 하나를 시뮬레이터로 평가 → allowed / explicitDeny / implicitDeny
simulate() { # <쉼표로 구분한 정책 이름들> <액션> <리전>
  local names="$1" action="$2" region="$3" n
  local args=()
  IFS=',' read -r -a list <<<"$names"
  for n in "${list[@]}"; do args+=("$(doc "$n")"); done
  aws iam simulate-custom-policy --policy-input-list "${args[@]}" --action-names "$action" \
    --context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=$region,ContextKeyType=string" \
    --query 'EvaluationResults[0].EvalDecision' --output text
}

read -r -a MINE <<<"${MY_ANSWERS:-}"
if [ "${#MINE[@]}" -gt 0 ] && [ "${#MINE[@]}" -ne "${#SCENARIOS[@]}" ]; then
  echo "MY_ANSWERS 는 ${#SCENARIOS[@]}개여야 합니다 (지금 ${#MINE[@]}개)"; exit 2
fi

echo "== SCP 워크시트 채점 (SCP 계층별 판정 · IAM 판정 · 최종)"
printf '%-4s %-10s %-15s %-33s %-15s %-34s %-13s %-5s %-5s %s\n' \
  "#" "계정" "IAM" "Action" "Region" "SCP(계층별)" "IAM" "최종" "정답" "내 답"
mismatch=0
score=0
for i in "${!SCENARIOS[@]}"; do
  IFS='|' read -r where iam action region expect <<<"${SCENARIOS[$i]}"
  scp_results=()
  explicit=0
  scp_ok=1
  for level in $(levels_for "$where"); do
    d="$(simulate "$level" "$action" "$region")"
    scp_results+=("$d")
    [ "$d" = "explicitDeny" ] && explicit=1
    [ "$d" = "allowed" ] || scp_ok=0
  done
  if [ "$iam" = "none" ]; then
    iam_d="implicitDeny" # 정책이 하나도 없으면 시뮬레이션할 것도 없이 암묵적 Deny
  else
    iam_d="$(simulate "$iam" "$action" "$region")"
  fi
  [ "$iam_d" = "explicitDeny" ] && explicit=1
  if [ "$explicit" -eq 1 ]; then final=D
  elif [ "$scp_ok" -eq 1 ] && [ "$iam_d" = "allowed" ]; then final=A
  else final=I
  fi
  [ "$final" = "$expect" ] || mismatch=$((mismatch + 1))
  scp_txt="$(IFS=/; echo "${scp_results[*]:-(적용 안 됨)}")"
  mine="-"
  if [ "${#MINE[@]}" -gt 0 ]; then
    mine="${MINE[$i]}"
    if [ "$mine" = "$final" ]; then score=$((score + 1)); mine="$mine ✔"; else mine="$mine ✘"; fi
  fi
  printf '%-4s %-10s %-15s %-33s %-15s %-34s %-13s %-5s %-5s %s\n' \
    "S$((i + 1))" "$where" "$iam" "$action" "$region" "$scp_txt" "$iam_d" "$final" "$expect" "$mine"
done
[ "${#MINE[@]}" -gt 0 ] && echo "내 점수: $score / ${#SCENARIOS[@]}"

echo "== 참고: 같은 판정을 '권한 경계' 입력으로 흉내 내기 (S5: 샌드박스 OU + 관리자)"
aws iam simulate-custom-policy --policy-input-list "$(doc iam-admin)" \
  --permissions-boundary-policy-input-list "$(doc scp-sandbox-allow-list)" \
  --action-names ec2:RunInstances s3:PutObject \
  --query 'EvaluationResults[].{Action: EvalActionName, Decision: EvalDecision, AllowedByBoundary: PermissionsBoundaryDecisionDetail.AllowedByPermissionsBoundary}'

# ---- 단언
[ "$mismatch" -eq 0 ] || { echo "FAIL: 정답표와 계산 결과가 $mismatch 문항에서 다르다"; exit 1; }
echo "LAB06 OK"
