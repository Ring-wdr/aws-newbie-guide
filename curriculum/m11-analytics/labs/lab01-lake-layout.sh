#!/usr/bin/env bash
# M11 lab01 — S3 데이터 레이크의 뼈대 (🟢 S3 구성 / 🟡 Lake Formation 설정 읽기)
# 버킷 하나에 영역(zone)을 접두사로 나눈다:
#   raw/       원본 그대로 (Firehose·앱이 쓰는 곳, 수정 금지)
#   curated/   정제·집계 결과 (Glue ETL 이 쓰는 곳)
#   athena-results/  쿼리 결과 위치
# 그리고 레이크 버킷에 꼭 필요한 기본값(퍼블릭 차단, 기본 암호화, 버전 관리, 수명 주기)을 건다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-datalake"
empty_bucket "$BUCKET"

echo "== 1. 레이크 버킷과 기본 보호 장치"
aws s3api create-bucket --bucket "$BUCKET" --query Location --output text
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

echo "== 2. 수명 주기: raw 는 30일 뒤 Standard-IA, 365일 뒤 Glacier Flexible Retrieval / athena-results 는 7일 뒤 삭제"
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {"ID": "raw-tiering", "Status": "Enabled", "Filter": {"Prefix": "raw/"},
     "Transitions": [{"Days": 30, "StorageClass": "STANDARD_IA"}, {"Days": 365, "StorageClass": "GLACIER"}]},
    {"ID": "athena-results-expire", "Status": "Enabled", "Filter": {"Prefix": "athena-results/"},
     "Expiration": {"Days": 7}}]}'
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID: ID, Prefix: Filter.Prefix, Transitions: Transitions[].[Days, StorageClass], ExpireDays: Expiration.Days}'

echo "== 3. 영역별 예시 객체 — 'Hive 스타일' 파티션 경로(key=value)"
printf '{"order_id":"A-1001","store":"gangnam","amount":18000,"ordered_at":"2026-11-10T03:12:00Z"}\n' |
  aws s3 cp - "s3://$BUCKET/raw/orders/dt=2026-11-10/part-0000.json"
printf '{"day":"2026-11-10","store":"gangnam","orders":1,"revenue":18000}\n' |
  aws s3 cp - "s3://$BUCKET/curated/daily_revenue/dt=2026-11-10/part-0000.json"
aws s3 ls "s3://$BUCKET" --recursive | awk '{print $3, $4}'
keys="$(aws s3api list-objects-v2 --bucket "$BUCKET" --output json | py -c 'import json,sys; print(len(json.load(sys.stdin).get("Contents", [])))')"

echo "== 4. 접두사(prefix)와 구분자(/)로 '폴더처럼' 보기 — S3에 실제 폴더는 없다"
aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter / --query 'CommonPrefixes[].Prefix'

echo "== 5. Lake Formation 데이터 레이크 설정 읽기 (권한 모델 확인)"
aws lakeformation get-data-lake-settings --query 'DataLakeSettings.{Admins: DataLakeAdmins, DefaultDbPerms: CreateDatabaseDefaultPermissions[0]}'
lf="$(aws lakeformation get-data-lake-settings --query 'DataLakeSettings.CreateDatabaseDefaultPermissions[0].Principal.DataLakePrincipalIdentifier' --output text)"

empty_bucket "$BUCKET"

# ---- 단언
[ "$keys" = 2 ] || fail "예시 객체가 2개가 아님: $keys"
[ "$lf" = IAM_ALLOWED_PRINCIPALS ] || echo "참고: Lake Formation 기본 권한이 $lf"
echo "LAB01 OK"
