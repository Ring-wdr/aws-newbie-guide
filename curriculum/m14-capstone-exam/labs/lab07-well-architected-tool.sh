#!/usr/bin/env bash
# M14 lab07 — Well-Architected Tool: TodayOrder 를 워크로드로 등록하고, 기둥마다 질문 하나씩
# "모듈 시절(M01~M13)"과 "캡스톤" 두 번 답해 마일스톤으로 남긴 뒤 위험 수를 비교한다.
# 리소스를 만들지 않는 리뷰 도구라 다른 lab 과 독립이다.
# 등급: 🟢 워크로드·답변·마일스톤 / 🟡 위험(HIGH·MEDIUM) 판정 규칙은 실제 AWS 와 대조하지 않음
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
NAME="$P-workload"

echo "== 0. 이전 실행의 워크로드 삭제"
for w in $(aws wellarchitected list-workloads --workload-name-prefix "$NAME" --query 'WorkloadSummaries[].WorkloadId' --output text); do
  aws wellarchitected delete-workload --workload-id "$w" --client-request-token "del-$w-$(date +%s)"
done

echo "== 1. 워크로드 등록 (렌즈: AWS Well-Architected Framework)"
W="$(aws wellarchitected create-workload --workload-name "$NAME" --description "TodayOrder capstone (M14)" \
  --environment PREPRODUCTION --aws-regions "$REGION" --review-owner ops@todayorder.example.com \
  --lenses wellarchitected --client-request-token "create-$(date +%s)" --query WorkloadId --output text)"
echo "워크로드 ID: $W"
for p in operationalExcellence security reliability performance costOptimization sustainability; do
  printf '%-22s 질문 %s개\n' "$p" "$(aws wellarchitected list-answers --workload-id "$W" --lens-alias wellarchitected --pillar-id "$p" \
    --query 'length(AnswerSummaries)' --output text)"
done

# answer <질문 ID> <선택지...> — 질문에 답하고 Tool 이 계산한 위험을 출력
answer() {
  local q="$1"
  shift
  aws wellarchitected update-answer --workload-id "$W" --lens-alias wellarchitected --question-id "$q" \
    --selected-choices "$@" --query 'Answer.[PillarId, QuestionId, Risk]' --output text
}
risk_total() {  # <마일스톤 번호> → HIGH+MEDIUM
  aws wellarchitected get-lens-review --workload-id "$W" --lens-alias wellarchitected --milestone-number "$1" --output json | py '
r = json.load(sys.stdin)["LensReview"]["RiskCounts"]
print(r.get("HIGH", 0) + r.get("MEDIUM", 0))'
}

echo "== 2. 모듈 시절(M01~M13)의 TodayOrder 로 답한다 — 레슨 01 리뷰 표 기준"
answer identities sec_identities_groups_attributes                                          # S1: IAM 사용자·장기 키
answer protect-data-at-rest sec_protect_data_rest_encrypt                                   # S4: 기본 암호화뿐
answer withstand-component-failures rel_withstand_component_failures_monitor_health         # R2·R3: 단일 AZ DB, 조정 정책 없음
answer workload-observability ops_workload_observability_analyze_workload_metrics ops_workload_observability_analyze_workload_logs   # O2: 업무 실패 알림 없음
answer data-management perf_data_purpose_built                                              # P1: Scan
answer data-transfer cost_data_transfer_modeling                                            # C1: NAT 경유
answer hardware-patterns sus_hardware_managed_services                                      # C5: x86
aws wellarchitected create-milestone --workload-id "$W" --milestone-name "v1-modules-m01-m13" \
  --client-request-token "m1-$(date +%s)" --query MilestoneNumber --output text >/dev/null

echo "== 3. 캡스톤으로 다시 답한다 — 레슨 02 결정 기록 기준"
answer identities sec_identities_unique sec_identities_secrets sec_identities_identity_provider sec_identities_groups_attributes
answer protect-data-at-rest sec_protect_data_rest_key_mgmt sec_protect_data_rest_encrypt sec_protect_data_rest_automate_protection \
  sec_protect_data_rest_access_control sec_protect_data_rest_people_away
answer withstand-component-failures rel_withstand_component_failures_monitor_health rel_withstand_component_failures_failover2good \
  rel_withstand_component_failures_auto_healing rel_withstand_component_failures_static_stability \
  rel_withstand_component_failures_notify_on_events rel_withstand_component_failures_avail_target_slas
answer workload-observability ops_workload_observability_analyze_workload_metrics ops_workload_observability_analyze_workload_logs \
  ops_workload_observability_create_actionable_alerts
answer data-management perf_data_purpose_built perf_data_config_options perf_data_query_performance
answer data-transfer cost_data_transfer_modeling cost_data_transfer_select_components cost_data_transfer_implement_services
answer hardware-patterns sus_hardware_minimum_amount sus_hardware_instance_types sus_hardware_managed_services
aws wellarchitected create-milestone --workload-id "$W" --milestone-name "v2-capstone" \
  --client-request-token "m2-$(date +%s)" --query MilestoneNumber --output text >/dev/null

echo "== 4. 마일스톤 비교 (답한 질문 7개의 위험 합계, 나머지 50개는 UNANSWERED)"
aws wellarchitected list-milestones --workload-id "$W" --query 'MilestoneSummaries[].[MilestoneNumber, MilestoneName]' --output text | sort
v1="$(risk_total 1)"
v2="$(risk_total 2)"
for m in 1 2; do
  aws wellarchitected get-lens-review --workload-id "$W" --lens-alias wellarchitected --milestone-number "$m" --output json | py '
r = json.load(sys.stdin)["LensReview"]["RiskCounts"]
print("마일스톤", sys.argv[1], " HIGH", r.get("HIGH", 0), " MEDIUM", r.get("MEDIUM", 0), " NONE", r.get("NONE", 0), " UNANSWERED", r.get("UNANSWERED", 0))' "$m"
done

# ---- 단언
[ "$v2" -lt "$v1" ] || fail "캡스톤의 위험(HIGH+MEDIUM=$v2)이 모듈 시절($v1)보다 줄지 않음"
assert_eq "$(aws wellarchitected list-milestones --workload-id "$W" --query 'length(MilestoneSummaries)' --output text)" 2 "마일스톤 수"
echo "LAB07 OK"
