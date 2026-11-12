"""Glue Python shell 작업 스크립트 — 원본 주문(raw)을 날짜·매장별 매출(curated)로 집계한다.

이 파일은 학습자 PC가 아니라 **Glue 작업 안에서** 실행된다 (lab04 가 S3 에 올리고 작업으로 등록한다).
작업은 Glue 서비스 역할로 실행되므로, 이 스크립트가 S3 를 읽고 쓸 수 있는지는 그 역할의 IAM 정책이 정한다.

인자 (Glue 작업 인자는 "--이름 값" 형태로 sys.argv 에 들어온다):
    --bucket  레이크 버킷
    --days    쉼표로 구분한 날짜들 (예: 2026-11-10,2026-11-11)

실제 Glue 에서는 awsglue.utils.getResolvedOptions 로 인자를 읽는 것이 관례지만,
여기서는 표준 라이브러리만 쓰려고 직접 파싱한다.
"""

from __future__ import annotations

import collections
import json
import sys

import boto3


def parse_args(argv: list[str]) -> dict[str, str]:
    args: dict[str, str] = {}
    it = iter(argv[1:])
    for token in it:
        if token.startswith("--"):
            args[token[2:]] = next(it, "")
    return args


def main() -> None:
    args = parse_args(sys.argv)
    bucket, days = args["bucket"], args["days"].split(",")
    s3 = boto3.client("s3")
    for day in days:
        totals: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])  # store -> [주문 수, 매출]
        prefix = f"raw/orders/dt={day}/"
        for obj in s3.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", []):
            body = s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read().decode()
            for line in body.splitlines():
                if not line.strip():
                    continue
                order = json.loads(line)
                totals[order["store"]][0] += 1
                totals[order["store"]][1] += int(order["amount"])
        rows = [
            {"day": day, "store": store, "orders": n, "revenue": revenue}
            for store, (n, revenue) in sorted(totals.items())
        ]
        out = "".join(json.dumps(r) + "\n" for r in rows)
        key = f"curated/daily_revenue/dt={day}/part-0000.json"
        s3.put_object(Bucket=bucket, Key=key, Body=out.encode(), ContentType="application/x-ndjson")
        print(f"{day}: {len(rows)} stores -> s3://{bucket}/{key}")


if __name__ == "__main__":
    main()
