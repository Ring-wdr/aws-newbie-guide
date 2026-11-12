"""M00 — lab02(S3 버킷 왕복)와 같은 작업을 boto3로.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m00-orientation/sdk/s3_roundtrip.py

코드에는 엔드포인트도 자격 증명도 없다. boto3가 환경 변수(AWS_ENDPOINT_URL,
AWS_SHARED_CREDENTIALS_FILE, AWS_CA_BUNDLE, AWS_REGION …)를 읽어 에뮬레이터로 보낸다.
그래서 같은 코드가 실제 AWS에서도 그대로 동작한다.

main() 첫 줄의 require_emulator() 는 클라이언트를 만들기 전에 "에뮬레이터가 맞는지"
확인하고, 아니면 아무 요청도 보내지 않고 종료한다. (실제 AWS에서 해 보려면
TODAYORDER_ALLOW_REAL_AWS=1 — 요금 주의)
"""

from __future__ import annotations

import json

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

BUCKET = "todayorder-m00-receipts-sdk"
KEY = "receipts/2026/11/A-1002.json"


def empty_and_delete_bucket(s3, bucket: str) -> None:  # type: ignore[no-untyped-def]
    """버킷이 있으면 비우고 지운다 (재실행해도 안전하도록)."""
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

    sts = boto3.client("sts")
    who = sts.get_caller_identity()
    print(f"계정: {who['Account']}  ARN: {who['Arn']}")

    s3 = boto3.client("s3")
    print(f"S3 엔드포인트: {s3.meta.endpoint_url}  리전: {s3.meta.region_name}")
    empty_and_delete_bucket(s3, BUCKET)

    s3.create_bucket(Bucket=BUCKET)
    receipt = {"orderId": "A-1002", "total": 8900, "currency": "KRW"}
    body = json.dumps(receipt).encode()
    put = s3.put_object(Bucket=BUCKET, Key=KEY, Body=body, ContentType="application/json")
    print(f"업로드: s3://{BUCKET}/{KEY}  ETag={put['ETag']}")

    keys = [o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])]
    print(f"목록: {keys}")

    got = s3.get_object(Bucket=BUCKET, Key=KEY)
    downloaded = json.loads(got["Body"].read())
    print(f"내려받음: {downloaded}  (ContentType={got['ContentType']}, {got['ContentLength']} bytes)")
    assert downloaded == receipt

    # 없는 키를 읽으면? → ClientError, 코드 NoSuchKey
    try:
        s3.get_object(Bucket=BUCKET, Key="receipts/none.json")
    except ClientError as e:
        print(f"없는 키: {e.response['Error']['Code']} (HTTP {e.response['ResponseMetadata']['HTTPStatusCode']})")

    empty_and_delete_bucket(s3, BUCKET)
    print("정리 완료")
    print("SDK s3_roundtrip OK")


if __name__ == "__main__":
    main()
