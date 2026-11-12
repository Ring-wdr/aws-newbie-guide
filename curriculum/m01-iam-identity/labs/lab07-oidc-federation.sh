#!/usr/bin/env bash
# M01 lab07 — 자격 증명 연동: GitHub Actions(OIDC) 배포 역할 구성 (🟡)
# 액세스 키를 CI 비밀 값에 넣는 대신, CI 가 발급받은 OIDC 토큰으로 역할을 맡게 하는 구성을 만든다.
#   1) IAM OIDC 자격 증명 공급자(token.actions.githubusercontent.com) 등록
#   2) 신뢰 정책 Principal 이 Federated 인 역할 + 조건(aud, sub = 저장소·브랜치)
#   3) 일반 sts:AssumeRole 로는 이 역할을 맡을 수 없음을 확인
# 실제 토큰 교환(AssumeRoleWithWebIdentity)은 하지 않는다: 에뮬레이터가 토큰 서명을 검증하려고
# 발급자(GitHub)의 공개 키를 가져오려 하며, 이 실습은 외부로 나가는 요청을 만들지 않는다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ACCOUNT=000000000000
ISSUER=token.actions.githubusercontent.com
PROVIDER_ARN="arn:aws:iam::$ACCOUNT:oidc-provider/$ISSUER"
ROLE=todayorder-gha-deploy

cleanup() {
  delete_role_fully "$ROLE"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1 || true
}
cleanup

echo "== 1. OIDC 자격 증명 공급자 등록"
# 지문(thumbprint)은 예시 값이다. 실제 AWS는 GitHub 같은 주요 공급자에 대해 자체 신뢰 루트로 검증한다.
aws iam create-open-id-connect-provider --url "https://$ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn'

echo "== 2. 배포 역할: main 브랜치의 todayorder/api 저장소 워크플로만 맡을 수 있다"
TRUST="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Federated": "$PROVIDER_ARN"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {"$ISSUER:aud": "sts.amazonaws.com"},
        "StringLike": {"$ISSUER:sub": "repo:todayorder/api:ref:refs/heads/main"}
      }
    }
  ]
}
EOF
)"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
  --max-session-duration 3600 --query 'Role.Arn' --output text
aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-artifacts --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::todayorder-deploy-artifacts/*"}]
}'
trust_back="$(aws iam get-role --role-name "$ROLE" --query 'Role.AssumeRolePolicyDocument.Statement[0]' --output json)"
echo "$trust_back"

echo "== 3. 일반 AssumeRole 로는 맡을 수 없다 (신뢰 정책의 주체가 Federated 이므로)"
expect_fail aws sts assume-role --role-arn "arn:aws:iam::$ACCOUNT:role/$ROLE" --role-session-name local
e_assume="$ERR"

# ---- 단언
must_contain "$trust_back" "\"Federated\": \"$PROVIDER_ARN\"" "Federated 주체"
must_contain "$trust_back" "repo:todayorder/api:ref:refs/heads/main" "sub 조건"
must_contain "$e_assume" "AccessDenied" "일반 AssumeRole 거부"

cleanup
echo "LAB07 OK"
