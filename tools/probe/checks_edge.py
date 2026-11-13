"""M08: Route 53 / CloudFront / Global Accelerator / WAFv2 탐침."""

from __future__ import annotations

import json
import time

import boto3

from lib import ExternalTarget, Probe, container_curl, wait_until

from lib import _CFG  # noqa: E402  (같은 재시도·타임아웃 설정 재사용)


def _rr(name: str, rtype: str, value: str, **extra: object) -> dict:
    rrs: dict = {"Name": name, "Type": rtype, "TTL": 60, "ResourceRecords": [{"Value": value}]}
    rrs.update(extra)
    return {"Action": "UPSERT", "ResourceRecordSet": rrs}


def run_route53(p: Probe) -> None:
    r53, ec2 = p.client("route53"), p.client("ec2")
    domain = f"{p.suffix}.todayorder.example"
    hz = p.call("CreateHostedZone(퍼블릭)", r53.create_hosted_zone, Name=domain, CallerReference=p.name("hz"))
    if not hz:
        p.skip("레코드", "호스팅 영역 생성 실패")
        return
    zid = hz["HostedZone"]["Id"].split("/")[-1]
    p.behavior("퍼블릭 호스팅 영역에 NS/SOA 기본 레코드와 위임 세트", bool(hz.get("DelegationSet", {}).get("NameServers")),
               f"NameServers={hz.get('DelegationSet', {}).get('NameServers', [])[:2]}")

    def _del_zone() -> None:
        recs = r53.list_resource_record_sets(HostedZoneId=zid)["ResourceRecordSets"]
        ch = [{"Action": "DELETE", "ResourceRecordSet": r} for r in recs if r["Type"] not in ("NS", "SOA")]
        if ch:
            r53.change_resource_record_sets(HostedZoneId=zid, ChangeBatch={"Changes": ch})
        r53.delete_hosted_zone(Id=zid)

    p.cleanup("zone", _del_zone)

    vpc = ec2.create_vpc(CidrBlock="10.99.0.0/16")["Vpc"]["VpcId"]
    p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
    phz = p.call("CreateHostedZone(프라이빗, VPC 연결)", r53.create_hosted_zone, Name=f"internal.{domain}",
                 CallerReference=p.name("phz"), VPC={"VPCRegion": "us-east-1", "VPCId": vpc},
                 HostedZoneConfig={"PrivateZone": True, "Comment": "probe"})
    if phz:
        pid = phz["HostedZone"]["Id"].split("/")[-1]
        p.cleanup("phz", lambda: r53.delete_hosted_zone(Id=pid))
        p.behavior("프라이빗 호스팅 영역 PrivateZone=True", phz["HostedZone"]["Config"].get("PrivateZone") is True)

    ch = p.call("ChangeResourceRecordSets(A, CNAME)", r53.change_resource_record_sets, HostedZoneId=zid,
                ChangeBatch={"Changes": [_rr(f"api.{domain}", "A", "192.0.2.10"),
                                         _rr(f"www.{domain}", "CNAME", f"api.{domain}")]})
    if ch:
        cid = ch["ChangeInfo"]["Id"].split("/")[-1]
        first = ch["ChangeInfo"]["Status"]
        ok = wait_until(lambda: r53.get_change(Id=cid)["ChangeInfo"]["Status"] == "INSYNC", 15)
        p.behavior("GetChange 상태 PENDING → INSYNC", ok, f"처음 {first}, 이후 {r53.get_change(Id=cid)['ChangeInfo']['Status']}")

    hc = p.call("CreateHealthCheck(HTTPS)", r53.create_health_check, CallerReference=p.name("hc"),
                HealthCheckConfig={"Type": "HTTPS", "FullyQualifiedDomainName": f"api.{domain}", "Port": 443,
                                   "ResourcePath": "/health", "RequestInterval": 30, "FailureThreshold": 3})
    hc_id = hc["HealthCheck"]["Id"] if hc else None
    if hc_id:
        p.cleanup("hc", lambda: r53.delete_health_check(HealthCheckId=hc_id))
        st = p.call("GetHealthCheckStatus", r53.get_health_check_status, HealthCheckId=hc_id)
        if st is not None:
            obs = st.get("HealthCheckObservations", [])
            stat = [o.get("StatusReport", {}).get("Status", "")[:40] for o in obs[:2]]
            # 대상 도메인은 존재하지 않는(.example) 이름이다. 실제 검사라면 실패해야 한다.
            fake_ok = any(x.startswith("Success") for x in stat)
            p.behavior("상태 확인이 실제로 대상을 검사함(존재하지 않는 도메인 → 실패여야 함)", not fake_ok and bool(obs),
                       f"관찰 {len(obs)}건 {stat} — 존재하지 않는 대상인데 Success면 시뮬레이션된 결과")

    w = [_rr(f"w.{domain}", "A", "192.0.2.1", SetIdentifier="blue", Weight=90),
         _rr(f"w.{domain}", "A", "192.0.2.2", SetIdentifier="green", Weight=10)]
    p.call("ChangeResourceRecordSets(가중치)", r53.change_resource_record_sets, HostedZoneId=zid, ChangeBatch={"Changes": w})
    fo = [_rr(f"fo.{domain}", "A", "192.0.2.3", SetIdentifier="primary", Failover="PRIMARY",
              **({"HealthCheckId": hc_id} if hc_id else {})),
          _rr(f"fo.{domain}", "A", "192.0.2.4", SetIdentifier="secondary", Failover="SECONDARY")]
    p.call("ChangeResourceRecordSets(장애 조치)", r53.change_resource_record_sets, HostedZoneId=zid, ChangeBatch={"Changes": fo})
    lat = [_rr(f"lat.{domain}", "A", "192.0.2.5", SetIdentifier="use1", Region="us-east-1"),
           _rr(f"lat.{domain}", "A", "192.0.2.6", SetIdentifier="apne2", Region="ap-northeast-2")]
    p.call("ChangeResourceRecordSets(지연 시간)", r53.change_resource_record_sets, HostedZoneId=zid, ChangeBatch={"Changes": lat})
    geo = [_rr(f"geo.{domain}", "A", "192.0.2.7", SetIdentifier="kr", GeoLocation={"CountryCode": "KR"}),
           _rr(f"geo.{domain}", "A", "192.0.2.8", SetIdentifier="default", GeoLocation={"CountryCode": "*"})]
    p.call("ChangeResourceRecordSets(지리적 위치)", r53.change_resource_record_sets, HostedZoneId=zid, ChangeBatch={"Changes": geo})
    mv = [_rr(f"mv.{domain}", "A", f"192.0.2.{20 + i}", SetIdentifier=f"m{i}", MultiValueAnswer=True) for i in range(2)]
    p.call("ChangeResourceRecordSets(다중값 응답)", r53.change_resource_record_sets, HostedZoneId=zid, ChangeBatch={"Changes": mv})

    # Alias → S3 웹 사이트 엔드포인트 (us-east-1 S3 웹사이트 호스팅 영역 ID: Z3AQBSTGFYJSTF)
    alias = {"Action": "UPSERT", "ResourceRecordSet": {"Name": f"static.{domain}", "Type": "A", "AliasTarget": {
        # external-host-ok: Route 53 별칭 값(에뮬레이터가 질의하지 않음, 리뷰 DNS 기록 확인). AWS 가 요구하는 고정 이름
        "HostedZoneId": "Z3AQBSTGFYJSTF", "DNSName": "s3-website-us-east-1.amazonaws.com", "EvaluateTargetHealth": False}}}
    p.call("ChangeResourceRecordSets(Alias → S3 웹 사이트)", r53.change_resource_record_sets, HostedZoneId=zid,
           ChangeBatch={"Changes": [alias]})
    p.expect_error("ChangeResourceRecordSets(CNAME at apex)", r53.change_resource_record_sets, "InvalidChangeBatch",
                   HostedZoneId=zid, ChangeBatch={"Changes": [_rr(domain, "CNAME", "example.com")]},
                   what="영역 apex에 CNAME을 만들면 InvalidChangeBatch로 거부")

    lst = p.call("ListResourceRecordSets", r53.list_resource_record_sets, HostedZoneId=zid)
    if lst:
        types = sorted({r["Type"] for r in lst["ResourceRecordSets"]})
        p.behavior("레코드 목록에 생성한 레코드가 모두 보임", len(lst["ResourceRecordSets"]) >= 12,
                   f"{len(lst['ResourceRecordSets'])}개, 유형 {types}")

    t = p.call("TestDNSAnswer(가중치)", r53.test_dns_answer, HostedZoneId=zid, RecordName=f"w.{domain}", RecordType="A")
    if t:
        p.behavior("TestDNSAnswer가 가중치 레코드 중 하나를 응답", bool(t.get("RecordData")),
                   f"RecordData={t.get('RecordData')} ResponseCode={t.get('ResponseCode')}")
    p.skip("실제 DNS 질의(dig)", "에뮬레이터는 HTTPS API 포트 하나만 노출한다. 컨테이너에서 DNS(53) 포트를 내보내지 않으므로 dig로 확인 불가")


def run_cloudfront(p: Probe) -> None:
    cf, s3 = p.client("cloudfront"), p.client("s3")
    bucket = p.name("cforigin")
    s3.create_bucket(Bucket=bucket)
    p.cleanup("bucket", lambda: s3.delete_bucket(Bucket=bucket))

    oac = p.call("CreateOriginAccessControl", cf.create_origin_access_control, OriginAccessControlConfig={
        "Name": p.name("oac"), "SigningProtocol": "sigv4", "SigningBehavior": "always", "OriginAccessControlOriginType": "s3"})
    oac_id = oac["OriginAccessControl"]["Id"] if oac else ""
    if oac:
        etag = oac["ETag"]
        p.cleanup("oac", lambda: cf.delete_origin_access_control(Id=oac_id, IfMatch=cf.get_origin_access_control(Id=oac_id)["ETag"]))
        del etag

    cp = p.call("CreateCachePolicy", cf.create_cache_policy, CachePolicyConfig={
        "Name": p.name("cp"), "MinTTL": 0, "DefaultTTL": 86400, "MaxTTL": 31536000,
        "ParametersInCacheKeyAndForwardedToOrigin": {
            "EnableAcceptEncodingGzip": True,
            "HeadersConfig": {"HeaderBehavior": "none"}, "CookiesConfig": {"CookieBehavior": "none"},
            "QueryStringsConfig": {"QueryStringBehavior": "none"}}})
    cp_id = cp["CachePolicy"]["Id"] if cp else "658327ea-f89d-4fab-a63d-7e88639e58f6"  # 관리형 CachingOptimized
    if cp:
        p.cleanup("cp", lambda: cf.delete_cache_policy(Id=cp_id, IfMatch=cf.get_cache_policy(Id=cp_id)["ETag"]))

    # 원본 이름은 S3 형식(<버킷>.s3.<리전>.amazonaws.com)이어야 한다. 에뮬레이터는 이 이름을 보고 같은 에뮬레이터의
    # S3 버킷에 연결하고 OAC 를 집행한다(직접 확인: <버킷>.s3.todayorder.invalid 로 주면 버킷 정책 없이도 200 — OAC 미집행,
    # origin.todayorder.invalid 로 주면 404 NoSuchBucket). PR #15 리뷰의 DNS 기록과 --no-dns 비교 실행에서
    # 이 이름의 DNS 질의는 관찰되지 않았다(이름 해석 없이 내부에서 매핑).
    # external-host-ok: 에뮬레이터가 내부 S3 로 매핑하는 원본 이름(DNS 질의 없음 확인)
    origin = {"Id": "s3origin", "DomainName": f"{bucket}.s3.us-east-1.amazonaws.com",
              "S3OriginConfig": {"OriginAccessIdentity": ""}}
    if oac_id:
        origin["OriginAccessControlId"] = oac_id
    dist = p.call("CreateDistribution(S3 오리진 + OAC)", cf.create_distribution, DistributionConfig={
        "CallerReference": p.name("dist"), "Comment": "probe", "Enabled": True,
        "Origins": {"Quantity": 1, "Items": [origin]},
        "DefaultCacheBehavior": {"TargetOriginId": "s3origin", "ViewerProtocolPolicy": "redirect-to-https",
                                 "CachePolicyId": cp_id},
        "DefaultRootObject": "index.html"})
    if dist:
        d = dist["Distribution"]
        did = d["Id"]
        dom = d.get("DomainName", "")
        p.behavior("배포 도메인 이름(*.cloudfront.net) 발급", dom.endswith(".cloudfront.net"),
                   f"DomainName={dom} Status={d.get('Status')} — 에뮬레이터는 컨테이너 안의 로컬 포트를 준다")
        ok = wait_until(lambda: cf.get_distribution(Id=did)["Distribution"]["Status"] == "Deployed", 20)
        p.behavior("배포 상태 InProgress → Deployed", ok,
                   f"처음 {d.get('Status')}, 이후 {cf.get_distribution(Id=did)['Distribution']['Status']}")
        # 데이터 플레인: 배포 주소는 컨테이너 내부 포트라 호스트에서는 닿지 않는다. docker exec 로 확인.
        s3.put_object(Bucket=bucket, Key="index.html", Body=b"hello-cloudfront")
        p.cleanup("obj", lambda: s3.delete_object(Bucket=bucket, Key="index.html"))
        def _get() -> tuple[str, str]:
            r = container_curl(f"http://{dom}/index.html", "-w", "\\n%{http_code}").stdout
            body, _, code = r.rpartition("\n")
            return code.strip(), body

        try:
            if not p.target_ok("CloudFront 데이터 플레인(컨테이너 안 curl)", dom):
                raise ExternalTarget(dom)
            code0, _ = _get()
            p.behavior("버킷 정책 없이 배포로 GET → 403 (OAC가 허용되지 않음)", code0 == "403", f"HTTP {code0}")
            s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps({"Version": "2012-10-17", "Statement": [{
                "Effect": "Allow", "Principal": {"Service": "cloudfront.amazonaws.com"}, "Action": "s3:GetObject",
                "Resource": f"arn:aws:s3:::{bucket}/*",
                "Condition": {"StringEquals": {"AWS:SourceArn": d["ARN"]}}}]}))
            code1, body = _get()
            p.behavior("OAC용 버킷 정책 추가 후 배포 주소로 GET → 객체 반환 (컨테이너 안에서 curl)",
                       code1 == "200" and "hello-cloudfront" in body, f"HTTP {code1} {body[:40]!r}")
        except ExternalTarget:
            pass  # target_ok 가 이미 SKIP 을 남겼다
        except Exception as e:  # noqa: BLE001
            p.skip("CloudFront 데이터 플레인", f"docker exec 불가: {type(e).__name__}")
        inv = p.call("CreateInvalidation", cf.create_invalidation, DistributionId=did, InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": ["/*"]}, "CallerReference": p.name("inv")})
        if inv:
            p.behavior("무효화 상태", True, inv["Invalidation"]["Status"])

        def _disable_delete() -> None:
            g = cf.get_distribution_config(Id=did)
            cfg = g["DistributionConfig"]
            cfg["Enabled"] = False
            e = cf.update_distribution(Id=did, IfMatch=g["ETag"], DistributionConfig=cfg)["ETag"]
            cf.delete_distribution(Id=did, IfMatch=e)

        p.cleanup("dist", _disable_delete)

    fn_code = b"function handler(event) { var r = event.request; r.headers['x-probe'] = {value: '1'}; return r; }"
    fn = p.call("CreateFunction(CloudFront Functions)", cf.create_function, Name=p.name("fn")[:64],
                FunctionConfig={"Comment": "probe", "Runtime": "cloudfront-js-2.0"}, FunctionCode=fn_code)
    if fn:
        name = fn["FunctionSummary"]["Name"]
        etag = fn["ETag"]
        p.cleanup("fn", lambda: cf.delete_function(Name=name, IfMatch=cf.describe_function(Name=name)["ETag"]))
        ev = (b'{"version":"1.0","context":{"eventType":"viewer-request"},"viewer":{"ip":"1.2.3.4"},'
              b'"request":{"method":"GET","uri":"/index.html","headers":{},"cookies":{},"querystring":{}}}')
        t = p.call("TestFunction", cf.test_function, Name=name, IfMatch=etag, Stage="DEVELOPMENT", EventObject=ev)
        if t:
            out = t.get("TestResult", {}).get("FunctionOutput", "")
            p.behavior("TestFunction이 함수 코드를 실제로 실행(x-probe 헤더 추가)", "x-probe" in out, out[:120])


def run_globalaccelerator(p: Probe) -> None:
    for region in ("us-east-1", "us-west-2"):
        ga = boto3.client("globalaccelerator", region_name=region, config=_CFG)
        acc = p.call(f"CreateAccelerator({region} 클라이언트)", ga.create_accelerator, Name=p.name("ga")[:60],
                     IpAddressType="IPV4", Enabled=True, IdempotencyToken=p.name(region))
        if not acc:
            continue
        a = acc["Accelerator"]
        arn = a["AcceleratorArn"]
        ips = [ip for s in a.get("IpSets", []) for ip in s.get("IpAddresses", [])]
        p.behavior(f"정적 애니캐스트 IP 2개 할당({region})", len(ips) == 2, f"IP {ips} Status={a.get('Status')}")

        def _cleanup(ga=ga, arn=arn) -> None:
            for lst in ga.list_listeners(AcceleratorArn=arn)["Listeners"]:
                for eg in ga.list_endpoint_groups(ListenerArn=lst["ListenerArn"])["EndpointGroups"]:
                    ga.delete_endpoint_group(EndpointGroupArn=eg["EndpointGroupArn"])
                ga.delete_listener(ListenerArn=lst["ListenerArn"])
            ga.update_accelerator(AcceleratorArn=arn, Enabled=False)
            ga.delete_accelerator(AcceleratorArn=arn)

        p.cleanup(f"ga-{region}", _cleanup)
        lst = p.call("CreateListener(TCP 443)", ga.create_listener, AcceleratorArn=arn, Protocol="TCP",
                     PortRanges=[{"FromPort": 443, "ToPort": 443}], IdempotencyToken=p.name("l" + region))
        if lst:
            p.call("CreateEndpointGroup(ap-northeast-2)", ga.create_endpoint_group,
                   ListenerArn=lst["Listener"]["ListenerArn"], EndpointGroupRegion="ap-northeast-2",
                   TrafficDialPercentage=100, IdempotencyToken=p.name("eg" + region))
        break


def run_wafv2(p: Probe) -> None:
    waf = p.client("wafv2")
    ips = p.call("CreateIPSet(REGIONAL)", waf.create_ip_set, Name=p.name("ips"), Scope="REGIONAL", IPAddressVersion="IPV4",
                 Addresses=["198.51.100.0/24"])
    rules = [{
        "Name": "rate-limit", "Priority": 1, "Action": {"Block": {}},
        "Statement": {"RateBasedStatement": {"Limit": 1000, "AggregateKeyType": "IP"}},
        "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "rate"}}, {
        "Name": "aws-common", "Priority": 2, "OverrideAction": {"None": {}},
        "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS", "Name": "AWSManagedRulesCommonRuleSet"}},
        "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "common"}}]
    if ips:
        rules.append({"Name": "block-ips", "Priority": 0, "Action": {"Block": {}},
                      "Statement": {"IPSetReferenceStatement": {"ARN": ips["Summary"]["ARN"]}},
                      "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True,
                                           "MetricName": "ips"}})
    vis = {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "probe"}
    acl = p.call("CreateWebACL(REGIONAL, 속도 기반 + 관리형 규칙 그룹)", waf.create_web_acl, Name=p.name("acl"),
                 Scope="REGIONAL", DefaultAction={"Allow": {}}, Rules=rules, VisibilityConfig=vis)
    if acl:
        arn = acl["Summary"]["ARN"]
        got = p.call("GetWebACL", waf.get_web_acl, Name=p.name("acl"), Scope="REGIONAL", Id=acl["Summary"]["Id"])
        if got:
            p.behavior("Web ACL에 규칙 3개가 저장됨", len(got["WebACL"]["Rules"]) == len(rules),
                       f"{len(got['WebACL']['Rules'])}개, Capacity={got['WebACL'].get('Capacity')}")

        def _del_acl() -> None:
            g = waf.get_web_acl(Name=p.name("acl"), Scope="REGIONAL", Id=acl["Summary"]["Id"])
            waf.delete_web_acl(Name=p.name("acl"), Scope="REGIONAL", Id=acl["Summary"]["Id"], LockToken=g["LockToken"])

        p.cleanup("acl", _del_acl)
        # ALB 연결
        ec2, elb = p.client("ec2"), p.client("elbv2")
        try:
            vpc = ec2.create_vpc(CidrBlock="10.98.0.0/16")["Vpc"]["VpcId"]
            p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
            subs = []
            for i, az in enumerate(("us-east-1a", "us-east-1b")):
                sid = ec2.create_subnet(VpcId=vpc, CidrBlock=f"10.98.{i}.0/24", AvailabilityZone=az)["Subnet"]["SubnetId"]
                subs.append(sid)
                p.cleanup(f"sub{i}", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
            igw = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
            ec2.attach_internet_gateway(InternetGatewayId=igw, VpcId=vpc)
            p.cleanup("igw", lambda: (ec2.detach_internet_gateway(InternetGatewayId=igw, VpcId=vpc),
                                      ec2.delete_internet_gateway(InternetGatewayId=igw)))
            lb = elb.create_load_balancer(Name=p.name("alb")[:32], Subnets=subs, Type="application")
            lb_arn = lb["LoadBalancers"][0]["LoadBalancerArn"]
            p.cleanup("alb", lambda: elb.delete_load_balancer(LoadBalancerArn=lb_arn))
        except Exception as e:  # noqa: BLE001
            p.skip("AssociateWebACL", f"ALB 준비 실패: {type(e).__name__}: {str(e)[:100]}")
            lb_arn = None
        if lb_arn:
            if p.call("AssociateWebACL(ALB)", waf.associate_web_acl, WebACLArn=arn, ResourceArn=lb_arn) is not None:
                p.cleanup("assoc", lambda: waf.disassociate_web_acl(ResourceArn=lb_arn))
                g = p.call("GetWebACLForResource", waf.get_web_acl_for_resource, ResourceArn=lb_arn)
                if g:
                    p.behavior("ALB에 연결된 Web ACL 조회", g.get("WebACL", {}).get("ARN") == arn)
    if ips:
        p.cleanup("ips", lambda: waf.delete_ip_set(Name=p.name("ips"), Scope="REGIONAL", Id=ips["Summary"]["Id"],
                                                   LockToken=waf.get_ip_set(Name=p.name("ips"), Scope="REGIONAL",
                                                                            Id=ips["Summary"]["Id"])["LockToken"]))
    cfacl = p.call("CreateWebACL(CLOUDFRONT 범위)", waf.create_web_acl, Name=p.name("cfacl"), Scope="CLOUDFRONT",
                   DefaultAction={"Allow": {}}, Rules=[], VisibilityConfig=vis)
    if cfacl:
        p.cleanup("cfacl", lambda: waf.delete_web_acl(Name=p.name("cfacl"), Scope="CLOUDFRONT", Id=cfacl["Summary"]["Id"],
                                                      LockToken=cfacl["Summary"]["LockToken"]))
    time.sleep(0)


CHECKS = {
    "route53": run_route53,
    "cloudfront": run_cloudfront,
    "globalaccelerator": run_globalaccelerator,
    "wafv2": run_wafv2,
}
