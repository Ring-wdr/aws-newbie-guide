"""M02 — VPC 토폴로지를 읽어 Mermaid 다이어그램으로 출력한다 (boto3, 🟢).

실행 (저장소 루트에서, lab02 로 3-티어 VPC를 만든 뒤):
    source scripts/env.sh
    uv run python curriculum/m02-vpc-networking/sdk/vpc_to_mermaid.py                 # todayorder-vpc
    uv run python curriculum/m02-vpc-networking/sdk/vpc_to_mermaid.py --vpc-name X --out vpc.mmd

하는 일
1. describe_* 로 VPC·서브넷·라우팅 테이블·게이트웨이·엔드포인트·보안 그룹을 읽는다.
2. 서브넷마다 "실제로 적용되는" 라우팅 테이블(명시 연결이 없으면 main)을 찾아
   기본 경로(0.0.0.0/0)의 다음 홉으로 티어를 판정한다:
     igw-*  → public   (퍼블릭 서브넷의 정의)
     nat-*  → private  (NAT 로 아웃바운드만)
     없음   → isolated (인터넷 경로 없음)
3. Mermaid flowchart 텍스트를 만든다. GitHub·VS Code 미리보기에 붙여 넣으면 그림이 된다.

코드에는 엔드포인트도 자격 증명도 없다. 실제 AWS 계정에서도 그대로 동작한다(읽기 전용 호출만 한다).
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from typing import Any

import boto3

from emulator_guard import require_emulator


def name_of(resource: dict[str, Any], default: str) -> str:
    for tag in resource.get("Tags", []) or []:
        if tag["Key"] == "Name":
            return str(tag["Value"])
    return default


def node_id(raw: str) -> str:
    """Mermaid 노드 ID로 쓸 수 있게 '-' 를 '_' 로."""
    return raw.replace("-", "_")


@dataclass
class Topology:
    vpc: dict[str, Any]
    subnets: list[dict[str, Any]]
    route_tables: list[dict[str, Any]]
    igws: list[dict[str, Any]]
    nats: list[dict[str, Any]]
    endpoints: list[dict[str, Any]]
    security_groups: list[dict[str, Any]]
    tgw_attachments: list[dict[str, Any]] = field(default_factory=list)


def read_topology(ec2: Any, vpc_name: str) -> Topology:
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [vpc_name]}])["Vpcs"]
    if not vpcs:
        print(f"VPC '{vpc_name}' 를 찾지 못했습니다. 먼저 labs/lab02-three-tier-vpc.sh 를 실행하세요.", file=sys.stderr)
        raise SystemExit(1)
    vpc = vpcs[0]
    f = [{"Name": "vpc-id", "Values": [vpc["VpcId"]]}]
    return Topology(
        vpc=vpc,
        subnets=ec2.describe_subnets(Filters=f)["Subnets"],
        route_tables=ec2.describe_route_tables(Filters=f)["RouteTables"],
        igws=ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc["VpcId"]]}])[
            "InternetGateways"
        ],
        nats=[
            n
            for n in ec2.describe_nat_gateways(Filters=f)["NatGateways"]  # NAT 는 Filter 가 아니라 Filters(boto3)
            if n["State"] in ("pending", "available")
        ],
        endpoints=[e for e in ec2.describe_vpc_endpoints(Filters=f)["VpcEndpoints"] if e["State"] != "deleted"],
        security_groups=ec2.describe_security_groups(Filters=f)["SecurityGroups"],
        tgw_attachments=[
            a
            for a in ec2.describe_transit_gateway_vpc_attachments(Filters=f)["TransitGatewayVpcAttachments"]
            if a["State"] in ("pending", "available")
        ],
    )


def effective_route_table(topo: Topology, subnet_id: str) -> dict[str, Any]:
    main: dict[str, Any] | None = None
    for rt in topo.route_tables:
        for assoc in rt.get("Associations", []):
            if assoc.get("SubnetId") == subnet_id:
                return rt
            if assoc.get("Main"):
                main = rt
    assert main is not None, "VPC에는 항상 main 라우팅 테이블이 있다"
    return main


def target_of(route: dict[str, Any]) -> str:
    for key in ("GatewayId", "NatGatewayId", "TransitGatewayId", "VpcPeeringConnectionId", "NetworkInterfaceId"):
        if route.get(key):
            return str(route[key])
    return "?"


def tier_of(rt: dict[str, Any]) -> str:
    for r in rt["Routes"]:
        if r.get("DestinationCidrBlock") == "0.0.0.0/0":
            t = target_of(r)
            if t.startswith("igw-"):
                return "public"
            if t.startswith("nat-"):
                return "private"
    return "isolated"


def to_mermaid(topo: Topology) -> str:
    vpc_id = topo.vpc["VpcId"]
    out: list[str] = ["flowchart TB"]
    out.append('  internet(("인터넷"))')
    for igw in topo.igws:
        out.append(f'  {node_id(igw["InternetGatewayId"])}["{name_of(igw, igw["InternetGatewayId"])}<br/>IGW"]')
        out.append(f'  internet <--> {node_id(igw["InternetGatewayId"])}')

    vpc_label = f'{name_of(topo.vpc, vpc_id)} {topo.vpc["CidrBlock"]}'
    out.append(f'  subgraph {node_id(vpc_id)}["{vpc_label}"]')
    by_az: dict[str, list[dict[str, Any]]] = {}
    for s in topo.subnets:
        by_az.setdefault(s["AvailabilityZone"], []).append(s)
    for az in sorted(by_az):
        out.append(f'    subgraph {node_id(az)}["{az}"]')
        for s in sorted(by_az[az], key=lambda x: x["CidrBlock"]):
            tier = tier_of(effective_route_table(topo, s["SubnetId"]))
            out.append(f'      {node_id(s["SubnetId"])}["{name_of(s, s["SubnetId"])}<br/>{s["CidrBlock"]} · {tier}"]')
        for n in topo.nats:
            if n["SubnetId"] in {s["SubnetId"] for s in by_az[az]}:
                out.append(f'      {node_id(n["NatGatewayId"])}{{{{"{name_of(n, n["NatGatewayId"])}<br/>NAT GW"}}}}')
        out.append("    end")
    for e in topo.endpoints:
        short = e["ServiceName"].rsplit(".", 1)[-1]
        out.append(f'    {node_id(e["VpcEndpointId"])}[/"{short} {e["VpcEndpointType"]} 엔드포인트"/]')
    out.append("  end")
    for a in topo.tgw_attachments:
        out.append(f'  {node_id(a["TransitGatewayId"])}(["{a["TransitGatewayId"]}<br/>Transit Gateway"])')

    # 경로 → 화살표. 서브넷에서 다음 홉으로 (local 은 생략)
    seen: set[str] = set()
    for s in topo.subnets:
        rt = effective_route_table(topo, s["SubnetId"])
        for r in rt["Routes"]:
            t = target_of(r)
            if t == "local" or t == "?":
                continue
            dest = r.get("DestinationCidrBlock") or r.get("DestinationPrefixListId", "")
            edge = f'  {node_id(s["SubnetId"])} -->|{dest}| {node_id(t)}'
            if edge not in seen:
                seen.add(edge)
                out.append(edge)
    # NAT 는 자기 서브넷 안에 있다
    for n in topo.nats:
        out.append(f'  {node_id(n["NatGatewayId"])} -.- {node_id(n["SubnetId"])}')

    # 보안 그룹 체이닝: "B 가 A 를 출처로 허용" → A ==> B
    sg_names = {g["GroupId"]: g["GroupName"] for g in topo.security_groups}
    chain: list[str] = []
    for g in topo.security_groups:
        for perm in g.get("IpPermissions", []):
            port = perm.get("FromPort", "all")
            for pair in perm.get("UserIdGroupPairs", []):
                src = pair["GroupId"]
                if src != g["GroupId"] and src in sg_names:
                    chain.append(f'  {node_id(src)}["{sg_names[src]}"] ==>|tcp {port}| {node_id(g["GroupId"])}["{g["GroupName"]}"]')
            for rng in perm.get("IpRanges", []):
                if rng.get("CidrIp") == "0.0.0.0/0":
                    chain.append(f'  anywhere(("0.0.0.0/0")) ==>|tcp {port}| {node_id(g["GroupId"])}["{g["GroupName"]}"]')
    if chain:
        out.append('  subgraph sgchain["보안 그룹 체이닝"]')
        out.extend("  " + c for c in chain)
        out.append("  end")
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="VPC 토폴로지를 Mermaid 로 출력")
    parser.add_argument("--vpc-name", default="todayorder-vpc")
    parser.add_argument("--out", help="결과를 저장할 파일 (생략하면 화면에만)")
    args = parser.parse_args()

    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    ec2 = boto3.client("ec2")

    topo = read_topology(ec2, args.vpc_name)
    text = to_mermaid(topo)
    print("```mermaid")
    print(text, end="")
    print("```")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)

    tiers = sorted(tier_of(effective_route_table(topo, s["SubnetId"])) for s in topo.subnets)
    print(f"서브넷 {len(topo.subnets)}개 · 티어: {', '.join(tiers)}", file=sys.stderr)
    # 자기 점검: 모든 서브넷이 그림에 들어갔는가
    missing = [s["SubnetId"] for s in topo.subnets if node_id(s["SubnetId"]) not in text]
    assert not missing, f"그림에 빠진 서브넷: {missing}"
    print("SDK vpc_to_mermaid OK", file=sys.stderr)


if __name__ == "__main__":
    main()
