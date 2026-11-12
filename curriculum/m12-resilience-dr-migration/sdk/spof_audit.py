"""M12 — VPC 하나를 읽어 단일 장애점(SPOF, Single Point of Failure)을 찾는 감사 도구.

"한 AZ가 통째로 사라지면 무엇이 같이 죽는가?"를 구성 정보만으로 판정한다. 읽기만 하고 아무것도 바꾸지 않는다.

검사 항목
    NAT       각 프라이빗 서브넷의 기본 경로(0.0.0.0/0)가 **같은 AZ**의 NAT 게이트웨이로 가는가
    COMPUTE   ALB 뒤 대상이 2대 이상이고 2개 이상 AZ에 퍼져 있는가
    DATABASE  RDS 인스턴스가 Multi-AZ 인가
    EDGE      ALB 자체가 2개 이상 AZ의 서브넷에 걸쳐 있는가

실행 (저장소 루트에서, lab01 을 실행한 뒤):
    source scripts/env.sh
    uv run python curriculum/m12-resilience-dr-migration/sdk/spof_audit.py todayorder-m12-v1   # VPC 의 Name 태그

마지막 줄에 'SPOF n건' 을 출력한다. VPC 가 없으면 그렇게 알리고 0으로 끝난다.
"""

from __future__ import annotations

import sys
from collections import defaultdict
from typing import Any

import boto3

from emulator_guard import require_emulator


def name_of(tags: list[dict[str, str]] | None, default: str) -> str:
    return next((t["Value"] for t in tags or [] if t["Key"] == "Name"), default)


def audit(vpc_name: str) -> list[str]:
    ec2, elbv2, rds = boto3.client("ec2"), boto3.client("elbv2"), boto3.client("rds")
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [vpc_name]}])["Vpcs"]
    if not vpcs:
        print(f"VPC '{vpc_name}' 가 없습니다. lab01 을 먼저 실행하세요.")
        return []
    vpc = vpcs[0]["VpcId"]
    print(f"감사 대상: {vpc_name} ({vpc})")
    findings: list[str] = []

    subnets = {s["SubnetId"]: s for s in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["Subnets"]}
    nats = {n["NatGatewayId"]: n for n in ec2.describe_nat_gateways(
        Filters=[{"Name": "vpc-id", "Values": [vpc]}, {"Name": "state", "Values": ["available"]}])["NatGateways"]}
    nat_az = {nid: subnets[n["SubnetId"]]["AvailabilityZone"] for nid, n in nats.items()}

    # --- NAT: 프라이빗 서브넷별로 기본 경로가 가리키는 NAT 의 AZ 를 본다
    cross_az: list[str] = []
    for rt in ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["RouteTables"]:
        nat_id = next((r.get("NatGatewayId") for r in rt["Routes"]
                       if r.get("DestinationCidrBlock") == "0.0.0.0/0" and r.get("NatGatewayId")), None)
        if not nat_id:
            continue
        for a in rt.get("Associations", []):
            sub = subnets.get(a.get("SubnetId", ""))
            if sub and sub["AvailabilityZone"] != nat_az.get(nat_id):
                cross_az.append(f"{name_of(sub.get('Tags'), sub['SubnetId'])}({sub['AvailabilityZone']})"
                                f"→{nat_id}({nat_az.get(nat_id, '?')})")
    nat_azs = sorted(set(nat_az.values()))
    if cross_az:
        findings.append(f"NAT: NAT 게이트웨이가 {', '.join(nat_azs) or '없음'} 에만 있다. "
                        f"다른 AZ의 프라이빗 서브넷이 그 NAT 에 의존: {', '.join(sorted(cross_az))}")
    else:
        print(f"[OK]   NAT: 프라이빗 서브넷마다 같은 AZ의 NAT 사용 (NAT 있는 AZ: {', '.join(nat_azs) or '없음'})")

    # --- EDGE / COMPUTE: ALB 와 그 뒤의 대상
    lbs = [lb for lb in elbv2.describe_load_balancers()["LoadBalancers"] if lb.get("VpcId") == vpc]
    for lb in lbs:
        lb_azs = sorted(z["ZoneName"] for z in lb.get("AvailabilityZones", []))
        if len(lb_azs) < 2:
            findings.append(f"EDGE: 로드 밸런서 {lb['LoadBalancerName']} 가 AZ 하나({', '.join(lb_azs)})에만 있다")
        else:
            print(f"[OK]   EDGE: 로드 밸런서 {lb['LoadBalancerName']} 가 {len(lb_azs)}개 AZ에 걸쳐 있음")
        for tg in elbv2.describe_target_groups(LoadBalancerArn=lb["LoadBalancerArn"])["TargetGroups"]:
            # 등록 해제 중(draining)인 대상은 곧 빠질 서버라 세지 않는다
            ids = [d["Target"]["Id"] for d in elbv2.describe_target_health(
                TargetGroupArn=tg["TargetGroupArn"])["TargetHealthDescriptions"]
                if d["TargetHealth"]["State"] != "draining"]
            by_az: dict[str, list[str]] = defaultdict(list)
            if ids:
                for r in ec2.describe_instances(InstanceIds=ids)["Reservations"]:
                    for i in r["Instances"]:
                        if i["State"]["Name"] in ("pending", "running"):
                            by_az[i["Placement"]["AvailabilityZone"]].append(i["InstanceId"])
            total = sum(len(v) for v in by_az.values())
            spread = ", ".join(f"{az}:{len(v)}대" for az, v in sorted(by_az.items())) or "대상 없음"
            if total < 2 or len(by_az) < 2:
                findings.append(f"COMPUTE: 대상 그룹 {tg['TargetGroupName']} 의 서버가 {total}대 ({spread}) — "
                                "한 대(또는 한 AZ)가 죽으면 서비스 중단")
            else:
                print(f"[OK]   COMPUTE: 대상 그룹 {tg['TargetGroupName']} — {spread}")

    # --- DATABASE: 이 VPC 의 RDS
    for db in rds.describe_db_instances()["DBInstances"]:
        if db.get("DBSubnetGroup", {}).get("VpcId") != vpc:
            continue
        if not db.get("MultiAZ"):
            findings.append(f"DATABASE: RDS {db['DBInstanceIdentifier']} 가 단일 AZ({db.get('AvailabilityZone')}) — "
                            "대기 인스턴스가 없어 그 AZ 장애 시 스냅샷·PITR 로 복원할 때까지 DB 중단")
        else:
            print(f"[OK]   DATABASE: RDS {db['DBInstanceIdentifier']} Multi-AZ")

    for f in findings:
        print(f"[SPOF] {f}")
    return findings


def main(argv: list[str]) -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    vpc_name = argv[0] if argv else "todayorder-m12-v1"
    findings = audit(vpc_name)
    print(f"SPOF {len(findings)}건")


if __name__ == "__main__":
    main(sys.argv[1:])
