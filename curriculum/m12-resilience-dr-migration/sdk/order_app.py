"""M12 — 리전을 모르는(region-agnostic) TodayOrder 주문 앱.

이 앱은 자기가 어느 리전에서 도는지 모른다. 연결 대상은 오직 환경 변수(AWS_ENDPOINT_URL 등,
scripts/env.sh 가 EMULATOR_PORT 로 정한다)로 결정되고, 리전별로 달라지는 설정(영수증 버킷 이름)은
그 리전의 Parameter Store(`/todayorder/receipts-bucket`)에서 읽는다. 그래서 장애 조치(failover)는
"코드를 바꾸는 일"이 아니라 "어디를 바라볼지(EMULATOR_PORT)를 바꾸는 일"이 된다.

실행 (저장소 루트에서):
    export EMULATOR_PORT=9312 && source scripts/env.sh       # 서울(주 리전)
    uv run python curriculum/m12-resilience-dr-migration/sdk/order_app.py bootstrap todayorder-receipts-seoul
    uv run python curriculum/m12-resilience-dr-migration/sdk/order_app.py place A-1001 12000
    uv run python curriculum/m12-resilience-dr-migration/sdk/order_app.py list
    uv run python curriculum/m12-resilience-dr-migration/sdk/order_app.py          # 인자 없음: 자급자족 데모

하위 명령
    bootstrap <버킷>     이 리전에 테이블·버킷·설정 파라미터를 만든다 (이미 있으면 그대로 둔다)
    place <주문ID> <금액> 주문을 테이블에 쓰고 영수증 JSON 을 버킷에 올린다
    list                 주문 목록과 영수증 수를 출력한다
    (없음)               데모: 데모용 버킷으로 bootstrap → 주문 1건 → list → 데모 주문 정리
"""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

TABLE = "todayorder-orders"
PARAM = "/todayorder/receipts-bucket"
DEMO_BUCKET = "todayorder-m12-app-demo"


def wait_table_active(ddb: Any, table: str, timeout: float = 60.0) -> None:
    deadline = time.monotonic() + timeout
    status = "?"
    while time.monotonic() < deadline:
        status = ddb.describe_table(TableName=table)["Table"]["TableStatus"]
        if status == "ACTIVE":
            return
        time.sleep(0.5)
    raise SystemExit(f"테이블 {table} 이 {timeout:.0f}초 안에 ACTIVE 가 되지 않음 (마지막 상태 {status})")


def bootstrap(ddb: Any, s3: Any, ssm: Any, bucket: str) -> None:
    try:
        ddb.create_table(
            TableName=TABLE,
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": "orderId", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "orderId", "KeyType": "HASH"}],
        )
        print(f"테이블 생성: {TABLE}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            raise
        print(f"테이블 있음: {TABLE}")
    wait_table_active(ddb, TABLE)
    try:
        s3.head_bucket(Bucket=bucket)
        print(f"버킷 있음: {bucket}")
    except ClientError:
        s3.create_bucket(Bucket=bucket)
        print(f"버킷 생성: {bucket}")
    ssm.put_parameter(Name=PARAM, Value=bucket, Type="String", Overwrite=True)
    print(f"설정: {PARAM} = {bucket}")


def receipts_bucket(ssm: Any) -> str:
    try:
        return ssm.get_parameter(Name=PARAM)["Parameter"]["Value"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "ParameterNotFound":
            raise SystemExit(f"이 리전에 {PARAM} 이 없습니다. 먼저 'bootstrap <버킷>' 을 실행하세요.") from None
        raise


def place(ddb: Any, s3: Any, ssm: Any, order_id: str, amount: int) -> None:
    bucket = receipts_bucket(ssm)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    ddb.put_item(
        TableName=TABLE,
        Item={"orderId": {"S": order_id}, "amount": {"N": str(amount)}, "createdAt": {"S": now}},
    )
    receipt = {"orderId": order_id, "total": amount, "currency": "KRW", "createdAt": now}
    s3.put_object(Bucket=bucket, Key=f"receipts/{order_id}.json", Body=json.dumps(receipt).encode(),
                  ContentType="application/json")
    print(f"주문 저장: {order_id} ({amount}원) → 테이블 {TABLE}, s3://{bucket}/receipts/{order_id}.json")


def list_orders(ddb: Any, s3: Any, ssm: Any) -> list[str]:
    bucket = receipts_bucket(ssm)
    ids: list[str] = []
    for page in ddb.get_paginator("scan").paginate(TableName=TABLE):
        ids += [it["orderId"]["S"] for it in page.get("Items", [])]
    ids.sort()
    receipts = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="receipts/"):
        receipts += len(page.get("Contents", []))
    print(f"주문 {len(ids)}건: {', '.join(ids) if ids else '(없음)'}")
    print(f"영수증 {receipts}개 (s3://{bucket}/receipts/)")
    return ids


def main(argv: list[str]) -> None:
    endpoint = require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    ddb, s3, ssm = boto3.client("dynamodb"), boto3.client("s3"), boto3.client("ssm")
    print(f"[order_app] 연결 대상: {endpoint} (리전 {ddb.meta.region_name})")

    cmd = argv[0] if argv else "demo"
    if cmd == "bootstrap" and len(argv) == 2:
        bootstrap(ddb, s3, ssm, argv[1])
    elif cmd == "place" and len(argv) == 3:
        place(ddb, s3, ssm, argv[1], int(argv[2]))
    elif cmd == "list" and len(argv) == 1:
        list_orders(ddb, s3, ssm)
    elif cmd == "demo" and not argv:
        # 이미 bootstrap 된 리전이면 그 설정을 그대로 쓰고, 아니면 데모 버킷으로 bootstrap 한다.
        try:
            ssm.get_parameter(Name=PARAM)
            print(f"이미 bootstrap 된 리전입니다 ({PARAM} 있음)")
        except ClientError:
            bootstrap(ddb, s3, ssm, DEMO_BUCKET)
        place(ddb, s3, ssm, "DEMO-0001", 5000)
        ids = list_orders(ddb, s3, ssm)
        assert "DEMO-0001" in ids
        ddb.delete_item(TableName=TABLE, Key={"orderId": {"S": "DEMO-0001"}})
        s3.delete_object(Bucket=receipts_bucket(ssm), Key="receipts/DEMO-0001.json")
        print("데모 주문 정리 완료")
        print("SDK order_app OK")
    else:
        print(__doc__)
        raise SystemExit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
