"""M08 — 호스팅 영역의 레코드를 읽어 "라우팅 정책"별로 분류하기 (boto3).

ListResourceRecordSets 응답에는 "정책 이름" 필드가 없다. 레코드에 어떤 필드가 붙어 있느냐로
정책이 정해진다(Weight → 가중치, Region → 지연 시간, Failover → 장애 조치 …).
시험 문제의 레코드 JSON 을 읽을 때도 똑같이 판단하면 된다.

이 예제는 데모 영역(inventory.todayorder.example)에 여러 정책의 레코드를 만들고, 분류해 출력한 뒤 지운다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m08-dns-edge/sdk/routing_policy_inventory.py
"""

from __future__ import annotations

import uuid
from typing import Any

import boto3

from emulator_guard import require_emulator

ZONE = "inventory.todayorder.example."


def policy_of(rr: dict[str, Any]) -> str:
    """레코드 하나의 라우팅 정책을 필드로 판정한다."""
    if "Failover" in rr:
        return "장애 조치(failover)"
    if "Weight" in rr:
        return "가중치(weighted)"
    if "Region" in rr:
        return "지연 시간(latency)"
    if "GeoLocation" in rr:
        return "지리적 위치(geolocation)"
    if "GeoProximityLocation" in rr:
        return "지리 근접(geoproximity)"
    if "CidrRoutingConfig" in rr:
        return "IP 기반(IP-based)"
    if rr.get("MultiValueAnswer"):
        return "다중값 응답(multivalue)"
    return "단순(simple)"


def target_of(rr: dict[str, Any]) -> str:
    if "AliasTarget" in rr:
        return f"Alias → {rr['AliasTarget']['DNSName']}"
    return ", ".join(r["Value"] for r in rr.get("ResourceRecords", []))


def demo_records(cidr_collection_id: str) -> list[dict[str, Any]]:
    def rr(name: str, ip: str, **extra: Any) -> dict[str, Any]:
        return {"Name": f"{name}.{ZONE}", "Type": "A", "TTL": 60, "ResourceRecords": [{"Value": ip}], **extra}

    return [
        rr("home", "192.0.2.10"),
        rr("api", "192.0.2.1", SetIdentifier="blue", Weight=90),
        rr("api", "192.0.2.2", SetIdentifier="green", Weight=10),
        rr("global", "198.51.100.1", SetIdentifier="seoul", Region="ap-northeast-2"),
        rr("global", "198.51.100.2", SetIdentifier="virginia", Region="us-east-1"),
        rr("checkout", "192.0.2.100", SetIdentifier="primary", Failover="PRIMARY"),
        rr("checkout", "192.0.2.200", SetIdentifier="secondary", Failover="SECONDARY"),
        rr("shop", "203.0.113.1", SetIdentifier="kr", GeoLocation={"CountryCode": "KR"}),
        rr("shop", "203.0.113.9", SetIdentifier="default", GeoLocation={"CountryCode": "*"}),
        rr("edge", "203.0.113.21", SetIdentifier="seoul", GeoProximityLocation={"AWSRegion": "ap-northeast-2", "Bias": 25}),
        rr("img", "192.0.2.31", SetIdentifier="img-1", MultiValueAnswer=True),
        rr("img", "192.0.2.32", SetIdentifier="img-2", MultiValueAnswer=True),
        # IP 기반: CIDR 컬렉션의 기본 위치("*")만 쓴다 — 위치에 CIDR 을 넣는 ChangeCidrCollection 은 에뮬레이터에서 501
        rr("isp", "192.0.2.49", SetIdentifier="default", CidrRoutingConfig={"CollectionId": cidr_collection_id, "LocationName": "*"}),
        {
            "Name": ZONE,
            "Type": "A",
            # external-host-ok: Route 53 별칭 값(AWS 문서의 예시 배포 이름). 에뮬레이터는 저장만 하고 해석·접속하지 않는다
            "AliasTarget": {"HostedZoneId": "Z2FDTNDATAQYW2", "DNSName": "d111111abcdef8.cloudfront.net", "EvaluateTargetHealth": False},
        },
    ]


def delete_zone(r53, name: str) -> None:  # type: ignore[no-untyped-def]
    for zone in r53.list_hosted_zones()["HostedZones"]:
        if zone["Name"] != name:
            continue
        rrs = [
            r
            for page in r53.get_paginator("list_resource_record_sets").paginate(HostedZoneId=zone["Id"])
            for r in page["ResourceRecordSets"]
            if not (r["Name"] == name and r["Type"] in ("NS", "SOA"))
        ]
        if rrs:
            r53.change_resource_record_sets(
                HostedZoneId=zone["Id"], ChangeBatch={"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in rrs]}
            )
        r53.delete_hosted_zone(Id=zone["Id"])


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    r53 = boto3.client("route53")
    delete_zone(r53, ZONE)
    zid = r53.create_hosted_zone(Name=ZONE, CallerReference=f"m08-inv-{uuid.uuid4()}")["HostedZone"]["Id"]
    cidr_id = r53.create_cidr_collection(Name=f"todayorder-inv-{uuid.uuid4().hex[:8]}", CallerReference=str(uuid.uuid4()))[
        "Collection"
    ]["Id"]
    r53.change_resource_record_sets(
        HostedZoneId=zid, ChangeBatch={"Changes": [{"Action": "CREATE", "ResourceRecordSet": r} for r in demo_records(cidr_id)]}
    )

    rows = [
        (rr["Name"], rr["Type"], policy_of(rr), rr.get("SetIdentifier", "-"), target_of(rr))
        for page in r53.get_paginator("list_resource_record_sets").paginate(HostedZoneId=zid)
        for rr in page["ResourceRecordSets"]
        if rr["Type"] not in ("NS", "SOA")
    ]
    print(f"{'이름':<40}{'유형':<6}{'정책':<26}{'SetIdentifier':<14}대상")
    for name, rtype, policy, ident, target in rows:
        print(f"{name:<40}{rtype:<6}{policy:<26}{ident:<14}{target}")

    found = {p for _, _, p, _, _ in rows}
    delete_zone(r53, ZONE)
    print("정리 완료")
    assert len(found) == 8, found  # 라우팅 정책 8종이 모두 판정되어야 한다
    print("SDK routing_policy_inventory OK")


if __name__ == "__main__":
    main()
