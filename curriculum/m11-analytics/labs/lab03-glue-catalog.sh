#!/usr/bin/env bash
# M11 lab03 — Glue Data Catalog: 데이터베이스·테이블을 직접 정의하고 파티션 등록 (🟢) / 크롤러 (🔴 501)
#   S3 (raw/orders/dt=YYYY-MM-DD/*.json)  ──"이 파일들은 이런 열을 가진 표다"──▶  Glue 테이블 todayorder_lake.orders
# 크롤러가 이 일을 자동으로 해 주지만 에뮬레이터에서는 StartCrawler 가 501 이라 손으로 정의한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-catalog"
DB="todayorder_lake"
CRAWLER="todayorder-orders-crawler"
ROLE="todayorder-glue-crawler"
LOC="s3://$BUCKET/raw/orders/"
D1="$(utc_day -2)"
D2="$(utc_day -1)"

cleanup() {
  aws glue delete-crawler --name "$CRAWLER" >/dev/null 2>&1 || true
  aws glue delete-database --name "$DB" >/dev/null 2>&1 || true   # 데이터베이스를 지우면 안의 테이블·파티션도 지워진다
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name read-raw >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
  empty_bucket "$BUCKET"
}
cleanup

echo "== 1. S3 에 이틀치 주문 파일 (Hive 스타일 경로 dt=$D1, dt=$D2)"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text
history_orders "$D1" 1 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D1/part-0000.json"
history_orders "$D2" 2 | aws s3 cp - "s3://$BUCKET/raw/orders/dt=$D2/part-0000.json"
aws s3 ls "s3://$BUCKET/raw/orders/" --recursive | awk '{print $3, $4}'

echo "== 2. 데이터베이스 (카탈로그 안의 이름공간일 뿐, 데이터는 S3 에 그대로 있다)"
aws glue create-database --database-input "{\"Name\":\"$DB\",\"Description\":\"TodayOrder data lake\"}"
aws glue get-databases --query "DatabaseList[?Name=='$DB'].{Name: Name, Description: Description}"

echo "== 3. 테이블 정의: 열 이름·타입, S3 위치, 읽는 법(SerDe), 파티션 키 dt"
aws glue create-table --database-name "$DB" --table-input "$(orders_table_input orders "$LOC")"
aws glue get-table --database-name "$DB" --name orders --query 'Table.{
  Location: StorageDescriptor.Location, SerDe: StorageDescriptor.SerdeInfo.SerializationLibrary,
  Columns: join(`, `, StorageDescriptor.Columns[].Name), PartitionKeys: PartitionKeys[].Name}'

echo "== 4. 파티션 등록 (BatchCreatePartition) — 새 날짜 폴더가 생겨도 카탈로그는 저절로 모른다"
aws glue batch-create-partition --database-name "$DB" --table-name orders \
  --partition-input-list "$(partition_input "$LOC" "$D1" "$D2")" --query '{Errors: Errors}'
echo "-- 같은 파티션을 한 번 더 등록하면? (호출은 성공, 항목별 오류로 알려 준다)"
again="$(aws glue batch-create-partition --database-name "$DB" --table-name orders \
  --partition-input-list "$(partition_input "$LOC" "$D1")" --output json)"
echo "$again" | py -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["Errors"], indent=2))'

echo "== 5. 파티션 하나 조회 (GetPartition)"
aws glue get-partition --database-name "$DB" --table-name orders --partition-values "$D1" \
  --query 'Partition.{Values: Values, Location: StorageDescriptor.Location}'
p1="$(aws glue get-partition --database-name "$DB" --table-name orders --partition-values "$D1" --query 'Partition.Values[0]' --output text)"
echo "-- 파티션 전체 목록 (GetPartitions)"
set +e
gp="$(aws glue get-partitions --database-name "$DB" --table-name orders 2>&1)"
set -e
echo "$gp"

echo "== 6. 크롤러: 역할 신뢰 정책 확인 → 생성 OK → 실행은 501"
set +e
no_role="$(aws glue create-crawler --name "$CRAWLER" --role arn:aws:iam::000000000000:role/does-not-exist \
  --database-name "$DB" --targets "{\"S3Targets\":[{\"Path\":\"$LOC\"}]}" 2>&1)"
set -e
echo "없는 역할: $no_role"
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
aws iam put-role-policy --role-name "$ROLE" --policy-name read-raw --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
  \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/raw/*\"]}]}"
aws glue create-crawler --name "$CRAWLER" --role "$ROLE_ARN" --database-name "$DB" --table-prefix crawled_ \
  --targets "{\"S3Targets\":[{\"Path\":\"$LOC\"}]}" --schedule 'cron(15 0 * * ? *)'
aws glue get-crawler --name "$CRAWLER" --query 'Crawler.{State: State, Schedule: Schedule.ScheduleExpression, Target: Targets.S3Targets[0].Path}'
set +e
start="$(aws glue start-crawler --name "$CRAWLER" 2>&1)"
set -e
echo "$start"

tables="$(aws glue get-tables --database-name "$DB" --query 'TableList[].Name' --output text)"
cleanup

# ---- 단언
[ "$p1" = "$D1" ] || fail "파티션 $D1 이 조회되지 않음"
[[ "$again" == *AlreadyExistsException* ]] || fail "중복 파티션 등록이 오류로 보고되지 않음"
[[ "$no_role" == *InvalidInputException* ]] || fail "없는 역할로 크롤러가 만들어짐"
[[ "$gp" == *NotImplemented* ]] || echo "참고: GetPartitions 가 501이 아님 — 에뮬레이터가 바뀐 듯하다"
[[ "$start" == *NotImplemented* ]] || echo "참고: StartCrawler 가 501이 아님 — 에뮬레이터가 바뀐 듯하다. 레슨 3 등급을 다시 확인할 것"
[ "$tables" = orders ] || fail "카탈로그 테이블 목록이 orders 하나가 아님: $tables"
echo "LAB03 OK"
