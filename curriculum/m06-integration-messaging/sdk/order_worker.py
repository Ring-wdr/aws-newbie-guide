"""M06 — 주문 워커(SQS 컨슈머)를 boto3로.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m06-integration-messaging/sdk/order_worker.py

하는 일
1. 주문 큐(todayorder-sdk-orders)와 DLQ를 만든다 (maxReceiveCount=2, 가시성 타임아웃 2초).
2. 주문 5건을 SendMessageBatch로 넣는다. 그중 1건은 처리할 수 없는 "독 메시지", 1건은 생산자가 실수로 두 번 보낸 중복이다.
3. 워커 루프: 롱 폴링으로 최대 10건씩 받고 → 처리 → 성공한 것만 DeleteMessageBatch.
   - 표준 큐는 "최소 한 번" 전달이라 같은 주문이 두 번 올 수 있다 → orderId로 멱등 처리.
   - 처리 실패는 지우지 않는다 → 가시성 타임아웃 뒤 다시 오고, 2번 넘게 실패하면 DLQ로 간다.
4. 원본 큐와 DLQ가 기대한 상태인지 확인하고 정리한다.

엔드포인트·자격 증명은 코드에 없다(환경 변수). 그래서 같은 코드가 실제 AWS에서도 동작한다.
"""

from __future__ import annotations

import json
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

QUEUE = "todayorder-sdk-orders"
DLQ = "todayorder-sdk-orders-dlq"


def fresh_queue(sqs: Any, name: str, attributes: dict[str, str]) -> str:
    """같은 이름의 큐가 있으면 지우고 새로 만든다. 삭제 직후 재생성 거부(QueueDeletedRecently)는 재시도."""
    try:
        sqs.delete_queue(QueueUrl=sqs.get_queue_url(QueueName=name)["QueueUrl"])
    except ClientError:
        pass
    deadline = time.monotonic() + 90
    while True:
        try:
            return sqs.create_queue(QueueName=name, Attributes=attributes)["QueueUrl"]
        except ClientError as e:
            if "QueueDeletedRecently" not in e.response["Error"]["Code"] or time.monotonic() > deadline:
                raise
            time.sleep(2)


def count(sqs: Any, url: str) -> tuple[int, int]:
    a = sqs.get_queue_attributes(
        QueueUrl=url, AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )["Attributes"]
    return int(a["ApproximateNumberOfMessages"]), int(a["ApproximateNumberOfMessagesNotVisible"])


def process(order: dict[str, Any]) -> None:
    """실제 업무 로직 자리. 통화 코드가 이상하면 실패한다(독 메시지)."""
    if order["currency"] != "KRW":
        raise ValueError(f"지원하지 않는 통화: {order['currency']}")


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    sqs = boto3.client("sqs")
    dlq_url = fresh_queue(sqs, DLQ, {"MessageRetentionPeriod": "1209600"})
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    url = fresh_queue(
        sqs,
        QUEUE,
        {
            "VisibilityTimeout": "2",
            "RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": "2"}),
        },
    )
    print(f"큐: {url}")

    orders = [
        {"orderId": "S-1", "total": 12000, "currency": "KRW"},
        {"orderId": "S-2", "total": 8000, "currency": "KRW"},
        {"orderId": "S-2", "total": 8000, "currency": "KRW"},  # 생산자 재시도로 생긴 중복
        {"orderId": "S-3", "total": 5000, "currency": "KRWW"},  # 독 메시지
        {"orderId": "S-4", "total": 30000, "currency": "KRW"},
    ]
    sent = sqs.send_message_batch(
        QueueUrl=url,
        Entries=[{"Id": str(i), "MessageBody": json.dumps(o)} for i, o in enumerate(orders)],
    )
    print(f"보냄: {len(sent.get('Successful', []))}건, 실패 {len(sent.get('Failed', []))}건")

    processed: set[str] = set()  # 실제로는 DynamoDB 조건부 쓰기 등으로 "처리한 주문 ID"를 저장한다
    failures = 0
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        resp = sqs.receive_message(
            QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=1, AttributeNames=["ApproximateReceiveCount"]
        )
        to_delete = []
        for m in resp.get("Messages", []):
            order = json.loads(m["Body"])
            rc = m["Attributes"]["ApproximateReceiveCount"]
            if order["orderId"] in processed:
                print(f"  {order['orderId']}: 이미 처리한 주문 → 건너뛰고 삭제 (멱등)")
                to_delete.append(m)
                continue
            try:
                process(order)
            except ValueError as e:
                failures += 1
                print(f"  {order['orderId']}: 실패 #{rc} ({e}) → 삭제하지 않음")
                continue
            processed.add(order["orderId"])
            print(f"  {order['orderId']}: 처리 완료 ({order['total']}원)")
            to_delete.append(m)
        if to_delete:
            sqs.delete_message_batch(
                QueueUrl=url,
                Entries=[{"Id": str(i), "ReceiptHandle": m["ReceiptHandle"]} for i, m in enumerate(to_delete)],
            )
        if count(sqs, url) == (0, 0) and count(sqs, dlq_url)[0] == 1:
            break
    else:
        raise SystemExit(f"제한 시간 안에 끝나지 않음: 원본={count(sqs, url)} DLQ={count(sqs, dlq_url)}")

    poison = sqs.receive_message(QueueUrl=dlq_url, VisibilityTimeout=0)["Messages"][0]["Body"]
    print(f"처리한 주문: {sorted(processed)}  실패 횟수: {failures}")
    print(f"DLQ에 남은 독 메시지: {poison}")
    assert processed == {"S-1", "S-2", "S-4"}
    assert json.loads(poison)["orderId"] == "S-3"

    sqs.delete_queue(QueueUrl=url)
    sqs.delete_queue(QueueUrl=dlq_url)
    print("정리 완료")
    print("SDK order_worker OK")


if __name__ == "__main__":
    main()
