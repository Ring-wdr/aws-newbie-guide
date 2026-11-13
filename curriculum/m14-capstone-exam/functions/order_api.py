"""TodayOrder 캡스톤 주문 API (M14 lab03). HTTP API(페이로드 2.0, JWT 권한 부여자) → 이 함수.

라우트 (모두 Cognito 사용자 풀 JWT 필요 — 고객 ID는 본문이 아니라 토큰의 sub 클레임에서 읽는다)
- POST /orders              본문 {"orderId", "items", "total"} → 201 / 409 이미 있음 / 400 잘못된 요청
- GET  /orders/{orderId}    → 200 (내 주문만) / 404
- GET  /me/orders           → 200, GSI byCustomer 로 최근 주문 목록

주문을 DynamoDB 에 조건부로 저장(멱등)한 뒤 EventBridge 에 OrderPlaced 이벤트를 보낸다.
설정은 환경 변수(배포 스크립트가 Parameter Store 에서 읽어 넣는다)에서, 자격 증명은 실행 역할에서 온다.
"""

import datetime
import json
import os

import boto3
from botocore.exceptions import ClientError

TABLE = os.environ["TABLE_NAME"]
BUS = os.environ["EVENT_BUS"]
MAX_ITEMS = int(os.environ.get("MAX_ITEMS", "20"))
CURRENCY = os.environ.get("CURRENCY", "KRW")

ddb = boto3.client("dynamodb")  # 핸들러 밖: 실행 환경이 재사용되면 연결도 재사용된다
events = boto3.client("events")


def respond(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"},
            "body": json.dumps(body, ensure_ascii=False)}


def customer_of(event):
    return event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]


def create_order(event):
    customer = customer_of(event)
    try:
        order = json.loads(event.get("body") or "{}")
        order_id, items, total = order["orderId"], int(order["items"]), int(order["total"])
    except (ValueError, KeyError, TypeError):
        return respond(400, {"message": "orderId, items(정수), total(정수) 가 필요합니다"})
    if not (1 <= items <= MAX_ITEMS) or total <= 0:
        return respond(400, {"message": f"items 는 1~{MAX_ITEMS}, total 은 양수여야 합니다"})
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        ddb.put_item(
            TableName=TABLE,
            Item={"orderId": {"S": order_id}, "customerId": {"S": customer}, "items": {"N": str(items)},
                  "total": {"N": str(total)}, "currency": {"S": CURRENCY}, "status": {"S": "PENDING"},
                  "createdAt": {"S": now}},
            ConditionExpression="attribute_not_exists(orderId)",  # 클라이언트 재시도에도 주문은 하나
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return respond(409, {"message": f"order {order_id} already exists"})
        raise
    # 이벤트 발행. 실패하면 500 → 클라이언트가 재시도해도 409 가 나므로 이 지점의 유실은
    # 실제 서비스에서는 DynamoDB Streams 기반 발행(아웃박스)으로 막는다(레슨 02 "알려진 한계").
    events.put_events(Entries=[{
        "EventBusName": BUS, "Source": "todayorder.orders", "DetailType": "OrderPlaced",
        "Detail": json.dumps({"orderId": order_id, "customerId": customer, "items": items,
                              "total": total, "currency": CURRENCY}),
    }])
    print(json.dumps({"msg": "order placed", "orderId": order_id, "total": total}))
    return respond(201, {"orderId": order_id, "status": "PENDING"})


def get_order(event, order_id):
    item = ddb.get_item(TableName=TABLE, Key={"orderId": {"S": order_id}}).get("Item")
    if not item or item["customerId"]["S"] != customer_of(event):  # 남의 주문은 없는 것처럼
        return respond(404, {"message": f"order {order_id} not found"})
    body = {"orderId": order_id, "status": item["status"]["S"], "total": int(item["total"]["N"])}
    if "receiptKey" in item:
        body["receiptKey"] = item["receiptKey"]["S"]
    return respond(200, body)


def my_orders(event):
    resp = ddb.query(
        TableName=TABLE, IndexName="byCustomer",
        KeyConditionExpression="customerId = :c", ExpressionAttributeValues={":c": {"S": customer_of(event)}},
        ScanIndexForward=False, Limit=20,
    )
    orders = [{"orderId": i["orderId"]["S"], "status": i["status"]["S"], "total": int(i["total"]["N"])}
              for i in resp.get("Items", [])]
    return respond(200, {"orders": orders})


def handler(event, context):
    route = event.get("routeKey")
    if route == "POST /orders":
        return create_order(event)
    if route == "GET /orders/{orderId}":
        return get_order(event, event["pathParameters"]["orderId"])
    if route == "GET /me/orders":
        return my_orders(event)
    return respond(404, {"message": "no such route"})
