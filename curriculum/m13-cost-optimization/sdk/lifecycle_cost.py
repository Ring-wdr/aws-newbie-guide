"""M13 — 버킷의 S3 수명 주기 규칙을 읽어 "정상 상태(steady state)" 월 비용을 계산한다.

에뮬레이터는 수명 주기 전환을 실제로 하지 않는다(시간이 지나도 객체는 STANDARD 에 머문다).
그래서 이 예제는 **설정된 규칙을 읽어** 객체가 어느 클래스에 몇 달씩 머무는지 계산한다.

가정 (레슨 03 워크시트와 같다)
    매달 영수증 1,000,000 개, 평균 0.5 MB → 매달 500 GB 가 새로 쌓인다 (계산 편의상 1 GB = 1,000 MB)
    한 달 = 30일. 규칙의 Days 를 30 으로 나눠 "몇 달째에 옮기는지"로 본다
    정상 상태 = 만료(Expiration)까지의 모든 나이대 객체가 다 차 있는 상태

⚠️ PRICES 는 계산 연습용 **예시 단가**다. 실제 AWS 가격이 아니다. 실제 숫자는 AWS Pricing Calculator 로.
   Glacier 계열의 객체당 메타데이터 오버헤드, 조회(검색) 요금, 요청 요금(PUT/GET)은 계산에서 뺐다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m13-cost-optimization/sdk/lifecycle_cost.py todayorder-m13-receipts
    uv run python curriculum/m13-cost-optimization/sdk/lifecycle_cost.py      # 데모 버킷을 만들어 계산
"""

from __future__ import annotations

import sys
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

OBJECTS_PER_MONTH = 1_000_000
GB_PER_MONTH = 500.0
DAYS_PER_MONTH = 30

# ---- 예시 단가 (USD). 실제 가격이 아니다 ----
STORAGE_GB_MONTH = {"STANDARD": 0.025, "STANDARD_IA": 0.0125, "GLACIER_IR": 0.005,
                    "GLACIER": 0.004, "DEEP_ARCHIVE": 0.001}
TRANSITION_PER_1000 = {"STANDARD_IA": 0.01, "GLACIER_IR": 0.02, "GLACIER": 0.05, "DEEP_ARCHIVE": 0.05}
MIN_DAYS = {"STANDARD_IA": 30, "GLACIER_IR": 90, "GLACIER": 90, "DEEP_ARCHIVE": 180}  # 실제 AWS 의 최소 보관 기간

DEMO_BUCKET = "todayorder-m13-lifecycle-demo"
DEMO_RULE = {"ID": "receipts-tiering", "Status": "Enabled", "Filter": {"Prefix": "receipts/"},
             "Transitions": [{"Days": 30, "StorageClass": "STANDARD_IA"},
                             {"Days": 90, "StorageClass": "DEEP_ARCHIVE"}],
             "Expiration": {"Days": 1800}}


def stages(rule: dict[str, Any]) -> list[tuple[str, int, int]]:
    """규칙을 (클래스, 시작 일, 끝 일) 구간 목록으로 바꾼다."""
    end = rule.get("Expiration", {}).get("Days")
    if not end:
        raise SystemExit("만료(Expiration)가 없는 규칙은 정상 상태가 없다 (데이터가 끝없이 쌓인다)")
    points = [("STANDARD", 0)] + sorted(((t["StorageClass"], t["Days"]) for t in rule.get("Transitions", [])),
                                        key=lambda x: x[1])
    return [(cls, start, points[i + 1][1] if i + 1 < len(points) else end) for i, (cls, start) in enumerate(points)]


def monthly_cost(rule: dict[str, Any]) -> tuple[float, float]:
    storage = transitions = 0.0
    print(f"규칙 {rule['ID']}: " + " → ".join(f"{c}({s}일~)" for c, s, _ in stages(rule))
          + f" → 삭제({rule['Expiration']['Days']}일)")
    print(f"  {'클래스':<13} {'머무는 기간':>10} {'쌓인 양(GB)':>12} {'저장 요금':>10} {'전환 요금':>10}")
    for cls, start, end in stages(rule):
        months = (end - start) / DAYS_PER_MONTH
        gb = GB_PER_MONTH * months
        s = gb * STORAGE_GB_MONTH[cls]
        t = OBJECTS_PER_MONTH / 1000 * TRANSITION_PER_1000.get(cls, 0.0)  # 매달 이 클래스로 넘어오는 객체 수
        warn = ""
        if cls in MIN_DAYS and end - start < MIN_DAYS[cls]:
            warn = f"  ⚠ 최소 보관 {MIN_DAYS[cls]}일 미만 → 조기 삭제 요금"
        print(f"  {cls:<13} {end - start:>8}일 {gb:>12,.0f} {s:>10.2f} {t:>10.2f}{warn}")
        storage += s
        transitions += t
    return round(storage, 2), round(transitions, 2)


def main(argv: list[str]) -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    s3 = boto3.client("s3")
    bucket = argv[0] if argv else DEMO_BUCKET
    if not argv:
        try:
            s3.head_bucket(Bucket=bucket)
        except ClientError:
            s3.create_bucket(Bucket=bucket)
        s3.put_bucket_lifecycle_configuration(Bucket=bucket, LifecycleConfiguration={"Rules": [DEMO_RULE]})
    rules = s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
    print("※ 예시 단가로 계산 (실제 AWS 가격 아님 — AWS Pricing Calculator 로 확인)")
    print(f"가정: 매달 {OBJECTS_PER_MONTH:,}개 · {GB_PER_MONTH:.0f} GB 유입, 한 달 = {DAYS_PER_MONTH}일")
    baseline_gb = GB_PER_MONTH * rules[0]["Expiration"]["Days"] / DAYS_PER_MONTH
    baseline = round(baseline_gb * STORAGE_GB_MONTH["STANDARD"], 2)
    for rule in rules:
        storage, trans = monthly_cost(rule)
        total = round(storage + trans, 2)
        print(f"  합계: 저장 {storage:.2f} + 전환 {trans:.2f} = {total:.2f} USD/월")
        print(f"  비교: 전부 STANDARD 로 두면 {baseline_gb:,.0f} GB × {STORAGE_GB_MONTH['STANDARD']} = {baseline:.2f} USD/월")
        print(f"RESULT rule={rule['ID']} storage={storage:.2f} transitions={trans:.2f} total={total:.2f} all_standard={baseline:.2f}")


if __name__ == "__main__":
    main(sys.argv[1:])
