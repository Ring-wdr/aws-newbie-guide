"""TodayOrder 결제 함수 (M06 lab06 의 Step Functions Task 가 호출한다).

입력의 paymentScenario 로 결과를 흉내 낸다.
- "ok"       : 결제 성공
- "declined" : 카드 거절 → PaymentDeclined (재시도해도 소용없는 업무 오류)
- "pg-down"  : PG사 응답 없음 → GatewayTimeout (잠시 뒤 재시도하면 나을 수 있는 일시 오류)

예외 클래스 이름이 그대로 Step Functions 의 오류 이름(Error)이 된다.
"""


class PaymentDeclined(Exception):
    pass


class GatewayTimeout(Exception):
    pass


def handler(event, context):
    scenario = event.get("paymentScenario", "ok")
    if scenario == "declined":
        raise PaymentDeclined(f"card declined for {event.get('orderId')}")
    if scenario == "pg-down":
        raise GatewayTimeout("payment gateway did not respond")
    return {"approved": True, "approvalNo": "AP-" + str(event.get("orderId", "")).replace("-", "")}
