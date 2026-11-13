#!/usr/bin/env bash
# M05 lab01 — RDS 기본: 서브넷 그룹·파라미터 그룹·인스턴스·백업·스냅샷 (🟡)
# 프라이빗 서브넷 2개 → DB 서브넷 그룹 → 파라미터 그룹 → PostgreSQL 인스턴스(암호화·자동 백업 7일·삭제 방지)
# → 수동 스냅샷 → 스냅샷에서 "새" 인스턴스로 복원 → 시점 복원(PITR) 시도 → 삭제 방지·최종 스냅샷 → 정리
# 에뮬레이터: 구성은 모두 저장되지만 엔드포인트는 컨테이너 안에만 있어 SQL 접속은 하지 않는다. PITR 은 501.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

DB=todayorder-m05-db
RESTORED=todayorder-m05-db-restored
SNAP=todayorder-m05-db-snap-manual
FINAL=todayorder-m05-db-final
SNG=todayorder-m05-db-subnets
PG=todayorder-m05-pg16

cleanup() {
  rds_delete_instance "$RESTORED"
  rds_delete_instance "$DB"
  rds_delete_snapshot "$SNAP"
  rds_delete_snapshot "$FINAL"
  aws rds delete-db-parameter-group --db-parameter-group-name "$PG" >/dev/null 2>&1 || true
  aws rds delete-db-subnet-group --db-subnet-group-name "$SNG" >/dev/null 2>&1 || true
}
cleanup   # 이전 실행이 남긴 것이 있으면 지우고 시작한다 (멱등)

echo "== 1. 네트워크: 프라이빗 서브넷 2개(서로 다른 AZ)와 DB 보안 그룹"
ensure_m05_vpc
ensure_db_sg
echo "VPC=$VPC_ID  subnet-a=$SUBNET_A(us-east-1a)  subnet-b=$SUBNET_B(us-east-1b)  sg=$DB_SG"

echo "== 2. DB 서브넷 그룹: RDS 에게 '이 서브넷들 중에 DB를 놓아라'"
aws rds create-db-subnet-group --db-subnet-group-name "$SNG" \
  --db-subnet-group-description "TodayOrder private DB subnets" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" \
  --query 'DBSubnetGroup.{Name: DBSubnetGroupName, Status: SubnetGroupStatus, AZs: Subnets[].SubnetAvailabilityZone.Name}'

echo "== 3. 파라미터 그룹: postgresql.conf 를 대신하는 설정 묶음"
aws rds create-db-parameter-group --db-parameter-group-name "$PG" \
  --db-parameter-group-family postgres16 --description "TodayOrder PostgreSQL 16" \
  --query 'DBParameterGroup.{Name: DBParameterGroupName, Family: DBParameterGroupFamily}'
aws rds modify-db-parameter-group --db-parameter-group-name "$PG" \
  --parameters "ParameterName=log_min_duration_statement,ParameterValue=500,ApplyMethod=immediate" >/dev/null
aws rds describe-db-parameters --db-parameter-group-name "$PG" --source user \
  --query 'Parameters[].{Name: ParameterName, Value: ParameterValue, ApplyType: ApplyType}'

echo "== 4. DB 인스턴스 생성 (PostgreSQL 16, 암호화, 자동 백업 7일, 퍼블릭 접근 없음, 삭제 방지)"
aws rds create-db-instance --db-instance-identifier "$DB" \
  --engine postgres --engine-version 16.3 --db-instance-class db.t3.micro \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --master-username todayorder --master-user-password 'Lab-only-Passw0rd' \
  --db-subnet-group-name "$SNG" --vpc-security-group-ids "$DB_SG" \
  --db-parameter-group-name "$PG" --backup-retention-period 7 \
  --no-publicly-accessible --deletion-protection \
  --query 'DBInstance.{Status: DBInstanceStatus, Engine: Engine, Version: EngineVersion, Class: DBInstanceClass}'
wait_rds_instance_available "$DB"
aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].{
  Status: DBInstanceStatus, AZ: AvailabilityZone, Endpoint: Endpoint.Address, Port: Endpoint.Port,
  Encrypted: StorageEncrypted, Public: PubliclyAccessible, BackupRetention: BackupRetentionPeriod,
  BackupWindow: PreferredBackupWindow, DeletionProtection: DeletionProtection,
  ParamGroup: DBParameterGroups[0].DBParameterGroupName, SG: VpcSecurityGroups[0].VpcSecurityGroupId}'
retention="$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].BackupRetentionPeriod' --output text)"
restorable="$(aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].LatestRestorableTime' --output text)"
echo "LatestRestorableTime=$restorable  (자동 백업이 켜져 있으면 '여기까지는 되돌릴 수 있다'는 시각이 생긴다)"

echo "== 5. 수동 스냅샷 (자동 백업과 달리 직접 지울 때까지 남는다)"
aws rds create-db-snapshot --db-instance-identifier "$DB" --db-snapshot-identifier "$SNAP" \
  --query 'DBSnapshot.{Id: DBSnapshotIdentifier, Type: SnapshotType, Status: Status}'
wait_rds_snapshot_available "$SNAP"
aws rds describe-db-snapshots --db-snapshot-identifier "$SNAP" \
  --query 'DBSnapshots[0].{Id: DBSnapshotIdentifier, Type: SnapshotType, Status: Status, Encrypted: Encrypted, Engine: EngineVersion}'

echo "== 6. 스냅샷에서 복원 = 새 인스턴스가 생긴다 (원본을 덮어쓰지 않는다)"
aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "$RESTORED" \
  --db-snapshot-identifier "$SNAP" --db-subnet-group-name "$SNG" --vpc-security-group-ids "$DB_SG" \
  --db-parameter-group-name "$PG" \
  --query 'DBInstance.{Id: DBInstanceIdentifier, Status: DBInstanceStatus, Version: EngineVersion}'
wait_rds_instance_available "$RESTORED"
aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, 'todayorder-m05-db')].[DBInstanceIdentifier, DBInstanceStatus, Endpoint.Port]" --output table

echo "== 7. 시점 복원(PITR) 시도 — 에뮬레이터 미구현"
expect_error NotImplemented aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$DB" --target-db-instance-identifier todayorder-m05-db-pitr \
  --use-latest-restorable-time --db-subnet-group-name "$SNG"

echo "== 8. 삭제 방지가 켜진 DB는 지울 수 없다"
expect_error InvalidParameterCombination aws rds delete-db-instance --db-instance-identifier "$DB" \
  --final-db-snapshot-identifier "$FINAL"
echo "-- 삭제 방지를 끄고, 최종 스냅샷을 남기며 삭제"
aws rds modify-db-instance --db-instance-identifier "$DB" --no-deletion-protection --apply-immediately \
  --query 'DBInstance.DeletionProtection'
wait_rds_instance_available "$DB"
echo "-- 최종 스냅샷 이름도, --skip-final-snapshot 도 주지 않으면?"
expect_error InvalidParameterCombination aws rds delete-db-instance --db-instance-identifier "$DB"
aws rds delete-db-instance --db-instance-identifier "$DB" --final-db-snapshot-identifier "$FINAL" \
  --query 'DBInstance.DBInstanceStatus'
wait_rds_instance_deleted "$DB"
aws rds describe-db-snapshots --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, 'todayorder-m05-db')].[DBSnapshotIdentifier, SnapshotType, Status, DBInstanceIdentifier]" --output table
final_status="$(aws rds describe-db-snapshots --db-snapshot-identifier "$FINAL" --query 'DBSnapshots[0].Status' --output text)"

echo "== 9. 정리"
cleanup

# ---- 단언
[ "$retention" = "7" ] || fail "백업 보존 기간이 7이 아님: $retention"
[ -n "$restorable" ] && [ "$restorable" != "None" ] || fail "LatestRestorableTime 이 없음"
[ "$final_status" = "available" ] || fail "최종 스냅샷 상태: $final_status"
rds_instance_exists "$DB" && fail "인스턴스가 남아 있음"
echo "LAB01 OK"
