"""TodayOrder 정산 컨슈머 (M07 lab02). SQS 이벤트 소스 매핑이 배치로 호출한다.

event["Records"] 의 각 레코드가 SQS 메시지 하나다. 실패한 메시지만 batchItemFailures 로 돌려주면
(이벤트 소스 매핑에 ReportBatchItemFailures 를 켰을 때) 그 메시지만 큐에 남아 다시 시도되고,
성공한 메시지는 Lambda 서비스가 큐에서 지운다.
"""

import json


def handler(event, context):
    failures = []
    for record in event["Records"]:
        order = json.loads(record["body"])
        if order.get("currency") != "KRW":
            print(json.dumps({"result": "failed", "orderId": order.get("orderId")}))
            failures.append({"itemIdentifier": record["messageId"]})
            continue
        print(json.dumps({"result": "settled", "orderId": order["orderId"], "total": order["total"]}))
    return {"batchItemFailures": failures}
