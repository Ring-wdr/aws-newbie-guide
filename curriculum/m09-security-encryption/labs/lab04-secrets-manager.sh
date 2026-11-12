#!/usr/bin/env bash
# M09 lab04 — Secrets Manager: 비밀·버전 스테이지·롤백·Lambda 자동 교체·삭제 복구 (🟢)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

SECRET="todayorder/m09/orders-db"
ALIAS="alias/todayorder-m09-secrets"
FN="todayorder-m09-rotate-orders-db"
ROLE="todayorder-m09-rotation-role"
WORK="$TMP_LIB"
cd "$WORK"

# ---- 이전 실행 정리 (멱등). 강제 삭제는 비동기라 같은 이름을 다시 쓸 수 있을 때까지 기다린다.
if aws secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then
  aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null
  poll 60 "이전 비밀 삭제 완료" sh -c "! aws secretsmanager describe-secret --secret-id '$SECRET' >/dev/null 2>&1"
fi
aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
delete_role "$ROLE"
reset_alias "$ALIAS"

stages() { aws secretsmanager describe-secret --secret-id "$SECRET" --output json | py '
v = json.load(sys.stdin)["VersionIdsToStages"]
for k, s in sorted(v.items(), key=lambda kv: "AWSCURRENT" in kv[1]):
    print("  버전", k[:8] + "…", "→", ", ".join(sorted(s)))'; }
current() { aws secretsmanager get-secret-value --secret-id "$SECRET" "$@" --query SecretString --output text; }

echo "== 1. 비밀 만들기 — 고객 관리형 KMS 키로 암호화"
KEY="$(aws kms create-key --description "TodayOrder 비밀 키" --query KeyMetadata.KeyId --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY"
aws secretsmanager create-secret --name "$SECRET" --kms-key-id "$ALIAS" --description "주문 DB 접속 정보" \
  --secret-string '{"username":"orders_app","password":"v1-Initial!","host":"orders-db.internal","port":5432}' \
  --query '{ARN: ARN, Name: Name}'
echo "ARN 끝의 '-xxxxxx' 6자는 AWS가 붙이는 무작위 접미사다 (같은 이름을 지웠다 다시 만들어도 ARN 이 다르게)"

echo "== 2. 새 값 저장 → AWSCURRENT 는 새 버전으로, AWSPREVIOUS 는 옛 버전으로"
aws secretsmanager put-secret-value --secret-id "$SECRET" \
  --secret-string '{"username":"orders_app","password":"v2-Changed!","host":"orders-db.internal","port":5432}' >/dev/null
stages
echo "AWSCURRENT : $(current)"
echo "AWSPREVIOUS: $(current --version-stage AWSPREVIOUS)"
v2="$(current)"

echo "== 3. 잘못 바꿨다! AWSCURRENT 를 옛 버전으로 되돌리기(롤백)"
cur_id="$(aws secretsmanager describe-secret --secret-id "$SECRET" --output json | py '
print(next(k for k, s in json.load(sys.stdin)["VersionIdsToStages"].items() if "AWSCURRENT" in s))')"
prev_id="$(aws secretsmanager describe-secret --secret-id "$SECRET" --output json | py '
print(next(k for k, s in json.load(sys.stdin)["VersionIdsToStages"].items() if "AWSPREVIOUS" in s))')"
aws secretsmanager update-secret-version-stage --secret-id "$SECRET" --version-stage AWSCURRENT \
  --move-to-version-id "$prev_id" --remove-from-version-id "$cur_id" >/dev/null
stages
rolled_back="$(current)"
echo "롤백 후 AWSCURRENT: $rolled_back"

echo "== 4. Lambda 로 자동 교체 — 교체 함수(4단계: createSecret→setSecret→testSecret→finishSecret)"
cat >lambda_function.py <<'PY'
import json

import boto3

sm = boto3.client("secretsmanager")


def handler(event, context):
    arn, token, step = event["SecretId"], event["ClientRequestToken"], event["Step"]
    print(f"rotation step={step}")
    if step == "createSecret":
        current = json.loads(sm.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"])
        try:
            sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        except sm.exceptions.ResourceNotFoundException:
            current["password"] = sm.get_random_password(PasswordLength=24, ExcludePunctuation=True)["RandomPassword"]
            sm.put_secret_value(SecretId=arn, ClientRequestToken=token,
                                SecretString=json.dumps(current), VersionStages=["AWSPENDING"])
    elif step == "setSecret":
        pass  # 실제 교체 함수는 여기서 DB 사용자의 비밀번호를 AWSPENDING 값으로 바꾼다 (ALTER USER ...)
    elif step == "testSecret":
        pass  # 실제 교체 함수는 여기서 AWSPENDING 값으로 DB 에 접속해 본다
    elif step == "finishSecret":
        stages = sm.describe_secret(SecretId=arn)["VersionIdsToStages"]
        old = next(v for v, s in stages.items() if "AWSCURRENT" in s)
        if old != token:
            sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                           MoveToVersionId=token, RemoveFromVersionId=old)
    return {"step": step}
PY
py 'import zipfile
with zipfile.ZipFile("fn.zip", "w") as z:
    z.write("lambda_function.py")' </dev/null
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --query Role.Arn --output text --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}')"
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET" --query ARN --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name rotate-this-secret --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:PutSecretValue\",
      \"secretsmanager:DescribeSecret\", \"secretsmanager:UpdateSecretVersionStage\"], \"Resource\": \"$SECRET_ARN\"},
    {\"Effect\": \"Allow\", \"Action\": \"secretsmanager:GetRandomPassword\", \"Resource\": \"*\"},
    {\"Effect\": \"Allow\", \"Action\": [\"kms:Decrypt\", \"kms:GenerateDataKey\"], \"Resource\": \"arn:aws:kms:us-east-1:000000000000:key/$KEY\"}]}"
FN_ARN="$(aws lambda create-function --function-name "$FN" --runtime python3.12 --handler lambda_function.handler \
  --role "$ROLE_ARN" --zip-file fileb://fn.zip --timeout 30 --query FunctionArn --output text)"
aws lambda wait function-active-v2 --function-name "$FN"

echo "-- 리소스 정책 없이 교체 설정 (실패해야 정상: Secrets Manager 가 함수를 호출할 권한이 없다)"
expect_error noperm_err aws secretsmanager rotate-secret --secret-id "$SECRET" --rotation-lambda-arn "$FN_ARN" \
  --rotation-rules AutomaticallyAfterDays=30
echo "$noperm_err" | grep -m1 'error occurred'
aws lambda add-permission --function-name "$FN" --statement-id secretsmanager-rotate \
  --action lambda:InvokeFunction --principal secretsmanager.amazonaws.com --source-arn "$SECRET_ARN" >/dev/null
before_rotate="$(current)"
aws secretsmanager rotate-secret --secret-id "$SECRET" --rotation-lambda-arn "$FN_ARN" \
  --rotation-rules AutomaticallyAfterDays=30 --query VersionId --output text >/dev/null
poll 120 "교체 완료(AWSCURRENT 값 변경)" sh -c "[ \"\$(aws secretsmanager get-secret-value --secret-id '$SECRET' --query SecretString --output text)\" != '$before_rotate' ]"
aws secretsmanager describe-secret --secret-id "$SECRET" \
  --query '{RotationEnabled: RotationEnabled, Rules: RotationRules, LastRotated: LastRotatedDate != null}'
stages
after_rotate="$(current)"
echo "교체 후 AWSCURRENT: $after_rotate"

echo "== 5. 삭제는 '복구 기간'(7~30일, 지정하지 않으면 30일)을 거친다 → 그 사이 RestoreSecret 으로 되살릴 수 있다"
aws secretsmanager delete-secret --secret-id "$SECRET" --recovery-window-in-days 7 --query '{Name: Name, DeletionDate: DeletionDate != null}'
expect_error deleted_err current
echo "삭제 예약 중 조회 → $(grep -m1 -o 'InvalidRequestException.*' <<<"$deleted_err")"
aws secretsmanager restore-secret --secret-id "$SECRET" --query Name --output text
restored="$(current)"

# ---- 단언
grep -q 'v2-Changed!' <<<"$v2" || fail "새 값이 AWSCURRENT 가 아님"
grep -q 'v1-Initial!' <<<"$rolled_back" || fail "롤백이 안 됨: $rolled_back"
grep -q 'function policy' <<<"$noperm_err" || fail "리소스 정책 없는 교체 설정이 거부되지 않음: $noperm_err"
[ "$after_rotate" != "$before_rotate" ] || fail "교체 후 값이 같음"
grep -q '"username": "orders_app"' <<<"$after_rotate" || fail "교체 후 사용자 이름이 사라짐: $after_rotate"
grep -q InvalidRequestException <<<"$deleted_err" || fail "삭제 예약된 비밀이 조회됨"
assert_eq "$restored" "$after_rotate" "복구 후 값"
echo "LAB04 OK"
