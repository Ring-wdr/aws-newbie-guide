"""M07 — Lambda 함수 배포와 세 가지 호출 유형을 boto3로.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m07-serverless-containers/sdk/lambda_invoke.py

하는 일
1. 실행 역할(신뢰: lambda.amazonaws.com)을 만들고, functions/order_status.py 를 메모리에서 zip 으로 묶어 배포한다.
2. waiter(function_active_v2)로 Active 를 기다린다.
3. RequestResponse(동기) / Event(비동기) / DryRun 으로 호출하고, 함수 오류(FunctionError)를
   예외(ClientError)와 구분해서 처리한다 — Invoke 자체는 성공(200)했지만 함수가 실패한 경우다.
4. 정리한다.
"""

from __future__ import annotations

import io
import json
import zipfile
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

FUNCTION = "todayorder-sdk-order-status"
ROLE = "todayorder-sdk-lambda-role"
SOURCE = Path(__file__).resolve().parent.parent / "functions" / "order_status.py"
TRUST = {
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}],
}


def build_zip(source: Path) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(source, source.name)
    return buf.getvalue()


def ensure_role(iam: Any) -> str:
    try:
        return iam.get_role(RoleName=ROLE)["Role"]["Arn"]
    except ClientError:
        return iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(TRUST))["Role"]["Arn"]


def invoke(lam: Any, payload: dict[str, Any], invocation_type: str = "RequestResponse") -> dict[str, Any]:
    """Invoke 한 번. 함수 오류는 예외가 아니라 응답의 FunctionError 로 온다는 점에 주의."""
    resp = lam.invoke(FunctionName=FUNCTION, InvocationType=invocation_type, Payload=json.dumps(payload).encode())
    body = resp["Payload"].read()
    result: dict[str, Any] = {"StatusCode": resp["StatusCode"]}
    if resp.get("FunctionError"):
        err = json.loads(body)
        result["FunctionError"] = resp["FunctionError"]
        result["error"] = f"{err['errorType']}: {err['errorMessage']}"
    elif body:
        result["payload"] = json.loads(body)
    return result


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    iam = boto3.client("iam")
    lam = boto3.client("lambda")
    role_arn = ensure_role(iam)

    try:
        lam.delete_function(FunctionName=FUNCTION)
    except lam.exceptions.ResourceNotFoundException:
        pass
    created = lam.create_function(
        FunctionName=FUNCTION,
        Runtime="python3.12",
        Handler="order_status.handler",
        Role=role_arn,
        Code={"ZipFile": build_zip(SOURCE)},
        Timeout=3,
        Environment={"Variables": {"APP_VERSION": "sdk"}},
    )
    print(f"생성: {created['FunctionName']} State={created['State']}")
    lam.get_waiter("function_active_v2").wait(FunctionName=FUNCTION)
    print(f"대기 후 State={lam.get_function(FunctionName=FUNCTION)['Configuration']['State']}")

    ok = invoke(lam, {"orderId": "S-7001"})
    print(f"[동기] {ok}")
    assert ok["StatusCode"] == 200 and ok["payload"]["status"] == "PAID"

    bad = invoke(lam, {})
    print(f"[동기, 함수 오류] {bad}")
    assert bad["StatusCode"] == 200 and bad["FunctionError"] == "Unhandled"

    ev = invoke(lam, {"orderId": "S-7002"}, "Event")
    print(f"[비동기] {ev}")
    assert ev["StatusCode"] == 202

    dry = invoke(lam, {"orderId": "S-7003"}, "DryRun")
    print(f"[DryRun] {dry}")
    assert dry["StatusCode"] == 204

    # Invoke 자체가 실패하는 경우(없는 함수) → 이건 ClientError 예외다
    try:
        lam.invoke(FunctionName=FUNCTION + "-nope", Payload=b"{}")
    except ClientError as e:
        print(f"[없는 함수] {e.response['Error']['Code']} (HTTP {e.response['ResponseMetadata']['HTTPStatusCode']})")

    lam.delete_function(FunctionName=FUNCTION)
    iam.delete_role(RoleName=ROLE)
    print("정리 완료")
    print("SDK lambda_invoke OK")


if __name__ == "__main__":
    main()
