"""M13 — 인벤토리를 읽어 월 비용을 "추정"하고, 같은 일을 더 싸게 하는 조합을 제안한다.

Cost Explorer(GetCostAndUsage)는 에뮬레이터에서 501 이고, 에뮬레이터는 요금을 매기지 않는다.
그래서 이 예제는 청구서를 읽는 대신 **리소스 구성(인벤토리)을 읽어** 예시 단가를 곱한다.
실제 업무에서도 "아직 청구서가 없는 설계안"을 비교할 때 쓰는 방식이다(AWS Pricing Calculator 가 하는 일).

⚠️ 아래 PRICES 는 계산 연습용 **예시 단가**다. 실제 AWS 가격이 아니며 리전·시기마다 다르다.
   실제 숫자는 AWS Pricing Calculator(https://calculator.aws/)로 확인한다.

읽는 것 (태그 cost-lab=<값> 이 붙은 리소스만)
    EC2 인스턴스   InstanceType, 태그 workload(steady|batch), hours-per-month(없으면 730)
    EBS 볼륨       VolumeType, Size
    NAT 게이트웨이 개수, 태그 monthly-gb(처리량 가정)
    탄력적 IP       연결 여부

실행 (저장소 루트에서, lab01 을 실행한 뒤):
    source scripts/env.sh
    uv run python curriculum/m13-cost-optimization/sdk/cost_estimator.py            # cost-lab=m13
    uv run python curriculum/m13-cost-optimization/sdk/cost_estimator.py m13
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Any

import boto3

from emulator_guard import require_emulator

HOURS = 730  # 한 달 = 730시간으로 계산 (AWS Pricing Calculator 도 같은 값을 쓴다)

# ---- 예시 단가 (USD). 실제 가격이 아니다 ----
PRICES: dict[str, float] = {
    "ec2:m7i.large": 0.10,     # x86, 시간당 온디맨드
    "ec2:m7g.large": 0.08,     # 같은 크기의 Graviton(Arm) — 예시로 20% 저렴
    "ec2:c7i.xlarge": 0.18,
    "ec2:c7g.xlarge": 0.144,
    "ebs:gp2": 0.10,           # GB-월
    "ebs:gp3": 0.08,
    "nat:hour": 0.05,
    "nat:gb": 0.05,            # NAT 가 처리한 GB 당
    "ipv4:hour": 0.005,        # 퍼블릭 IPv4 주소 1개 시간당
}
SAVINGS_PLAN_DISCOUNT = 0.30   # 예시: Compute Savings Plans 1년 약정 30% 할인
SPOT_DISCOUNT = 0.70           # 예시: 스팟 70% 할인
GRAVITON = {"m7i.large": "m7g.large", "c7i.xlarge": "c7g.xlarge"}


@dataclass
class Line:
    item: str
    now: float
    better: float
    how: str


def tags_of(resource: dict[str, Any]) -> dict[str, str]:
    return {t["Key"]: t["Value"] for t in resource.get("Tags", [])}


def estimate(lab: str) -> list[Line]:
    ec2 = boto3.client("ec2")
    flt = [{"Name": "tag:cost-lab", "Values": [lab]}]
    lines: list[Line] = []

    for r in ec2.describe_instances(Filters=flt + [{"Name": "instance-state-name", "Values": ["pending", "running"]}])["Reservations"]:
        for i in r["Instances"]:
            t = tags_of(i)
            itype = i["InstanceType"]
            hours = float(t.get("hours-per-month", HOURS))
            od = PRICES[f"ec2:{itype}"] * hours
            name = t.get("Name", i["InstanceId"])
            if t.get("workload") == "steady":
                g = GRAVITON.get(itype, itype)
                better = PRICES[f"ec2:{g}"] * hours * (1 - SAVINGS_PLAN_DISCOUNT)
                lines.append(Line(f"EC2 {name} ({itype}, {hours:.0f}h, 상시)", od, better,
                                  f"Graviton {g} + Compute Savings Plans"))
            elif t.get("workload") == "batch":
                better = od * (1 - SPOT_DISCOUNT)
                lines.append(Line(f"EC2 {name} ({itype}, {hours:.0f}h, 배치)", od, better, "스팟 인스턴스(중단 허용)"))
            else:
                lines.append(Line(f"EC2 {name} ({itype}, {hours:.0f}h)", od, od, "(workload 태그 없음 — 판단 보류)"))

    for v in ec2.describe_volumes(Filters=flt)["Volumes"]:
        now = PRICES[f"ebs:{v['VolumeType']}"] * v["Size"]
        better = PRICES["ebs:gp3"] * v["Size"] if v["VolumeType"] == "gp2" else now
        how = "gp2 → gp3 (같은 크기, 기본 3,000 IOPS)" if v["VolumeType"] == "gp2" else "-"
        lines.append(Line(f"EBS {v['VolumeId']} ({v['VolumeType']} {v['Size']} GiB)", now, better, how))

    for n in ec2.describe_nat_gateways(Filters=flt + [{"Name": "state", "Values": ["available"]}])["NatGateways"]:
        gb = float(tags_of(n).get("monthly-gb", 0))
        now = PRICES["nat:hour"] * HOURS + PRICES["nat:gb"] * gb
        lines.append(Line(f"NAT {n['NatGatewayId']} (월 {gb:.0f} GB 처리)", now, now,
                          "S3·DynamoDB 트래픽이면 게이트웨이 엔드포인트 검토 (lab03)"))

    for a in ec2.describe_addresses(Filters=flt)["Addresses"]:
        now = PRICES["ipv4:hour"] * HOURS
        if a.get("AssociationId"):
            lines.append(Line(f"EIP {a['PublicIp']} (연결됨)", now, now, "-"))
        else:
            lines.append(Line(f"EIP {a['PublicIp']} (연결 안 됨)", now, 0.0, "쓰지 않는 IP 해제"))
    return lines


def main(argv: list[str]) -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    lab = argv[0] if argv else "m13"
    lines = estimate(lab)
    if not lines:
        print(f"태그 cost-lab={lab} 리소스가 없습니다. lab01 을 먼저 실행하세요.")
        return
    print("※ 예시 단가로 계산한 추정치 (실제 AWS 가격 아님 — AWS Pricing Calculator 로 확인)")
    print(f"{'항목':<44} {'현재':>9} {'개선안':>9}  방법")
    for ln in lines:
        print(f"{ln.item:<44} {ln.now:>9.2f} {ln.better:>9.2f}  {ln.how}")
    now = round(sum(ln.now for ln in lines), 2)
    better = round(sum(ln.better for ln in lines), 2)
    print(f"{'합계 (USD/월)':<44} {now:>9.2f} {better:>9.2f}  절감 {now - better:.2f} ({(now - better) / now:.1%})")
    print(f"TOTAL now={now:.2f} optimized={better:.2f}")


if __name__ == "__main__":
    main(sys.argv[1:])
