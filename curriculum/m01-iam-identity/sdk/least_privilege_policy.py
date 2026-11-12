"""M01 — boto3: 최소 권한 정책 생성기.

"이 워커는 무엇을, 어디에 하는가"를 (액션, 리소스 ARN) 목록으로 적으면
1) 같은 리소스끼리 묶어 Statement 를 만들고 (와일드카드 액션 금지),
2) IAM 이 실제로 받아 주는 문서인지 CreatePolicy 로 검증한 뒤,
3) iam:SimulateCustomPolicy 로 "필요한 것은 allowed, 그 밖은 implicitDeny" 를 확인한다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m01-iam-identity/sdk/least_privilege_policy.py

코드에 엔드포인트·자격 증명이 없다. boto3가 환경 변수(AWS_ENDPOINT_URL 등)를 읽는다.
require_emulator() 는 클라이언트를 만들기 전에 에뮬레이터인지 확인한다.
"""

from __future__ import annotations

import json
import re
from collections import OrderedDict
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

ACCOUNT = "000000000000"
REGION = "us-east-1"
POLICY_NAME = "todayorder-order-worker-least-privilege"
MANAGED_POLICY_MAX_CHARS = 6144  # 고객 관리형 정책 최대 크기(공백 제외) — IAM 할당량 문서 기준


@dataclass(frozen=True)
class Need:
    """워커가 필요로 하는 권한 하나: 어떤 액션을 어떤 리소스에."""

    action: str
    resource: str


# TodayOrder 주문 워커: 큐에서 주문을 꺼내 DynamoDB에 저장하고, 영수증 JSON을 S3에 쓴다.
ORDER_WORKER_NEEDS: list[Need] = [
    Need("sqs:ReceiveMessage", f"arn:aws:sqs:{REGION}:{ACCOUNT}:todayorder-orders"),
    Need("sqs:DeleteMessage", f"arn:aws:sqs:{REGION}:{ACCOUNT}:todayorder-orders"),
    Need("sqs:GetQueueAttributes", f"arn:aws:sqs:{REGION}:{ACCOUNT}:todayorder-orders"),
    Need("dynamodb:PutItem", f"arn:aws:dynamodb:{REGION}:{ACCOUNT}:table/todayorder-orders"),
    Need("dynamodb:GetItem", f"arn:aws:dynamodb:{REGION}:{ACCOUNT}:table/todayorder-orders"),
    Need("s3:PutObject", "arn:aws:s3:::todayorder-receipts/receipts/*"),
]

# 워커가 하면 안 되는 일 — 생성된 정책에서 거부되어야 한다.
MUST_BE_DENIED: list[Need] = [
    Need("dynamodb:DeleteTable", f"arn:aws:dynamodb:{REGION}:{ACCOUNT}:table/todayorder-orders"),
    Need("dynamodb:PutItem", f"arn:aws:dynamodb:{REGION}:{ACCOUNT}:table/todayorder-payments"),
    Need("s3:GetObject", "arn:aws:s3:::todayorder-receipts/receipts/A-1001.json"),
    Need("s3:PutObject", "arn:aws:s3:::todayorder-images/logo.png"),
    Need("sqs:SendMessage", f"arn:aws:sqs:{REGION}:{ACCOUNT}:todayorder-orders"),
    Need("iam:CreateUser", f"arn:aws:iam::{ACCOUNT}:user/anyone"),
]


def build_policy(needs: list[Need]) -> dict:
    """리소스별로 액션을 모아 Statement 를 만든다. '*' 액션은 거부한다."""
    by_resource: "OrderedDict[str, list[str]]" = OrderedDict()
    for n in needs:
        if "*" in n.action:
            raise ValueError(f"최소 권한 위반: 와일드카드 액션 {n.action!r}")
        by_resource.setdefault(n.resource, [])
        if n.action not in by_resource[n.resource]:
            by_resource[n.resource].append(n.action)

    statements = []
    for resource, actions in by_resource.items():
        service = actions[0].split(":")[0]
        tail = re.sub(r"[^A-Za-z0-9]", "", resource.split(":")[-1].title())[:40]
        statements.append(
            {
                "Sid": f"{service.capitalize()}{tail}",
                "Effect": "Allow",
                "Action": sorted(actions),
                "Resource": resource,
            }
        )
    return {"Version": "2012-10-17", "Statement": statements}


def policy_size(doc: dict) -> int:
    """IAM 은 공백을 빼고 센다."""
    return len(re.sub(r"\s", "", json.dumps(doc)))


def simulate(iam, doc: dict, needs: list[Need]) -> dict[Need, str]:  # type: ignore[no-untyped-def]
    """각 (액션, 리소스)를 시뮬레이션한다. 리소스의 '*' 는 실제 객체 키 예시로 바꿔 평가한다."""
    results: dict[Need, str] = {}
    for n in needs:
        sample = Need(n.action, n.resource.replace("*", "2026/11/A-1001.json"))
        r = iam.simulate_custom_policy(
            PolicyInputList=[json.dumps(doc)], ActionNames=[sample.action], ResourceArns=[sample.resource]
        )
        results[sample] = r["EvaluationResults"][0]["EvalDecision"]
    return results


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    doc = build_policy(ORDER_WORKER_NEEDS)
    print("생성된 정책:")
    print(json.dumps(doc, indent=2))
    size = policy_size(doc)
    print(f"크기: {size}자 (관리형 정책 한도 {MANAGED_POLICY_MAX_CHARS}자)")
    assert size <= MANAGED_POLICY_MAX_CHARS

    try:
        build_policy([Need("s3:*", "*")])
    except ValueError as e:
        print(f"와일드카드 거부 확인: {e}")

    iam = boto3.client("iam")
    arn = f"arn:aws:iam::{ACCOUNT}:policy/{POLICY_NAME}"
    try:
        iam.delete_policy(PolicyArn=arn)  # 이전 실행의 흔적 (멱등)
    except ClientError:
        pass

    # IAM 의 문법 검사를 통과하는가
    created = iam.create_policy(PolicyName=POLICY_NAME, PolicyDocument=json.dumps(doc))
    print(f"CreatePolicy 통과: {created['Policy']['Arn']} ({created['Policy']['DefaultVersionId']})")

    # 잘못된 문서는 IAM 이 거부한다 (Resource 누락)
    try:
        bad = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:GetObject"}]}
        iam.create_policy(PolicyName=POLICY_NAME + "-bad", PolicyDocument=json.dumps(bad))
        raise AssertionError("Resource 없는 정책이 받아들여졌다")
    except ClientError as e:
        print(f"잘못된 문서: {e.response['Error']['Code']} — {e.response['Error']['Message']}")

    print("\n시뮬레이션 — 필요한 권한:")
    allowed = simulate(iam, doc, ORDER_WORKER_NEEDS)
    for n, d in allowed.items():
        print(f"  {d:13} {n.action:22} {n.resource}")
    print("시뮬레이션 — 없어야 할 권한:")
    denied = simulate(iam, doc, MUST_BE_DENIED)
    for n, d in denied.items():
        print(f"  {d:13} {n.action:22} {n.resource}")

    iam.delete_policy(PolicyArn=arn)
    assert all(d == "allowed" for d in allowed.values()), allowed
    assert all(d == "implicitDeny" for d in denied.values()), denied
    print("SDK least_privilege_policy OK")


if __name__ == "__main__":
    main()
