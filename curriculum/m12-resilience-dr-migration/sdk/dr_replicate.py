"""M12 — 주 리전("서울")의 주문 데이터를 DR 리전("도쿄")으로 복사한다 (파일럿 라이트의 데이터 복제 흉내).

두 "리전"은 포트가 다른 두 에뮬레이터다(둘 다 기술적으로는 us-east-1). 코드에는 엔드포인트가 없다.
    주 리전  : scripts/env.sh 가 만든 AWS_ENDPOINT_URL · AWS_CA_BUNDLE · AWS_SHARED_CREDENTIALS_FILE · AWS_CONFIG_FILE
    DR 리전  : labs/dr-env.sh 가 만든 DR_AWS_ENDPOINT_URL · DR_AWS_CA_BUNDLE · DR_AWS_SHARED_CREDENTIALS_FILE · DR_AWS_CONFIG_FILE

DR 쪽 클라이언트를 만들 때는 위 네 변수를 잠시 기본 이름(AWS_...)으로 바꿔 끼운 상태에서
require_emulator() 를 **한 번 더** 호출한다. 그래서 안전 장치(127.0.0.1 엔드포인트 + 계정
000000000000 확인)가 두 리전 모두에 똑같이 적용되고, boto3 는 평소처럼 환경 변수만 읽는다.
실제 AWS에서라면 DR_... 변수 대신 리전만 다른 두 세션(region_name="ap-northeast-2"/"ap-northeast-1")을 쓴다.

실행 (저장소 루트에서):
    export EMULATOR_PORT=9312 && source scripts/env.sh
    source curriculum/m12-resilience-dr-migration/labs/dr-env.sh
    uv run python curriculum/m12-resilience-dr-migration/sdk/dr_replicate.py          # = sync
    uv run python curriculum/m12-resilience-dr-migration/sdk/dr_replicate.py status

하위 명령
    sync    (기본) DR 쪽 기반 시설(테이블·버킷·설정)이 없으면 만들고, S3 영수증과 DynamoDB 주문을 복사한 뒤
            DR 버킷에 체크포인트(_dr/last-sync.json)를 남긴다
    status  두 리전의 주문 수·영수증 수와 마지막 동기화 시각을 비교한다
"""

from __future__ import annotations

import json
import os
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

TABLE = "todayorder-orders"
PARAM = "/todayorder/receipts-bucket"
CHECKPOINT_KEY = "_dr/last-sync.json"
SITE_KEYS = ("AWS_ENDPOINT_URL", "AWS_CA_BUNDLE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CONFIG_FILE")


@dataclass
class Site:
    name: str
    endpoint: str
    s3: Any
    ddb: Any
    ssm: Any


@contextmanager
def site_environment(prefix: str) -> Iterator[None]:
    """prefix 가 붙은 변수(DR_AWS_ENDPOINT_URL …)를 잠시 기본 이름(AWS_ENDPOINT_URL …)으로 바꿔 끼운다."""
    if not prefix:
        yield
        return
    missing = [prefix + k for k in SITE_KEYS if not os.environ.get(prefix + k)]
    if missing:
        raise SystemExit(f"[dr_replicate] {', '.join(missing)} 가 없습니다. "
                         "'source curriculum/m12-resilience-dr-migration/labs/dr-env.sh' 를 먼저 실행하세요.")
    saved = {k: os.environ.get(k) for k in SITE_KEYS}
    try:
        for k in SITE_KEYS:
            os.environ[k] = os.environ[prefix + k]
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def open_site(name: str, prefix: str) -> Site:
    with site_environment(prefix):
        # require_emulator() 는 boto3 기본 세션으로 STS 를 부른다. 기본 세션은 자격 증명을 캐시하므로
        # 리전(=에뮬레이터)을 바꿀 때마다 새로 만들게 비워 둔다.
        boto3.DEFAULT_SESSION = None
        endpoint = require_emulator()  # 이 사이트의 엔드포인트가 에뮬레이터가 아니면 여기서 종료
        session = boto3.Session()  # 지금 환경 변수(이 사이트의 엔드포인트·자격 증명·CA)로 클라이언트를 만든다
        site = Site(name, endpoint, session.client("s3"), session.client("dynamodb"), session.client("ssm"))
        boto3.DEFAULT_SESSION = None
    print(f"[{name}] {endpoint} (리전 이름 {site.s3.meta.region_name} — 에뮬레이터라 둘 다 us-east-1)")
    return site


def receipts_bucket(site: Site) -> str | None:
    try:
        return site.ssm.get_parameter(Name=PARAM)["Parameter"]["Value"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "ParameterNotFound":
            return None
        raise


def ensure_dr_infra(primary: Site, dr: Site, primary_bucket: str) -> str:
    """파일럿 라이트: DR 리전에 '불씨'(테이블·버킷·설정)만 미리 만들어 둔다. 이미 있으면 그대로."""
    bucket = receipts_bucket(dr) or f"{primary_bucket}-dr"
    desc = primary.ddb.describe_table(TableName=TABLE)["Table"]
    try:
        dr.ddb.create_table(TableName=TABLE, BillingMode="PAY_PER_REQUEST",
                            AttributeDefinitions=desc["AttributeDefinitions"], KeySchema=desc["KeySchema"])
        print(f"[{dr.name}] 테이블 생성: {TABLE} (주 리전과 같은 키 스키마)")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            raise
    deadline = time.monotonic() + 60
    while dr.ddb.describe_table(TableName=TABLE)["Table"]["TableStatus"] != "ACTIVE":
        if time.monotonic() > deadline:
            raise SystemExit(f"[{dr.name}] 테이블이 60초 안에 ACTIVE 가 되지 않음")
        time.sleep(0.5)
    try:
        dr.s3.head_bucket(Bucket=bucket)
    except ClientError:
        dr.s3.create_bucket(Bucket=bucket)
        print(f"[{dr.name}] 버킷 생성: {bucket}")
    dr.ssm.put_parameter(Name=PARAM, Value=bucket, Type="String", Overwrite=True)
    return bucket


def copy_objects(primary: Site, src_bucket: str, dr: Site, dst_bucket: str) -> tuple[int, int]:
    dst_etags: dict[str, str] = {}
    for page in dr.s3.get_paginator("list_objects_v2").paginate(Bucket=dst_bucket, Prefix="receipts/"):
        dst_etags.update({o["Key"]: o["ETag"] for o in page.get("Contents", [])})
    copied = skipped = 0
    for page in primary.s3.get_paginator("list_objects_v2").paginate(Bucket=src_bucket, Prefix="receipts/"):
        for obj in page.get("Contents", []):
            if dst_etags.get(obj["Key"]) == obj["ETag"]:
                skipped += 1
                continue
            got = primary.s3.get_object(Bucket=src_bucket, Key=obj["Key"])
            dr.s3.put_object(Bucket=dst_bucket, Key=obj["Key"], Body=got["Body"].read(),
                             ContentType=got.get("ContentType", "application/octet-stream"))
            copied += 1
    return copied, skipped


def copy_items(primary: Site, dr: Site) -> int:
    n = 0
    for page in primary.ddb.get_paginator("scan").paginate(TableName=TABLE):
        items = page.get("Items", [])
        for i in range(0, len(items), 25):  # BatchWriteItem 한 번에 최대 25개
            batch = [{"PutRequest": {"Item": it}} for it in items[i:i + 25]]
            req: dict[str, Any] = {TABLE: batch}
            while req:
                req = dr.ddb.batch_write_item(RequestItems=req).get("UnprocessedItems") or {}
            n += len(batch)
    return n


def count(site: Site, bucket: str) -> tuple[int, int]:
    orders = sum(p.get("Count", 0) for p in site.ddb.get_paginator("scan").paginate(TableName=TABLE, Select="COUNT"))
    receipts = sum(len(p.get("Contents", [])) for p in
                   site.s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="receipts/"))
    return orders, receipts


def order_ids(site: Site) -> set[str]:
    ids: set[str] = set()
    for page in site.ddb.get_paginator("scan").paginate(TableName=TABLE, ProjectionExpression="orderId"):
        ids |= {it["orderId"]["S"] for it in page.get("Items", [])}
    return ids


def sync(primary: Site, dr: Site) -> None:
    src_bucket = receipts_bucket(primary)
    if src_bucket is None:
        raise SystemExit(f"[{primary.name}] {PARAM} 가 없습니다. 주 리전에서 order_app.py bootstrap 을 먼저 실행하세요.")
    started = time.monotonic()
    dst_bucket = ensure_dr_infra(primary, dr, src_bucket)
    copied, skipped = copy_objects(primary, src_bucket, dr, dst_bucket)
    items = copy_items(primary, dr)
    checkpoint = {"syncedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                  "orders": items, "receiptsCopied": copied, "receiptsUnchanged": skipped,
                  "source": primary.endpoint}
    dr.s3.put_object(Bucket=dst_bucket, Key=CHECKPOINT_KEY, Body=json.dumps(checkpoint).encode(),
                     ContentType="application/json")
    print(f"동기화: 영수증 {copied}개 복사 · {skipped}개 변경 없음 · 주문 {items}건 → "
          f"{dr.name}(s3://{dst_bucket}, {TABLE}) [{time.monotonic() - started:.1f}초]")
    p, d = count(primary, src_bucket), count(dr, dst_bucket)
    print(f"확인: {primary.name} 주문 {p[0]} · 영수증 {p[1]}  |  {dr.name} 주문 {d[0]} · 영수증 {d[1]}")
    p_ids, d_ids = order_ids(primary), order_ids(dr)
    if p_ids - d_ids:
        raise SystemExit(f"복사 뒤에도 {dr.name}에 없는 주문: {sorted(p_ids - d_ids)}")
    if d_ids - p_ids:
        # 단방향 복제는 DR 쪽에만 있는 데이터를 지우지 않는다. 장애 조치 뒤 DR 에서 받은 주문이 여기 해당한다.
        print(f"주의: {dr.name}에만 있는 주문 {sorted(d_ids - p_ids)} — 장애 조치 중에 쓰인 데이터. "
              f"페일백 전에 {dr.name} → {primary.name} 역방향 동기화가 필요하다")


def status(primary: Site, dr: Site) -> None:
    src_bucket, dst_bucket = receipts_bucket(primary), receipts_bucket(dr)
    if src_bucket is None or dst_bucket is None:
        raise SystemExit("한쪽 리전이 아직 준비되지 않았습니다 (sync 를 먼저 실행)")
    cp = json.loads(dr.s3.get_object(Bucket=dst_bucket, Key=CHECKPOINT_KEY)["Body"].read())
    p, d = count(primary, src_bucket), count(dr, dst_bucket)
    print(f"마지막 동기화: {cp['syncedAt']}")
    print(f"{primary.name}: 주문 {p[0]} · 영수증 {p[1]}")
    print(f"{dr.name}: 주문 {d[0]} · 영수증 {d[1]}")
    lost = sorted(order_ids(primary) - order_ids(dr))
    print(f"지금 주 리전이 사라지면 잃는 주문: {len(lost)}건 {lost}  ← 마지막 동기화 이후의 데이터(RPO)")


def main(argv: list[str]) -> None:
    primary = open_site("서울", "")  # 주 리전: 기본 환경 변수 그대로. 여기서 첫 안전 장치가 돈다
    dr = open_site("도쿄", "DR_")    # DR 리전: DR_ 변수로 바꿔 끼우고 안전 장치를 다시 돈다
    if primary.endpoint.rstrip("/") == dr.endpoint.rstrip("/"):
        raise SystemExit("주 리전과 DR 리전이 같은 에뮬레이터입니다. DR_EMULATOR_PORT 를 확인하세요.")
    cmd = argv[0] if argv else "sync"
    if cmd == "sync":
        sync(primary, dr)
        print("SDK dr_replicate OK")
    elif cmd == "status":
        status(primary, dr)
    else:
        print(__doc__)
        raise SystemExit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
