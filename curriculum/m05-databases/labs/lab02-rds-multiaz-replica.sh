#!/usr/bin/env bash
# M05 lab02 — Multi-AZ vs 읽기 전용 복제본 (🟡)
# Multi-AZ 인스턴스 → 강제 장애 조치(reboot --force-failover) → 읽기 복제본(다른 AZ) → 수직 확장(클래스 변경)
# → 백업이 꺼진 원본에서는 복제본을 못 만든다 → 복제본 승격(501) → 원본을 지우면 복제본은 독립 인스턴스가 된다
# 에뮬레이터: Multi-AZ 의 대기(standby) 인스턴스와 실제 장애 조치(AZ 이동)는 재현되지 않는다 → 다이어그램으로 보충.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

PRIMARY=todayorder-m05-maz
REPLICA=todayorder-m05-maz-rr
NOBACKUP=todayorder-m05-nobackup
SNG=todayorder-m05-maz-subnets

# 같은 에뮬레이터에서 다시 실행하면 이전 실행의 이벤트도 남아 있으므로, 이 실행이 시작된 뒤의 이벤트만 본다.
RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cleanup() {
  rds_delete_instance "$REPLICA"
  rds_delete_instance "$PRIMARY"
  rds_delete_instance "$NOBACKUP"
  aws rds delete-db-subnet-group --db-subnet-group-name "$SNG" >/dev/null 2>&1 || true
}
cleanup

ensure_m05_vpc
ensure_db_sg
aws rds create-db-subnet-group --db-subnet-group-name "$SNG" \
  --db-subnet-group-description "TodayOrder Multi-AZ lab" --subnet-ids "$SUBNET_A" "$SUBNET_B" >/dev/null

echo "== 1. Multi-AZ 인스턴스 생성 (--multi-az)"
aws rds create-db-instance --db-instance-identifier "$PRIMARY" \
  --engine postgres --engine-version 16.3 --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username todayorder --master-user-password 'Lab-only-Passw0rd' \
  --db-subnet-group-name "$SNG" --vpc-security-group-ids "$DB_SG" \
  --multi-az --backup-retention-period 7 --no-publicly-accessible \
  --query 'DBInstance.{Status: DBInstanceStatus, MultiAZ: MultiAZ}'
aws rds wait db-instance-available --db-instance-identifier "$PRIMARY"
aws rds describe-db-instances --db-instance-identifier "$PRIMARY" --query 'DBInstances[0].{
  Status: DBInstanceStatus, MultiAZ: MultiAZ, AZ: AvailabilityZone, SecondaryAZ: SecondaryAvailabilityZone}'
az_before="$(aws rds describe-db-instances --db-instance-identifier "$PRIMARY" --query 'DBInstances[0].AvailabilityZone' --output text)"
maz="$(aws rds describe-db-instances --db-instance-identifier "$PRIMARY" --query 'DBInstances[0].MultiAZ' --output text)"

echo "== 2. 강제 장애 조치 (reboot --force-failover)"
aws rds reboot-db-instance --db-instance-identifier "$PRIMARY" --force-failover \
  --query 'DBInstance.{Status: DBInstanceStatus, AZ: AvailabilityZone}'
aws rds wait db-instance-available --db-instance-identifier "$PRIMARY"
az_after="$(aws rds describe-db-instances --db-instance-identifier "$PRIMARY" --query 'DBInstances[0].AvailabilityZone' --output text)"
echo "장애 조치 전 AZ=$az_before → 후 AZ=$az_after   (실제 AWS라면 대기 인스턴스의 AZ로 바뀐다)"
aws rds describe-events --source-type db-instance --source-identifier "$PRIMARY" --start-time "$RUN_START" \
  --query 'Events[].Message'

echo "== 3. 읽기 전용 복제본을 다른 AZ에 (비동기 복제, 읽기 전용, 자기 엔드포인트를 가진다)"
aws rds create-db-instance-read-replica --db-instance-identifier "$REPLICA" \
  --source-db-instance-identifier "$PRIMARY" --db-instance-class db.t3.micro \
  --availability-zone us-east-1b \
  --query 'DBInstance.{Status: DBInstanceStatus, Source: ReadReplicaSourceDBInstanceIdentifier}'
aws rds wait db-instance-available --db-instance-identifier "$REPLICA"
aws rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, '$PRIMARY')].{Id: DBInstanceIdentifier, AZ: AvailabilityZone, MultiAZ: MultiAZ, Port: Endpoint.Port, SourceOf: ReadReplicaDBInstanceIdentifiers, ReplicaOf: ReadReplicaSourceDBInstanceIdentifier}"
replica_src="$(aws rds describe-db-instances --db-instance-identifier "$REPLICA" --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text)"

echo "== 4. 수직 확장: 인스턴스 클래스 변경 (db.t3.micro → db.t3.small)"
aws rds modify-db-instance --db-instance-identifier "$PRIMARY" --db-instance-class db.t3.small --apply-immediately \
  --query 'DBInstance.{Status: DBInstanceStatus, Class: DBInstanceClass}'
aws rds wait db-instance-available --db-instance-identifier "$PRIMARY"
class="$(aws rds describe-db-instances --db-instance-identifier "$PRIMARY" --query 'DBInstances[0].DBInstanceClass' --output text)"
echo "현재 클래스: $class"

echo "== 5. 자동 백업이 꺼진(보존 기간 0) 원본에서는 복제본을 만들 수 없다"
aws rds create-db-instance --db-instance-identifier "$NOBACKUP" \
  --engine postgres --engine-version 16.3 --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username todayorder --master-user-password 'Lab-only-Passw0rd' \
  --db-subnet-group-name "$SNG" --backup-retention-period 0 --query 'DBInstance.BackupRetentionPeriod'
aws rds wait db-instance-available --db-instance-identifier "$NOBACKUP"
expect_error InvalidDBInstanceState aws rds create-db-instance-read-replica \
  --db-instance-identifier todayorder-m05-nobackup-rr --source-db-instance-identifier "$NOBACKUP"

echo "== 6. 복제본 승격(promote-read-replica) — 에뮬레이터 미구현"
expect_error NotImplemented aws rds promote-read-replica --db-instance-identifier "$REPLICA"

echo "== 7. 원본을 지우면? 같은 리전의 복제본은 독립 인스턴스로 승격된다"
aws rds delete-db-instance --db-instance-identifier "$PRIMARY" --skip-final-snapshot --query 'DBInstance.DBInstanceStatus'
aws rds wait db-instance-deleted --db-instance-identifier "$PRIMARY"
aws rds describe-db-instances --db-instance-identifier "$REPLICA" \
  --query 'DBInstances[0].{Id: DBInstanceIdentifier, Status: DBInstanceStatus, ReplicaOf: ReadReplicaSourceDBInstanceIdentifier}'
after_src="$(aws rds describe-db-instances --db-instance-identifier "$REPLICA" --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text)"

echo "== 8. 정리"
cleanup

# ---- 단언
[ "$maz" = "True" ] || fail "MultiAZ 가 True 가 아님: $maz"
[ "$replica_src" = "$PRIMARY" ] || fail "복제본의 원본이 다름: $replica_src"
[ "$class" = "db.t3.small" ] || fail "클래스 변경 미반영: $class"
[ "$after_src" = "None" ] || fail "원본 삭제 후에도 복제본이 원본을 가리킴: $after_src"
echo "LAB02 OK"
