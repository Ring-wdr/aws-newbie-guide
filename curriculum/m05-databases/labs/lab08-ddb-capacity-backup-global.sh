#!/usr/bin/env bash
# M05 lab08 — DynamoDB 운영 설정: 용량 모드 전환, 온디맨드 백업·복원, PITR, 글로벌 테이블 (🟢 / 글로벌 테이블 🟡)
# 프로비저닝(5/5) 테이블 → 온디맨드로 전환 → 백업 → 백업에서 새 테이블로 복원 → PITR 켜고 시점 복원
# → us-west-2 복제본 추가(글로벌 테이블)
# 에뮬레이터: 리전을 분리하지 않으므로 복제본이 "다른 리전에 따로 있는" 것은 볼 수 없다(설정·상태만).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_common.sh"

T=todayorder-m05-catalog
FROM_BACKUP=todayorder-m05-catalog-from-backup
FROM_PITR=todayorder-m05-catalog-pitr

cleanup() {
  if aws dynamodb describe-table --table-name "$T" --query 'Table.Replicas[0].RegionName' --output text 2>/dev/null | grep -q us-west-2; then
    aws dynamodb update-table --table-name "$T" --replica-updates 'Delete={RegionName=us-west-2}' >/dev/null
    poll_until 120 "복제본 삭제" bash -c \
      "[ \"\$(aws dynamodb describe-table --table-name $T --query 'length(Table.Replicas || \`[]\`)' --output text)\" = 0 ]"
  fi
  for b in $(aws dynamodb list-backups --table-name "$T" --query 'BackupSummaries[].BackupArn' --output text 2>/dev/null); do
    aws dynamodb delete-backup --backup-arn "$b" >/dev/null
  done
  ddb_delete_table "$FROM_BACKUP"
  ddb_delete_table "$FROM_PITR"
  ddb_delete_table "$T"
}
cleanup

echo "== 1. 프로비저닝 모드(RCU 5 / WCU 5)로 상품 카탈로그 테이블"
aws dynamodb create-table --table-name "$T" \
  --attribute-definitions AttributeName=product_id,AttributeType=S \
  --key-schema AttributeName=product_id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --query 'TableDescription.{Status: TableStatus, Throughput: ProvisionedThroughput.{R: ReadCapacityUnits, W: WriteCapacityUnits}}'
wait_dynamodb_table_active "$T"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
for i in 1 2 3 4 5; do
  aws dynamodb put-item --table-name "$T" --item "{\"product_id\":{\"S\":\"P-10$i\"},\"stock\":{\"N\":\"$((i * 10))\"}}"
done

echo "== 2. 트래픽을 예측할 수 없다 → 온디맨드(PAY_PER_REQUEST)로 전환"
aws dynamodb update-table --table-name "$T" --billing-mode PAY_PER_REQUEST \
  --query 'TableDescription.{Status: TableStatus, Mode: BillingModeSummary.BillingMode}'
poll_until 120 "테이블 ACTIVE" bash -c \
  "[ \"\$(aws dynamodb describe-table --table-name $T --query 'Table.TableStatus' --output text)\" = ACTIVE ]"
mode="$(aws dynamodb describe-table --table-name "$T" --query 'Table.BillingModeSummary.BillingMode' --output text)"
echo "BillingMode=$mode"

echo "== 3. 온디맨드 백업 → 백업에서 '새 테이블'로 복원"
BACKUP_ARN="$(aws dynamodb create-backup --table-name "$T" --backup-name todayorder-m05-catalog-bk \
  --query 'BackupDetails.BackupArn' --output text)"
poll_until 120 "백업 AVAILABLE" bash -c \
  "[ \"\$(aws dynamodb describe-backup --backup-arn $BACKUP_ARN --query 'BackupDescription.BackupDetails.BackupStatus' --output text)\" = AVAILABLE ]"
aws dynamodb describe-backup --backup-arn "$BACKUP_ARN" \
  --query 'BackupDescription.BackupDetails.{Name: BackupName, Status: BackupStatus, Type: BackupType}'
aws dynamodb restore-table-from-backup --target-table-name "$FROM_BACKUP" --backup-arn "$BACKUP_ARN" \
  --query 'TableDescription.{Status: TableStatus, RestoreInProgress: RestoreSummary.RestoreInProgress}'
wait_dynamodb_table_active "$FROM_BACKUP"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
restored_count="$(aws dynamodb scan --table-name "$FROM_BACKUP" --select COUNT --query Count --output json)"
echo "복원된 테이블 항목 수: $restored_count"

echo "== 4. PITR(지속적 백업) 켜기 — 복구 기간 7일"
aws dynamodb update-continuous-backups --table-name "$T" \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true,RecoveryPeriodInDays=7 \
  --query 'ContinuousBackupsDescription.{Status: ContinuousBackupsStatus, PITR: PointInTimeRecoveryDescription.PointInTimeRecoveryStatus, Days: PointInTimeRecoveryDescription.RecoveryPeriodInDays}'
aws dynamodb describe-continuous-backups --table-name "$T" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.{Earliest: EarliestRestorableDateTime, Latest: LatestRestorableDateTime}'
echo "-- 복구 가능 구간 밖의 시각(1시간 전)을 고르면 거부된다"
expect_error InvalidRestoreTimeException aws dynamodb restore-table-to-point-in-time \
  --source-table-name "$T" --target-table-name "$FROM_PITR" --restore-date-time "$(($(date +%s) - 3600))"
echo "-- 실수로 P-101 재고를 0으로 덮어썼다. '복구 가능한 가장 최근 시각'으로 새 테이블을 만든다"
aws dynamodb put-item --table-name "$T" --item '{"product_id":{"S":"P-101"},"stock":{"N":"0"}}'
aws dynamodb restore-table-to-point-in-time --source-table-name "$T" --target-table-name "$FROM_PITR" \
  --use-latest-restorable-time \
  --query 'TableDescription.{Status: TableStatus, Source: RestoreSummary.SourceTableArn, RestoreInProgress: RestoreSummary.RestoreInProgress}'
wait_dynamodb_table_active "$FROM_PITR"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
pitr_count="$(aws dynamodb scan --table-name "$FROM_PITR" --select COUNT --query Count --output json)"
pitr_stock="$(aws dynamodb get-item --table-name "$FROM_PITR" --key '{"product_id":{"S":"P-101"}}' --query 'Item.stock.N' --output text)"
aws dynamodb describe-continuous-backups --table-name "$T" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.LatestRestorableDateTime'
echo "시점 복원 테이블: 항목 ${pitr_count}개, P-101 재고=$pitr_stock"
echo "(에뮬레이터 차이: LatestRestorableDateTime 이 PITR 을 켠 시각에 멈춰 있고, 복원 결과는 '복원 요청 시점의"
echo " 현재 데이터'다. 실제 AWS는 이 값이 보통 현재보다 약 5분 전까지 따라오며, 그 시각의 데이터로 복원한다.)"

echo "== 5. 글로벌 테이블: us-west-2 에 복제본 추가 (버전 2019.11.21)"
aws dynamodb update-table --table-name "$T" --replica-updates 'Create={RegionName=us-west-2}' \
  --query 'TableDescription.{Status: TableStatus, Replicas: Replicas[].{Region: RegionName, Status: ReplicaStatus}}'
poll_until 300 "복제본 ACTIVE" bash -c \
  "[ \"\$(aws dynamodb describe-table --table-name $T --query 'Table.Replicas[0].ReplicaStatus' --output text)\" = ACTIVE ]"
aws dynamodb describe-table --table-name "$T" \
  --query 'Table.{Status: TableStatus, Version: GlobalTableVersion, Replicas: Replicas[].{Region: RegionName, Status: ReplicaStatus}}'
replica="$(aws dynamodb describe-table --table-name "$T" --query 'Table.Replicas[0].ReplicaStatus' --output text)"
echo "-- us-west-2 로 물어보면? (에뮬레이터는 리전을 나누지 않아 같은 테이블이 보인다)"
aws dynamodb describe-table --table-name "$T" --region us-west-2 --query 'Table.TableArn'

echo "== 6. 정리 (복제본 제거 → 백업 삭제 → 테이블 삭제)"
cleanup

# ---- 단언
[ "$mode" = "PAY_PER_REQUEST" ] || fail "용량 모드 전환 실패: $mode"
[ "$restored_count" = "5" ] || fail "백업 복원 항목 수가 5가 아님: $restored_count"
[ "$pitr_count" = "5" ] || fail "시점 복원 테이블 항목 수가 5가 아님: $pitr_count"
[ "$replica" = "ACTIVE" ] || fail "복제본 상태: $replica"
echo "LAB08 OK"
