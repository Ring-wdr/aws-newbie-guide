"""M11 — Athena 매출 리포트 (boto3).

order_events_loader.py 로 사흘치 주문을 S3·Glue 에 적재한 뒤, Athena 로 일자·매장별 매출을 구해
표로 출력하고, 같은 데이터를 Python 으로 직접 더한 값과 맞춰 본다.

    StartQueryExecution → (폴링) GetQueryExecution → GetQueryResults(paginator)

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m11-analytics/sdk/athena_revenue_report.py

실제 AWS에서는 쿼리가 스캔한 데이터 양만큼 요금이 나온다. 작업 그룹의 BytesScannedCutoffPerQuery 로 상한을 건다.
"""

from __future__ import annotations

import collections
import datetime as dt
import time
from typing import Any

import boto3

from emulator_guard import require_emulator
from order_events_loader import BUCKET, DATABASE, ensure_bucket, ensure_table, fake_orders, load_day, reset

WORKGROUP = "todayorder-sdk-reports"

REVENUE_SQL = """
SELECT substr(ordered_at, 1, 10) AS order_day, store, count(*) AS orders, sum(amount) AS revenue
FROM orders
GROUP BY 1, 2
ORDER BY 1, 2
"""


def ensure_workgroup(athena: Any, bucket: str) -> None:
    config = {
        "ResultConfiguration": {"OutputLocation": f"s3://{bucket}/athena-results/"},
        "EnforceWorkGroupConfiguration": True,
        "BytesScannedCutoffPerQuery": 100 * 1024 * 1024,
    }
    try:
        athena.get_work_group(WorkGroup=WORKGROUP)
        athena.update_work_group(WorkGroup=WORKGROUP, ConfigurationUpdates={
            "ResultConfigurationUpdates": config["ResultConfiguration"],
            "EnforceWorkGroupConfiguration": True,
            "BytesScannedCutoffPerQuery": config["BytesScannedCutoffPerQuery"],
        })
    except athena.exceptions.InvalidRequestException:
        athena.create_work_group(Name=WORKGROUP, Configuration=config)


def run_query(athena: Any, sql: str, database: str, timeout_s: float = 60) -> tuple[list[dict[str, str]], dict[str, Any]]:
    """쿼리를 실행하고 (행 목록, 실행 정보)를 돌려준다. 실패하면 이유와 함께 예외."""
    qid = athena.start_query_execution(
        QueryString=sql, WorkGroup=WORKGROUP, QueryExecutionContext={"Database": database}
    )["QueryExecutionId"]
    deadline = time.time() + timeout_s
    while True:
        ex = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = ex["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        if time.time() > deadline:
            raise TimeoutError(f"{timeout_s}초 안에 끝나지 않음 (마지막 상태 {state})")
        time.sleep(1)
    if state != "SUCCEEDED":
        raise RuntimeError(f"쿼리 {state}: {ex['Status'].get('StateChangeReason')}")

    rows: list[list[str]] = []
    for page in athena.get_paginator("get_query_results").paginate(QueryExecutionId=qid):
        rows.extend([c.get("VarCharValue", "") for c in r["Data"]] for r in page["ResultSet"]["Rows"])
    header, data = rows[0], rows[1:]  # 첫 행은 열 이름
    return [dict(zip(header, r)) for r in data], ex


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    s3, glue, athena = boto3.client("s3"), boto3.client("glue"), boto3.client("athena")
    reset(s3, glue, BUCKET)
    ensure_bucket(s3, BUCKET)
    ensure_table(glue, BUCKET)
    ensure_workgroup(athena, BUCKET)

    today = dt.datetime.now(dt.timezone.utc).date()
    expected: dict[tuple[str, str], list[int]] = collections.defaultdict(lambda: [0, 0])
    for i, day in enumerate(today - dt.timedelta(days=n) for n in (3, 2, 1)):
        orders = fake_orders(day, count=20, seed=i)
        load_day(s3, glue, BUCKET, day, orders)
        for o in orders:
            expected[(o["ordered_at"][:10], o["store"])][0] += 1
            expected[(o["ordered_at"][:10], o["store"])][1] += o["amount"]

    rows, ex = run_query(athena, REVENUE_SQL, DATABASE)
    print(f"{'order_day':<12}{'store':<10}{'orders':>7}{'revenue':>10}")
    for r in rows:
        print(f"{r['order_day']:<12}{r['store']:<10}{r['orders']:>7}{int(r['revenue']):>10,}")
    stats = ex["Statistics"]
    print(f"스캔 {stats['DataScannedInBytes']} bytes · 엔진 {ex['EngineVersion']['EffectiveEngineVersion']}")

    got = {(r["order_day"], r["store"]): [int(r["orders"]), int(r["revenue"])] for r in rows}
    assert got == dict(expected), (got, dict(expected))
    print("Python 으로 직접 합산한 값과 Athena 결과가 일치")

    reset(s3, glue, BUCKET)
    print("SDK athena_revenue_report OK")


if __name__ == "__main__":
    main()
