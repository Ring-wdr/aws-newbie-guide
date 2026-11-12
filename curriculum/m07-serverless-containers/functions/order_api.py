"""TodayOrder 서버리스 주문 API (M07 lab04). HTTP API(페이로드 2.0) → 이 함수 → DynamoDB.

라우트
- POST /orders            본문 {"orderId", "customerId", "total"} → 201 생성 / 409 이미 있음 / 400 잘못된 요청
- GET  /orders/{orderId}  → 200 / 404

표 이름은 환경 변수 TABLE_NAME 에서 읽는다. 자격 증명·엔드포인트는 코드에 없다 —
Lambda 는 실행 역할의 임시 자격 증명을 함수 환경에 넣어 주고, boto3 가 그것을 쓴다.
"""

import datetime
import json
import os

import boto3
from botocore.exceptions import ClientError

TABLE = os.environ["TABLE_NAME"]
ddb = boto3.client("dynamodb")  # 핸들러 밖에서 만들면 실행 환경이 재사용될 때 연결도 재사용된다


def respond(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body, ensure_ascii=False)}


def create_order(event):
    try:
        order = json.loads(event.get("body") or "{}")
        order_id, customer_id, total = order["orderId"], order["customerId"], int(order["total"])
    except (ValueError, KeyError, TypeError):
        return respond(400, {"message": "orderId, customerId, total(정수) 가 필요합니다"})
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        ddb.put_item(
            TableName=TABLE,
            Item={"orderId": {"S": order_id}, "customerId": {"S": customer_id},
                  "total": {"N": str(total)}, "status": {"S": "CREATED"}, "createdAt": {"S": now}},
            ConditionExpression="attribute_not_exists(orderId)",  # 같은 주문을 두 번 만들지 않는다(멱등)
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return respond(409, {"message": f"order {order_id} already exists"})
        raise  # 권한 오류 등은 숨기지 않는다 → 500, 로그에 남는다
    print(json.dumps({"msg": "order created", "orderId": order_id}))
    return respond(201, {"orderId": order_id, "status": "CREATED"})


def get_order(order_id):
    item = ddb.get_item(TableName=TABLE, Key={"orderId": {"S": order_id}}).get("Item")
    if not item:
        return respond(404, {"message": f"order {order_id} not found"})
    return respond(200, {"orderId": item["orderId"]["S"], "customerId": item["customerId"]["S"],
                         "total": int(item["total"]["N"]), "status": item["status"]["S"]})


def handler(event, context):
    route = event.get("routeKey")
    if route == "POST /orders":
        return create_order(event)
    if route == "GET /orders/{orderId}":
        return get_order(event["pathParameters"]["orderId"])
    return respond(404, {"message": "no such route"})
