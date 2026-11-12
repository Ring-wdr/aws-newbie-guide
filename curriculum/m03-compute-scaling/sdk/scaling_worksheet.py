"""M03 — "이 지표 값이면 몇 대?" 워크시트 채점기.

에뮬레이터는 Auto Scaling 조정 정책이 501 이라 정책이 실제로 돌지 않는다(lab09).
그래서 레슨 6 의 워크시트 답을 이 스크립트로 계산해 본다. 정책 값(목표값·단계·쿨다운)은
labs/policies/*.json 에서 읽는다 — lab09 에서 CLI 에 넣어 본 바로 그 파일이다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m03-compute-scaling/sdk/scaling_worksheet.py

이 스크립트는 AWS API 를 부르지 않는다. 그래도 저장소 규칙대로 맨 앞에서 require_emulator() 를
호출한다(나중에 누군가 boto3 호출을 덧붙여도 실제 AWS 로 나가지 않도록).

주의: 대상 추적(target tracking)의 정확한 계산식은 AWS가 공개하지 않는다. 여기서는 시험 풀이에
쓰는 근사식 "필요 대수 = ceil(현재 대수 × 현재 지표 ÷ 목표값)" 을 쓴다. 실제 AWS의 축소(scale-in)는
이보다 보수적으로(천천히) 일어난다.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from emulator_guard import require_emulator

POLICY_DIR = Path(__file__).resolve().parent.parent / "labs" / "policies"
MIN_SIZE, MAX_SIZE = 2, 10  # 워크시트의 ASG: todayorder-api-asg (min 2 / max 10)


def load(name: str) -> dict:  # type: ignore[type-arg]
    return json.loads((POLICY_DIR / name).read_text())


def clamp(n: int) -> int:
    return max(MIN_SIZE, min(MAX_SIZE, n))


def target_tracking(current: int, metric: float, target: float) -> int:
    """근사식: 지표가 목표값이 되도록 대수를 비례해서 맞춘다."""
    return clamp(math.ceil(current * metric / target - 1e-9))


def round_percent(change: float) -> int:
    """PercentChangeInCapacity 반올림 규칙 (AWS 문서)."""
    if change > 1 or change < -1:
        return int(change)  # 1보다 크면 내림, -1보다 작으면 올림(0 쪽으로)
    if change > 0:
        return 1
    if change < 0:
        return -1
    return 0


def step_scaling(current: int, metric: float, threshold: float, policy: dict, min_magnitude: int = 0) -> int:  # type: ignore[type-arg]
    """단계 조정: 경보 임계값을 넘은 '폭'으로 단계를 고른다(경계는 임계값 기준 상대값)."""
    breach = metric - threshold
    if breach < 0:  # 경보가 울리지 않았다 (이 정책은 확장 전용)
        return current
    for step in policy["StepAdjustments"]:
        lo = step.get("MetricIntervalLowerBound", -math.inf)
        hi = step.get("MetricIntervalUpperBound", math.inf)
        if lo <= breach < hi:  # 임계값보다 위: 하한 포함, 상한 미포함
            adj = step["ScalingAdjustment"]
            if policy["AdjustmentType"] == "ChangeInCapacity":
                delta = adj
            elif policy["AdjustmentType"] == "PercentChangeInCapacity":
                delta = round_percent(current * adj / 100)
                if min_magnitude and 0 < delta < min_magnitude:
                    delta = min_magnitude
            else:  # ExactCapacity
                return clamp(adj)
            return clamp(current + delta)
    return current


def simple_scaling(current: int, policy: dict, seconds_since_last: int | None) -> int:  # type: ignore[type-arg]
    """단순 조정: 한 번 조정하면 쿨다운이 끝날 때까지 다음 경보를 무시한다."""
    if seconds_since_last is not None and seconds_since_last < policy["Cooldown"]:
        return current
    return clamp(current + policy["ScalingAdjustment"])


@dataclass
class Question:
    no: int
    text: str
    answer: int
    expected: int


def main() -> None:
    require_emulator()  # (API 는 부르지 않지만 저장소 규칙: 클라이언트를 만들기 전에 항상 호출)

    tt_cpu = load("target-tracking-cpu50.json")["TargetTrackingConfiguration"]["TargetValue"]
    tt_req = load("target-tracking-alb-requests.json")["TargetTrackingConfiguration"]["TargetValue"]
    step = load("step-scaling-cpu.json")
    simple = load("simple-scaling.json")
    sched = load("scheduled-lunch-peak.json")
    pct_policy = {
        "AdjustmentType": "PercentChangeInCapacity",
        "StepAdjustments": [{"MetricIntervalLowerBound": 0.0, "ScalingAdjustment": 25}],
    }

    req_per_target = 7500 / 4
    q = [
        Question(1, f"대상 추적 CPU {tt_cpu:g}%, 현재 4대, 평균 CPU 75%", target_tracking(4, 75, tt_cpu), 6),
        Question(2, f"대상 추적 CPU {tt_cpu:g}%, 현재 6대, 평균 CPU 90% (max 10)", target_tracking(6, 90, tt_cpu), 10),
        Question(3, f"대상 추적 CPU {tt_cpu:g}%, 현재 6대, 평균 CPU 30%", target_tracking(6, 30, tt_cpu), 4),
        Question(4, f"대상 추적 대상당 요청 {tt_req:g}, 현재 4대, ALB 전체 7,500 요청(대상당 {req_per_target:g})",
                 target_tracking(4, req_per_target, tt_req), 8),
        Question(5, "단계 조정(경보 임계값 CPU 60%), 현재 4대, CPU 65%", step_scaling(4, 65, 60, step), 5),
        Question(6, "단계 조정(경보 임계값 CPU 60%), 현재 4대, CPU 85%", step_scaling(4, 85, 60, step), 7),
        Question(7, "단계 조정(경보 임계값 CPU 60%), 현재 4대, CPU 55%", step_scaling(4, 55, 60, step), 4),
        Question(8, f"단순 조정 +{simple['ScalingAdjustment']}, 쿨다운 {simple['Cooldown']}초: 4대에서 경보 → 120초 뒤 또 경보",
                 simple_scaling(simple_scaling(4, simple, None), simple, 120), 6),
        Question(9, "단계 조정 PercentChangeInCapacity +25%, MinAdjustmentMagnitude 2, 현재 4대",
                 step_scaling(4, 70, 60, pct_policy, min_magnitude=2), 6),
        Question(10, f"예약 작업 {sched['ScheduledActionName']}({sched['Recurrence']} {sched['TimeZone']}) 시각, 현재 3대",
                 max(sched["MinSize"], sched["DesiredCapacity"]), 6),
        Question(11, "정책 두 개: CPU 추적은 6대, 요청 추적은 8대를 원한다", max(6, 8), 8),
    ]

    print(f"ASG todayorder-api-asg: min {MIN_SIZE} / max {MAX_SIZE}")
    for x in q:
        mark = "OK" if x.answer == x.expected else f"!= 정답 {x.expected}"
        print(f"{x.no:>2}. {x.text} → {x.answer}대  [{mark}]")
    wrong = [x.no for x in q if x.answer != x.expected]
    assert not wrong, f"계산이 답안과 다르다: {wrong}"
    print("SDK scaling_worksheet OK")


if __name__ == "__main__":
    main()
