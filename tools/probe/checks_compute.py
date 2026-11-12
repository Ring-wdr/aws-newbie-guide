"""M03: EC2 인스턴스 / EBS·AMI·시작 템플릿 / ELBv2 / Auto Scaling 탐침."""

from __future__ import annotations

import base64
import os
import subprocess
import time
from typing import Any

from lib import Probe, wait_until


def _find_ami(p: Probe) -> str | None:
    ec2, ssm = p.client("ec2"), p.client("ssm")
    r = p.call("SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…)", ssm.get_parameter,
               Name="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64")
    if r:
        return r["Parameter"]["Value"]
    imgs = p.call("DescribeImages(Owners=amazon)", ec2.describe_images, Owners=["amazon"])
    if imgs and imgs["Images"]:
        return imgs["Images"][0]["ImageId"]
    return None


def _subnet(p: Probe) -> tuple[str | None, list[str]]:
    """실습용 VPC + 서브넷 2개 (정리 등록 포함)."""
    ec2 = p.client("ec2")
    try:
        vpc = ec2.create_vpc(CidrBlock="10.20.0.0/16")["Vpc"]["VpcId"]
    except Exception:  # noqa: BLE001
        return None, []
    p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
    subs: list[str] = []
    for az, cidr in (("us-east-1a", "10.20.1.0/24"), ("us-east-1b", "10.20.2.0/24")):
        try:
            sid = ec2.create_subnet(VpcId=vpc, CidrBlock=cidr, AvailabilityZone=az)["Subnet"]["SubnetId"]
            subs.append(sid)
            p.cleanup("subnet", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
        except Exception:  # noqa: BLE001
            pass
    return vpc, subs


def _state(ec2: Any, iid: str) -> str:
    return ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]["State"]["Name"]


def run_instances(p: Probe) -> None:
    ec2 = p.client("ec2")
    ami = _find_ami(p)
    if not ami:
        p.skip("인스턴스 탐침", "AMI 없음")
        return
    p.behavior("사용 가능한 AMI 확보", True, ami)
    kp = p.call("CreateKeyPair", ec2.create_key_pair, KeyName=p.name("key"))
    if kp:
        p.behavior("CreateKeyPair가 개인 키(KeyMaterial)를 반환", "BEGIN" in kp.get("KeyMaterial", ""), kp.get("KeyFingerprint", "")[:40])
        p.cleanup("kp", lambda: ec2.delete_key_pair(KeyName=p.name("key")))
    vpc, subs = _subnet(p)
    kw: dict[str, Any] = {"SubnetId": subs[0]} if subs else {}
    ud = "#!/bin/bash\necho hello > /tmp/hello\n"
    if kp:
        kw["KeyName"] = p.name("key")
    r = p.call("RunInstances(t3.micro, UserData)", ec2.run_instances, ImageId=ami, InstanceType="t3.micro", MinCount=1,
               MaxCount=1, UserData=ud,
               TagSpecifications=[{"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": p.name("web")}]}], **kw)
    if not r:
        p.skip("상태 전이", "RunInstances 실패")
        return
    inst = r["Instances"][0]
    iid = inst["InstanceId"]
    p.cleanup("term", lambda: ec2.terminate_instances(InstanceIds=[iid]))
    first = inst["State"]["Name"]
    seen = [first]

    def _running() -> bool:
        s = _state(ec2, iid)
        if s != seen[-1]:
            seen.append(s)
        return s == "running"
    ok = wait_until(_running, 20)
    p.behavior("인스턴스 상태 pending→running", ok, " → ".join(seen))
    d = ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]
    p.behavior("프라이빗 IP·서브넷·AZ가 채워짐", bool(d.get("PrivateIpAddress")) and bool(d.get("Placement", {}).get("AvailabilityZone")),
               f"{d.get('PrivateIpAddress')} {d.get('SubnetId')} {d.get('Placement', {}).get('AvailabilityZone')}")
    ua = p.call("DescribeInstanceAttribute(userData)", ec2.describe_instance_attribute, InstanceId=iid, Attribute="userData")
    if ua:
        val = ua.get("UserData", {}).get("Value", "")
        try:
            dec = base64.b64decode(val).decode() if val else ""
        except Exception:  # noqa: BLE001
            dec = ""
        p.behavior("사용자 데이터가 저장되어 조회됨(실행은 안 됨)", dec == ud, repr(dec[:40]))
    p.call("DescribeInstanceStatus", ec2.describe_instance_status, InstanceIds=[iid], IncludeAllInstances=True)
    p.call("ModifyInstanceMetadataOptions(HttpTokens=required)", ec2.modify_instance_metadata_options,
           InstanceId=iid, HttpTokens="required", HttpEndpoint="enabled")
    mo = ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0].get("MetadataOptions", {})
    p.behavior("IMDSv2 필수(HttpTokens=required) 반영", mo.get("HttpTokens") == "required", str(mo)[:120])
    p.call("CreateTags", ec2.create_tags, Resources=[iid], Tags=[{"Key": "env", "Value": "dev"}])
    t = p.call("DescribeTags", ec2.describe_tags, Filters=[{"Name": "resource-id", "Values": [iid]}])
    if t:
        p.behavior("태그 조회", any(x["Key"] == "env" for x in t["Tags"]), str([x["Key"] for x in t["Tags"]]))

    if p.call("StopInstances", ec2.stop_instances, InstanceIds=[iid]) is not None:
        seen2 = [_state(ec2, iid)]

        def _stopped() -> bool:
            s = _state(ec2, iid)
            if s != seen2[-1]:
                seen2.append(s)
            return s == "stopped"
        p.behavior("running→stopping→stopped", wait_until(_stopped, 20), " → ".join(seen2))
    p.call("ModifyInstanceAttribute(InstanceType=t3.small, 중지 상태)", ec2.modify_instance_attribute,
           InstanceId=iid, InstanceType={"Value": "t3.small"})
    if p.call("StartInstances", ec2.start_instances, InstanceIds=[iid]) is not None:
        p.behavior("stopped→running", wait_until(lambda: _state(ec2, iid) == "running", 20), _state(ec2, iid))
    p.call("RebootInstances", ec2.reboot_instances, InstanceIds=[iid])
    p.call("MonitorInstances(세부 모니터링)", ec2.monitor_instances, InstanceIds=[iid])
    p.call("RunInstances(스팟: InstanceMarketOptions)", ec2.run_instances, ImageId=ami, InstanceType="t3.micro",
           MinCount=1, MaxCount=1, InstanceMarketOptions={"MarketType": "spot"},
           **({"SubnetId": kw["SubnetId"]} if "SubnetId" in kw else {}))
    p.call("DescribeSpotPriceHistory", ec2.describe_spot_price_history, InstanceTypes=["t3.micro"], MaxResults=5)
    p.call("DescribeInstanceTypes(t3.micro)", ec2.describe_instance_types, InstanceTypes=["t3.micro"])
    p.call("CreatePlacementGroup(cluster)", ec2.create_placement_group, GroupName=p.name("pg"), Strategy="cluster")
    p.cleanup("pg", lambda: ec2.delete_placement_group(GroupName=p.name("pg")))
    if p.call("TerminateInstances", ec2.terminate_instances, InstanceIds=[iid]) is not None:
        p.behavior("→shutting-down→terminated", wait_until(lambda: _state(ec2, iid) == "terminated", 20), _state(ec2, iid))
    # 스팟으로 띄운 인스턴스 정리
    try:
        rs = ec2.describe_instances(Filters=[{"Name": "instance-lifecycle", "Values": ["spot"]}])["Reservations"]
        ids = [i["InstanceId"] for r_ in rs for i in r_["Instances"]]
        if ids:
            ec2.terminate_instances(InstanceIds=ids)
    except Exception:  # noqa: BLE001
        pass


def run_ebs_ami(p: Probe) -> None:
    ec2 = p.client("ec2")
    ami = _find_ami(p)
    v = p.call("CreateVolume(gp3 10GiB)", ec2.create_volume, AvailabilityZone="us-east-1a", Size=10, VolumeType="gp3")
    v2 = p.call("CreateVolume(io2 Iops=3000, MultiAttach)", ec2.create_volume, AvailabilityZone="us-east-1a", Size=10,
                VolumeType="io2", Iops=3000, MultiAttachEnabled=True)
    if v2:
        p.cleanup("v2", lambda: ec2.delete_volume(VolumeId=v2["VolumeId"]))
    p.expect_error("CreateVolume(st1 1GiB)", ec2.create_volume, "InvalidParameterValue", AvailabilityZone="us-east-1a",
                   Size=1, VolumeType="st1", what="st1 최소 크기(125GiB) 미만 → InvalidParameterValue")
    vid = v["VolumeId"] if v else None
    if vid:
        p.cleanup("vol", lambda: ec2.delete_volume(VolumeId=vid))
        p.behavior("볼륨 creating→available", wait_until(
            lambda: ec2.describe_volumes(VolumeIds=[vid])["Volumes"][0]["State"] == "available", 15), f"생성 직후 {v['State']}")
    iid = None
    if ami and vid:
        r = p.call("RunInstances(볼륨 연결용)", ec2.run_instances, ImageId=ami, InstanceType="t3.micro", MinCount=1,
                   MaxCount=1, Placement={"AvailabilityZone": "us-east-1a"})
        if r:
            iid = r["Instances"][0]["InstanceId"]
            p.cleanup("term", lambda: ec2.terminate_instances(InstanceIds=[iid]))
            wait_until(lambda: _state(ec2, iid) == "running", 15)
            if p.call("AttachVolume", ec2.attach_volume, VolumeId=vid, InstanceId=iid, Device="/dev/sdf") is not None:
                p.behavior("볼륨 in-use(attached)", wait_until(
                    lambda: ec2.describe_volumes(VolumeIds=[vid])["Volumes"][0]["State"] == "in-use", 15),
                    ec2.describe_volumes(VolumeIds=[vid])["Volumes"][0]["State"])
                p.call("DetachVolume", ec2.detach_volume, VolumeId=vid)
                wait_until(lambda: ec2.describe_volumes(VolumeIds=[vid])["Volumes"][0]["State"] == "available", 15)
            p.expect_error("AttachVolume(다른 AZ)", ec2.attach_volume, "InvalidVolume.ZoneMismatch",
                           VolumeId=ec2.create_volume(AvailabilityZone="us-east-1b", Size=1, VolumeType="gp3")["VolumeId"],
                           InstanceId=iid, Device="/dev/sdg", what="다른 AZ의 볼륨 연결 → InvalidVolume.ZoneMismatch")
    if vid:
        p.call("ModifyVolume(gp3 → 20GiB)", ec2.modify_volume, VolumeId=vid, Size=20)
        s = p.call("CreateSnapshot", ec2.create_snapshot, VolumeId=vid, Description="probe")
        if s:
            sid = s["SnapshotId"]
            p.cleanup("snap", lambda: ec2.delete_snapshot(SnapshotId=sid))
            p.behavior("스냅샷 pending→completed", wait_until(
                lambda: ec2.describe_snapshots(SnapshotIds=[sid])["Snapshots"][0]["State"] == "completed", 20),
                f"생성 직후 {s['State']}")
            c = p.call("CopySnapshot(Encrypted)", ec2.copy_snapshot, SourceSnapshotId=sid, SourceRegion="us-east-1",
                       Encrypted=True)
            if c:
                p.cleanup("snap2", lambda: ec2.delete_snapshot(SnapshotId=c["SnapshotId"]))
                cs = ec2.describe_snapshots(SnapshotIds=[c["SnapshotId"]])["Snapshots"][0]
                p.behavior("암호화 사본 스냅샷 Encrypted=True", cs.get("Encrypted") is True, str(cs.get("Encrypted")))
            vr = p.call("CreateVolume(SnapshotId=… 스냅샷에서 복원)", ec2.create_volume, AvailabilityZone="us-east-1b", SnapshotId=sid)
            if vr:
                p.cleanup("vr", lambda: ec2.delete_volume(VolumeId=vr["VolumeId"]))
            reg = p.call("RegisterImage(스냅샷 기반)", ec2.register_image, Name=p.name("reg"), RootDeviceName="/dev/xvda",
                         Architecture="x86_64", VirtualizationType="hvm",
                         BlockDeviceMappings=[{"DeviceName": "/dev/xvda", "Ebs": {"SnapshotId": sid}}])
            if reg:
                p.cleanup("dereg", lambda: ec2.deregister_image(ImageId=reg["ImageId"]))
    if iid:
        img = p.call("CreateImage(인스턴스에서 AMI)", ec2.create_image, InstanceId=iid, Name=p.name("ami"), NoReboot=True)
        if img:
            aid = img["ImageId"]
            p.cleanup("dereg2", lambda: ec2.deregister_image(ImageId=aid))
            p.behavior("AMI pending→available", wait_until(
                lambda: ec2.describe_images(ImageIds=[aid])["Images"][0]["State"] == "available", 20),
                ec2.describe_images(ImageIds=[aid])["Images"][0]["State"])
            p.call("CopyImage", ec2.copy_image, SourceImageId=aid, SourceRegion="us-east-1", Name=p.name("ami-copy"))
    p.call("EnableEbsEncryptionByDefault", ec2.enable_ebs_encryption_by_default)
    g = p.call("GetEbsEncryptionByDefault", ec2.get_ebs_encryption_by_default)
    if g:
        p.behavior("기본 암호화 켜짐 반영", g.get("EbsEncryptionByDefault") is True, str(g.get("EbsEncryptionByDefault")))
        ve = ec2.create_volume(AvailabilityZone="us-east-1a", Size=1, VolumeType="gp3")
        p.cleanup("ve", lambda: ec2.delete_volume(VolumeId=ve["VolumeId"]))
        p.behavior("기본 암호화 후 새 볼륨이 Encrypted=True", ve.get("Encrypted") is True, str(ve.get("Encrypted")))
    p.cleanup("disable-enc", lambda: ec2.disable_ebs_encryption_by_default())

    # 시작 템플릿
    lt = p.call("CreateLaunchTemplate", ec2.create_launch_template, LaunchTemplateName=p.name("lt"),
                LaunchTemplateData={"ImageId": ami or "ami-00000000000000010", "InstanceType": "t3.micro"})
    if lt:
        ltid = lt["LaunchTemplate"]["LaunchTemplateId"]
        p.cleanup("lt", lambda: ec2.delete_launch_template(LaunchTemplateId=ltid))
        v = p.call("CreateLaunchTemplateVersion", ec2.create_launch_template_version, LaunchTemplateId=ltid,
                   SourceVersion="1", LaunchTemplateData={"InstanceType": "t3.small"})
        if v:
            vs = ec2.describe_launch_template_versions(LaunchTemplateId=ltid)["LaunchTemplateVersions"]
            got = sorted((x["VersionNumber"], x["LaunchTemplateData"].get("InstanceType"), x["LaunchTemplateData"].get("ImageId") is not None) for x in vs)
            p.behavior("버전 2가 생기고 SourceVersion의 ImageId를 상속", got == [(1, "t3.micro", True), (2, "t3.small", True)], str(got))
            p.call("ModifyLaunchTemplate(DefaultVersion=2)", ec2.modify_launch_template, LaunchTemplateId=ltid, DefaultVersion="2")
        if ami:
            r = p.call("RunInstances(LaunchTemplate)", ec2.run_instances, MinCount=1, MaxCount=1,
                       LaunchTemplate={"LaunchTemplateId": ltid, "Version": "$Latest"})
            if r:
                i = r["Instances"][0]
                p.cleanup("lt-term", lambda: ec2.terminate_instances(InstanceIds=[i["InstanceId"]]))
                p.behavior("시작 템플릿 최신 버전 값으로 인스턴스 생성", i.get("InstanceType") == ("t3.small" if v else "t3.micro"),
                           i.get("InstanceType"))


def run_elbv2(p: Probe) -> None:
    elb, ec2 = p.client("elbv2"), p.client("ec2")
    vpc, subs = _subnet(p)
    if not vpc or len(subs) < 2:
        p.skip("ELB 탐침", "VPC/서브넷 준비 실패")
        return
    igw = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
    ec2.attach_internet_gateway(InternetGatewayId=igw, VpcId=vpc)
    p.cleanup("igw", lambda: (ec2.detach_internet_gateway(InternetGatewayId=igw, VpcId=vpc),
                              ec2.delete_internet_gateway(InternetGatewayId=igw)))
    sg = ec2.create_security_group(GroupName=p.name("alb-sg"), Description="alb", VpcId=vpc)["GroupId"]
    p.cleanup("sg", lambda: ec2.delete_security_group(GroupId=sg))
    lb = p.call("CreateLoadBalancer(ALB)", elb.create_load_balancer, Name=f"to-alb-{p.suffix}", Subnets=subs,
                SecurityGroups=[sg], Scheme="internet-facing", Type="application")
    lb_arn = lb["LoadBalancers"][0]["LoadBalancerArn"] if lb else None
    if lb:
        d = lb["LoadBalancers"][0]
        p.cleanup("lb", lambda: elb.delete_load_balancer(LoadBalancerArn=lb_arn))
        p.behavior("ALB DNSName 발급", bool(d.get("DNSName")), d.get("DNSName", ""))
        p.behavior("ALB provisioning→active", wait_until(
            lambda: elb.describe_load_balancers(LoadBalancerArns=[lb_arn])["LoadBalancers"][0]["State"]["Code"] == "active", 20),
            f"생성 직후 {d['State']['Code']}")
    nlb = p.call("CreateLoadBalancer(NLB)", elb.create_load_balancer, Name=f"to-nlb-{p.suffix}", Subnets=subs,
                 Scheme="internal", Type="network")
    if nlb:
        p.cleanup("nlb", lambda: elb.delete_load_balancer(LoadBalancerArn=nlb["LoadBalancers"][0]["LoadBalancerArn"]))
    tg = p.call("CreateTargetGroup(instance, /health)", elb.create_target_group, Name=f"to-tg-{p.suffix}", Protocol="HTTP",
                Port=8080, VpcId=vpc, TargetType="instance", HealthCheckPath="/health")
    tg_arn = tg["TargetGroups"][0]["TargetGroupArn"] if tg else None
    if tg_arn:
        p.cleanup("tg", lambda: elb.delete_target_group(TargetGroupArn=tg_arn))
        ami = _find_ami(p)
        r = ec2.run_instances(ImageId=ami, InstanceType="t3.micro", MinCount=2, MaxCount=2, SubnetId=subs[0]) if ami else None
        ids = [i["InstanceId"] for i in r["Instances"]] if r else []
        if ids:
            p.cleanup("term", lambda: ec2.terminate_instances(InstanceIds=ids))
            wait_until(lambda: all(_state(ec2, i) == "running" for i in ids), 15)
            p.call("RegisterTargets", elb.register_targets, TargetGroupArn=tg_arn, Targets=[{"Id": i} for i in ids])
            time.sleep(3)
            h = p.call("DescribeTargetHealth", elb.describe_target_health, TargetGroupArn=tg_arn)
            if h:
                states = [x["TargetHealth"]["State"] for x in h["TargetHealthDescriptions"]]
                p.behavior("대상 헬스 상태(실제 헬스 체크는 없음)", True, f"{states} — 리스너 없음 상태")
        p.call("ModifyTargetGroupAttributes(stickiness)", elb.modify_target_group_attributes, TargetGroupArn=tg_arn,
               Attributes=[{"Key": "stickiness.enabled", "Value": "true"},
                           {"Key": "stickiness.type", "Value": "lb_cookie"}])
        a = elb.describe_target_group_attributes(TargetGroupArn=tg_arn)["Attributes"]
        p.behavior("스티키 세션 속성 반영", {"Key": "stickiness.enabled", "Value": "true"} in a, "")
    if lb_arn and tg_arn:
        ls = p.call("CreateListener(HTTP:80 → TG)", elb.create_listener, LoadBalancerArn=lb_arn, Protocol="HTTP", Port=80,
                    DefaultActions=[{"Type": "forward", "TargetGroupArn": tg_arn}])
        if ls:
            la = ls["Listeners"][0]["ListenerArn"]
            p.call("CreateRule(path /api/*)", elb.create_rule, ListenerArn=la, Priority=10,
                   Conditions=[{"Field": "path-pattern", "Values": ["/api/*"]}],
                   Actions=[{"Type": "forward", "TargetGroupArn": tg_arn}])
            p.call("CreateRule(fixed-response)", elb.create_rule, ListenerArn=la, Priority=20,
                   Conditions=[{"Field": "host-header", "Values": ["admin.example.com"]}],
                   Actions=[{"Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "403", "ContentType": "text/plain"}}])
            rules = elb.describe_rules(ListenerArn=la)["Rules"]
            p.behavior("리스너 규칙 우선순위 조회(default 포함)", sorted(r["Priority"] for r in rules) == ["10", "20", "default"],
                       str(sorted(r["Priority"] for r in rules)))
            time.sleep(2)
            h = elb.describe_target_health(TargetGroupArn=tg_arn)["TargetHealthDescriptions"]
            p.behavior("리스너 연결 후 대상 헬스 상태", True, str([x["TargetHealth"]["State"] for x in h]))
            dns = elb.describe_load_balancers(LoadBalancerArns=[lb_arn])["LoadBalancers"][0]["DNSName"]
            # 에뮬레이터는 ALB 리스너를 컨테이너 안의 127.0.0.1:<임의 포트>에 실제로 띄운다.
            # 그 포트는 호스트에 게시되지 않으므로 컨테이너 안에서 curl 로 확인한다.
            elb.create_rule(ListenerArn=la, Priority=30, Conditions=[{"Field": "path-pattern", "Values": ["/hello"]}],
                            Actions=[{"Type": "fixed-response", "FixedResponseConfig": {
                                "StatusCode": "200", "ContentType": "text/plain", "MessageBody": "hello-from-alb"}}])
            port = os.environ.get("EMULATOR_PORT", "9297")
            try:
                out = subprocess.run(["docker", "exec", f"aws-emulator-{port}", "curl", "-s", "-m", "3",
                                      "-w", " HTTP%{http_code}", f"http://{dns}/hello"],
                                     capture_output=True, text=True, timeout=15).stdout
                p.behavior("ALB 리스너가 실제로 HTTP를 처리(컨테이너 안에서 fixed-response 규칙 확인)",
                           "hello-from-alb" in out, f"DNSName={dns} → {out.strip()[:80]}")
                out2 = subprocess.run(["docker", "exec", f"aws-emulator-{port}", "curl", "-s", "-m", "3",
                                       "-w", " HTTP%{http_code}", f"http://{dns}/api/x"],
                                      capture_output=True, text=True, timeout=15).stdout
                p.behavior("ALB forward 규칙 → 대상 인스턴스(실체 없음)로 전달 시 응답", True, f"/api/x → {out2.strip()[-40:] or '응답 없음'}")
            except Exception as e:  # noqa: BLE001
                p.behavior("ALB 리스너가 실제로 HTTP를 처리(컨테이너 안에서 fixed-response 규칙 확인)", False, f"{type(e).__name__}: {e}")
            host, _, hport = dns.partition(":")
            import socket
            try:
                socket.create_connection((host, int(hport or 80)), timeout=2).close()
                p.behavior("호스트(macOS)에서 ALB DNSName으로 직접 연결", True, dns)
            except Exception as e:  # noqa: BLE001
                p.behavior("호스트(macOS)에서 ALB DNSName으로 직접 연결", False,
                           f"{type(e).__name__} — 리스너 포트가 컨테이너 밖으로 게시되지 않음")

def run_autoscaling(p: Probe) -> None:
    asg, ec2 = p.client("autoscaling"), p.client("ec2")
    vpc, subs = _subnet(p)
    ami = _find_ami(p)
    if not subs or not ami:
        p.skip("ASG 탐침", "서브넷/AMI 준비 실패")
        return
    lt = ec2.create_launch_template(LaunchTemplateName=p.name("asg-lt"),
                                    LaunchTemplateData={"ImageId": ami, "InstanceType": "t3.micro"})["LaunchTemplate"]
    p.cleanup("lt", lambda: ec2.delete_launch_template(LaunchTemplateId=lt["LaunchTemplateId"]))
    name = p.name("asg")

    def _cleanup_asg() -> None:
        asg.delete_auto_scaling_group(AutoScalingGroupName=name, ForceDelete=True)
        rs = ec2.describe_instances(Filters=[{"Name": "tag:aws:autoscaling:groupName", "Values": [name]}])["Reservations"]
        ids = [i["InstanceId"] for r in rs for i in r["Instances"]]
        if ids:
            ec2.terminate_instances(InstanceIds=ids)
    c = p.call("CreateAutoScalingGroup(min1 max4 desired2)", asg.create_auto_scaling_group, AutoScalingGroupName=name,
               LaunchTemplate={"LaunchTemplateId": lt["LaunchTemplateId"], "Version": "$Latest"},
               MinSize=1, MaxSize=4, DesiredCapacity=2, VPCZoneIdentifier=",".join(subs), HealthCheckGracePeriod=60)
    if c is None:
        return
    p.cleanup("asg", _cleanup_asg)
    g = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"]
    if not g:
        p.behavior("ASG가 조회됨", False, "DescribeAutoScalingGroups 결과 없음")
        return
    g0 = g[0]
    p.behavior("Min/Max/Desired 값이 그대로 저장됨", (g0["MinSize"], g0["MaxSize"], g0["DesiredCapacity"]) == (1, 4, 2),
               f"Min={g0['MinSize']} Max={g0['MaxSize']} Desired={g0['DesiredCapacity']}")

    def _count() -> int:
        return len(asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"][0]["Instances"])
    ok = wait_until(lambda: _count() == 2, 25)
    p.behavior("Desired=2 만큼 인스턴스가 실제로 시작됨", ok, f"Instances={_count()}")
    ec2_ids = ec2.describe_instances(Filters=[{"Name": "tag:aws:autoscaling:groupName", "Values": [name]}])["Reservations"]
    p.behavior("ASG 인스턴스가 EC2 DescribeInstances에도 나타남", bool(ec2_ids), f"{sum(len(r['Instances']) for r in ec2_ids)}개")
    pol = p.call("PutScalingPolicy(TargetTracking CPU 50%)", asg.put_scaling_policy, AutoScalingGroupName=name,
                 PolicyName="cpu50", PolicyType="TargetTrackingScaling",
                 TargetTrackingConfiguration={"PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageCPUUtilization"},
                                              "TargetValue": 50.0})
    if pol:
        p.behavior("대상 추적 정책이 CloudWatch 경보를 자동 생성", bool(pol.get("Alarms")),
                   str([a.get("AlarmName") for a in pol.get("Alarms", [])])[:150])
    p.call("PutScalingPolicy(StepScaling)", asg.put_scaling_policy, AutoScalingGroupName=name, PolicyName="step",
           PolicyType="StepScaling", AdjustmentType="ChangeInCapacity",
           StepAdjustments=[{"MetricIntervalLowerBound": 0, "ScalingAdjustment": 1}])
    p.call("PutScheduledUpdateGroupAction", asg.put_scheduled_update_group_action, AutoScalingGroupName=name,
           ScheduledActionName="morning", Recurrence="0 9 * * *", DesiredCapacity=3)
    p.call("PutLifecycleHook(launching)", asg.put_lifecycle_hook, AutoScalingGroupName=name, LifecycleHookName="warmup",
           LifecycleTransition="autoscaling:EC2_INSTANCE_LAUNCHING", HeartbeatTimeout=300, DefaultResult="CONTINUE")
    if p.call("SetDesiredCapacity(3)", asg.set_desired_capacity, AutoScalingGroupName=name, DesiredCapacity=3) is not None:
        ok = wait_until(lambda: _count() == 3, 25)
        p.behavior("SetDesiredCapacity 3 → 인스턴스 3개", ok, f"Instances={_count()}")
    p.expect_error("SetDesiredCapacity(10 > Max)", asg.set_desired_capacity, "ValidationError",
                   AutoScalingGroupName=name, DesiredCapacity=10, what="Max 초과 Desired → ValidationError")
    acts = p.call("DescribeScalingActivities", asg.describe_scaling_activities, AutoScalingGroupName=name)
    if acts:
        p.behavior("조정 활동 기록", bool(acts["Activities"]), f"{len(acts['Activities'])}건")
    insts = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"][0]["Instances"]
    if insts:
        victim = insts[0]["InstanceId"]
        ec2.terminate_instances(InstanceIds=[victim])

        def _healed() -> bool:
            cur = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"][0]["Instances"]
            return victim not in [i["InstanceId"] for i in cur] and len(cur) >= 3
        ok = wait_until(_healed, 20)
        cur = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"][0]["Instances"]
        vs = [f"{i['LifecycleState']}/{i['HealthStatus']}" for i in cur if i["InstanceId"] == victim]
        p.behavior("인스턴스를 직접 종료하면 ASG가 대체 인스턴스를 띄움(자가 치유)", ok,
                   f"20초 후에도 종료된 인스턴스가 ASG에 {vs} 로 남음" if not ok else f"Instances={len(cur)}")

def run_compute_gaps(p: Probe) -> None:
    """M03 모듈 저자가 찾은 501·동작 차이를 재현한다."""
    ec2, asg, elb = p.client("ec2"), p.client("autoscaling"), p.client("elbv2")
    ami = _find_ami(p)
    vpc, subs = _subnet(p)
    if not ami or len(subs) < 2:
        p.skip("compute-gaps", "AMI/서브넷 준비 실패")
        return

    # 키 페어 삭제
    kn = p.name("gapkey")
    ec2.create_key_pair(KeyName=kn)
    p.call("DeleteKeyPair", ec2.delete_key_pair, KeyName=kn)

    # EBS IOPS:GiB 비율 (gp3 최대 500 IOPS/GiB → 10 GiB 면 5,000 이 상한)
    vol = p.call("CreateVolume(gp3 10 GiB, 20000 IOPS — AWS: 비율 초과로 거부)", ec2.create_volume,
                 AvailabilityZone="us-east-1a", Size=10, VolumeType="gp3", Iops=20000)
    if vol:
        vid = vol["VolumeId"]
        p.cleanup("vol", lambda: ec2.delete_volume(VolumeId=vid))
    p.behavior("gp3 10 GiB 에 20,000 IOPS 요청이 거부됨(IOPS:GiB 비율 검사)", vol is None,
               "받아 줌 — 비율 미검사" if vol else "거부")

    # 종료된 인스턴스의 루트 볼륨
    r = ec2.run_instances(ImageId=ami, InstanceType="t3.micro", MinCount=1, MaxCount=1, SubnetId=subs[0])
    iid = r["Instances"][0]["InstanceId"]
    wait_until(lambda: _state(ec2, iid) == "running", 30)
    vols = ec2.describe_volumes(Filters=[{"Name": "attachment.instance-id", "Values": [iid]}])["Volumes"]
    root_ids = [v["VolumeId"] for v in vols]
    ec2.terminate_instances(InstanceIds=[iid])
    wait_until(lambda: _state(ec2, iid) == "terminated", 30)
    if root_ids:
        time.sleep(2)
        after = ec2.describe_volumes(Filters=[{"Name": "volume-id", "Values": root_ids}])["Volumes"]
        states = [v["State"] for v in after]
        p.behavior("인스턴스 종료 시 DeleteOnTermination 루트 볼륨이 삭제됨", not after or all(s_ == "deleted" for s_ in states),
                   f"남은 볼륨 상태 {states}")
    else:
        p.skip("루트 볼륨", "인스턴스에 붙은 볼륨이 조회되지 않음")

    # ALB + 대상 그룹 + ASG
    igw = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
    ec2.attach_internet_gateway(InternetGatewayId=igw, VpcId=vpc)
    p.cleanup("igw", lambda: (ec2.detach_internet_gateway(InternetGatewayId=igw, VpcId=vpc),
                              ec2.delete_internet_gateway(InternetGatewayId=igw)))
    sg = ec2.create_security_group(GroupName=p.name("gap-sg"), Description="gap", VpcId=vpc)["GroupId"]
    p.cleanup("sg", lambda: ec2.delete_security_group(GroupId=sg))
    lb = elb.create_load_balancer(Name=f"gap-alb-{p.suffix}", Subnets=subs, SecurityGroups=[sg],
                                  Scheme="internet-facing", Type="application")["LoadBalancers"][0]
    lb_arn = lb["LoadBalancerArn"]
    p.cleanup("lb", lambda: elb.delete_load_balancer(LoadBalancerArn=lb_arn))
    tg = elb.create_target_group(Name=f"gap-tg-{p.suffix}", Protocol="HTTP", Port=80, VpcId=vpc,
                                 TargetType="instance")["TargetGroups"][0]["TargetGroupArn"]
    p.cleanup("tg", lambda: elb.delete_target_group(TargetGroupArn=tg))
    wait_until(lambda: elb.describe_load_balancers(LoadBalancerArns=[lb_arn])["LoadBalancers"][0]["State"]["Code"] == "active", 20)
    lis = elb.create_listener(LoadBalancerArn=lb_arn, Protocol="HTTP", Port=80, DefaultActions=[{
        "Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "200", "ContentType": "text/plain",
                                                          "MessageBody": "default"}}])["Listeners"][0]["ListenerArn"]
    p.cleanup("lis", lambda: elb.delete_listener(ListenerArn=lis))
    p.call("CreateRule(host-header api.todayorder.example → 'host')", elb.create_rule, ListenerArn=lis, Priority=10,
           Conditions=[{"Field": "host-header", "HostHeaderConfig": {"Values": ["api.todayorder.example"]}}],
           Actions=[{"Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "200", "ContentType": "text/plain",
                                                                       "MessageBody": "host"}}])
    port = os.environ.get("EMULATOR_PORT", "9297")
    dns = lb.get("DNSName", "")
    try:
        out = subprocess.run(["docker", "exec", f"aws-emulator-{port}", "curl", "-s", "-m", "5",
                              "-H", "Host: api.todayorder.example", f"http://{dns}/"],
                             capture_output=True, text=True, timeout=20)
        body = out.stdout.strip()
        if out.returncode != 0 and not body:
            p.skip("ALB host-header 규칙 매칭", f"docker exec curl 실패: {out.stderr.strip()[:80]}")
        else:
            p.behavior("ALB host-header 조건 규칙이 매칭됨(컨테이너 안 요청)", body == "host", f"응답 본문 '{body[:40]}'")
    except Exception as e:  # noqa: BLE001
        p.skip("ALB host-header 규칙 매칭", f"docker 사용 불가: {type(e).__name__}")

    lt = ec2.create_launch_template(LaunchTemplateName=p.name("gap-lt"),
                                    LaunchTemplateData={"ImageId": ami, "InstanceType": "t3.micro"})["LaunchTemplate"]
    p.cleanup("lt", lambda: ec2.delete_launch_template(LaunchTemplateId=lt["LaunchTemplateId"]))
    name = p.name("gap-asg")

    def _rm_asg() -> None:
        asg.delete_auto_scaling_group(AutoScalingGroupName=name, ForceDelete=True)
        rs = ec2.describe_instances(Filters=[{"Name": "tag:aws:autoscaling:groupName", "Values": [name]}])["Reservations"]
        ids = [i["InstanceId"] for r_ in rs for i in r_["Instances"]]
        if ids:
            ec2.terminate_instances(InstanceIds=ids)

    if p.call("CreateAutoScalingGroup(--target-group-arns, desired 2)", asg.create_auto_scaling_group,
              AutoScalingGroupName=name, LaunchTemplate={"LaunchTemplateId": lt["LaunchTemplateId"], "Version": "$Latest"},
              MinSize=1, MaxSize=3, DesiredCapacity=2, VPCZoneIdentifier=",".join(subs), TargetGroupARNs=[tg]) is None:
        return
    p.cleanup("asg", _rm_asg)

    def _inst() -> list[dict]:
        g = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[name])["AutoScalingGroups"]
        return g[0]["Instances"] if g else []

    wait_until(lambda: len(_inst()) >= 2, 20)
    ids = [i["InstanceId"] for i in _inst()]
    time.sleep(3)
    th = elb.describe_target_health(TargetGroupArn=tg)["TargetHealthDescriptions"]
    reg = [t["Target"]["Id"] for t in th]
    p.behavior("ASG(--target-group-arns) 인스턴스가 대상 그룹에 자동 등록됨", bool(ids) and set(ids) <= set(reg),
               f"ASG 인스턴스 {len(ids)}개, 대상 그룹 등록 {len(reg)}개")

    p.call("DescribePolicies", asg.describe_policies, AutoScalingGroupName=name)
    p.call("DescribeLifecycleHooks", asg.describe_lifecycle_hooks, AutoScalingGroupName=name)
    p.call("DescribeScheduledActions", asg.describe_scheduled_actions, AutoScalingGroupName=name)
    if ids:
        p.call("SetInstanceHealth", asg.set_instance_health, InstanceId=ids[0], HealthStatus="Unhealthy")

    # 인스턴스 새로 고침
    rf = p.call("StartInstanceRefresh", asg.start_instance_refresh, AutoScalingGroupName=name,
                Preferences={"MinHealthyPercentage": 50, "InstanceWarmup": 0})
    if rf:
        rid = rf["InstanceRefreshId"]
        status = {"s": "?"}

        def _done() -> bool:
            r_ = asg.describe_instance_refreshes(AutoScalingGroupName=name, InstanceRefreshIds=[rid])["InstanceRefreshes"]
            status["s"] = r_[0]["Status"] if r_ else "?"
            return status["s"] in ("Successful", "Failed", "Cancelled")

        wait_until(_done, 60, 2)
        new_ids = {i["InstanceId"] for i in _inst()}
        p.behavior("인스턴스 새로 고침이 Successful 까지 진행(인스턴스 교체)", status["s"] == "Successful",
                   f"Status={status['s']}, 교체 전후 겹치는 인스턴스 {len(new_ids & set(ids))}개")


CHECKS = {
    "ec2-instances": run_instances,
    "ebs-ami": run_ebs_ami,
    "elbv2": run_elbv2,
    "autoscaling": run_autoscaling,
    "compute-gaps": run_compute_gaps,
}
