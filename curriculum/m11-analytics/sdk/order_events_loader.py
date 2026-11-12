"""M11 — 주문 이벤트를 S3 파티션 경로로 적재하고 Glue 파티션을 등록하는 적재기 (boto3).

    주문 이벤트 → JSON Lines 로 묶기 → s3://<버킷>/raw/orders/dt=YYYY-MM-DD/part-<uuid>.json
                                     → Glue BatchCreatePartition (이미 있으면 건너뜀)

Firehose 를 쓰지 않고 앱(또는 배치)이 직접 S3 에 쓰는 경로다. 과거 데이터를 다시 넣는 백필(backfill)이나
하루 한 번 내보내는 배치에 쓴다. 실시간 스트림은 Firehose(lab02)가 같은 dt= 경로로 쓴다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m11-analytics/sdk/order_events_loader.py

athena_revenue_report.py 가 이 파일의 함수를 가져다 쓴다.
"""

from __future__ import annotations

import datetime as dt
import json
import random
import uuid
from collections.abc import Iterable
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

BUCKET = "todayorder-sdk-lake"
DATABASE = "todayorder_sdk"
TABLE = "orders"
PREFIX = "raw/orders/"

STORES = ["gangnam", "mapo", "jamsil"]
MENU = {"bibimbap": 9000, "kimbap": 3500, "tteokbokki": 6000}
PAYMENTS = ["card", "card", "kakaopay", "cash"]

COLUMNS = [
    ("order_id", "string"),
    ("store", "string"),
    ("menu", "string"),
    ("qty", "int"),
    ("amount", "bigint"),
    ("payment", "string"),
    ("ordered_at", "string"),
]


def storage_descriptor(location: str) -> dict[str, Any]:
    """JSON Lines 를 읽는 Hive 테이블의 StorageDescriptor. 테이블과 파티션이 같은 것을 쓴다."""
    return {
        "Columns": [{"Name": n, "Type": t} for n, t in COLUMNS],
        "Location": location,
        "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
        "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
        "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"},
    }


def fake_orders(day: dt.date, count: int, seed: int) -> list[dict[str, Any]]:
    """재현 가능한(같은 seed → 같은 결과) 가짜 주문."""
    rnd = random.Random(seed)
    orders = []
    for i in range(count):
        menu = rnd.choice(list(MENU))
        qty = rnd.randint(1, 3)
        at = dt.datetime.combine(day, dt.time(hour=rnd.randint(0, 23), minute=rnd.randint(0, 59)), dt.timezone.utc)
        orders.append({
            "order_id": f"S-{day:%m%d}-{i:04d}",
            "store": rnd.choice(STORES),
            "menu": menu,
            "qty": qty,
            "amount": MENU[menu] * qty,
            "payment": rnd.choice(PAYMENTS),
            "ordered_at": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
    return orders


def ensure_bucket(s3: Any, bucket: str) -> None:
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError:
        s3.create_bucket(Bucket=bucket)


def ensure_table(glue: Any, bucket: str, database: str = DATABASE, table: str = TABLE) -> None:
    try:
        glue.create_database(DatabaseInput={"Name": database})
    except glue.exceptions.AlreadyExistsException:
        pass
    try:
        glue.create_table(DatabaseName=database, TableInput={
            "Name": table,
            "TableType": "EXTERNAL_TABLE",
            "Parameters": {"classification": "json", "EXTERNAL": "TRUE"},
            "PartitionKeys": [{"Name": "dt", "Type": "string"}],
            "StorageDescriptor": storage_descriptor(f"s3://{bucket}/{PREFIX}"),
        })
    except glue.exceptions.AlreadyExistsException:
        pass


def load_day(s3: Any, glue: Any, bucket: str, day: dt.date, orders: Iterable[dict[str, Any]],
             database: str = DATABASE, table: str = TABLE) -> str:
    """하루치 주문을 JSON Lines 객체 하나로 쓰고, 그 날짜 파티션을 등록한다. 쓴 키를 돌려준다."""
    partition = f"dt={day:%Y-%m-%d}"
    key = f"{PREFIX}{partition}/part-{uuid.uuid4().hex[:12]}.json"
    # 한 줄에 JSON 하나, 줄 끝에 \n — Athena 의 JSON SerDe 가 줄 단위로 읽는다.
    body = "".join(json.dumps(o, ensure_ascii=False) + "\n" for o in orders)
    s3.put_object(Bucket=bucket, Key=key, Body=body.encode(), ContentType="application/x-ndjson")

    resp = glue.batch_create_partition(DatabaseName=database, TableName=table, PartitionInputList=[{
        "Values": [f"{day:%Y-%m-%d}"],
        "StorageDescriptor": storage_descriptor(f"s3://{bucket}/{PREFIX}{partition}/"),
    }])
    # 같은 날짜를 다시 적재하면 파티션은 이미 있다 — 오류가 아니라 "이미 있음"으로 보고된다.
    for err in resp.get("Errors", []):
        if err["ErrorDetail"]["ErrorCode"] != "AlreadyExistsException":
            raise RuntimeError(f"파티션 등록 실패: {err}")
    return key


def reset(s3: Any, glue: Any, bucket: str, database: str = DATABASE) -> None:
    """이전 실행이 남긴 버킷·데이터베이스를 지운다 (재실행해도 같은 결과가 나오도록)."""
    try:
        glue.delete_database(Name=database)  # 테이블·파티션도 함께 지워진다
    except glue.exceptions.EntityNotFoundException:
        pass
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError:
        return
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=obj["Key"])
    s3.delete_bucket(Bucket=bucket)


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    s3 = boto3.client("s3")
    glue = boto3.client("glue")
    reset(s3, glue, BUCKET)
    ensure_bucket(s3, BUCKET)
    ensure_table(glue, BUCKET)

    today = dt.datetime.now(dt.timezone.utc).date()
    days = [today - dt.timedelta(days=n) for n in (3, 2, 1)]
    for i, day in enumerate(days):
        orders = fake_orders(day, count=20, seed=i)
        key = load_day(s3, glue, BUCKET, day, orders)
        revenue = sum(o["amount"] for o in orders)
        print(f"{day}: {len(orders)}건 {revenue:,}원 → s3://{BUCKET}/{key}")

    # 같은 날을 한 번 더 적재해도(추가 파일) 파티션 등록은 중복 오류 없이 넘어간다.
    load_day(s3, glue, BUCKET, days[-1], fake_orders(days[-1], count=1, seed=99))

    for day in days:
        p = glue.get_partition(DatabaseName=DATABASE, TableName=TABLE, PartitionValues=[f"{day:%Y-%m-%d}"])
        print(f"파티션 {p['Partition']['Values'][0]} → {p['Partition']['StorageDescriptor']['Location']}")

    objects = [o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX).get("Contents", [])]
    assert len(objects) == 4, objects
    assert all("/dt=" in k for k in objects), objects
    print("SDK order_events_loader OK")


if __name__ == "__main__":
    main()
