"""M00 레슨 5 — boto3의 네 가지 도구: client, resource, paginator, waiter.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m00-orientation/sdk/client_resource_paginator_waiter.py
"""

from __future__ import annotations

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

BUCKET = "todayorder-m00-boto3-tools"
TABLE = "todayorder-m00-boto3-orders"


def cleanup(s3, ddb) -> None:  # type: ignore[no-untyped-def]
    try:
        boto3.resource("s3").Bucket(BUCKET).objects.all().delete()
        s3.delete_bucket(Bucket=BUCKET)
    except ClientError:
        pass
    try:
        ddb.delete_table(TableName=TABLE)
        ddb.get_waiter("table_not_exists").wait(TableName=TABLE, WaiterConfig={"Delay": 1, "MaxAttempts": 30})
    except ClientError:
        pass


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    s3 = boto3.client("s3")
    ddb = boto3.client("dynamodb")
    cleanup(s3, ddb)

    # 1) client: AWS API와 1:1 대응하는 저수준 인터페이스. 응답은 dict.
    s3.create_bucket(Bucket=BUCKET)
    for i in range(1, 8):
        s3.put_object(Bucket=BUCKET, Key=f"orders/A-{1000 + i}.txt", Body=f"order {i}".encode())
    resp = s3.list_objects_v2(Bucket=BUCKET, MaxKeys=3)
    print(f"[client] 한 번 호출: {resp['KeyCount']}건, IsTruncated={resp['IsTruncated']}")

    # 2) paginator: NextContinuationToken 을 대신 따라가 준다.
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, PaginationConfig={"PageSize": 3})
    sizes = [len(p.get("Contents", [])) for p in pages]
    print(f"[paginator] 페이지별 건수: {sizes} → 합계 {sum(sizes)}")
    assert sum(sizes) == 7

    # 3) resource: 객체 지향 고수준 인터페이스 (AWS가 신규 기능 추가를 중단한 '동결' 상태 — 새 코드는 client 권장)
    bucket = boto3.resource("s3").Bucket(BUCKET)
    keys = sorted(o.key for o in bucket.objects.filter(Prefix="orders/"))
    print(f"[resource] 첫 키 {keys[0]}, 마지막 키 {keys[-1]}")

    # 4) waiter: "원하는 상태가 될 때까지" 폴링해 준다.
    created = ddb.create_table(
        TableName=TABLE,
        AttributeDefinitions=[{"AttributeName": "orderId", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "orderId", "KeyType": "HASH"}],
        BillingMode="PAY_PER_REQUEST",
    )
    # 생성 응답의 상태는 항상 CREATING. (직후에 describe_table 을 부르면 CREATING/ACTIVE 가 실행마다 다르다)
    print(f"[waiter] create_table 응답의 상태: {created['TableDescription']['TableStatus']}")
    ddb.get_waiter("table_exists").wait(TableName=TABLE, WaiterConfig={"Delay": 1, "MaxAttempts": 30})
    status = ddb.describe_table(TableName=TABLE)["Table"]["TableStatus"]
    print(f"[waiter] 기다린 뒤 상태: {status}")
    assert status == "ACTIVE"

    cleanup(s3, ddb)
    print("SDK client_resource_paginator_waiter OK")


if __name__ == "__main__":
    main()
