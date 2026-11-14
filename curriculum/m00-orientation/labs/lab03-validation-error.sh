#!/usr/bin/env bash
# M00 lab03 — 검증 오류 관찰 (🟢)
# DynamoDB 테이블 이름은 3~255자다. 2글자 이름으로 만들면 AWS와 같은 ValidationException 이 돌아온다.
# 오류 메시지를 읽는 연습과, CLI 종료 코드(254)를 스크립트에서 다루는 법을 익힌다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
# DynamoDB 테이블은 wait_dynamodb_table_active 로 기다린다 (= table-exists + 준비 직후 재확인, scripts/lab-wait.sh)
# 삭제는 wait_dynamodb_table_gone 으로 끝날 때까지 기다린다 (= table-not-exists 를 1초 간격으로) — 삭제 중(DELETING)인
# 같은 이름으로 만들면 ResourceInUseException 이므로, 곧바로 다시 실행해도 통과하게 한다 (규칙 4)
source "$(git rev-parse --show-toplevel)/scripts/lab-wait.sh"

TABLE="todayorder-m00-orders"
aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
wait_dynamodb_table_gone "$TABLE"   # = aws dynamodb wait table-not-exists (scripts/lab-wait.sh)

create() {
  aws dynamodb create-table --table-name "$1" \
    --attribute-definitions AttributeName=orderId,AttributeType=S \
    --key-schema AttributeName=orderId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST "${@:2}"
}

echo "== 1. 2글자 이름으로 테이블 만들기 (실패해야 정상)"
set +e
err="$(create ab 2>&1 >/dev/null)"
rc=$?
set -e
echo "$err"
echo "종료 코드: $rc"

echo "== 2. 올바른 이름으로 다시 만들기"
create "$TABLE" --query 'TableDescription.{Name: TableName, Status: TableStatus, Billing: BillingModeSummary.BillingMode}'
wait_dynamodb_table_active "$TABLE"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
status="$(aws dynamodb describe-table --table-name "$TABLE" --query Table.TableStatus --output text)"
echo "대기 후 상태: $status"

echo "== 3. 정리"
aws dynamodb delete-table --table-name "$TABLE" --query 'TableDescription.TableStatus' --output text
wait_dynamodb_table_gone "$TABLE"   # = aws dynamodb wait table-not-exists (scripts/lab-wait.sh)

# ---- 단언
[ "$rc" -eq 254 ] || { echo "FAIL: 종료 코드가 254가 아님 ($rc)"; exit 1; }
case "$err" in
  *ValidationException*"length greater than or equal to 3"*) ;;
  *) echo "FAIL: 예상한 ValidationException 메시지가 아님"; exit 1 ;;
esac
[ "$status" = "ACTIVE" ] || { echo "FAIL: 테이블이 ACTIVE가 아님 ($status)"; exit 1; }
echo "LAB03 OK"
