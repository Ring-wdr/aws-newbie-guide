#!/usr/bin/env bash
# M05 lab09 — 캐시 구성: ElastiCache Valkey(복제·Multi-AZ·장애 조치 테스트), Memcached, 서버리스, DAX (🟡)
# 캐시 서브넷 그룹 → Valkey 복제 그룹(기본 1 + 복제본 1, 자동 장애 조치, Multi-AZ, 암호화)
# → test-failover 로 기본 노드 역할 이동 → 잘못된 구성 2가지(복제본 없는 자동 장애 조치, Memcached 복제 그룹)
# → Memcached 2노드 클러스터 → Valkey 서버리스 캐시 → DynamoDB 전용 캐시 DAX 클러스터
# 에뮬레이터: 엔드포인트에 실제 캐시 서버가 없다(구성·상태만). DeleteReplicationGroup 이 501 이라
#   복제 그룹은 지울 수 없다 → 다시 실행하면 남아 있는 복제 그룹을 재사용한다(에뮬레이터를 재시작하면 사라진다).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

CSG=todayorder-m05-cache-subnets
RG=todayorder-m05-sessions
MC=todayorder-m05-mc
SL=todayorder-m05-serverless
DAX=todayorder-m05-dax
DAX_ROLE=todayorder-m05-dax-role

rg_exists() { aws elasticache describe-replication-groups --replication-group-id "$1" >/dev/null 2>&1; }
cleanup() {
  # 복제 그룹은 지우지 않는다: DeleteReplicationGroup 이 에뮬레이터에서 501 (README "에뮬레이터 제약")
  if aws elasticache describe-cache-clusters --cache-cluster-id "$MC" >/dev/null 2>&1; then
    aws elasticache delete-cache-cluster --cache-cluster-id "$MC" >/dev/null
    poll_until 300 "Memcached 삭제" bash -c "! aws elasticache describe-cache-clusters --cache-cluster-id $MC >/dev/null 2>&1"
  fi
  if aws elasticache describe-serverless-caches --serverless-cache-name "$SL" >/dev/null 2>&1; then
    aws elasticache delete-serverless-cache --serverless-cache-name "$SL" >/dev/null
    poll_until 300 "서버리스 캐시 삭제" bash -c "! aws elasticache describe-serverless-caches --serverless-cache-name $SL >/dev/null 2>&1"
  fi
  if aws dax describe-clusters --cluster-names "$DAX" >/dev/null 2>&1; then
    aws dax delete-cluster --cluster-name "$DAX" >/dev/null
    poll_until 300 "DAX 삭제" bash -c "! aws dax describe-clusters --cluster-names $DAX >/dev/null 2>&1"
  fi
  aws iam delete-role-policy --role-name "$DAX_ROLE" --policy-name ddb-access >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$DAX_ROLE" >/dev/null 2>&1 || true
}
cleanup

ensure_m05_vpc

echo "== 1. 캐시 서브넷 그룹 (DB 와 같은 프라이빗 서브넷 2개)"
if ! aws elasticache describe-cache-subnet-groups --cache-subnet-group-name "$CSG" >/dev/null 2>&1; then
  aws elasticache create-cache-subnet-group --cache-subnet-group-name "$CSG" \
    --cache-subnet-group-description "TodayOrder cache subnets" --subnet-ids "$SUBNET_A" "$SUBNET_B" \
    --query 'CacheSubnetGroup.{Name: CacheSubnetGroupName, AZs: Subnets[].SubnetAvailabilityZone.Name}'
else
  echo "(이전 실행이 만든 서브넷 그룹 재사용 — 지워지지 않는 복제 그룹이 쓰고 있다)"
fi

echo "== 2. Valkey 복제 그룹: 기본 1 + 복제본 1, 자동 장애 조치, Multi-AZ, 저장·전송 암호화"
if rg_exists "$RG"; then
  echo "(이전 실행이 만든 복제 그룹 재사용 — 에뮬레이터에서 DeleteReplicationGroup 은 501)"
  expect_error NotImplemented aws elasticache delete-replication-group --replication-group-id "$RG"
else
  aws elasticache create-replication-group --replication-group-id "$RG" \
    --replication-group-description "TodayOrder session and product cache" \
    --engine valkey --cache-node-type cache.t4g.micro \
    --num-node-groups 1 --replicas-per-node-group 1 \
    --automatic-failover-enabled --multi-az-enabled \
    --cache-subnet-group-name "$CSG" --at-rest-encryption-enabled --transit-encryption-enabled \
    --query 'ReplicationGroup.{Status: Status, Engine: Engine, AutomaticFailover: AutomaticFailover, MultiAZ: MultiAZ, Members: MemberClusters}'
fi
wait_status "복제 그룹 available" available \
  aws elasticache describe-replication-groups --replication-group-id "$RG" --query 'ReplicationGroups[0].Status' --output text
aws elasticache describe-replication-groups --replication-group-id "$RG" --query 'ReplicationGroups[0].{
  Status: Status, ClusterMode: ClusterMode,
  Primary: NodeGroups[0].PrimaryEndpoint, Reader: NodeGroups[0].ReaderEndpoint,
  Nodes: NodeGroups[0].NodeGroupMembers[].{Id: CacheClusterId, Role: CurrentRole, AZ: PreferredAvailabilityZone}}'
primary_before="$(aws elasticache describe-replication-groups --replication-group-id "$RG" \
  --query "ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[?CurrentRole=='primary'].CacheClusterId | [0]" --output text)"

FAILOVER_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # 이전 실행의 이벤트는 빼고 보기 위해
echo "== 3. 장애 조치 테스트 (test-failover): 기본 노드를 일부러 넘긴다"
aws elasticache test-failover --replication-group-id "$RG" --node-group-id 0001 --query 'ReplicationGroup.Status'
poll_until 300 "장애 조치 후 available + 기본 노드 변경" bash -c \
  "[ \"\$(aws elasticache describe-replication-groups --replication-group-id $RG --query \"ReplicationGroups[0].join(',', [Status, NodeGroups[0].NodeGroupMembers[?CurrentRole=='primary'].CacheClusterId | [0]])\" --output text)\" != 'available,$primary_before' ] && [ \"\$(aws elasticache describe-replication-groups --replication-group-id $RG --query 'ReplicationGroups[0].Status' --output text)\" = available ]"
aws elasticache describe-replication-groups --replication-group-id "$RG" \
  --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].{Id: CacheClusterId, Role: CurrentRole}'
primary_after="$(aws elasticache describe-replication-groups --replication-group-id "$RG" \
  --query "ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[?CurrentRole=='primary'].CacheClusterId | [0]" --output text)"
aws elasticache describe-events --source-type replication-group --source-identifier "$RG" --start-time "$FAILOVER_START" \
  --query 'Events[].Message'

echo "== 4. 잘못된 구성 ①: 복제본 0개로 자동 장애 조치?"
expect_error InvalidParameterCombination aws elasticache create-replication-group \
  --replication-group-id todayorder-m05-bad1 --replication-group-description bad \
  --engine valkey --cache-node-type cache.t4g.micro --replicas-per-node-group 0 --automatic-failover-enabled
echo "== 4. 잘못된 구성 ②: Memcached 로 복제 그룹?"
expect_error InvalidParameterValue aws elasticache create-replication-group \
  --replication-group-id todayorder-m05-bad2 --replication-group-description bad \
  --engine memcached --cache-node-type cache.t4g.micro --replicas-per-node-group 1

echo "== 5. Memcached 클러스터: 노드 2개를 두 AZ에 (복제 없음, 노드끼리 데이터를 나눠 가진다)"
aws elasticache create-cache-cluster --cache-cluster-id "$MC" --engine memcached \
  --cache-node-type cache.t4g.micro --num-cache-nodes 2 --az-mode cross-az \
  --preferred-availability-zones us-east-1a us-east-1b --cache-subnet-group-name "$CSG" \
  --query 'CacheCluster.{Status: CacheClusterStatus, Engine: Engine, Nodes: NumCacheNodes}'
wait_status "Memcached 클러스터 available" available \
  aws elasticache describe-cache-clusters --cache-cluster-id "$MC" --query 'CacheClusters[0].CacheClusterStatus' --output text
aws elasticache describe-cache-clusters --cache-cluster-id "$MC" --show-cache-node-info --query 'CacheClusters[0].{
  Status: CacheClusterStatus, ConfigEndpoint: ConfigurationEndpoint,
  Nodes: CacheNodes[].{Id: CacheNodeId, AZ: CustomerAvailabilityZone}}'
mc_nodes="$(aws elasticache describe-cache-clusters --cache-cluster-id "$MC" --query 'CacheClusters[0].NumCacheNodes' --output text)"

echo "== 6. 서버리스 캐시 (Valkey): 노드 유형 대신 사용량 상한만 정한다"
aws elasticache create-serverless-cache --serverless-cache-name "$SL" --engine valkey \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" \
  --cache-usage-limits 'DataStorage={Maximum=5,Unit=GB},ECPUPerSecond={Maximum=5000}' \
  --query 'ServerlessCache.{Status: Status, Engine: Engine}'
poll_until 300 "서버리스 캐시 available" bash -c \
  "[ \"\$(aws elasticache describe-serverless-caches --serverless-cache-name $SL --query 'ServerlessCaches[0].Status' --output text)\" = available ]"
aws elasticache describe-serverless-caches --serverless-cache-name "$SL" \
  --query 'ServerlessCaches[0].{Status: Status, Endpoint: Endpoint, Reader: ReaderEndpoint, Limits: CacheUsageLimits}'

echo "== 7. DAX: DynamoDB 앞에 두는 전용 캐시 (기본 1 + 읽기 복제본 2 = 노드 3개)"
aws iam create-role --role-name "$DAX_ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"dax.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "$DAX_ROLE" --policy-name ddb-access --policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:Query","dynamodb:Scan","dynamodb:BatchGetItem",
    "dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:BatchWriteItem","dynamodb:DescribeTable"],
    "Resource":"arn:aws:dynamodb:us-east-1:000000000000:table/todayorder-*"}]}'
echo "-- (에뮬레이터 제약) DAX 서브넷 그룹은 어떤 서브넷을 줘도 거부된다"
expect_error InvalidParameterValueException aws dax create-subnet-group --subnet-group-name todayorder-m05-dax-subnets \
  --subnet-ids "$SUBNET_A" "$SUBNET_B"
echo "-- 서브넷 그룹 없이(기본 VPC) 클러스터 생성"
aws dax create-cluster --cluster-name "$DAX" --node-type dax.t3.small --replication-factor 3 \
  --iam-role-arn "arn:aws:iam::000000000000:role/$DAX_ROLE" \
  --sse-specification Enabled=true --cluster-endpoint-encryption-type TLS \
  --query 'Cluster.{Status: Status, TotalNodes: TotalNodes, Endpoint: ClusterDiscoveryEndpoint.URL}'
poll_until 300 "DAX available" bash -c \
  "[ \"\$(aws dax describe-clusters --cluster-names $DAX --query 'Clusters[0].Status' --output text)\" = available ]"
aws dax describe-clusters --cluster-names "$DAX" --query 'Clusters[0].{
  Status: Status, ActiveNodes: ActiveNodes, Nodes: Nodes[].{Id: NodeId, AZ: AvailabilityZone, Status: NodeStatus}}'
dax_nodes="$(aws dax describe-clusters --cluster-names "$DAX" --query 'Clusters[0].ActiveNodes' --output text)"

echo "== 8. 정리 (복제 그룹 삭제는 에뮬레이터 미구현이라 남겨 둔다)"
expect_error NotImplemented aws elasticache delete-replication-group --replication-group-id "$RG"
cleanup

# ---- 단언
[ "$primary_before" != "$primary_after" ] || fail "test-failover 후 기본 노드가 그대로: $primary_after"
[ "$mc_nodes" = "2" ] || fail "Memcached 노드 수: $mc_nodes"
[ "$dax_nodes" = "3" ] || fail "DAX 활성 노드 수: $dax_nodes"
echo "LAB09 OK"
