#!/usr/bin/env bash
# M14 lab03 — 캡스톤 계층 3: 주문 파이프라인
#   CLI:            EventBridge 사용자 지정 버스, Cognito 사용자 풀, Lambda 2개(최소 권한 역할), SQS 이벤트 소스 매핑,
#                   HTTP API(JWT 권한 부여자·스로틀링), Lambda 리소스 정책
#   CloudFormation: 버스 규칙 → SNS 팬아웃 → SQS(DLQ, 필터 정책), 운영 알림 토픽·큐 (templates/messaging.yaml)
# 선행 계층: lab02(테이블·버킷·비밀·KMS 키). 없으면 스스로 만든다.
# 등급: 🟢
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 0. 선행 계층"
ensure have_data "$LABS/lab02-data-security.sh"
KEY_ARN="$(stack_output "$DATA_STACK" KeyArn)"
TABLE_ARN="$(stack_output "$DATA_STACK" TableArn)"
SECRET_ARN="$(stack_output "$DATA_STACK" SecretArn)"

echo "== 1. EventBridge 사용자 지정 버스(CLI) + 메시징 스택(CloudFormation)"
aws events describe-event-bus --name "$BUS" >/dev/null 2>&1 || aws events create-event-bus --name "$BUS" >/dev/null
BUS_ARN="$(aws events describe-event-bus --name "$BUS" --query Arn --output text)"
echo "버스: $BUS_ARN"
deploy_stack "$MSG_STACK" "$LABS/templates/messaging.yaml" "ParameterKey=BusName,ParameterValue=$BUS"
WORK_Q_ARN="$(stack_output "$MSG_STACK" FulfillmentQueueArn)"
aws sns list-subscriptions-by-topic --topic-arn "$(stack_output "$MSG_STACK" OrderEventsTopicArn)" --output json | py '
for s in json.load(sys.stdin)["Subscriptions"]:
    print(s["Protocol"], s["Endpoint"].split(":")[-1], sep="\t")'

echo "== 2. Cognito 사용자 풀(고객 로그인) + 앱 클라이언트(비밀 없음 = 모바일·웹 앱)"
POOL="$(aws cognito-idp list-user-pools --max-results 60 --output json | py '
for p in json.load(sys.stdin)["UserPools"]:
    if p["Name"] == sys.argv[1]:
        print(p["Id"])' "$P-customers" | head -1)"
if [ -z "$POOL" ]; then
  POOL="$(aws cognito-idp create-user-pool --pool-name "$P-customers" --username-attributes email \
    --policies 'PasswordPolicy={MinimumLength=10,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true}' \
    --query UserPool.Id --output text)"
fi
CLIENT="$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL" --query "UserPoolClients[?ClientName=='todayorder-app'].ClientId | [0]" --output text)"
if [ "$CLIENT" = None ] || [ -z "$CLIENT" ]; then
  CLIENT="$(aws cognito-idp create-user-pool-client --user-pool-id "$POOL" --client-name todayorder-app --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH --query UserPoolClient.ClientId --output text)"
fi
echo "사용자 풀 $POOL · 앱 클라이언트 $CLIENT"

echo "== 3. 실행 역할 2개 — 각자 필요한 것만 (최소 권한)"
# 테이블·영수증·비밀은 모두 고객 관리형 키로 암호화돼 있고, 키 정책은 계정(IAM)에 위임만 한다. 그래서 각 역할의
# IAM 정책에 키 사용 권한이 있어야 한다. DynamoDB·S3·Secrets Manager 는 "호출자 대신" KMS 를 부르므로
# kms:ViaService 로 "그 서비스를 거친 호출만" 허용한다(역할이 키를 직접 쓰는 것은 막힌다).
#   order-api:    DynamoDB 테이블 키 풀기 → kms:Decrypt (+ DescribeKey)
#   order-worker: DynamoDB(Decrypt) · S3 SSE-KMS 쓰기(GenerateDataKey, 버킷 키·멀티파트용 Decrypt) · 비밀 읽기(Decrypt)
#   SQS·SNS 는 SSE-SQS(관리형)라 KMS 권한이 필요 없다(messaging.yaml 머리말).
VIA_DDB="dynamodb.$REGION.amazonaws.com"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
for r in "$API_ROLE" "$WORKER_ROLE"; do
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || aws iam create-role --role-name "$r" --assume-role-policy-document "$TRUST" >/dev/null
  aws iam attach-role-policy --role-name "$r" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
done
aws iam put-role-policy --role-name "$API_ROLE" --policy-name order-api --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Sid\":\"Orders\",\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutItem\",\"dynamodb:GetItem\",\"dynamodb:Query\"],
   \"Resource\":[\"$TABLE_ARN\",\"$TABLE_ARN/index/byCustomer\"]},
  {\"Sid\":\"OrdersTableKey\",\"Effect\":\"Allow\",\"Action\":[\"kms:Decrypt\",\"kms:DescribeKey\"],\"Resource\":\"$KEY_ARN\",
   \"Condition\":{\"StringEquals\":{\"kms:ViaService\":\"$VIA_DDB\"}}},
  {\"Sid\":\"Events\",\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$BUS_ARN\"}]}"
aws iam put-role-policy --role-name "$WORKER_ROLE" --policy-name order-worker --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Sid\":\"Queue\",\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"$WORK_Q_ARN\"},
  {\"Sid\":\"Orders\",\"Effect\":\"Allow\",\"Action\":\"dynamodb:UpdateItem\",\"Resource\":\"$TABLE_ARN\"},
  {\"Sid\":\"Receipts\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$RECEIPTS/receipts/*\"},
  {\"Sid\":\"Secret\",\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"$SECRET_ARN\"},
  {\"Sid\":\"Kms\",\"Effect\":\"Allow\",\"Action\":[\"kms:Decrypt\",\"kms:GenerateDataKey\",\"kms:DescribeKey\"],\"Resource\":\"$KEY_ARN\",
   \"Condition\":{\"StringEquals\":{\"kms:ViaService\":[\"$VIA_DDB\",\"s3.$REGION.amazonaws.com\",\"secretsmanager.$REGION.amazonaws.com\"]}}},
  {\"Sid\":\"Metric\",\"Effect\":\"Allow\",\"Action\":\"cloudwatch:PutMetricData\",\"Resource\":\"*\",
   \"Condition\":{\"StringEquals\":{\"cloudwatch:namespace\":\"$METRIC_NS\"}}}]}"
aws iam list-role-policies --role-name "$WORKER_ROLE" --query PolicyNames --output text
for r in "$API_ROLE" "$WORKER_ROLE"; do
  printf '%s\t' "$r"
  aws iam get-role-policy --role-name "$r" --policy-name "$(n="${r#"$P-"}"; echo "${n%-role}")" --query PolicyDocument --output json | py '
for st in json.load(sys.stdin)["Statement"]:
    if any(a.startswith("kms:") for a in ([st["Action"]] if isinstance(st["Action"], str) else st["Action"])):
        v = st["Condition"]["StringEquals"]["kms:ViaService"]
        print(st["Sid"], " ".join(sorted(st["Action"])), "via", " ".join(v if isinstance(v, list) else [v]))'
done

echo "== 4. Lambda 2개 (설정은 배포 시 Parameter Store 에서 읽어 환경 변수로)"
MAX_ITEMS="$(aws ssm get-parameter --name "$PARAM_PREFIX/order/max-items" --query Parameter.Value --output text)"
CURRENCY="$(aws ssm get-parameter --name "$PARAM_PREFIX/order/currency" --query Parameter.Value --output text)"
for u in $(aws lambda list-event-source-mappings --function-name "$WORKER_FN" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  aws lambda delete-event-source-mapping --uuid "$u" >/dev/null
done
deploy_fn() {  # <이름> <파일> <역할> <환경 변수> <타임아웃>
  zip_function "$MOD/functions/$2" "$WORK/$1.zip"
  aws lambda delete-function --function-name "$1" >/dev/null 2>&1 || true
  aws lambda create-function --function-name "$1" --runtime python3.12 --architectures arm64 \
    --handler "${2%.py}.handler" --role "arn:aws:iam::$ACCOUNT:role/$3" --zip-file "fileb://$WORK/$1.zip" \
    --timeout "$5" --memory-size 256 --environment "Variables={$4}" --tags Project=todayorder >/dev/null
  aws lambda wait function-active-v2 --function-name "$1"
}
deploy_fn "$API_FN" order_api.py "$API_ROLE" "TABLE_NAME=$TABLE,EVENT_BUS=$BUS,MAX_ITEMS=$MAX_ITEMS,CURRENCY=$CURRENCY" 10
deploy_fn "$WORKER_FN" order_worker.py "$WORKER_ROLE" "TABLE_NAME=$TABLE,RECEIPT_BUCKET=$RECEIPTS,SECRET_ID=$SECRET,METRIC_NAMESPACE=$METRIC_NS" 5
# 로그 보존 기간: 기본은 무기한(=계속 과금). 30일로
for f in "$API_FN" "$WORKER_FN"; do
  aws logs create-log-group --log-group-name "/aws/lambda/$f" >/dev/null 2>&1 || true
  aws logs put-retention-policy --log-group-name "/aws/lambda/$f" --retention-in-days 30
done
aws lambda get-function-configuration --function-name "$WORKER_FN" \
  --query '{Runtime: Runtime, Arch: Architectures[0], Timeout: Timeout, Memory: MemorySize}' --output json

echo "== 5. SQS → 워커: 이벤트 소스 매핑 (배치 5, 부분 배치 실패 보고). 큐 가시성 30초 = 함수 타임아웃 5초 × 6"
UUID="$(aws lambda create-event-source-mapping --function-name "$WORKER_FN" --event-source-arn "$WORK_Q_ARN" \
  --batch-size 5 --function-response-types ReportBatchItemFailures --query UUID --output text)"
poll 60 "매핑 Enabled" sh -c "aws lambda get-event-source-mapping --uuid '$UUID' --query State --output text | grep -qx Enabled"
aws lambda get-event-source-mapping --uuid "$UUID" --query '{State: State, BatchSize: BatchSize, Report: FunctionResponseTypes}' --output json

echo "== 6. HTTP API + JWT 권한 부여자(사용자 풀) + 스테이지 스로틀(이 lab 이 지정: 초당 500, 버스트 1000) + 라우트 3개"
for id in $(aws apigatewayv2 get-apis --output json | py '
for a in json.load(sys.stdin).get("Items", []):
    if a["Name"] == sys.argv[1]:
        print(a["ApiId"])' "$API_NAME"); do
  aws apigatewayv2 delete-api --api-id "$id"
done
# 권한 부여자의 Issuer 는 토큰의 iss 와 같아야 한다. 에뮬레이터의 iss 는 https://127.0.0.1:<포트>/<풀 ID> 라
# external-host-ok: 아래 줄은 실제 AWS의 발급자 형식을 설명하는 주석일 뿐 어디에도 등록·접속하지 않는다
# (실제 AWS: https://cognito-idp.us-east-1.amazonaws.com/<풀 ID>) 점검용 사용자로 토큰을 받아 읽는다.
PROBE_USER="lab03-probe@todayorder.example.com"
PROBE_PW='Probe-Passw0rd!'
aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$PROBE_USER" >/dev/null 2>&1 || {
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$PROBE_USER" --message-action SUPPRESS \
    --user-attributes Name=email,Value="$PROBE_USER" Name=email_verified,Value=true >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$PROBE_USER" --password "$PROBE_PW" --permanent
}
TOKEN="$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$PROBE_USER,PASSWORD=$PROBE_PW" --query AuthenticationResult.IdToken --output text)"
ISSUER="$(printf '%s' "$TOKEN" | cut -d. -f2 | py '
import base64
s = sys.stdin.read().strip(); s += "=" * (-len(s) % 4)
print(json.loads(base64.urlsafe_b64decode(s))["iss"])')"
echo "토큰 발급자(iss): $ISSUER"
API="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --query ApiId --output text)"
AUTHZ="$(aws apigatewayv2 create-authorizer --api-id "$API" --name cognito-customers --authorizer-type JWT \
  --identity-source '$request.header.Authorization' --jwt-configuration "Audience=$CLIENT,Issuer=$ISSUER" \
  --query AuthorizerId --output text)"
INTEG="$(aws apigatewayv2 create-integration --api-id "$API" --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT:function:$API_FN" --payload-format-version 2.0 --query IntegrationId --output text)"
for rk in 'POST /orders' 'GET /orders/{orderId}' 'GET /me/orders'; do
  aws apigatewayv2 create-route --api-id "$API" --route-key "$rk" --target "integrations/$INTEG" \
    --authorization-type JWT --authorizer-id "$AUTHZ" --query '[RouteKey, AuthorizationType]' --output text
done
# 스로틀 값 = NFR-P1 피크(초당 300건) × 여유 약 1.7 → 초당 500, 버스트 1000. 지정하지 않으면 계정 한도
# (리전당 초당 10,000·버스트 5,000)만 적용되어 한 API 가 계정 몫을 다 쓸 수 있다(레슨 02 결정 기록).
aws apigatewayv2 create-stage --api-id "$API" --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingBurstLimit=1000,ThrottlingRateLimit=500 \
  --query 'DefaultRouteSettings.[ThrottlingBurstLimit, ThrottlingRateLimit]' --output text
# 실제 AWS 에서는 이 리소스 정책이 없으면 API Gateway 가 함수를 부르지 못한다(에뮬레이터 HTTP API 는 검사하지 않음 — M07)
aws lambda add-permission --function-name "$API_FN" --statement-id http-api-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API/*/*" >/dev/null
B="$(api_base "$API")"
echo "API: $B   (실제 AWS: https://$API.execute-api.$REGION.amazonaws.com)"

echo "== 7. 연결 확인: 토큰 없이 → 401, 토큰으로 내 주문 목록 → 200"
call GET "$B/me/orders" | tee "$WORK/noauth"
call GET "$B/me/orders" -H "Authorization: Bearer $TOKEN" | tee "$WORK/auth"

# ---- 단언
grep -q 'HTTP 401' "$WORK/noauth" || fail "토큰 없는 요청이 401 이 아님"
grep -q 'HTTP 200' "$WORK/auth" || fail "토큰 있는 요청이 200 이 아님"
assert_eq "$(aws apigatewayv2 get-stage --api-id "$API" --stage-name '$default' --query 'DefaultRouteSettings.ThrottlingRateLimit' --output text)" 500.0 "스테이지 스로틀 ≥ NFR-P1 300건/초"
for r in "$API_ROLE" "$WORKER_ROLE"; do
  aws iam get-role-policy --role-name "$r" --policy-name "$(n="${r#"$P-"}"; echo "${n%-role}")" --query PolicyDocument --output json | py '
ok = any("kms:Decrypt" in st["Action"] and st["Resource"] == sys.argv[1] for st in json.load(sys.stdin)["Statement"])
sys.exit(0 if ok else 1)' "$KEY_ARN" || fail "$r 에 데이터 키 kms:Decrypt 권한 없음"
done
assert_eq "$(aws lambda get-event-source-mapping --uuid "$UUID" --query 'FunctionResponseTypes[0]' --output text)" ReportBatchItemFailures "부분 배치 실패 보고"
assert_eq "$(aws sqs get-queue-attributes --queue-url "$(queue_url "$WORK_QUEUE")" --attribute-names RedrivePolicy --query Attributes.RedrivePolicy --output text | py 'print(json.load(sys.stdin)["maxReceiveCount"])')" 2 "DLQ maxReceiveCount"
assert_eq "$(aws events list-targets-by-rule --rule "$P-order-placed" --event-bus-name "$BUS" --query 'Targets[0].Arn' --output text)" "$(stack_output "$MSG_STACK" OrderEventsTopicArn)" "규칙 대상 = 주문 이벤트 토픽"
echo "LAB03 OK"
