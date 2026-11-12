"""TodayOrder 주문 상태 조회 함수 (M07 lab01).

- event = {"orderId": "A-1001"}           → 상태를 돌려준다
- orderId 가 없으면                        → ValueError (호출자는 FunctionError=Unhandled 를 받는다)
- event 에 "sleepSeconds" 가 있으면 그만큼 잔다 → 함수 타임아웃 관찰용
환경 변수 APP_VERSION 을 응답에 넣어, 어느 버전이 실행됐는지 보이게 한다.
"""

import json
import os
import time

# 핸들러 밖(초기화 단계)에서 한 번만 실행되는 코드. 실행 환경이 재사용되면 다시 실행되지 않는다.
COLD_START_AT = time.time()


def handler(event, context):
    print(json.dumps({"msg": "request", "event": event}))
    if "sleepSeconds" in event:
        time.sleep(event["sleepSeconds"])
    order_id = event.get("orderId")
    if not order_id:
        raise ValueError("orderId is required")
    return {
        "orderId": order_id,
        "status": "PAID",
        "appVersion": os.environ.get("APP_VERSION", "dev"),
        "functionVersion": context.function_version,
        "remainingMs": context.get_remaining_time_in_millis(),
    }
