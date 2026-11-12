"""M02: VPC 네트워킹 탐침 (서브넷·라우팅·IGW·NAT·SG·NACL·엔드포인트·피어링·TGW·Flow Logs)."""

from __future__ import annotations

from typing import Any

from lib import Probe, wait_until


def _tag(name: str, rtype: str) -> list[dict[str, Any]]:
    return [{"ResourceType": rtype, "Tags": [{"Key": "Name", "Value": name}]}]


def run_vpc(p: Probe) -> None:
    ec2 = p.client("ec2")

    azs = p.call("DescribeAvailabilityZones", ec2.describe_availability_zones)
    az_names = [z["ZoneName"] for z in azs["AvailabilityZones"]] if azs else []
    if azs:
        p.behavior("us-east-1 AZ 목록 조회", len(az_names) >= 2, ", ".join(az_names))
    a1 = az_names[0] if az_names else "us-east-1a"
    a2 = az_names[1] if len(az_names) > 1 else "us-east-1b"

    v = p.call("CreateVpc", ec2.create_vpc, CidrBlock="10.0.0.0/16",
               TagSpecifications=_tag(p.name("vpc"), "vpc"))
    if not v:
        p.skip("나머지 VPC 탐침", "CreateVpc 실패")
        return
    vpc = v["Vpc"]["VpcId"]
    p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
    st = wait_until(lambda: ec2.describe_vpcs(VpcIds=[vpc])["Vpcs"][0]["State"] == "available", 10)
    p.behavior("VPC 상태 pending→available", st, f"생성 직후 {v['Vpc']['State']}")
    p.call("ModifyVpcAttribute(EnableDnsHostnames)", ec2.modify_vpc_attribute, VpcId=vpc,
           EnableDnsHostnames={"Value": True})

    # 서브넷 2개 (2 AZ)
    subnets: list[str] = []
    for i, (az, cidr) in enumerate(((a1, "10.0.1.0/24"), (a2, "10.0.2.0/24"))):
        s = p.call(f"CreateSubnet({az})", ec2.create_subnet, VpcId=vpc, CidrBlock=cidr, AvailabilityZone=az)
        if s:
            sid = s["Subnet"]["SubnetId"]
            subnets.append(sid)
            p.cleanup(f"subnet{i}", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
    if subnets:
        d = p.call("DescribeSubnets", ec2.describe_subnets, Filters=[{"Name": "vpc-id", "Values": [vpc]}])
        if d:
            got = {(x["AvailabilityZone"], x["CidrBlock"]) for x in d["Subnets"]}
            p.behavior("서브넷이 실제로 저장되고 AZ·CIDR이 유지됨",
                       got == {(a1, "10.0.1.0/24"), (a2, "10.0.2.0/24")}, str(sorted(got)))
            cnt = [x["AvailableIpAddressCount"] for x in d["Subnets"]]
            p.behavior("/24 서브넷의 사용 가능 IP = 251 (AWS 예약 5개)", all(c == 251 for c in cnt), f"{cnt}")
    p.expect_error("CreateSubnet(VPC 범위 밖)", ec2.create_subnet, "InvalidSubnet.Range",
                   VpcId=vpc, CidrBlock="10.1.0.0/24", AvailabilityZone=a1,
                   what="VPC CIDR 밖의 서브넷 → InvalidSubnet.Range")
    p.expect_error("CreateSubnet(겹침)", ec2.create_subnet, "InvalidSubnet.Conflict",
                   VpcId=vpc, CidrBlock="10.0.1.128/25", AvailabilityZone=a1,
                   what="기존 서브넷과 겹치는 CIDR → InvalidSubnet.Conflict")
    if subnets:
        p.call("ModifySubnetAttribute(MapPublicIpOnLaunch)", ec2.modify_subnet_attribute, SubnetId=subnets[0],
               MapPublicIpOnLaunch={"Value": True})
        d = ec2.describe_subnets(SubnetIds=[subnets[0]])["Subnets"][0]
        p.behavior("MapPublicIpOnLaunch 반영", d.get("MapPublicIpOnLaunch") is True, str(d.get("MapPublicIpOnLaunch")))

    # IGW + 라우팅
    igw = p.call("CreateInternetGateway", ec2.create_internet_gateway)
    igw_id = igw["InternetGateway"]["InternetGatewayId"] if igw else None
    if igw_id:
        p.cleanup("igw", lambda: ec2.delete_internet_gateway(InternetGatewayId=igw_id))
        if p.call("AttachInternetGateway", ec2.attach_internet_gateway, InternetGatewayId=igw_id, VpcId=vpc) is not None:
            p.cleanup("igw-detach", lambda: ec2.detach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc))
    rt = p.call("CreateRouteTable", ec2.create_route_table, VpcId=vpc)
    rt_id = rt["RouteTable"]["RouteTableId"] if rt else None
    if rt_id:
        p.cleanup("rt", lambda: ec2.delete_route_table(RouteTableId=rt_id))
        if igw_id:
            p.call("CreateRoute(0.0.0.0/0 → IGW)", ec2.create_route, RouteTableId=rt_id,
                   DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
        if subnets:
            a = p.call("AssociateRouteTable", ec2.associate_route_table, RouteTableId=rt_id, SubnetId=subnets[0])
            if a:
                p.cleanup("rta", lambda: ec2.disassociate_route_table(AssociationId=a["AssociationId"]))
        r = ec2.describe_route_tables(RouteTableIds=[rt_id])["RouteTables"][0]
        routes = [(x.get("DestinationCidrBlock"), x.get("GatewayId")) for x in r["Routes"]]
        p.behavior("라우팅 테이블에 local 경로 + IGW 경로", ("10.0.0.0/16", "local") in routes
                   and ("0.0.0.0/0", igw_id) in routes, str(routes))
    main_rt = ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc]},
                                                 {"Name": "association.main", "Values": ["true"]}])["RouteTables"]
    p.behavior("VPC 생성 시 기본(main) 라우팅 테이블 자동 생성", len(main_rt) == 1, f"{len(main_rt)}개")

    # EIP + NAT
    eip = p.call("AllocateAddress", ec2.allocate_address, Domain="vpc")
    alloc = eip["AllocationId"] if eip else None
    if alloc:
        p.cleanup("eip", lambda: ec2.release_address(AllocationId=alloc))
    if alloc and subnets:
        nat = p.call("CreateNatGateway", ec2.create_nat_gateway, SubnetId=subnets[0], AllocationId=alloc)
        if nat:
            nid = nat["NatGateway"]["NatGatewayId"]
            first = nat["NatGateway"]["State"]
            ok = wait_until(lambda: ec2.describe_nat_gateways(NatGatewayIds=[nid])["NatGateways"][0]["State"] == "available", 20)
            p.behavior("NAT 게이트웨이 pending→available", ok, f"생성 직후 {first}")
            p.cleanup("nat", lambda: ec2.delete_nat_gateway(NatGatewayId=nid))
            if rt_id:
                rt2 = ec2.create_route_table(VpcId=vpc)["RouteTable"]["RouteTableId"]
                p.cleanup("rt2", lambda: ec2.delete_route_table(RouteTableId=rt2))
                p.call("CreateRoute(0.0.0.0/0 → NAT)", ec2.create_route, RouteTableId=rt2,
                       DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nid)
            pub = ec2.describe_nat_gateways(NatGatewayIds=[nid])["NatGateways"][0].get("NatGatewayAddresses", [])
            p.behavior("NAT 게이트웨이에 EIP 공인 IP가 붙음", bool(pub and pub[0].get("PublicIp")), str(pub)[:120])

    eg = p.call("CreateEgressOnlyInternetGateway", ec2.create_egress_only_internet_gateway, VpcId=vpc)
    if eg:
        eid = eg["EgressOnlyInternetGateway"]["EgressOnlyInternetGatewayId"]
        p.cleanup("eigw", lambda: ec2.delete_egress_only_internet_gateway(EgressOnlyInternetGatewayId=eid))
        d = p.call("DescribeEgressOnlyInternetGateways", ec2.describe_egress_only_internet_gateways,
                   EgressOnlyInternetGatewayIds=[eid])
        if d:
            p.behavior("Egress-only IGW가 저장되고 조회됨", len(d["EgressOnlyInternetGateways"]) == 1,
                       str(d["EgressOnlyInternetGateways"][0].get("Attachments") if d["EgressOnlyInternetGateways"] else ""))

    # 보안 그룹 체이닝
    sgs: dict[str, str] = {}
    for tier in ("web", "app", "db"):
        g = p.call(f"CreateSecurityGroup({tier})", ec2.create_security_group, GroupName=p.name(f"sg-{tier}"),
                   Description=f"{tier} tier", VpcId=vpc)
        if g:
            sgs[tier] = g["GroupId"]
            p.cleanup(f"sg{tier}", lambda gid=g["GroupId"]: ec2.delete_security_group(GroupId=gid))
    if len(sgs) == 3:
        p.call("AuthorizeSecurityGroupIngress(0.0.0.0/0:443 → web)", ec2.authorize_security_group_ingress,
               GroupId=sgs["web"], IpPermissions=[{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                                                   "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}])
        p.call("AuthorizeSecurityGroupIngress(SG 참조 web→app)", ec2.authorize_security_group_ingress,
               GroupId=sgs["app"], IpPermissions=[{"IpProtocol": "tcp", "FromPort": 8080, "ToPort": 8080,
                                                   "UserIdGroupPairs": [{"GroupId": sgs["web"]}]}])
        p.call("AuthorizeSecurityGroupIngress(SG 참조 app→db)", ec2.authorize_security_group_ingress,
               GroupId=sgs["db"], IpPermissions=[{"IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
                                                  "UserIdGroupPairs": [{"GroupId": sgs["app"]}]}])
        d = ec2.describe_security_groups(GroupIds=[sgs["db"]])["SecurityGroups"][0]
        pairs = [pr.get("GroupId") for perm in d["IpPermissions"] for pr in perm.get("UserIdGroupPairs", [])]
        p.behavior("SG 체이닝 규칙이 조회됨(db ← app 참조)", sgs["app"] in pairs, str(pairs))
        eg_rules = d.get("IpPermissionsEgress", [])
        p.behavior("새 SG의 기본 아웃바운드 전체 허용 규칙", any(r.get("IpProtocol") == "-1" for r in eg_rules), str(eg_rules)[:120])
        rules = p.call("DescribeSecurityGroupRules", ec2.describe_security_group_rules,
                       Filters=[{"Name": "group-id", "Values": [sgs["db"]]}])
        if rules:
            p.behavior("DescribeSecurityGroupRules가 규칙을 반환", len(rules["SecurityGroupRules"]) >= 2,
                       f"{len(rules['SecurityGroupRules'])}개")
        p.expect_error("AuthorizeSecurityGroupIngress(중복)", ec2.authorize_security_group_ingress,
                       "InvalidPermission.Duplicate", GroupId=sgs["web"],
                       IpPermissions=[{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}],
                       what="같은 규칙 중복 추가 → InvalidPermission.Duplicate")
        p.expect_error("DeleteSecurityGroup(참조 중)", ec2.delete_security_group, "DependencyViolation",
                       GroupId=sgs["app"], what="다른 SG가 참조 중인 SG 삭제 → DependencyViolation")

    # NACL
    acl = p.call("CreateNetworkAcl", ec2.create_network_acl, VpcId=vpc)
    if acl:
        aid = acl["NetworkAcl"]["NetworkAclId"]
        p.cleanup("acl", lambda: ec2.delete_network_acl(NetworkAclId=aid))
        p.call("CreateNetworkAclEntry(100 allow 443)", ec2.create_network_acl_entry, NetworkAclId=aid, RuleNumber=100,
               Protocol="6", RuleAction="allow", Egress=False, CidrBlock="0.0.0.0/0", PortRange={"From": 443, "To": 443})
        p.call("CreateNetworkAclEntry(90 deny 203.0.113.0/24)", ec2.create_network_acl_entry, NetworkAclId=aid,
               RuleNumber=90, Protocol="-1", RuleAction="deny", Egress=False, CidrBlock="203.0.113.0/24")
        p.call("CreateNetworkAclEntry(egress 100 allow 1024-65535)", ec2.create_network_acl_entry, NetworkAclId=aid,
               RuleNumber=100, Protocol="6", RuleAction="allow", Egress=True, CidrBlock="0.0.0.0/0",
               PortRange={"From": 1024, "To": 65535})
        e = ec2.describe_network_acls(NetworkAclIds=[aid])["NetworkAcls"][0]["Entries"]
        nums = sorted((x["RuleNumber"], x["RuleAction"], x["Egress"]) for x in e)
        p.behavior("NACL 규칙 번호·allow/deny·기본 * deny(32767) 조회", (32767, "deny", False) in nums
                   and (90, "deny", False) in nums, str(nums))
        p.expect_error("CreateNetworkAclEntry(같은 번호)", ec2.create_network_acl_entry, "NetworkAclEntryAlreadyExists",
                       NetworkAclId=aid, RuleNumber=100, Protocol="6", RuleAction="allow", Egress=False,
                       CidrBlock="0.0.0.0/0", PortRange={"From": 80, "To": 80},
                       what="같은 규칙 번호 중복 → NetworkAclEntryAlreadyExists")
        if subnets:
            cur = ec2.describe_network_acls(Filters=[{"Name": "association.subnet-id", "Values": [subnets[1]]}])["NetworkAcls"]
            assoc = [a["NetworkAclAssociationId"] for n in cur for a in n["Associations"] if a["SubnetId"] == subnets[1]]
            if assoc:
                p.call("ReplaceNetworkAclAssociation", ec2.replace_network_acl_association,
                       AssociationId=assoc[0], NetworkAclId=aid)
                # 원래 기본 NACL로 되돌려야 삭제 가능
                default_acl = [n["NetworkAclId"] for n in cur][0]

                def _restore() -> None:
                    now = ec2.describe_network_acls(NetworkAclIds=[aid])["NetworkAcls"][0]["Associations"]
                    for a in now:
                        ec2.replace_network_acl_association(AssociationId=a["NetworkAclAssociationId"], NetworkAclId=default_acl)
                p.cleanup("acl-restore", _restore)
            else:
                p.behavior("서브넷이 기본 NACL에 자동 연결됨", False, "연결 정보 없음")

    # VPC 엔드포인트
    if rt_id:
        gw = p.call("CreateVpcEndpoint(Gateway S3)", ec2.create_vpc_endpoint, VpcId=vpc, VpcEndpointType="Gateway",
                    ServiceName="com.amazonaws.us-east-1.s3", RouteTableIds=[rt_id])
        if gw:
            eid = gw["VpcEndpoint"]["VpcEndpointId"]
            p.cleanup("vpce", lambda: ec2.delete_vpc_endpoints(VpcEndpointIds=[eid]))
            r = ec2.describe_route_tables(RouteTableIds=[rt_id])["RouteTables"][0]["Routes"]
            pl = [x for x in r if x.get("DestinationPrefixListId")]
            p.behavior("게이트웨이 엔드포인트가 라우팅 테이블에 prefix list 경로 추가", bool(pl), str(pl)[:150])
    if subnets and sgs:
        ie = p.call("CreateVpcEndpoint(Interface SQS)", ec2.create_vpc_endpoint, VpcId=vpc, VpcEndpointType="Interface",
                    ServiceName="com.amazonaws.us-east-1.sqs", SubnetIds=subnets[:1],
                    SecurityGroupIds=[sgs.get("app", list(sgs.values())[0])], PrivateDnsEnabled=False)
        if ie:
            eid2 = ie["VpcEndpoint"]["VpcEndpointId"]
            p.cleanup("vpce2", lambda: ec2.delete_vpc_endpoints(VpcEndpointIds=[eid2]))
            p.behavior("인터페이스 엔드포인트 ENI·DNS 항목", bool(ie["VpcEndpoint"].get("NetworkInterfaceIds"))
                       or bool(ie["VpcEndpoint"].get("DnsEntries")),
                       f"ENI {ie['VpcEndpoint'].get('NetworkInterfaceIds')} DNS {len(ie['VpcEndpoint'].get('DnsEntries', []))}개")
    p.call("DescribeVpcEndpointServices", ec2.describe_vpc_endpoint_services, MaxResults=5)

    # 피어링
    v2 = p.call("CreateVpc(피어용 10.1.0.0/16)", ec2.create_vpc, CidrBlock="10.1.0.0/16")
    if v2:
        vpc2 = v2["Vpc"]["VpcId"]
        p.cleanup("vpc2", lambda: ec2.delete_vpc(VpcId=vpc2))
        pc = p.call("CreateVpcPeeringConnection", ec2.create_vpc_peering_connection, VpcId=vpc, PeerVpcId=vpc2)
        if pc:
            pcx = pc["VpcPeeringConnection"]["VpcPeeringConnectionId"]
            s0 = pc["VpcPeeringConnection"]["Status"]["Code"]
            p.cleanup("pcx", lambda: ec2.delete_vpc_peering_connection(VpcPeeringConnectionId=pcx))
            def _pcx_status() -> str:
                return ec2.describe_vpc_peering_connections(VpcPeeringConnectionIds=[pcx])["VpcPeeringConnections"][0]["Status"]["Code"]
            wait_until(lambda: _pcx_status() != "initiating-request", 5)
            s1 = _pcx_status()
            p.behavior("피어링 생성 후 pending-acceptance 로 전이", s1 == "pending-acceptance", f"생성 직후 {s0} → {s1}")
            p.call("AcceptVpcPeeringConnection", ec2.accept_vpc_peering_connection, VpcPeeringConnectionId=pcx)
            ok = wait_until(lambda: _pcx_status() == "active", 5)
            p.behavior("피어링 수락 후 active", ok, f"최종 {_pcx_status()}")
            if rt_id:
                p.call("CreateRoute(10.1.0.0/16 → pcx)", ec2.create_route, RouteTableId=rt_id,
                       DestinationCidrBlock="10.1.0.0/16", VpcPeeringConnectionId=pcx)
        v3 = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
        p.cleanup("vpc3", lambda: ec2.delete_vpc(VpcId=v3))
        try:
            ov = ec2.create_vpc_peering_connection(VpcId=vpc, PeerVpcId=v3)["VpcPeeringConnection"]
            pcx3 = ov["VpcPeeringConnectionId"]
            p.cleanup("pcx3", lambda: ec2.delete_vpc_peering_connection(VpcPeeringConnectionId=pcx3))
            wait_until(lambda: ec2.describe_vpc_peering_connections(VpcPeeringConnectionIds=[pcx3])
                       ["VpcPeeringConnections"][0]["Status"]["Code"] != "initiating-request", 5)
            code = ec2.describe_vpc_peering_connections(VpcPeeringConnectionIds=[pcx3])["VpcPeeringConnections"][0]["Status"]["Code"]
            try:
                ec2.accept_vpc_peering_connection(VpcPeeringConnectionId=pcx3)
                code2 = ec2.describe_vpc_peering_connections(VpcPeeringConnectionIds=[pcx3])["VpcPeeringConnections"][0]["Status"]["Code"]
            except Exception as e:  # noqa: BLE001
                code2 = f"accept 오류: {getattr(e, 'response', {}).get('Error', {}).get('Code', type(e).__name__)}"
            p.behavior("CIDR이 겹치는 VPC 피어링은 실패(failed/거부)", code == "failed" or code2 == "failed",
                       f"상태 {code}, 수락 시도 → {code2}")
        except Exception as e:  # noqa: BLE001
            p.behavior("CIDR이 겹치는 VPC 피어링은 실패(failed/거부)", True, f"생성 거부: {str(e)[:120]}")

    # Transit Gateway
    tgw = p.call("CreateTransitGateway", ec2.create_transit_gateway, Description="probe")
    if tgw:
        tid = tgw["TransitGateway"]["TransitGatewayId"]
        p.cleanup("tgw", lambda: ec2.delete_transit_gateway(TransitGatewayId=tid))
        ok = wait_until(lambda: ec2.describe_transit_gateways(TransitGatewayIds=[tid])["TransitGateways"][0]["State"] == "available", 15)
        p.behavior("TGW pending→available", ok, f"생성 직후 {tgw['TransitGateway']['State']}")
        if subnets:
            att = p.call("CreateTransitGatewayVpcAttachment", ec2.create_transit_gateway_vpc_attachment,
                         TransitGatewayId=tid, VpcId=vpc, SubnetIds=subnets)
            if att:
                taid = att["TransitGatewayVpcAttachment"]["TransitGatewayAttachmentId"]
                p.cleanup("tgwa", lambda: ec2.delete_transit_gateway_vpc_attachment(TransitGatewayAttachmentId=taid))
                ok = wait_until(lambda: ec2.describe_transit_gateway_vpc_attachments(TransitGatewayAttachmentIds=[taid])
                                ["TransitGatewayVpcAttachments"][0]["State"] == "available", 15)
                p.behavior("TGW VPC 연결 pending→available", ok, f"생성 직후 {att['TransitGatewayVpcAttachment']['State']}")
        trt = p.call("CreateTransitGatewayRouteTable", ec2.create_transit_gateway_route_table, TransitGatewayId=tid)
        if trt:
            trid = trt["TransitGatewayRouteTable"]["TransitGatewayRouteTableId"]
            p.cleanup("tgwrt", lambda: ec2.delete_transit_gateway_route_table(TransitGatewayRouteTableId=trid))
        if rt_id:
            p.call("CreateRoute(10.2.0.0/16 → TGW)", ec2.create_route, RouteTableId=rt_id,
                   DestinationCidrBlock="10.2.0.0/16", TransitGatewayId=tid)

    # VPN 관련 (개념 실습 대비)
    cgw = p.call("CreateCustomerGateway", ec2.create_customer_gateway, Type="ipsec.1", PublicIp="203.0.113.10", BgpAsn=65000)
    vgw = p.call("CreateVpnGateway", ec2.create_vpn_gateway, Type="ipsec.1")
    if cgw:
        p.cleanup("cgw", lambda: ec2.delete_customer_gateway(CustomerGatewayId=cgw["CustomerGateway"]["CustomerGatewayId"]))
    if vgw:
        p.cleanup("vgw", lambda: ec2.delete_vpn_gateway(VpnGatewayId=vgw["VpnGateway"]["VpnGatewayId"]))
    if cgw and vgw:
        vpn = p.call("CreateVpnConnection", ec2.create_vpn_connection, Type="ipsec.1",
                     CustomerGatewayId=cgw["CustomerGateway"]["CustomerGatewayId"],
                     VpnGatewayId=vgw["VpnGateway"]["VpnGatewayId"], Options={"StaticRoutesOnly": True})
        if vpn:
            p.cleanup("vpn", lambda: ec2.delete_vpn_connection(VpnConnectionId=vpn["VpnConnection"]["VpnConnectionId"]))

    # Flow Logs (CloudWatch Logs 대상)
    fl = p.call("CreateFlowLogs(cloud-watch-logs)", ec2.create_flow_logs, ResourceIds=[vpc], ResourceType="VPC",
                TrafficType="ALL", LogGroupName=p.name("flowlogs"),
                DeliverLogsPermissionArn="arn:aws:iam::000000000000:role/flowlogs")
    if fl:
        ids = fl.get("FlowLogIds", [])
        p.behavior("Flow Log ID 발급(Unsuccessful 없음)", bool(ids) and not fl.get("Unsuccessful"), str(fl.get("Unsuccessful"))[:120])
        if ids:
            p.cleanup("fl", lambda: ec2.delete_flow_logs(FlowLogIds=ids))
    p.expect_error("DeleteVpc(의존 리소스 있음)", ec2.delete_vpc, "DependencyViolation", VpcId=vpc,
                   what="서브넷이 남은 VPC 삭제 → DependencyViolation")


CHECKS = {
    "ec2-vpc": run_vpc,
}
