"""M01 — boto3: 역할을 맡아(AssumeRole) 그 임시 자격 증명으로 새 세션 만들기.

lab02 를 코드로 옮긴 것이다. 백엔드 코드에서 "다른 권한으로 잠깐 일하기"
(운영 조회 역할, 교차 계정 역할)는 이렇게 한다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m01-iam-identity/sdk/assume_role_session.py

엔드포인트를 코드에 쓰지 않는다. 임시 자격 증명으로 만든 Session 도 AWS_ENDPOINT_URL 을 그대로 쓴다.
"""

from __future__ import annotations

import json

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

ROLE_NAME = "todayorder-sdk-ops-readonly"
SESSION_NAME = "sdk-oncall"


def ensure_role(iam, account: str) -> str:  # type: ignore[no-untyped-def]
    """같은 계정의 IAM 주체가 맡을 수 있는 조회 전용 역할을 (다시) 만든다."""
    try:
        for name in iam.list_role_policies(RoleName=ROLE_NAME)["PolicyNames"]:
            iam.delete_role_policy(RoleName=ROLE_NAME, PolicyName=name)
        iam.delete_role(RoleName=ROLE_NAME)
    except ClientError:
        pass
    trust = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"AWS": f"arn:aws:iam::{account}:root"},
                "Action": "sts:AssumeRole",
            }
        ],
    }
    role = iam.create_role(RoleName=ROLE_NAME, AssumeRolePolicyDocument=json.dumps(trust))
    iam.put_role_policy(
        RoleName=ROLE_NAME,
        PolicyName="describe-only",
        PolicyDocument=json.dumps(
            {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "ec2:Describe*", "Resource": "*"}]}
        ),
    )
    return role["Role"]["Arn"]


def session_for_role(sts, role_arn: str, seconds: int = 900) -> boto3.session.Session:  # type: ignore[no-untyped-def]
    """AssumeRole 결과로 새 boto3 Session 을 만든다. 만료되면 다시 호출해야 한다."""
    c = sts.assume_role(RoleArn=role_arn, RoleSessionName=SESSION_NAME, DurationSeconds=seconds)["Credentials"]
    print(f"임시 키 ID: {c['AccessKeyId'][:8]}…  만료: {c['Expiration'].isoformat()}")
    return boto3.session.Session(
        aws_access_key_id=c["AccessKeyId"],
        aws_secret_access_key=c["SecretAccessKey"],
        aws_session_token=c["SessionToken"],
    )


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    sts = boto3.client("sts")
    me = sts.get_caller_identity()
    print(f"원래 나: {me['Arn']}")
    iam = boto3.client("iam")
    role_arn = ensure_role(iam, me["Account"])

    role_session = session_for_role(sts, role_arn)
    who = role_session.client("sts").get_caller_identity()["Arn"]
    print(f"역할을 맡은 나: {who}")
    assert who.endswith(f"assumed-role/{ROLE_NAME}/{SESSION_NAME}"), who

    vpcs = role_session.client("ec2").describe_vpcs()["Vpcs"]
    print(f"ec2:DescribeVpcs 허용 — VPC {len(vpcs)}개")

    try:
        role_session.client("iam").create_user(UserName="todayorder-sdk-should-not-exist")
        raise AssertionError("역할 권한 밖의 호출이 허용되었다")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        print(f"iam:CreateUser 거부 — {code}")
        assert code == "AccessDenied", code

    iam.delete_role_policy(RoleName=ROLE_NAME, PolicyName="describe-only")
    iam.delete_role(RoleName=ROLE_NAME)
    print("SDK assume_role_session OK")


if __name__ == "__main__":
    main()
