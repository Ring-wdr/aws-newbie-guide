"""M05 — TodayOrder 주문 저장소(repository)를 DynamoDB 로 구현한다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m05-databases/sdk/order_repository.py

설계 (레슨 4·5의 접근 패턴에서 출발):

| 접근 패턴                          | 어디서                | 어떻게                                   |
|-----------------------------------|----------------------|-----------------------------------------|
| 주문 생성 + 재고 차감 (원자적)       | orders, products     | TransactWriteItems (조건 2종)             |
| 고객의 최근 주문 N건                 | orders (PK, SK)      | Query, ScanIndexForward=False, Limit     |
| 주문 1건 조회                       | orders               | GetItem (customer_id + order_ts)         |
| 상태별 주문(예: 배송 대기) 날짜순     | GSI status-index     | Query + 페이지네이터                      |
| 상태 전이 (PAID → SHIPPED 만 허용)   | orders               | UpdateItem + ConditionExpression          |
| 주문 취소 + 재고 복원 (원자적)        | orders, products     | TransactWriteItems                       |

boto3 resource 대신 client 를 쓴다(M00 레슨 5: resource 는 신규 기능 추가가 중단됨).
DynamoDB 타입 표기({"S": ...})와 파이썬 값 사이의 변환은 boto3 의 TypeSerializer/TypeDeserializer 로 한다.
엔드포인트·자격 증명은 코드에 없다(환경 변수로 주입) — 실제 AWS에서도 그대로 동작한다.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Iterator

import boto3
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

ORDERS = "todayorder-m05-repo-orders"
PRODUCTS = "todayorder-m05-repo-products"

_ser = TypeSerializer()
_de = TypeDeserializer()


def to_ddb(d: dict[str, Any]) -> dict[str, Any]:
    return {k: _ser.serialize(v) for k, v in d.items()}


def from_ddb(item: dict[str, Any]) -> dict[str, Any]:
    return {k: _de.deserialize(v) for k, v in item.items()}


@dataclass(frozen=True)
class Order:
    customer_id: str
    order_ts: str  # "2026-11-12T09:00:00Z#A-1001" — 시각으로 정렬되고, 주문번호로 유일해진다
    order_id: str
    status: str
    total: int
    lines: dict[str, int]  # product_id → 수량

    @staticmethod
    def from_item(item: dict[str, Any]) -> "Order":
        v = from_ddb(item)
        return Order(
            customer_id=v["customer_id"],
            order_ts=v["order_ts"],
            order_id=v["order_id"],
            status=v["status"],
            total=int(v["total"]),
            lines={k: int(q) for k, q in v.get("lines", {}).items()},
        )


class OutOfStock(Exception):
    def __init__(self, product_id: str) -> None:
        super().__init__(f"재고 부족: {product_id}")
        self.product_id = product_id


class InvalidTransition(Exception):
    pass


class OrderRepository:
    def __init__(self, ddb: Any) -> None:
        self.ddb = ddb

    # ---- 쓰기

    def place_order(self, order: Order, token: str | None = None) -> None:
        """주문 Put(중복 금지) + 상품별 재고 차감(부족 금지)을 하나의 트랜잭션으로."""
        actions: list[dict[str, Any]] = [
            {
                "Put": {
                    "TableName": ORDERS,
                    "Item": to_ddb(
                        {
                            "customer_id": order.customer_id,
                            "order_ts": order.order_ts,
                            "order_id": order.order_id,
                            "status": order.status,
                            "total": order.total,
                            "lines": order.lines,
                        }
                    ),
                    "ConditionExpression": "attribute_not_exists(customer_id)",
                }
            }
        ]
        products = list(order.lines)
        for pid in products:
            actions.append(
                {
                    "Update": {
                        "TableName": PRODUCTS,
                        "Key": to_ddb({"product_id": pid}),
                        "UpdateExpression": "SET stock = stock - :q",
                        "ConditionExpression": "stock >= :q",
                        "ExpressionAttributeValues": to_ddb({":q": order.lines[pid]}),
                    }
                }
            )
        kwargs: dict[str, Any] = {"TransactItems": actions}
        if token:
            kwargs["ClientRequestToken"] = token  # 같은 토큰으로 재시도하면 한 번만 반영된다(멱등)
        try:
            self.ddb.transact_write_items(**kwargs)
        except ClientError as e:
            if e.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            reasons = e.response.get("CancellationReasons", [])
            # reasons[i] 는 actions[i] 의 결과. 0번은 주문 Put, 1번부터 상품 Update
            for i, r in enumerate(reasons):
                if r.get("Code") == "ConditionalCheckFailed" and i >= 1:
                    raise OutOfStock(products[i - 1]) from e
            raise

    def change_status(self, customer_id: str, order_ts: str, expected: str, new: str) -> None:
        """현재 상태가 expected 일 때만 new 로 바꾼다 (상태 기계를 DB 조건으로 지킨다)."""
        try:
            self.ddb.update_item(
                TableName=ORDERS,
                Key=to_ddb({"customer_id": customer_id, "order_ts": order_ts}),
                UpdateExpression="SET #s = :new",
                ConditionExpression="#s = :expected",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues=to_ddb({":new": new, ":expected": expected}),
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise InvalidTransition(f"{order_ts}: {expected} 상태가 아니라 {new} 로 바꿀 수 없음") from e
            raise

    def cancel_order(self, order: Order) -> None:
        """PAID 인 주문만 취소하고, 같은 트랜잭션에서 재고를 되돌린다."""
        actions: list[dict[str, Any]] = [
            {
                "Update": {
                    "TableName": ORDERS,
                    "Key": to_ddb({"customer_id": order.customer_id, "order_ts": order.order_ts}),
                    "UpdateExpression": "SET #s = :c",
                    "ConditionExpression": "#s = :paid",
                    "ExpressionAttributeNames": {"#s": "status"},
                    "ExpressionAttributeValues": to_ddb({":c": "CANCELLED", ":paid": "PAID"}),
                }
            }
        ]
        for pid, qty in order.lines.items():
            actions.append(
                {
                    "Update": {
                        "TableName": PRODUCTS,
                        "Key": to_ddb({"product_id": pid}),
                        "UpdateExpression": "SET stock = stock + :q",
                        "ExpressionAttributeValues": to_ddb({":q": qty}),
                    }
                }
            )
        self.ddb.transact_write_items(TransactItems=actions)

    # ---- 읽기

    def get(self, customer_id: str, order_ts: str) -> Order | None:
        resp = self.ddb.get_item(
            TableName=ORDERS, Key=to_ddb({"customer_id": customer_id, "order_ts": order_ts})
        )
        return Order.from_item(resp["Item"]) if "Item" in resp else None

    def recent_orders(self, customer_id: str, limit: int) -> list[Order]:
        resp = self.ddb.query(
            TableName=ORDERS,
            KeyConditionExpression="customer_id = :c",
            ExpressionAttributeValues=to_ddb({":c": customer_id}),
            ScanIndexForward=False,  # 정렬 키 역순 = 최신 주문부터
            Limit=limit,
        )
        return [Order.from_item(i) for i in resp["Items"]]

    def orders_by_status(self, status: str, since: str) -> Iterator[Order]:
        """GSI 를 페이지네이터로 끝까지 읽는다 (1 MB 또는 Limit 마다 LastEvaluatedKey)."""
        pages = self.ddb.get_paginator("query").paginate(
            TableName=ORDERS,
            IndexName="status-index",
            KeyConditionExpression="#s = :s AND order_ts >= :since",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues=to_ddb({":s": status, ":since": since}),
            PaginationConfig={"PageSize": 2},  # 페이지네이션이 실제로 일어나게 일부러 작게
        )
        for page in pages:
            for item in page["Items"]:
                yield Order.from_item(item)

    def stock(self, product_id: str) -> int:
        item = self.ddb.get_item(
            TableName=PRODUCTS, Key=to_ddb({"product_id": product_id}), ConsistentRead=True
        )["Item"]
        return int(from_ddb(item)["stock"])


# ---- 테이블 준비/정리 (보통은 IaC(M10)로 만들지만, 예제를 자급자족하게)


def delete_table_if_exists(ddb: Any, table: str) -> None:
    try:
        ddb.delete_table(TableName=table)
    except ddb.exceptions.ResourceNotFoundException:
        return
    except ddb.exceptions.ResourceInUseException:
        pass  # 이미 삭제 중
    ddb.get_waiter("table_not_exists").wait(TableName=table, WaiterConfig={"Delay": 1, "MaxAttempts": 300})


def create_tables(ddb: Any) -> None:
    for t in (ORDERS, PRODUCTS):
        delete_table_if_exists(ddb, t)
    ddb.create_table(
        TableName=ORDERS,
        AttributeDefinitions=[
            {"AttributeName": "customer_id", "AttributeType": "S"},
            {"AttributeName": "order_ts", "AttributeType": "S"},
            {"AttributeName": "status", "AttributeType": "S"},
        ],
        KeySchema=[
            {"AttributeName": "customer_id", "KeyType": "HASH"},
            {"AttributeName": "order_ts", "KeyType": "RANGE"},
        ],
        GlobalSecondaryIndexes=[
            {
                "IndexName": "status-index",
                "KeySchema": [
                    {"AttributeName": "status", "KeyType": "HASH"},
                    {"AttributeName": "order_ts", "KeyType": "RANGE"},
                ],
                "Projection": {"ProjectionType": "ALL"},
            }
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    ddb.create_table(
        TableName=PRODUCTS,
        AttributeDefinitions=[{"AttributeName": "product_id", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "product_id", "KeyType": "HASH"}],
        BillingMode="PAY_PER_REQUEST",
    )
    waiter = ddb.get_waiter("table_exists")
    for t in (ORDERS, PRODUCTS):
        waiter.wait(TableName=t, WaiterConfig={"Delay": 1, "MaxAttempts": 120})


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    ddb = boto3.client("dynamodb")
    create_tables(ddb)
    repo = OrderRepository(ddb)
    for pid, stock in {"P-100": 5, "P-200": 1}.items():
        ddb.put_item(TableName=PRODUCTS, Item=to_ddb({"product_id": pid, "stock": stock}))
    print("상품 준비: P-100 재고 5, P-200 재고 1")

    o1 = Order("c-001", "2026-11-10T09:00:00Z#A-1001", "A-1001", "PAID", 24000, {"P-100": 2})
    o2 = Order("c-001", "2026-11-11T10:30:00Z#A-1002", "A-1002", "PAID", 31000, {"P-100": 1, "P-200": 1})
    o3 = Order("c-002", "2026-11-11T11:00:00Z#A-1003", "A-1003", "PAID", 12000, {"P-100": 1})
    # 멱등 토큰은 약 10분 동안 기억된다. 예제를 다시 실행해도 겹치지 않게 실행마다 다른 접미사를 붙인다.
    run = uuid.uuid4().hex[:8]
    for o in (o1, o2, o3):
        repo.place_order(o, token=f"place-{o.order_id}-{run}")
        print(f"주문 생성 {o.order_id}  재고 P-100={repo.stock('P-100')} P-200={repo.stock('P-200')}")

    print("\n같은 토큰으로 A-1003 재시도(타임아웃 뒤 재시도 상황)")
    repo.place_order(o3, token=f"place-A-1003-{run}")
    print(f"  → 성공 응답, 재고 P-100={repo.stock('P-100')} (두 번 차감되지 않음)")

    o4 = Order("c-003", "2026-11-12T08:00:00Z#A-1004", "A-1004", "PAID", 9000, {"P-100": 1, "P-200": 1})
    try:
        repo.place_order(o4)
        raise AssertionError("재고 부족인데 주문이 생성됐다")
    except OutOfStock as e:
        print(f"\nA-1004 거절: {e}  → 주문 항목 존재? {repo.get(o4.customer_id, o4.order_ts) is not None}"
              f", P-100 재고 그대로 {repo.stock('P-100')}")

    recent = repo.recent_orders("c-001", limit=1)
    print(f"\nc-001 의 최근 주문 1건: {recent[0].order_id} ({recent[0].order_ts})")

    repo.change_status("c-001", o1.order_ts, expected="PAID", new="SHIPPED")
    print("A-1001: PAID → SHIPPED")
    try:
        repo.change_status("c-001", o1.order_ts, expected="PAID", new="SHIPPED")
        raise AssertionError("두 번째 전이가 통과했다")
    except InvalidTransition as e:
        print(f"같은 전이를 한 번 더: 거절 ({e})")

    paid = [o.order_id for o in repo.orders_by_status("PAID", since="2026-11-01")]
    shipped = [o.order_id for o in repo.orders_by_status("SHIPPED", since="2026-11-01")]
    print(f"\nGSI status-index  PAID={paid}  SHIPPED={shipped}")

    repo.cancel_order(o2)
    print(f"A-1002 취소 → 재고 복원 P-100={repo.stock('P-100')} P-200={repo.stock('P-200')}")
    cancelled = repo.get("c-001", o2.order_ts)

    for t in (ORDERS, PRODUCTS):
        delete_table_if_exists(ddb, t)
    print("정리 완료")

    assert recent[0].order_id == "A-1002"
    assert sorted(paid) == ["A-1002", "A-1003"] and shipped == ["A-1001"], (paid, shipped)
    assert cancelled is not None and cancelled.status == "CANCELLED"
    assert isinstance(from_ddb(to_ddb({"x": 1}))["x"], Decimal)  # DynamoDB 숫자는 Decimal 로 돌아온다
    print("SDK order_repository OK")


if __name__ == "__main__":
    main()
