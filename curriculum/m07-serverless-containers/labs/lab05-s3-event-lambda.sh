#!/usr/bin/env bash
# M07 lab05 — S3 이벤트 처리: 영수증 업로드 → Lambda → DynamoDB (🟢)
# S3 는 알림 구성을 저장할 때 Lambda 리소스 정책(add-permission)을 검증한다 — 없으면 거부된다.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"

BUCKET=todayorder-m07-receipts
TABLE=todayorder-receipts
FN=todayorder-receipt-processor
ROLE=todayorder-receipt-processor-role

echo "== 0. 이전 실행 정리 (버킷, 표)"
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$TABLE" >/dev/null
  aws dynamodb wait table-not-exists --table-name "$TABLE"
fi

echo "== 1. 버킷, 영수증 표"
aws s3 mb "s3://$BUCKET"
aws dynamodb create-table --table-name "$TABLE" --attribute-definitions AttributeName=orderId,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH --billing-mode PAY_PER_REQUEST --query TableDescription.TableName --output text
aws dynamodb wait table-exists --table-name "$TABLE"

echo "== 2. 실행 역할: 로그 + receipts/ 아래 객체 읽기 + 영수증 표 쓰기"
ensure_role "$ROLE" lambda.amazonaws.com
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name "$ROLE" --policy-name receipts --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/receipts/*\"},{\"Effect\":\"Allow\",\"Action\":\"dynamodb:PutItem\",\"Resource\":\"arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TABLE\"}]}"
fresh_function "$FN" "$MOD/functions/receipt_processor.py" receipt_processor.handler "arn:aws:iam::$ACCOUNT:role/$ROLE" \
  --timeout 10 --environment "Variables={TABLE_NAME=$TABLE}"
FN_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FN"

cat >"$WORK/notif.json" <<JSON
{"LambdaFunctionConfigurations": [{
  "Id": "receipt-json",
  "LambdaFunctionArn": "$FN_ARN",
  "Events": ["s3:ObjectCreated:*"],
  "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "receipts/"}, {"Name": "suffix", "Value": ".json"}]}}
}]}
JSON

echo "== 3. add-permission 없이 알림 구성 → S3 가 거부한다"
if aws s3api put-bucket-notification-configuration --bucket "$BUCKET" \
  --notification-configuration "file://$WORK/notif.json" 2>"$WORK/e"; then
  fail "Lambda 권한 없이 알림 구성이 저장됨"
fi
cat "$WORK/e"

echo "== 4. add-permission(주체 s3.amazonaws.com, 이 버킷·이 계정에서만) 후 다시 구성"
aws lambda add-permission --function-name "$FN" --statement-id s3-receipts --action lambda:InvokeFunction \
  --principal s3.amazonaws.com --source-arn "arn:aws:s3:::$BUCKET" --source-account "$ACCOUNT" >/dev/null
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "file://$WORK/notif.json"
aws s3api get-bucket-notification-configuration --bucket "$BUCKET" \
  --query 'LambdaFunctionConfigurations[0].{Id: Id, Events: Events, Rules: Filter.Key.FilterRules}'

echo "== 5. 영수증 2건(receipts/*.json) + 필터 밖 객체 2건 업로드"
printf '{"orderId":"A-5001","total":12000}' | aws s3 cp - "s3://$BUCKET/receipts/2026/11/A-5001.json"
printf '{"orderId":"A-5002","total":45000}' | aws s3 cp - "s3://$BUCKET/receipts/2026/11/A-5002.json"
printf 'not a receipt' | aws s3 cp - "s3://$BUCKET/receipts/2026/11/readme.txt"
printf '{"orderId":"X-0000","total":1}' | aws s3 cp - "s3://$BUCKET/tmp/X-0000.json"
two() { [ "$(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text)" -ge 2 ]; }
poll 60 "영수증 2건 저장" two
aws dynamodb scan --table-name "$TABLE" --query 'Items[].[orderId.S, total.N, sourceKey.S, eventName.S]' --output text | sort
count="$(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text)"

# ---- 단언
[ "$count" = 2 ] || fail "필터에 맞는 2건만 처리돼야 함: $count"
aws dynamodb get-item --table-name "$TABLE" --key '{"orderId":{"S":"X-0000"}}' --query Item --output text | grep -q None \
  || fail "필터 밖 객체(tmp/)가 처리됨"
echo "LAB05 OK"
