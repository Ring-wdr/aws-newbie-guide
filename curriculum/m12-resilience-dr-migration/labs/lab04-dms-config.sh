#!/usr/bin/env bash
# M12 lab04 — DMS: 온프레미스 MySQL → Aurora MySQL 이전 작업 "구성" (🟡 데이터는 움직이지 않는다)
#
# 1) 복제 서브넷 그룹(2-AZ) → 복제 인스턴스(Multi-AZ) available 까지
# 2) 소스 엔드포인트(온프레미스 MySQL) · 타깃 엔드포인트(Aurora MySQL)
# 3) TestConnection → 501 (에뮬레이터 미구현. 실제 AWS에서는 이 단계가 필수)
# 4) 복제 작업: full-load-and-cdc, 테이블 매핑(선택·제외·스키마 이름 변경), 작업 설정 → ready
#    작업은 시작하지 않는다: 에뮬레이터는 시작하면 원본이 없는데도 running 이 되고,
#    StopReplicationTask·DeleteReplicationInstance 가 501 이라 되돌릴 수 없다.
#
# DeleteReplicationInstance·DeleteEndpoint 가 501 이므로 VPC·서브넷 그룹·복제 인스턴스·엔드포인트는 "있으면 재사용"한다(멱등).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

P="todayorder-m12-dms"
SUBNET_GROUP="todayorder-dms-subnets"
RI_ID="todayorder-dms"
SRC_ID="todayorder-onprem-mysql"
TGT_ID="todayorder-aurora-mysql"
TASK_ID="todayorder-orders-migration"

wait_until() { # wait_until <설명> <최대초> <명령...>
  local what="$1" max="$2" i; shift 2
  for i in $(seq "$max"); do "$@" && return 0; sleep 1; done
  echo "FAIL: ${max}초 안에 '$what' 이 되지 않음"; return 1
}
task_arn() { aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$TASK_ID" \
  --query 'ReplicationTasks[0].ReplicationTaskArn' --output text 2>/dev/null || true; }
endpoint_arn() { aws dms describe-endpoints --filters "Name=endpoint-id,Values=$1" \
  --query 'Endpoints[0].EndpointArn' --output text 2>/dev/null || true; }
task_gone() { local a; a="$(task_arn)"; [ -z "$a" ] || [ "$a" = "None" ]; }

# 이전 실행의 작업은 지우고 새로 만든다 (ready 상태의 작업은 삭제된다).
# 엔드포인트는 DeleteEndpoint 가 501 이라 지울 수 없으므로 아래에서 "있으면 재사용"한다.
t="$(task_arn)"
if [ -n "$t" ] && [ "$t" != "None" ]; then
  aws dms delete-replication-task --replication-task-arn "$t" >/dev/null
  wait_until "이전 작업 삭제" 60 task_gone
fi

echo "== 1. 네트워크와 복제 인스턴스 (있으면 재사용)"
VPC="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P" --query 'Vpcs[0].VpcId' --output text)"
if [ "$VPC" = "None" ]; then
  VPC="$(aws ec2 create-vpc --cidr-block 10.13.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$P}]" --query Vpc.VpcId --output text)"
  aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.13.1.0/24 --availability-zone us-east-1a >/dev/null
  aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.13.2.0/24 --availability-zone us-east-1b >/dev/null
fi
# DescribeReplicationSubnetGroups 가 501 이라 존재 여부를 조회할 수 없다 → 만들어 보고 "이미 있음"이면 재사용.
set +e
# shellcheck disable=SC2046
sg_out="$(aws dms create-replication-subnet-group --replication-subnet-group-identifier "$SUBNET_GROUP" \
  --replication-subnet-group-description "TodayOrder DMS (2 AZ)" \
  --subnet-ids $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text) 2>&1)"
sg_rc=$?
set -e
if [ "$sg_rc" -ne 0 ] && ! grep -q ResourceAlreadyExistsFault <<<"$sg_out"; then echo "$sg_out"; exit 1; fi
RI_ARN="$(aws dms describe-replication-instances --filters "Name=replication-instance-id,Values=$RI_ID" \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text 2>/dev/null || true)"
if [ -z "$RI_ARN" ] || [ "$RI_ARN" = "None" ]; then
  RI_ARN="$(aws dms create-replication-instance --replication-instance-identifier "$RI_ID" \
    --replication-instance-class dms.t3.medium --allocated-storage 50 --multi-az --no-publicly-accessible \
    --replication-subnet-group-identifier "$SUBNET_GROUP" \
    --query 'ReplicationInstance.ReplicationInstanceArn' --output text)"
fi
ri_available() { [ "$(aws dms describe-replication-instances --filters "Name=replication-instance-arn,Values=$RI_ARN" \
  --query 'ReplicationInstances[0].ReplicationInstanceStatus' --output text)" = "available" ]; }
wait_until "복제 인스턴스 available" 300 ri_available
aws dms describe-replication-instances --filters "Name=replication-instance-arn,Values=$RI_ARN" \
  --query 'ReplicationInstances[0].{Id:ReplicationInstanceIdentifier,Class:ReplicationInstanceClass,Status:ReplicationInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,StandbyAZ:SecondaryAvailabilityZone,Engine:EngineVersion}'

echo "== 2. 엔드포인트: 소스(온프레미스 MySQL) · 타깃(Aurora MySQL)"
ensure_endpoint() { # ensure_endpoint <id> <type> <engine> <server> <user>
  local arn
  arn="$(endpoint_arn "$1")"
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then
    arn="$(aws dms create-endpoint --endpoint-identifier "$1" --endpoint-type "$2" --engine-name "$3" \
      --server-name "$4" --port 3306 --username "$5" --password 'Example-Passw0rd' \
      --query Endpoint.EndpointArn --output text)"
  fi
  echo "$arn"
}
SRC_ARN="$(ensure_endpoint "$SRC_ID" source mysql db.onprem.todayorder.example dms_reader)"
TGT_ARN="$(ensure_endpoint "$TGT_ID" target aurora todayorder.cluster-example.us-east-1.rds.amazonaws.com dms_writer)"
aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$SRC_ARN,$TGT_ARN" \
  --query 'Endpoints[].{Id:EndpointIdentifier,Type:EndpointType,Engine:EngineDisplayName,Server:ServerName,Status:Status}'

echo "== 3. 연결 테스트 (실제 AWS에서는 작업을 만들기 전에 반드시 통과시켜야 한다)"
set +e
test_out="$(aws dms test-connection --replication-instance-arn "$RI_ARN" --endpoint-arn "$SRC_ARN" 2>&1)"
set -e
echo "$test_out"

echo "== 4. 복제 작업: 전체 로드 + CDC"
MAPPINGS="$(cat <<'EOF'
{"rules":[
 {"rule-type":"selection","rule-id":"1","rule-name":"include-orders","object-locator":{"schema-name":"shop","table-name":"order%"},"rule-action":"include"},
 {"rule-type":"selection","rule-id":"2","rule-name":"exclude-audit","object-locator":{"schema-name":"shop","table-name":"audit_log"},"rule-action":"exclude"},
 {"rule-type":"transformation","rule-id":"3","rule-name":"rename-schema","rule-target":"schema","object-locator":{"schema-name":"shop"},"rule-action":"rename","value":"todayorder"}
]}
EOF
)"
SETTINGS='{"TargetMetadata":{"SupportLobs":true,"LimitedSizeLobMode":true,"LobMaxSize":32},"FullLoadSettings":{"TargetTablePrepMode":"DROP_AND_CREATE"},"Logging":{"EnableLogging":true}}'
TASK_ARN="$(aws dms create-replication-task --replication-task-identifier "$TASK_ID" \
  --source-endpoint-arn "$SRC_ARN" --target-endpoint-arn "$TGT_ARN" --replication-instance-arn "$RI_ARN" \
  --migration-type full-load-and-cdc --table-mappings "$MAPPINGS" --replication-task-settings "$SETTINGS" \
  --query ReplicationTask.ReplicationTaskArn --output text)"
task_ready() { [ "$(aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$TASK_ARN" \
  --query 'ReplicationTasks[0].Status' --output text)" = "ready" ]; }
wait_until "작업 ready" 120 task_ready
aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$TASK_ARN" \
  --query 'ReplicationTasks[0].{Id:ReplicationTaskIdentifier,Type:MigrationType,Status:Status}'
echo "-- 저장된 테이블 매핑 규칙"
aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$TASK_ARN" \
  --query 'ReplicationTasks[0].TableMappings' --output text \
  | python3 -c 'import json,sys
for r in json.load(sys.stdin)["rules"]:
    print("  %s. %-14s %-8s %s" % (r["rule-id"], r["rule-type"], r["rule-action"], json.dumps(r["object-locator"])))'

# ---- 단언
[ "$(aws dms describe-replication-instances --filters "Name=replication-instance-arn,Values=$RI_ARN" --query 'ReplicationInstances[0].MultiAZ' --output text)" = "True" ] \
  || { echo "FAIL: 복제 인스턴스 Multi-AZ"; exit 1; }
[ "$(aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$SRC_ARN,$TGT_ARN" --query 'length(Endpoints[?Status==`active`])' --output text)" = "2" ] \
  || { echo "FAIL: 엔드포인트 2개 active"; exit 1; }
grep -q 'NotImplemented' <<<"$test_out" || { echo "FAIL: TestConnection 이 501 이 아님 → 구현되었을 수 있다(문서 갱신 필요)"; exit 1; }
task_ready || { echo "FAIL: 작업 ready 아님"; exit 1; }
echo "LAB04 OK"
