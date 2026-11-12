"""M07 — Cognito 사용자 풀 가입·로그인과 JWT 읽기를 boto3로.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m07-serverless-containers/sdk/cognito_login.py

웹·모바일 백엔드가 하는 일을 순서대로 해 본다: 사용자 풀·앱 클라이언트 생성 → 가입 → 확인 →
로그인(USER_PASSWORD_AUTH) → ID 토큰의 클레임 읽기 → 갱신 토큰으로 새 토큰 받기 → 정리.

주의: 여기서는 토큰의 payload 를 **읽기만** 한다. 서명 검증은 하지 않는다. 실제 서비스에서 토큰을
신뢰하려면 사용자 풀의 JWKS 공개 키로 서명·만료·aud/iss 를 검증해야 한다(API Gateway JWT 권한
부여자가 대신 해 주는 일 — lab07).
"""

from __future__ import annotations

import base64
import json
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

POOL_NAME = "todayorder-sdk-customers"
EMAIL = "sdk-user@example.com"
PASSWORD = "Sdk-Passw0rd!2026"


def claims(token: str) -> dict[str, Any]:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def delete_pools(idp: Any) -> None:
    for pool in idp.list_user_pools(MaxResults=60)["UserPools"]:
        if pool["Name"] == POOL_NAME:
            idp.delete_user_pool(UserPoolId=pool["Id"])


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    idp = boto3.client("cognito-idp")
    delete_pools(idp)
    pool_id = idp.create_user_pool(PoolName=POOL_NAME, UsernameAttributes=["email"])["UserPool"]["Id"]
    client_id = idp.create_user_pool_client(
        UserPoolId=pool_id,
        ClientName="todayorder-sdk",
        GenerateSecret=False,
        ExplicitAuthFlows=["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    )["UserPoolClient"]["ClientId"]
    print(f"사용자 풀: {pool_id}")

    signup = idp.sign_up(
        ClientId=client_id, Username=EMAIL, Password=PASSWORD, UserAttributes=[{"Name": "email", "Value": EMAIL}]
    )
    print(f"가입: UserConfirmed={signup['UserConfirmed']}")

    try:
        idp.initiate_auth(
            ClientId=client_id, AuthFlow="USER_PASSWORD_AUTH", AuthParameters={"USERNAME": EMAIL, "PASSWORD": PASSWORD}
        )
    except idp.exceptions.UserNotConfirmedException as e:
        print(f"확인 전 로그인: {e.response['Error']['Code']}")

    idp.admin_confirm_sign_up(UserPoolId=pool_id, Username=EMAIL)
    auth = idp.initiate_auth(
        ClientId=client_id, AuthFlow="USER_PASSWORD_AUTH", AuthParameters={"USERNAME": EMAIL, "PASSWORD": PASSWORD}
    )["AuthenticationResult"]
    id_claims = claims(auth["IdToken"])
    access_claims = claims(auth["AccessToken"])
    print(f"로그인: ExpiresIn={auth['ExpiresIn']}  토큰={sorted(k for k in auth if k.endswith('Token'))}")
    print(f"ID 토큰: token_use={id_claims['token_use']} email={id_claims['email']} aud==클라이언트 ID? {id_claims['aud'] == client_id}")
    print(f"액세스 토큰: token_use={access_claims['token_use']} client_id==클라이언트 ID? {access_claims['client_id'] == client_id}")

    me = idp.get_user(AccessToken=auth["AccessToken"])
    print(f"GetUser(액세스 토큰): {[(a['Name'], a['Value']) for a in me['UserAttributes'] if a['Name'] == 'email']}")

    refreshed = idp.initiate_auth(
        ClientId=client_id, AuthFlow="REFRESH_TOKEN_AUTH", AuthParameters={"REFRESH_TOKEN": auth["RefreshToken"]}
    )["AuthenticationResult"]
    print(f"갱신: 새 ID 토큰 받음={bool(refreshed.get('IdToken'))}, 갱신 토큰 재발급={bool(refreshed.get('RefreshToken'))}")

    try:
        idp.initiate_auth(
            ClientId=client_id, AuthFlow="USER_PASSWORD_AUTH", AuthParameters={"USERNAME": EMAIL, "PASSWORD": "Wrong-Passw0rd!"}
        )
    except ClientError as e:
        print(f"틀린 비밀번호: {e.response['Error']['Code']}")

    assert id_claims["email"] == EMAIL and id_claims["token_use"] == "id"
    assert access_claims["token_use"] == "access"
    delete_pools(idp)
    print("정리 완료")
    print("SDK cognito_login OK")


if __name__ == "__main__":
    main()
