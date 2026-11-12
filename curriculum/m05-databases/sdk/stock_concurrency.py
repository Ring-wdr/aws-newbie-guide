"""M05 — 재고 10개짜리 한정판에 40명이 동시에 "구매"를 누르면? (조건부 쓰기 동시성 시연)

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m05-databases/sdk/stock_concurrency.py

두 가지 방법으로 같은 상황을 재현한다.

1. 나쁜 방법 — 읽고(GetItem) → 애플리케이션에서 계산하고 → 덮어쓰기(SET stock = 9)
   40개의 스레드가 모두 "재고 10"을 읽은 뒤에 쓰도록 threading.Barrier 로 줄을 세운다.
   (실제 서버에서도 요청이 몰리면 흔히 일어나는 순서다. Barrier 는 그 순서를 매번 똑같이 재현하려는 장치일 뿐이다.)
   → 40명 모두 "구매 성공", 재고는 9. 39개가 초과 판매되고 업데이트도 사라졌다(lost update).

2. 좋은 방법 — 조건부 원자적 감소 한 번:
       UpdateExpression    = "SET stock = stock - :q"
       ConditionExpression = "stock >= :q"
   DynamoDB 가 항목 하나에 대한 쓰기를 직렬화하고 조건을 검사하므로 정확히 10명만 성공하고 나머지 30명은
   ConditionalCheckFailedException 을 받는다. 재고는 0, 음수가 될 수 없다.

코드에는 엔드포인트·자격 증명이 없다(환경 변수로 주입). 실제 AWS에서도 같은 코드가 그대로 동작한다.
"""

from __future__ import annotations

import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

TABLE = "todayorder-m05-stock-demo"
PRODUCT_KEY = {"product_id": {"S": "P-777"}}
INITIAL_STOCK = 10
BUYERS = 40


def delete_table_if_exists(ddb: Any, table: str) -> None:
    """있으면 지우고 사라질 때까지 기다린다. 이미 '삭제 중'이어도 기다린다."""
    try:
        ddb.delete_table(TableName=table)
    except ddb.exceptions.ResourceNotFoundException:
        return
    except ddb.exceptions.ResourceInUseException:
        pass  # 이전 실행이 지우는 중
    ddb.get_waiter("table_not_exists").wait(TableName=table, WaiterConfig={"Delay": 1, "MaxAttempts": 300})


def recreate_table(ddb: Any) -> None:
    delete_table_if_exists(ddb, TABLE)
    resp = ddb.create_table(
        TableName=TABLE,
        AttributeDefinitions=[{"AttributeName": "product_id", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "product_id", "KeyType": "HASH"}],
        BillingMode="PAY_PER_REQUEST",
    )
    print(f"테이블 생성 요청: {resp['TableDescription']['TableStatus']} → waiter 로 ACTIVE 까지 대기")
    ddb.get_waiter("table_exists").wait(TableName=TABLE, WaiterConfig={"Delay": 1, "MaxAttempts": 120})


def reset_stock(ddb: Any) -> None:
    ddb.put_item(TableName=TABLE, Item={**PRODUCT_KEY, "stock": {"N": str(INITIAL_STOCK)}})


def current_stock(ddb: Any) -> int:
    item = ddb.get_item(TableName=TABLE, Key=PRODUCT_KEY, ConsistentRead=True)["Item"]
    return int(item["stock"]["N"])


def run_buyers(buy: Any) -> list[bool]:
    with ThreadPoolExecutor(max_workers=BUYERS) as pool:
        return list(pool.map(buy, range(BUYERS)))


def naive_round(ddb: Any) -> tuple[int, int]:
    """읽기 → 계산 → 덮어쓰기. 모두가 같은 값을 읽은 뒤 쓰므로 lost update 가 생긴다."""
    reset_stock(ddb)
    barrier = threading.Barrier(BUYERS)

    def buy(_: int) -> bool:
        seen = int(ddb.get_item(TableName=TABLE, Key=PRODUCT_KEY, ConsistentRead=True)["Item"]["stock"]["N"])
        barrier.wait()  # 모두 읽을 때까지 기다렸다가 동시에 쓴다
        if seen < 1:
            return False
        ddb.update_item(
            TableName=TABLE,
            Key=PRODUCT_KEY,
            UpdateExpression="SET stock = :new",
            ExpressionAttributeValues={":new": {"N": str(seen - 1)}},
        )
        return True

    sold = sum(run_buyers(buy))
    return sold, current_stock(ddb)


def conditional_round(ddb: Any) -> tuple[int, int, int]:
    """조건부 원자적 감소. 성공 수 = 초기 재고, 재고는 0에서 멈춘다."""
    reset_stock(ddb)
    barrier = threading.Barrier(BUYERS)

    def buy(_: int) -> bool:
        barrier.wait()  # 40명이 동시에 요청
        try:
            ddb.update_item(
                TableName=TABLE,
                Key=PRODUCT_KEY,
                UpdateExpression="SET stock = stock - :q",
                ConditionExpression="stock >= :q",
                ExpressionAttributeValues={":q": {"N": "1"}},
            )
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    results = run_buyers(buy)
    sold = sum(results)
    return sold, len(results) - sold, current_stock(ddb)


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    # 스레드 40개가 한 클라이언트를 같이 쓴다(boto3 client 는 스레드 안전). 연결 풀을 넉넉히.
    ddb = boto3.client("dynamodb", config=Config(max_pool_connections=BUYERS))
    recreate_table(ddb)

    print(f"\n[1] 읽고-계산하고-덮어쓰기  (재고 {INITIAL_STOCK}, 구매자 {BUYERS}명)")
    sold, stock = naive_round(ddb)
    print(f"    '구매 성공' 응답 {sold}건, 남은 재고 {stock}  → 초과 판매 {sold - (INITIAL_STOCK - stock)}건")

    print(f"\n[2] 조건부 원자적 감소  SET stock = stock - :q  IF stock >= :q")
    ok, rejected, stock2 = conditional_round(ddb)
    print(f"    성공 {ok}건, ConditionalCheckFailed {rejected}건, 남은 재고 {stock2}")

    delete_table_if_exists(ddb, TABLE)
    print("\n정리 완료")

    assert sold > INITIAL_STOCK - stock, "나쁜 방법에서 lost update 가 재현되지 않았다"
    assert ok == INITIAL_STOCK and rejected == BUYERS - INITIAL_STOCK and stock2 == 0
    print("SDK stock_concurrency OK")


if __name__ == "__main__":
    main()
