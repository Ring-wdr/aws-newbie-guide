"""M08 — 가중치 레코드로 카나리 배포하기 (boto3).

TodayOrder 가 새 주문 API(green)를 내보낼 때, DNS 가중치를 100:0 → 90:10 → 50:50 → 0:100 으로
옮기며 각 단계에서 Route 53 이 실제로 어떤 답을 주는지 TestDNSAnswer 로 표본을 뽑아 본다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m08-dns-edge/sdk/weighted_canary.py

코드에는 엔드포인트도 자격 증명도 없다(환경 변수로 주입). 클라이언트를 만들기 전에
require_emulator() 로 에뮬레이터인지 확인한다.

주의: TestDNSAnswer 는 "Route 53 이 이 순간 고를 답"을 보여 줄 뿐, 실제 사용자 트래픽 비율은
리졸버 캐시(TTL) 때문에 가중치와 정확히 같지 않다. 실제 AWS에서는 TTL 을 짧게(예: 60초) 둔다.
"""

from __future__ import annotations

import time
import uuid
from collections import Counter

import boto3

from emulator_guard import require_emulator

ZONE = "canary.todayorder.example."
NAME = f"api.{ZONE}"
BLUE, GREEN = "192.0.2.1", "192.0.2.2"
SAMPLES = 200


def delete_zone(r53, name: str) -> None:  # type: ignore[no-untyped-def]
    """같은 이름의 영역을 레코드까지 지운다 (재실행해도 안전하도록)."""
    for zone in r53.list_hosted_zones()["HostedZones"]:
        if zone["Name"] != name:
            continue
        zid = zone["Id"]
        rrs = [
            r
            for page in r53.get_paginator("list_resource_record_sets").paginate(HostedZoneId=zid)
            for r in page["ResourceRecordSets"]
            if not (r["Name"] == name and r["Type"] in ("NS", "SOA"))
        ]
        if rrs:
            r53.change_resource_record_sets(
                HostedZoneId=zid,
                ChangeBatch={"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in rrs]},
            )
        r53.delete_hosted_zone(Id=zid)


def set_weights(r53, zone_id: str, blue: int, green: int) -> None:  # type: ignore[no-untyped-def]
    changes = [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": NAME,
                "Type": "A",
                "TTL": 60,
                "SetIdentifier": ident,
                "Weight": weight,
                "ResourceRecords": [{"Value": ip}],
            },
        }
        for ident, weight, ip in (("blue", blue, BLUE), ("green", green, GREEN))
    ]
    change_id = r53.change_resource_record_sets(HostedZoneId=zone_id, ChangeBatch={"Changes": changes})["ChangeInfo"]["Id"]
    r53.get_waiter("resource_record_sets_changed").wait(Id=change_id, WaiterConfig={"Delay": 1, "MaxAttempts": 60})


def sample(r53, zone_id: str, n: int) -> Counter[str]:  # type: ignore[no-untyped-def]
    counts: Counter[str] = Counter()
    for _ in range(n):
        ans = r53.test_dns_answer(HostedZoneId=zone_id, RecordName=NAME, RecordType="A")
        counts[",".join(ans["RecordData"]) or "(빈 응답)"] += 1
    return counts


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    r53 = boto3.client("route53")
    delete_zone(r53, ZONE)
    zone_id = r53.create_hosted_zone(Name=ZONE, CallerReference=f"m08-sdk-{uuid.uuid4()}")["HostedZone"]["Id"]
    print(f"호스팅 영역 {ZONE} ({zone_id})")

    results: dict[tuple[int, int], Counter[str]] = {}
    for blue, green in ((100, 0), (90, 10), (50, 50), (0, 100)):
        set_weights(r53, zone_id, blue, green)
        started = time.monotonic()
        counts = sample(r53, zone_id, SAMPLES)
        results[(blue, green)] = counts
        g = counts.get(GREEN, 0)
        bar = "#" * round(40 * g / SAMPLES)
        print(
            f"blue {blue:>3} : green {green:>3}  →  green 응답 {g:>3}/{SAMPLES} ({100 * g / SAMPLES:5.1f}%) "
            f"|{bar:<40}|  ({time.monotonic() - started:.1f}s)"
        )

    delete_zone(r53, ZONE)
    print("정리 완료")

    # 가중치 0 인 쪽은 절대 응답되지 않는다. 섞인 단계에서는 양쪽 모두 나와야 한다.
    assert results[(100, 0)].get(GREEN, 0) == 0
    assert results[(0, 100)].get(BLUE, 0) == 0
    assert results[(90, 10)].get(GREEN, 0) > 0 and results[(90, 10)].get(BLUE, 0) > 0
    assert results[(50, 50)].get(GREEN, 0) > results[(90, 10)].get(GREEN, 0)
    print("SDK weighted_canary OK")


if __name__ == "__main__":
    main()
