#!/usr/bin/env bash
# M05 lab10 — 목적별 DB 구성 맛보기: DocumentDB · Keyspaces · Neptune (🟡)
# "JSON 문서 그대로" → DocumentDB 클러스터 + 인스턴스 (MongoDB 호환, 포트 27017)
# "Cassandra 코드를 그대로, 서버리스로" → Keyspaces 키스페이스 + 테이블 (CQL 스키마, 온디맨드)
# "관계 자체가 데이터" → Neptune 클러스터 (그래프, 포트 8182)
# 에뮬레이터: 리소스 구성·상태만 확인한다. 데이터를 넣고 질의하는 것은 하지 않는다(엔드포인트 접속 불가).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

DOCDB=todayorder-m05-reviews
DOCDB_I=todayorder-m05-reviews-1
NEPTUNE=todayorder-m05-recommend
KS=todayorder_m05

cleanup() {
  if aws docdb describe-db-instances --db-instance-identifier "$DOCDB_I" >/dev/null 2>&1; then
    aws docdb delete-db-instance --db-instance-identifier "$DOCDB_I" >/dev/null
    aws docdb wait db-instance-deleted --db-instance-identifier "$DOCDB_I"
  fi
  if aws docdb describe-db-clusters --db-cluster-identifier "$DOCDB" >/dev/null 2>&1; then
    aws docdb delete-db-cluster --db-cluster-identifier "$DOCDB" --skip-final-snapshot >/dev/null
    poll_until 120 "DocumentDB 클러스터 삭제" bash -c "! aws docdb describe-db-clusters --db-cluster-identifier $DOCDB >/dev/null 2>&1"
  fi
  if aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE" >/dev/null 2>&1; then
    aws neptune delete-db-cluster --db-cluster-identifier "$NEPTUNE" --skip-final-snapshot >/dev/null
    poll_until 120 "Neptune 클러스터 삭제" bash -c "! aws neptune describe-db-clusters --db-cluster-identifier $NEPTUNE >/dev/null 2>&1"
  fi
  if aws keyspaces get-keyspace --keyspace-name "$KS" >/dev/null 2>&1; then
    aws keyspaces delete-keyspace --keyspace-name "$KS"
    poll_until 120 "키스페이스 삭제" bash -c "! aws keyspaces get-keyspace --keyspace-name $KS >/dev/null 2>&1"
  fi
}
cleanup

echo "== 1. DocumentDB: 상품 리뷰(모양이 제각각인 JSON 문서) 저장소"
aws docdb create-db-cluster --db-cluster-identifier "$DOCDB" --engine docdb \
  --master-username todayorder --master-user-password 'Lab-only-Passw0rd' --storage-encrypted \
  --query 'DBCluster.{Status: Status, Engine: Engine, Port: Port}'
aws docdb create-db-instance --db-instance-identifier "$DOCDB_I" --db-cluster-identifier "$DOCDB" \
  --engine docdb --db-instance-class db.t3.medium --query 'DBInstance.DBInstanceStatus'
aws docdb wait db-instance-available --db-instance-identifier "$DOCDB_I"
aws docdb describe-db-clusters --db-cluster-identifier "$DOCDB" --query 'DBClusters[0].{
  Status: Status, Version: EngineVersion, Endpoint: Endpoint, ReaderEndpoint: ReaderEndpoint, Port: Port,
  Members: DBClusterMembers[].{Id: DBInstanceIdentifier, Writer: IsClusterWriter}}'
docdb_port="$(aws docdb describe-db-clusters --db-cluster-identifier "$DOCDB" --query 'DBClusters[0].Port' --output text)"

echo "== 2. Keyspaces: 주문 이벤트 이력 (Cassandra 호환, 서버리스)"
aws keyspaces create-keyspace --keyspace-name "$KS"
aws keyspaces create-table --keyspace-name "$KS" --table-name order_events \
  --schema-definition 'allColumns=[{name=order_id,type=text},{name=event_time,type=timestamp},{name=status,type=text}],partitionKeys=[{name=order_id}],clusteringKeys=[{name=event_time,orderBy=DESC}]'
poll_until 120 "Keyspaces 테이블 ACTIVE" bash -c \
  "[ \"\$(aws keyspaces get-table --keyspace-name $KS --table-name order_events --query status --output text)\" = ACTIVE ]"
aws keyspaces get-table --keyspace-name "$KS" --table-name order_events --query '{
  Status: status, Capacity: capacitySpecification.throughputMode,
  PartitionKey: schemaDefinition.partitionKeys[].name, ClusteringKey: schemaDefinition.clusteringKeys}'
ks_status="$(aws keyspaces get-table --keyspace-name "$KS" --table-name order_events --query status --output text)"

echo "== 3. Neptune: '이 상품을 산 사람이 함께 산 상품' 추천용 그래프"
aws neptune create-db-cluster --db-cluster-identifier "$NEPTUNE" --engine neptune --storage-encrypted \
  --query 'DBCluster.{Status: Status, Engine: Engine, Port: Port}'
poll_until 120 "Neptune 클러스터 available" bash -c \
  "[ \"\$(aws neptune describe-db-clusters --db-cluster-identifier $NEPTUNE --query 'DBClusters[0].Status' --output text)\" = available ]"
aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE" \
  --query 'DBClusters[0].{Status: Status, Version: EngineVersion, Endpoint: Endpoint, Port: Port}'
neptune_port="$(aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE" --query 'DBClusters[0].Port' --output text)"

echo "== 4. 정리"
cleanup

# ---- 단언
[ "$docdb_port" = "27017" ] || fail "DocumentDB 포트: $docdb_port"
[ "$ks_status" = "ACTIVE" ] || fail "Keyspaces 테이블 상태: $ks_status"
[ "$neptune_port" = "8182" ] || fail "Neptune 포트: $neptune_port"
echo "LAB10 OK"
