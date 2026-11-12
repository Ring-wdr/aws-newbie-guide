#!/usr/bin/env bash
# M09 lab10 — 심층 방어: Network Firewall 아웃바운드 허용 목록 규칙 그룹과 방화벽 정책 (🟡 구성만)
# TodayOrder 의 주문 서버는 결제 대행사 API 와 AWS API 로만 나가야 한다. 도메인(SNI/Host) 허용 목록을
# 상태 저장(stateful) 규칙 그룹으로 만들고 정책에 묶는다. 에뮬레이터는 트래픽을 흘리지 않으므로 차단은 볼 수 없다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

RG="todayorder-m09-egress-allowlist"
POLICY="todayorder-m09-egress-policy"
WORK="$TMP_LIB"
cd "$WORK"

# ---- 이전 실행 정리 (멱등): 정책 → 규칙 그룹 순서로
aws network-firewall delete-firewall-policy --firewall-policy-name "$POLICY" >/dev/null 2>&1 || true
aws network-firewall delete-rule-group --rule-group-name "$RG" --type STATEFUL >/dev/null 2>&1 || true

echo "== 1. 상태 저장 규칙 그룹 — 도메인 허용 목록(ALLOWLIST)"
aws network-firewall create-rule-group --rule-group-name "$RG" --type STATEFUL --capacity 100 \
  --description "orders-api egress allowlist" --rule-group '{
    "RulesSource": {"RulesSourceList": {
      "Targets": [".amazonaws.com", "api.payments.example"],
      "TargetTypes": ["TLS_SNI", "HTTP_HOST"],
      "GeneratedRulesType": "ALLOWLIST"}}}' \
  --query 'RuleGroupResponse.{Name: RuleGroupName, Type: Type, Capacity: Capacity, Status: RuleGroupStatus}'
RG_ARN="$(aws network-firewall describe-rule-group --rule-group-name "$RG" --type STATEFUL --query RuleGroupResponse.RuleGroupArn --output text)"
aws network-firewall describe-rule-group --rule-group-name "$RG" --type STATEFUL \
  --query 'RuleGroup.RulesSource.RulesSourceList'

echo "== 2. 방화벽 정책 — 상태 비저장 기본 동작은 '상태 저장 엔진으로 넘김', 상태 저장은 위 규칙 그룹"
aws network-firewall create-firewall-policy --firewall-policy-name "$POLICY" --firewall-policy "{
  \"StatelessDefaultActions\": [\"aws:forward_to_sfe\"],
  \"StatelessFragmentDefaultActions\": [\"aws:forward_to_sfe\"],
  \"StatefulRuleGroupReferences\": [{\"ResourceArn\": \"$RG_ARN\"}]}" \
  --query 'FirewallPolicyResponse.{Name: FirewallPolicyName, Status: FirewallPolicyStatus}'
refs="$(aws network-firewall describe-firewall-policy --firewall-policy-name "$POLICY" \
  --query 'length(FirewallPolicy.StatefulRuleGroupReferences)' --output text)"
echo "정책에 연결된 상태 저장 규칙 그룹: ${refs}개"

echo "== 3. 계층별 방어선 점검표 (TodayOrder) — 각 계층에 무엇이 있나"
cat <<'EOF'
  엣지      : CloudFront + WAF(관리형 규칙·속도 제한) + Shield Standard(자동)   ← M08 lab06
  VPC 경계  : Network Firewall(아웃바운드 도메인 허용 목록)                    ← 이 lab
  서브넷    : NACL(상태 비저장, 허용/거부 규칙)                               ← M02
  인스턴스  : 보안 그룹(상태 저장, 허용만)                                     ← M02
  데이터    : KMS 암호화 · 키 정책 · Secrets Manager                           ← M09 lab01~05
  탐지·감사 : CloudTrail · Config · GuardDuty                                ← M09 lab07~09
EOF

# ---- 단언
assert_eq "$refs" "1" "정책의 규칙 그룹 참조"
echo "LAB10 OK"
