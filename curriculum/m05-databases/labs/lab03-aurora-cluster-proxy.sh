#!/usr/bin/env bash
# M05 lab03 — Aurora 클러스터·엔드포인트·장애 조치·Global Database·RDS Proxy (🟡)
# Aurora PostgreSQL 클러스터(Serverless v2 용량 범위) → 쓰기 인스턴스(db.serverless) + 리더(db.r6g.large)
# → 클러스터(쓰기)·리더 엔드포인트 → failover-db-cluster 로 쓰기 역할 이동 → 사용자 지정 엔드포인트(501)
# → Global Database 로 승격 → RDS Proxy(Secrets Manager 비밀 + 역할) → 정리
# 에뮬레이터: 구성과 역할(IsClusterWriter) 전환은 보이지만 실제 연결·트래픽·복제 지연은 볼 수 없다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

CLUSTER=todayorder-m05-aurora
WRITER=todayorder-m05-aurora-1
READER=todayorder-m05-aurora-2
GLOBAL=todayorder-m05-global
PROXY=todayorder-m05-proxy
SECRET=todayorder-m05-aurora-secret
ROLE=todayorder-m05-proxy-role
SNG=todayorder-m05-aurora-subnets
CLUSTER_ARN="arn:aws:rds:us-east-1:000000000000:cluster:$CLUSTER"

cleanup() {
  aws rds delete-db-proxy --db-proxy-name "$PROXY" >/dev/null 2>&1 || true
  poll_until 120 "프록시 삭제" bash -c "! aws rds describe-db-proxies --db-proxy-name $PROXY >/dev/null 2>&1"
  if aws rds describe-global-clusters --global-cluster-identifier "$GLOBAL" >/dev/null 2>&1; then
    aws rds remove-from-global-cluster --global-cluster-identifier "$GLOBAL" \
      --db-cluster-identifier "$CLUSTER_ARN" >/dev/null 2>&1 || true
    aws rds delete-global-cluster --global-cluster-identifier "$GLOBAL" >/dev/null 2>&1 || true
    poll_until 120 "글로벌 클러스터 삭제" bash -c "! aws rds describe-global-clusters --global-cluster-identifier $GLOBAL >/dev/null 2>&1"
  fi
  rds_delete_instance "$READER"
  rds_delete_instance "$WRITER"
  if aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" >/dev/null 2>&1; then
    aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null
    aws rds wait db-cluster-deleted --db-cluster-identifier "$CLUSTER"
  fi
  aws rds delete-db-subnet-group --db-subnet-group-name "$SNG" >/dev/null 2>&1 || true
  aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name read-db-secret >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
}
cleanup

ensure_m05_vpc
ensure_db_sg
aws rds create-db-subnet-group --db-subnet-group-name "$SNG" \
  --db-subnet-group-description "TodayOrder Aurora lab" --subnet-ids "$SUBNET_A" "$SUBNET_B" >/dev/null

echo "== 1. Aurora PostgreSQL 클러스터 (스토리지는 클러스터 단위, Serverless v2 용량 0.5~4 ACU)"
aws rds create-db-cluster --db-cluster-identifier "$CLUSTER" --engine aurora-postgresql \
  --master-username todayorder --master-user-password 'Lab-only-Passw0rd' \
  --db-subnet-group-name "$SNG" --vpc-security-group-ids "$DB_SG" \
  --backup-retention-period 7 --storage-encrypted \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4 \
  --query 'DBCluster.{Status: Status, Engine: Engine, Version: EngineVersion, AZs: AvailabilityZones, ServerlessV2: ServerlessV2ScalingConfiguration}'
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER"

echo "== 2. 클러스터에 인스턴스 2대: 쓰기(db.serverless) + 리더(db.r6g.large, 다른 AZ)"
aws rds create-db-instance --db-instance-identifier "$WRITER" --db-cluster-identifier "$CLUSTER" \
  --engine aurora-postgresql --db-instance-class db.serverless --availability-zone us-east-1a \
  --query 'DBInstance.{Id: DBInstanceIdentifier, Class: DBInstanceClass, Status: DBInstanceStatus}'
aws rds wait db-instance-available --db-instance-identifier "$WRITER"
aws rds create-db-instance --db-instance-identifier "$READER" --db-cluster-identifier "$CLUSTER" \
  --engine aurora-postgresql --db-instance-class db.r6g.large --availability-zone us-east-1b \
  --promotion-tier 1 \
  --query 'DBInstance.{Id: DBInstanceIdentifier, Class: DBInstanceClass, Status: DBInstanceStatus}'
aws rds wait db-instance-available --db-instance-identifier "$READER"

echo "== 3. 엔드포인트: 앱은 인스턴스가 아니라 '클러스터 엔드포인트(쓰기)'와 '리더 엔드포인트(읽기)'에 붙는다"
aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].{
  Status: Status, WriterEndpoint: Endpoint, ReaderEndpoint: ReaderEndpoint, Port: Port,
  Members: DBClusterMembers[].{Id: DBInstanceIdentifier, Writer: IsClusterWriter}}'
writer_before="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier | [0]' --output text)"
reader_ep="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].ReaderEndpoint' --output text)"

echo "== 4. 장애 조치: 리더를 새 쓰기 인스턴스로 (failover-db-cluster)"
aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER" --target-db-instance-identifier "$READER" \
  --query 'DBCluster.Status'
poll_until 120 "장애 조치 완료(쓰기 역할이 $READER 로)" bash -c \
  "[ \"\$(aws rds describe-db-clusters --db-cluster-identifier $CLUSTER --query 'DBClusters[0].join(\`,\`, [Status, DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier | [0]])' --output text)\" = 'available,$READER' ]"
aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].{
  Status: Status, Members: DBClusterMembers[].{Id: DBInstanceIdentifier, Writer: IsClusterWriter}}'
writer_after="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier | [0]' --output text)"

echo "== 5. 사용자 지정 엔드포인트(분석용 리더 묶음) — 에뮬레이터 미구현"
expect_error NotImplemented aws rds create-db-cluster-endpoint --db-cluster-identifier "$CLUSTER" \
  --db-cluster-endpoint-identifier todayorder-m05-analytics --endpoint-type READER \
  --static-members "$WRITER"

echo "== 6. Global Database: 이 클러스터를 '주(primary) 리전' 클러스터로 하는 글로벌 클러스터"
aws rds create-global-cluster --global-cluster-identifier "$GLOBAL" --source-db-cluster-identifier "$CLUSTER_ARN" \
  --query 'GlobalCluster.{Id: GlobalClusterIdentifier, Status: Status, Engine: Engine, Members: GlobalClusterMembers[].{Cluster: DBClusterArn, IsWriter: IsWriter}, Endpoint: Endpoint}'
global_writer="$(aws rds describe-global-clusters --global-cluster-identifier "$GLOBAL" --query 'GlobalClusters[0].GlobalClusterMembers[0].IsWriter' --output text)"

echo "== 7. RDS Proxy: 비밀(Secrets Manager) + 그 비밀을 읽을 역할 + 대상 클러스터"
secret_arn="$(aws secretsmanager create-secret --name "$SECRET" \
  --secret-string '{"username":"todayorder","password":"Lab-only-Passw0rd"}' --query ARN --output text)"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name read-db-secret --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"$secret_arn\"}]}"
aws rds create-db-proxy --db-proxy-name "$PROXY" --engine-family POSTGRESQL \
  --auth "AuthScheme=SECRETS,SecretArn=$secret_arn,IAMAuth=DISABLED" \
  --role-arn "arn:aws:iam::000000000000:role/$ROLE" \
  --vpc-subnet-ids "$SUBNET_A" "$SUBNET_B" --vpc-security-group-ids "$DB_SG" --require-tls \
  --query 'DBProxy.{Name: DBProxyName, Status: Status, EngineFamily: EngineFamily, Endpoint: Endpoint, RequireTLS: RequireTLS}'
poll_until 120 "프록시 available" bash -c \
  "[ \"\$(aws rds describe-db-proxies --db-proxy-name $PROXY --query 'DBProxies[0].Status' --output text)\" = available ]"
aws rds register-db-proxy-targets --db-proxy-name "$PROXY" --db-cluster-identifiers "$CLUSTER" \
  --query 'DBProxyTargets[].{Type: Type, Cluster: TrackedClusterId, Role: Role, Health: TargetHealth.State}'
proxy_target="$(aws rds describe-db-proxy-targets --db-proxy-name "$PROXY" --query 'Targets[0].TrackedClusterId' --output text)"

echo "== 8. 정리 (순서: 프록시 → 글로벌 클러스터에서 분리 → 인스턴스 → 클러스터)"
echo "-- 인스턴스가 남아 있는 클러스터는 지울 수 없다"
expect_error InvalidDBClusterStateFault aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot
cleanup

# ---- 단언
[ "$writer_before" = "$WRITER" ] || fail "처음 쓰기 인스턴스가 $WRITER 가 아님: $writer_before"
[ "$writer_after" = "$READER" ] || fail "장애 조치 후 쓰기 인스턴스가 $READER 가 아님: $writer_after"
case "$reader_ep" in *cluster-ro-*) ;; *) fail "리더 엔드포인트 형식이 다름: $reader_ep" ;; esac
[ "$global_writer" = "True" ] || fail "글로벌 클러스터의 쓰기 멤버가 아님"
[ "$proxy_target" = "$CLUSTER" ] || fail "프록시 대상이 다름: $proxy_target"
echo "LAB03 OK"
