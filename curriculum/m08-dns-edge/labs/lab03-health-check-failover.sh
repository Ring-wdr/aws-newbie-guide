#!/usr/bin/env bash
# M08 lab03 — 상태 확인과 장애 조치(failover) 레코드 (🔴 동작 / 구성은 가능)
# 에뮬레이터의 Route 53 상태 확인은 대상을 실제로 검사하지 않고 항상 Success 를 돌려준다.
# 그래서 "PRIMARY 가 죽으면 SECONDARY 가 대답한다"는 장애 조치 동작은 볼 수 없다.
# 이 lab 은 ① 구성을 실제처럼 만들고 ② 상태 확인이 가짜라는 증거를 관찰하고
# ③ PRIMARY 레코드를 직접 지워 "장애 조치 후 답"을 흉내 낸다. 판단 연습은 레슨 02 의 워크시트로.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ZONE="failover.todayorder.example"
WORK="$TMP_LIB"
delete_zones "$ZONE"
delete_health_checks "m08-lab03-"

ZID="$(aws route53 create-hosted-zone --name "$ZONE" --caller-reference "m08-lab03-$(date +%s)-$RANDOM" \
  --query HostedZone.Id --output text)"

echo "== 1. 상태 확인 만들기 — 존재할 수 없는 도메인(.invalid)을 검사하게 한다"
HC="$(aws route53 create-health-check --caller-reference "m08-lab03-primary-$(date +%s)-$RANDOM" \
  --health-check-config Type=HTTPS,FullyQualifiedDomainName=seoul-api.todayorder.invalid,Port=443,ResourcePath=/health,RequestInterval=30,FailureThreshold=3 \
  --query HealthCheck.Id --output text)"
aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$HC" --add-tags Key=Name,Value=todayorder-seoul-api
aws route53 get-health-check --health-check-id "$HC" \
  --query 'HealthCheck.HealthCheckConfig.{Type: Type, FQDN: FullyQualifiedDomainName, Path: ResourcePath, Interval: RequestInterval, Threshold: FailureThreshold}'

echo "== 2. 장애 조치 레코드: PRIMARY(서울, 상태 확인 연결) / SECONDARY(정적 점검 페이지)"
cat >"$WORK/failover.json" <<EOF
{"Changes": [
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "api.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "seoul-primary", "Failover": "PRIMARY", "HealthCheckId": "$HC",
   "ResourceRecords": [{"Value": "192.0.2.100"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "api.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "maintenance-secondary", "Failover": "SECONDARY",
   "ResourceRecords": [{"Value": "192.0.2.200"}]}}
]}
EOF
aws route53 wait resource-record-sets-changed --id "$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" \
  --change-batch "file://$WORK/failover.json" --query ChangeInfo.Id --output text)"
aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate \
  --query 'ResourceRecordSets[?Failover].[SetIdentifier, Failover, HealthCheckId || `-`, ResourceRecords[0].Value]' --output text

answer() { aws route53 test-dns-answer --hosted-zone-id "$ZID" --record-name "api.$ZONE" --record-type A --query 'join(`,`, RecordData)' --output text; }
hc_statuses() {
  aws route53 get-health-check-status --health-check-id "$HC" --output json | py '
obs = json.load(sys.stdin)["HealthCheckObservations"]
print(len(obs), sorted({o["StatusReport"]["Status"] for o in obs}))'
}

echo "== 3. 상태 확인 결과 — 대상 도메인은 존재하지 않는데?"
poll 60 "상태 확인 관찰값" sh -c "aws route53 get-health-check-status --health-check-id $HC --query 'length(HealthCheckObservations)' --output text | grep -qv '^0$'"
aws route53 get-health-check-status --health-check-id "$HC" --query 'HealthCheckObservations[:3].[Region, StatusReport.Status]' --output text
status_normal="$(hc_statuses)"
echo "관찰 지점 수와 상태 종류: $status_normal"
answer_normal="$(answer)"
echo "api.$ZONE → $answer_normal"

echo "== 4. Inverted(결과 뒤집기)를 켜도?"
aws route53 update-health-check --health-check-id "$HC" --inverted --query 'HealthCheck.HealthCheckConfig.Inverted' --output text
status_inverted="$(hc_statuses)"
answer_inverted="$(answer)"
echo "상태: $status_inverted / 응답: $answer_inverted"
aws route53 update-health-check --health-check-id "$HC" --no-inverted >/dev/null

echo "== 5. 다른 상태 확인을 묶는 계산된(CALCULATED) 상태 확인도 구성은 된다"
HC_CALC="$(aws route53 create-health-check --caller-reference "m08-lab03-calc-$(date +%s)-$RANDOM" \
  --health-check-config "{\"Type\": \"CALCULATED\", \"ChildHealthChecks\": [\"$HC\"], \"HealthThreshold\": 1}" \
  --query HealthCheck.Id --output text)"
aws route53 get-health-check --health-check-id "$HC_CALC" --query 'HealthCheck.HealthCheckConfig.{Type: Type, Children: ChildHealthChecks, Threshold: HealthThreshold}'

echo "== 6. 장애 조치를 '손으로' 흉내 내기: PRIMARY 레코드를 지운다"
cat >"$WORK/delete-primary.json" <<EOF
{"Changes": [
 {"Action": "DELETE", "ResourceRecordSet": {"Name": "api.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "seoul-primary", "Failover": "PRIMARY", "HealthCheckId": "$HC",
   "ResourceRecords": [{"Value": "192.0.2.100"}]}}
]}
EOF
aws route53 wait resource-record-sets-changed --id "$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" \
  --change-batch "file://$WORK/delete-primary.json" --query ChangeInfo.Id --output text)"
answer_failed_over="$(answer)"
echo "PRIMARY 가 없을 때 api.$ZONE → $answer_failed_over  (실제 AWS에서 상태 확인이 실패했을 때의 답과 같다)"

# ---- 단언 (에뮬레이터에서 관찰되는 동작 그대로)
case "$status_normal" in *"Success"*) ;; *) fail "상태 확인이 Success 가 아님: $status_normal (에뮬레이터가 실제 검사를 하게 됐다면 README 갱신)" ;; esac
grep -q Failure <<<"$status_normal" && fail "Failure 가 관찰됨 — 에뮬레이터 동작이 바뀌었다"
assert_eq "$answer_normal" "192.0.2.100" "정상 시 응답(PRIMARY)"
assert_eq "$answer_inverted" "192.0.2.100" "Inverted 후 응답(에뮬레이터는 여전히 PRIMARY)"
assert_eq "$answer_failed_over" "192.0.2.200" "PRIMARY 삭제 후 응답(SECONDARY)"
echo "LAB03 OK"
