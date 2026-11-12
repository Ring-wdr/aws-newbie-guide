"""TodayOrder 영수증 처리 함수 (M07 lab05). S3 ObjectCreated 이벤트가 비동기로 호출한다.

영수증 JSON 을 S3 에서 읽어 DynamoDB 영수증 표에 요약을 저장한다.
실행 역할에 s3:GetObject(버킷/receipts/*)와 dynamodb:PutItem(영수증 표)이 필요하다.
"""

import json
import os
import urllib.parse

import boto3

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")
TABLE = os.environ["TABLE_NAME"]


def handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])  # 이벤트의 키는 URL 인코딩되어 온다
        receipt = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        ddb.put_item(TableName=TABLE, Item={
            "orderId": {"S": receipt["orderId"]},
            "total": {"N": str(receipt["total"])},
            "sourceKey": {"S": key},
            "eventName": {"S": record["eventName"]},
        })
        print(json.dumps({"msg": "receipt stored", "orderId": receipt["orderId"], "key": key}))
    return {"processed": len(event["Records"])}
