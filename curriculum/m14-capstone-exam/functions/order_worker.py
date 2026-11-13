"""TodayOrder 캡스톤 주문 처리 워커 (M14 lab03). SQS fulfillment 큐 → 이벤트 소스 매핑 → 이 함수.

메시지 본문은 SNS 원시 전달(raw delivery)로 받은 EventBridge 이벤트(JSON)다.
주문마다:
  1) 결제 대행사 API 키를 Secrets Manager 에서 읽어(실행 환경당 한 번, 캐시) 결제를 "요청"한다
  2) 영수증 JSON 을 S3 에 쓴다 (버킷 기본 암호화 SSE-KMS)
  3) 주문 상태를 PENDING → CONFIRMED 로 조건부 갱신한다 (이미 CONFIRMED 면 건너뜀 = 멱등)
실패한 메시지만 batchItemFailures 로 돌려준다 → 그 메시지만 다시 시도되고, maxReceiveCount 를 넘으면 DLQ.
실패할 때마다 사용자 지정 지표 OrderProcessingFailed 를 1 올린다 → CloudWatch 알람 → SNS ops-alerts.

모의 장애: 주문 ID 가 "GW-DOWN-" 으로 시작하면 결제 대행사 타임아웃으로 간주한다(lab05 의 장애 경로 시험용).
"""

import datetime
import json
import os

import boto3
from botocore.exceptions import ClientError

TABLE = os.environ["TABLE_NAME"]
BUCKET = os.environ["RECEIPT_BUCKET"]
SECRET_ID = os.environ["SECRET_ID"]
METRIC_NS = os.environ["METRIC_NAMESPACE"]

ddb = boto3.client("dynamodb")
s3 = boto3.client("s3")
cw = boto3.client("cloudwatch")
secrets = boto3.client("secretsmanager")
_api_key = None


class PaymentGatewayTimeout(Exception):
    pass


def api_key():
    global _api_key
    if _api_key is None:  # 호출마다 읽지 않는다(지연·비용). 교체 주기보다 짧게 캐시하는 것이 원칙
        _api_key = json.loads(secrets.get_secret_value(SecretId=SECRET_ID)["SecretString"])["apiKey"]
    return _api_key


def charge(order):
    if not api_key():
        raise RuntimeError("no api key")
    if order["orderId"].startswith("GW-DOWN-"):
        raise PaymentGatewayTimeout(order["orderId"])


def process(order):
    charge(order)
    now = datetime.datetime.now(datetime.timezone.utc)
    key = f"receipts/{now:%Y/%m}/{order['orderId']}.json"
    # 영수증을 먼저 쓰고 상태를 바꾼다. 반대 순서면 상태 갱신 직후 실패했을 때 재시도가 "이미 CONFIRMED"로
    # 건너뛰어 영수증이 영영 안 생긴다. 이 순서에서는 중복 전달 시 같은 영수증을 한 번 더 쓸 뿐이다.
    receipt = {"orderId": order["orderId"], "customerId": order["customerId"], "total": order["total"],
               "currency": order["currency"], "issuedAt": now.isoformat()}
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(receipt).encode(), ContentType="application/json")
    try:
        ddb.update_item(
            TableName=TABLE, Key={"orderId": {"S": order["orderId"]}},
            UpdateExpression="SET #s = :confirmed, receiptKey = :k, confirmedAt = :t",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":confirmed": {"S": "CONFIRMED"}, ":pending": {"S": "PENDING"},
                                       ":k": {"S": key}, ":t": {"S": now.isoformat()}},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print(json.dumps({"result": "duplicate-skipped", "orderId": order["orderId"]}))
            return  # 같은 메시지가 두 번 와도(최소 한 번 전달) 결과는 한 번
        raise
    print(json.dumps({"result": "confirmed", "orderId": order["orderId"], "receipt": key}))


def handler(event, context):
    failures = []
    for record in event["Records"]:
        order = json.loads(record["body"])["detail"]
        try:
            process(order)
        except Exception as e:  # noqa: BLE001 — 어떤 실패든 이 메시지만 재시도 대상으로
            print(json.dumps({"result": "failed", "orderId": order.get("orderId"), "error": type(e).__name__}))
            cw.put_metric_data(Namespace=METRIC_NS, MetricData=[
                {"MetricName": "OrderProcessingFailed", "Value": 1.0, "Unit": "Count"}])
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
