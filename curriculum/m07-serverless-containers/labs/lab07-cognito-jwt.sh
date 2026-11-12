#!/usr/bin/env bash
# M07 lab07 — Cognito 사용자 풀: 가입·확인·로그인으로 JWT 받기 → HTTP API JWT 권한 부여자로 보호 (🟢)
# + 자격 증명 풀: 로그인한 사용자에게 임시 AWS 자격 증명 발급
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOD="$ROOT/curriculum/m07-serverless-containers"

POOL_NAME=todayorder-customers
IDP_NAME=todayorder_customers_identity
FN=todayorder-whoami
FN_ROLE=todayorder-whoami-role
AUTH_ROLE=todayorder-cognito-authenticated-role
API_NAME=todayorder-member-api
EMAIL=minji@example.com
PASSWORD='Today0rder!2026'

jwt_payload() { # JWT 의 두 번째 부분(payload)을 base64url 디코드
  uv run --quiet --project "$ROOT" python -c \
    'import sys,json,base64; p=sys.argv[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))), ensure_ascii=False, indent=2))' "$1"
}

echo "== 0. 이전 실행 정리 (같은 이름의 사용자 풀·자격 증명 풀·API)"
for id in $(aws cognito-idp list-user-pools --max-results 60 --output json --query "UserPools[?Name=='$POOL_NAME'].Id" | tr -d '[]", ' | grep . || true); do
  aws cognito-idp delete-user-pool --user-pool-id "$id"
done
for id in $(aws cognito-identity list-identity-pools --max-results 60 --output json --query "IdentityPools[?IdentityPoolName=='$IDP_NAME'].IdentityPoolId" | tr -d '[]", ' | grep . || true); do
  aws cognito-identity delete-identity-pool --identity-pool-id "$id"
done
for id in $(aws apigatewayv2 get-apis --output json --query "Items[?Name=='$API_NAME'].ApiId" | tr -d '[]", ' | grep . || true); do
  aws apigatewayv2 delete-api --api-id "$id"
done

echo "== 1. 사용자 풀 (이메일로 로그인, 비밀번호 정책) + 앱 클라이언트 (클라이언트 비밀 없음 = 브라우저·모바일 앱용)"
POOL="$(aws cognito-idp create-user-pool --pool-name "$POOL_NAME" --username-attributes email --auto-verified-attributes email \
  --policies 'PasswordPolicy={MinimumLength=10,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true}' \
  --query UserPool.Id --output text)"
echo "사용자 풀 ID: $POOL"
CLIENT="$(aws cognito-idp create-user-pool-client --user-pool-id "$POOL" --client-name todayorder-web --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH --query UserPoolClient.ClientId --output text)"

echo "== 2. 가입 (SignUp) → 아직 미확인"
aws cognito-idp sign-up --client-id "$CLIENT" --username "$EMAIL" --password "$PASSWORD" \
  --user-attributes Name=email,Value="$EMAIL" --query '{UserConfirmed: UserConfirmed}'
echo "-- 확인 전에 로그인하면:"
if aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$EMAIL,PASSWORD=$PASSWORD" >/dev/null 2>"$WORK/e1"; then fail "미확인 사용자 로그인 성공"; fi
cat "$WORK/e1"

echo "== 3. 확인 (실제로는 이메일 코드로 confirm-sign-up. 실습은 관리자 API 로 대신)"
aws cognito-idp admin-confirm-sign-up --user-pool-id "$POOL" --username "$EMAIL"
echo "-- 틀린 비밀번호:"
if aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$EMAIL,PASSWORD=wrong-Passw0rd!" >/dev/null 2>"$WORK/e2"; then fail "틀린 비밀번호로 로그인 성공"; fi
cat "$WORK/e2"

echo "== 4. 로그인 → 토큰 3종 (ID·액세스·갱신) — 토큰 값은 비밀이라 길이만 출력"
aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$EMAIL,PASSWORD=$PASSWORD" --output json >"$WORK/auth.json"
IDTOKEN="$(uv run --quiet --project "$ROOT" python -c 'import json,sys; print(json.load(open(sys.argv[1]))["AuthenticationResult"]["IdToken"])' "$WORK/auth.json")"
uv run --quiet --project "$ROOT" python -c 'import json,sys; r=json.load(open(sys.argv[1]))["AuthenticationResult"]; print(json.dumps({k: (f"<{len(v)}자>" if k.endswith("Token") else v) for k, v in r.items()}, indent=2, ensure_ascii=False))' "$WORK/auth.json"
echo "-- ID 토큰의 payload (서명된 JSON — 누구나 읽을 수 있으니 비밀을 넣지 않는다):"
jwt_payload "$IDTOKEN" | tee "$WORK/claims.json"
ISSUER="$(uv run --quiet --project "$ROOT" python -c 'import json,sys; print(json.load(open(sys.argv[1]))["iss"])' "$WORK/claims.json")"
echo "발급자(iss): $ISSUER   (실제 AWS: https://cognito-idp.$REGION.amazonaws.com/$POOL)"

echo "== 5. HTTP API 의 GET /me 를 JWT 권한 부여자(사용자 풀)로 보호"
ensure_role "$FN_ROLE" lambda.amazonaws.com
fresh_function "$FN" "$MOD/functions/whoami.py" whoami.handler "arn:aws:iam::$ACCOUNT:role/$FN_ROLE"
API="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --query ApiId --output text)"
INTEG="$(aws apigatewayv2 create-integration --api-id "$API" --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT:function:$FN" --payload-format-version 2.0 --query IntegrationId --output text)"
AUTHZ="$(aws apigatewayv2 create-authorizer --api-id "$API" --name cognito-customers --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --jwt-configuration "Audience=$CLIENT,Issuer=$ISSUER" --query AuthorizerId --output text)"
aws apigatewayv2 create-route --api-id "$API" --route-key 'GET /me' --target "integrations/$INTEG" \
  --authorization-type JWT --authorizer-id "$AUTHZ" --query '{Route: RouteKey, Auth: AuthorizationType}'
aws apigatewayv2 create-stage --api-id "$API" --stage-name '$default' --auto-deploy >/dev/null
aws lambda add-permission --function-name "$FN" --statement-id http-api-me --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API/*/*/me" >/dev/null
B="$(api_base "$API")"
echo "-- 토큰 없이:";        call GET "$B/me" | tee "$WORK/r1"
echo "-- 위조 토큰:";        call GET "$B/me" -H "Authorization: Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJoYWNrZXIifQ.x" | tee "$WORK/r2"
echo "-- 로그인 ID 토큰:";   call GET "$B/me" -H "Authorization: Bearer $IDTOKEN" | tee "$WORK/r3"

echo "== 6. 자격 증명 풀: 로그인한 사용자에게 임시 AWS 자격 증명 (예: 앱이 S3 에 직접 업로드)"
IDP="$(aws cognito-identity create-identity-pool --identity-pool-name "$IDP_NAME" --no-allow-unauthenticated-identities \
  --cognito-identity-providers "ProviderName=cognito-idp.$REGION.amazonaws.com/$POOL,ClientId=$CLIENT" \
  --query IdentityPoolId --output text)"
cat >"$WORK/trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"cognito-identity.amazonaws.com"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{"cognito-identity.amazonaws.com:aud":"$IDP"},
              "ForAnyValue:StringLike":{"cognito-identity.amazonaws.com:amr":"authenticated"}}}]}
JSON
aws iam delete-role-policy --role-name "$AUTH_ROLE" --policy-name upload-own-receipts >/dev/null 2>&1 || true
aws iam delete-role --role-name "$AUTH_ROLE" >/dev/null 2>&1 || true
aws iam create-role --role-name "$AUTH_ROLE" --assume-role-policy-document "file://$WORK/trust.json" >/dev/null
aws iam put-role-policy --role-name "$AUTH_ROLE" --policy-name upload-own-receipts --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::todayorder-uploads/${cognito-identity.amazonaws.com:sub}/*"}]}'
aws cognito-identity set-identity-pool-roles --identity-pool-id "$IDP" --roles "authenticated=arn:aws:iam::$ACCOUNT:role/$AUTH_ROLE"
LOGINS="{\"cognito-idp.$REGION.amazonaws.com/$POOL\":\"$IDTOKEN\"}"
IDENTITY="$(aws cognito-identity get-id --identity-pool-id "$IDP" --logins "$LOGINS" --query IdentityId --output text)"
echo "IdentityId: $IDENTITY"
aws cognito-identity get-credentials-for-identity --identity-id "$IDENTITY" --logins "$LOGINS" \
  --query '{IdentityId: IdentityId, HasAccessKey: length(Credentials.AccessKeyId) > `0`, HasSessionToken: length(Credentials.SessionToken) > `0`, Expiration: Credentials.Expiration}' \
  | tee "$WORK/creds"

# ---- 단언
grep -q UserNotConfirmedException "$WORK/e1" || fail "미확인 로그인 오류"
grep -q NotAuthorizedException "$WORK/e2" || fail "틀린 비밀번호 오류"
grep -q 'HTTP 401' "$WORK/r1" || fail "토큰 없는 요청이 401 이 아님"
grep -q 'HTTP 401' "$WORK/r2" || fail "위조 토큰이 401 이 아님"
grep -q 'HTTP 200' "$WORK/r3" && grep -q "\"email\": \"$EMAIL\"" "$WORK/r3" || fail "유효 토큰 요청"
grep -q '"HasAccessKey": true' "$WORK/creds" || fail "자격 증명 풀 임시 자격 증명"
echo "LAB07 OK"
