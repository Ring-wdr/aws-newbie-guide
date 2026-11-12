#!/usr/bin/env bash
# M02 lab09 — 관측과 방어: VPC Flow Logs(→ CloudWatch Logs) + AWS Network Firewall (🟡)
# 구성은 실제처럼 만들어지고 상태도 ACTIVE/READY 가 되지만, 에뮬레이터에는 트래픽이 없으므로
# 흐름 로그 레코드가 쌓이지 않고 방화벽이 무언가를 차단하는 것도 볼 수 없다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"
LOG_GROUP="/todayorder/vpc-flow-logs"
ROLE="todayorder-vpc-flow-logs-role"
FW_SUBNET_NAME="todayorder-firewall-a"

cleanup() {
  local ids
  ids="$(aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$VPC" --query 'FlowLogs[].FlowLogId' --output text)"
  [ -n "$ids" ] && aws ec2 delete-flow-logs --flow-log-ids $ids >/dev/null
  aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name deliver-to-cwl 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  if aws network-firewall describe-firewall --firewall-name todayorder-fw >/dev/null 2>&1; then
    aws network-firewall delete-firewall --firewall-name todayorder-fw >/dev/null
    poll_until gone 300 bash -c "aws network-firewall describe-firewall --firewall-name todayorder-fw >/dev/null 2>&1 && echo exists || echo gone"
  fi
  aws network-firewall delete-firewall-policy --firewall-policy-name todayorder-fw-policy >/dev/null 2>&1 || true
  aws network-firewall delete-rule-group --rule-group-name todayorder-deny-domains --type STATEFUL >/dev/null 2>&1 || true
  local sn
  sn="$(subnet_id "$FW_SUBNET_NAME")"
  [ -n "$sn" ] && aws ec2 delete-subnet --subnet-id "$sn"
  return 0
}
cleanup

echo "== 1. Flow Logs가 CloudWatch Logs에 쓸 수 있게: 로그 그룹 + 서비스 역할(신뢰 정책 + 권한)"
aws logs create-log-group --log-group-name "$LOG_GROUP"
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 30
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "vpc-flow-logs.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}' --query Role.Arn --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name deliver-to-cwl --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"],
    "Resource": "*"}]
}'
echo "   $ROLE_ARN"

echo "== 2. VPC 전체의 흐름 로그 (ACCEPT·REJECT 모두)"
FL="$(aws ec2 create-flow-logs --resource-type VPC --resource-ids "$VPC" --traffic-type ALL \
  --log-destination-type cloud-watch-logs --log-group-name "$LOG_GROUP" --deliver-logs-permission-arn "$ROLE_ARN" \
  --tag-specifications "$(tags vpc-flow-log todayorder-vpc-flow)" --query 'FlowLogIds[0]' --output text)"
aws ec2 describe-flow-logs --flow-log-ids "$FL" \
  --query 'FlowLogs[0].{Id: FlowLogId, Status: FlowLogStatus, Deliver: DeliverLogsStatus, Traffic: TrafficType, Dest: LogDestinationType, Format: LogFormat}' \
  --output json

echo "== 3. 로그 스트림이 생겼나? (에뮬레이터에는 트래픽이 없다)"
streams="$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --query 'length(logStreams)' --output text)"
echo "   로그 스트림 수: $streams"

echo "== 4. Network Firewall: 전용 서브넷(/28) + 상태 저장 규칙 그룹(도메인 차단 목록) + 정책 + 방화벽"
FW_SN="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.30.0/28 --availability-zone us-east-1a \
  --tag-specifications "$(tags subnet "$FW_SUBNET_NAME")" --query Subnet.SubnetId --output text)"
RG_ARN="$(aws network-firewall create-rule-group --rule-group-name todayorder-deny-domains --type STATEFUL --capacity 10 \
  --rule-group '{"RulesSource":{"RulesSourceList":{"Targets":[".malware.example"],"TargetTypes":["HTTP_HOST","TLS_SNI"],"GeneratedRulesType":"DENYLIST"}}}' \
  --query RuleGroupResponse.RuleGroupArn --output text)"
POL_ARN="$(aws network-firewall create-firewall-policy --firewall-policy-name todayorder-fw-policy \
  --firewall-policy "{\"StatelessDefaultActions\":[\"aws:forward_to_sfe\"],\"StatelessFragmentDefaultActions\":[\"aws:forward_to_sfe\"],\"StatefulRuleGroupReferences\":[{\"ResourceArn\":\"$RG_ARN\"}]}" \
  --query FirewallPolicyResponse.FirewallPolicyArn --output text)"
aws network-firewall create-firewall --firewall-name todayorder-fw --firewall-policy-arn "$POL_ARN" \
  --vpc-id "$VPC" --subnet-mappings "SubnetId=$FW_SN" --query 'FirewallStatus.Status' --output text
poll_until READY 300 aws network-firewall describe-firewall --firewall-name todayorder-fw --query 'FirewallStatus.Status' --output text
aws network-firewall describe-firewall --firewall-name todayorder-fw \
  --query 'FirewallStatus.{Status: Status, Sync: ConfigurationSyncStateSummary, Endpoint: SyncStates."us-east-1a".Attachment.EndpointId, Subnet: SyncStates."us-east-1a".Attachment.SubnetId}' \
  --output json
EP="$(aws network-firewall describe-firewall --firewall-name todayorder-fw --query 'FirewallStatus.SyncStates."us-east-1a".Attachment.EndpointId' --output text)"
echo "   실제 AWS라면 이제 퍼블릭/앱 라우팅 테이블의 0.0.0.0/0 다음 홉을 이 방화벽 엔드포인트($EP)로 바꿔 트래픽을 통과시킨다."

# ---- 단언 (정리 전에 상태를 확인)
assert_eq "흐름 로그 상태" ACTIVE "$(aws ec2 describe-flow-logs --flow-log-ids "$FL" --query 'FlowLogs[0].FlowLogStatus' --output text)"
assert_eq "방화벽 상태" READY "$(aws network-firewall describe-firewall --firewall-name todayorder-fw --query 'FirewallStatus.Status' --output text)"
case "$EP" in vpce-*) echo "  ✔ 방화벽 엔드포인트: $EP" ;; *) die "방화벽 엔드포인트 없음: $EP" ;; esac

echo "== 5. 정리 (Network Firewall 엔드포인트는 실제 AWS에서 시간당 요금이 붙는다 — 실습 후 바로 지운다)"
cleanup
[ -z "$(subnet_id "$FW_SUBNET_NAME")" ] || die "방화벽 서브넷이 남아 있음"
echo "LAB09 OK"
