#!/usr/bin/env bash
# M09 lab05 — Systems Manager Parameter Store: 계층·SecureString·버전·레이블·티어 (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

P="/todayorder/prod"
ALIAS="alias/todayorder-m09-params"
SECRET="todayorder/m09/payment-gateway"
WORK="$TMP_LIB"
cd "$WORK"

# ---- 이전 실행 정리 (멱등)
for n in $(aws ssm get-parameters-by-path --path /todayorder --recursive --no-paginate --query 'Parameters[].Name' --output text); do
  aws ssm delete-parameter --name "$n"
done
if aws secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then
  aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null
  poll 60 "이전 비밀 삭제 완료" sh -c "! aws secretsmanager describe-secret --secret-id '$SECRET' >/dev/null 2>&1"
fi
reset_alias "$ALIAS"
KEY="$(aws kms create-key --description "TodayOrder 파라미터 키" --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"

echo "== 1. 계층형 이름으로 설정값 넣기 — String / StringList / SecureString"
aws ssm put-parameter --name "$P/api/timeout-ms" --type String --value 3000 --query '{Version: Version, Tier: Tier}'
aws ssm put-parameter --name "$P/api/allowed-origins" --type StringList \
  --value "https://todayorder.example,https://admin.todayorder.example" >/dev/null
aws ssm put-parameter --name "$P/db/password" --type SecureString --value 'S3cr3t-db!' >/dev/null
aws ssm put-parameter --name "$P/payment/api-key" --type SecureString --key-id "$ALIAS" --value 'pk_live_example' >/dev/null
aws ssm put-parameter --name "/todayorder/dev/api/timeout-ms" --type String --value 10000 >/dev/null
aws ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=$P" \
  --query 'Parameters[].[Name, Type, Tier, KeyId || `-`]' --output text

echo "== 2. SecureString 은 WithDecryption 없이 읽으면 암호문"
aws ssm get-parameter --name "$P/db/password" --query 'Parameter.[Type, Value]' --output text
aws ssm get-parameter --name "$P/db/password" --with-decryption --query 'Parameter.[Type, Value]' --output text
dec="$(aws ssm get-parameter --name "$P/db/password" --with-decryption --query Parameter.Value --output text)"
enc="$(aws ssm get-parameter --name "$P/db/password" --query Parameter.Value --output text)"

echo "== 3. 경로로 한꺼번에 — 앱은 시작할 때 자기 환경(prod)의 설정만 읽는다"
aws ssm get-parameters-by-path --path "$P" --recursive --with-decryption --no-paginate \
  --query 'Parameters[].[Name, Value]' --output text
n_rec="$(aws ssm get-parameters-by-path --path "$P" --recursive --no-paginate --query 'length(Parameters)' --output text)"
n_flat="$(aws ssm get-parameters-by-path --path "$P" --no-paginate --query 'length(Parameters)' --output text)"
echo "Recursive: ${n_rec}개 · Recursive 없이(바로 아래 단계만): ${n_flat}개"

echo "== 4. SecureString 의 복호화는 KMS 를 거친다 — 키 정책으로 Decrypt 를 막으면 그 파라미터만 못 읽는다"
DEFAULT_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"EnableIAMUserPermissions","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:root"},"Action":"kms:*","Resource":"*"}]}'
aws kms put-key-policy --key-id "$KEY" --policy-name default --policy '{"Version":"2012-10-17","Statement":[
  {"Sid":"EnableIAMUserPermissions","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::000000000000:root"},"Action":"kms:*","Resource":"*"},
  {"Sid":"FreezePaymentKey","Effect":"Deny","Principal":{"AWS":"*"},"Action":"kms:Decrypt","Resource":"*"}]}'
expect_error param_err aws ssm get-parameter --name "$P/payment/api-key" --with-decryption
echo "payment/api-key(고객 관리형 키) → $(grep -m1 -oE 'AccessDeniedException.*explicit deny[a-z -]*' <<<"$param_err")"
still="$(aws ssm get-parameter --name "$P/db/password" --with-decryption --query Parameter.Value --output text)"
echo "db/password(aws/ssm 키) → $still"
aws kms put-key-policy --key-id "$KEY" --policy-name default --policy "$DEFAULT_POLICY"
echo "-- 참고: 키를 '비활성화'하는 것으로는 에뮬레이터의 SSM 복호화가 막히지 않는다 (AWS와 다름)"
aws kms disable-key --key-id "$KEY"
disabled_read="$(aws ssm get-parameter --name "$P/payment/api-key" --with-decryption --query Parameter.Value --output text 2>&1 || true)"
echo "비활성 키로 payment/api-key → $disabled_read"
aws kms enable-key --key-id "$KEY"

echo "== 5. 덮어쓰기는 --overwrite, 버전 이력과 레이블"
expect_error exists_err aws ssm put-parameter --name "$P/api/timeout-ms" --type String --value 5000
echo "$exists_err" | grep -m1 'error occurred'
aws ssm put-parameter --name "$P/api/timeout-ms" --type String --value 5000 --overwrite --query Version --output text
aws ssm get-parameter-history --name "$P/api/timeout-ms" --query 'Parameters[].[Version, Value]' --output text
aws ssm label-parameter-version --name "$P/api/timeout-ms" --parameter-version 1 --labels stable --query ParameterVersion --output text
by_label="$(aws ssm get-parameter --name "$P/api/timeout-ms:stable" --query Parameter.Value --output text)"
by_version="$(aws ssm get-parameter --name "$P/api/timeout-ms:2" --query Parameter.Value --output text)"
echo "이름:stable → $by_label · 이름:2 → $by_version"

echo "== 6. 티어 — Standard 는 값 4KB(4096자)까지, 더 크면 Advanced"
big="$(head -c 5000 /dev/zero | tr '\0' 'x')"
expect_error tier_err aws ssm put-parameter --name "$P/feature/big-config" --type String --value "$big"
echo "$tier_err" | grep -m1 -o 'ValidationException.*4096 characters'
aws ssm put-parameter --name "$P/feature/big-config" --type String --value "$big" --tier Advanced --query Tier --output text

echo "== 7. Parameter Store 에서 Secrets Manager 비밀 참조하기 (/aws/reference/secretsmanager/…)"
aws secretsmanager create-secret --name "$SECRET" --secret-string '{"apiKey":"pg_live_example"}' >/dev/null
ref="$(aws ssm get-parameter --name "/aws/reference/secretsmanager/$SECRET" --with-decryption --query Parameter.Value --output text)"
echo "$ref"

# ---- 단언
assert_eq "$dec" 'S3cr3t-db!' "SecureString 복호화"
[ "$enc" != "$dec" ] || fail "WithDecryption 없이도 평문이 나옴"
assert_eq "$n_rec" "4" "Recursive 조회 개수"
assert_eq "$n_flat" "0" "Recursive 없는 조회 개수"
grep -q AccessDeniedException <<<"$param_err" || fail "키 정책 Deny 인데 SecureString 이 복호화됨: $param_err"
[ "$disabled_read" = "pk_live_example" ] || echo "참고: 비활성 키로 SSM 복호화가 이제 실패한다 — README 갱신 ($disabled_read)"
assert_eq "$still" 'S3cr3t-db!' "aws/ssm 키 파라미터는 영향 없음"
grep -q ParameterAlreadyExists <<<"$exists_err" || fail "--overwrite 없이 덮어써짐"
assert_eq "$by_label" "3000" "레이블 조회"
assert_eq "$by_version" "5000" "버전 조회"
grep -q 4096 <<<"$tier_err" || fail "Standard 4KB 초과가 거부되지 않음"
assert_eq "$ref" '{"apiKey":"pg_live_example"}' "Secrets Manager 참조"
echo "LAB05 OK"
