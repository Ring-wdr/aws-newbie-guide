"""M03 — 태그 없는 컴퓨트 리소스 찾기 (필수 태그 감사).

TodayOrder 는 "모든 리소스에 Project 태그"를 규칙으로 정했다(비용 배분·정리용, M13에서 다시 나온다).
이 스크립트는 EC2 인스턴스·EBS 볼륨·스냅샷·시작 템플릿·로드 밸런서·대상 그룹·Auto Scaling 그룹을
훑어 Project 태그가 없는 것을 보고한다.

태그를 읽는 방법: **서비스별 describe/list 응답에 들어 있는 Tags 필드**를 쓴다.
  - EC2 계열(인스턴스·볼륨·스냅샷·시작 템플릿): describe_* 응답의 Tags
  - ELBv2(로드 밸런서·대상 그룹): elbv2.describe_tags (ARN 20개씩)
  - Auto Scaling 그룹: describe_auto_scaling_groups 응답의 Tags
쓰지 않는 것: EC2 DescribeTags(에뮬레이터 501), Resource Groups Tagging API GetResources
(에뮬레이터에서 EC2 리소스를 찾지 못함). 실제 AWS에서는 GetResources 한 번으로도 된다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m03-compute-scaling/sdk/untagged_resources.py

스크립트는 감사 대상이 되는 "표본" 리소스(태그 있는 것 / 없는 것)를 직접 만들고, 감사 후 지운다.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Iterable
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

REQUIRED_KEY = "Project"
PREFIX = "todayorder-m03-sdk"
SAMPLE_TAG = [{"Key": REQUIRED_KEY, "Value": "todayorder"}]
LIVE_INSTANCE_STATES = ["pending", "running", "stopping", "stopped"]


def has_key(tags: Iterable[dict[str, Any]] | None, key: str = REQUIRED_KEY) -> bool:
    return any(t.get("Key") == key for t in (tags or []))


def name_of(tags: Iterable[dict[str, Any]] | None) -> str:
    return next((t["Value"] for t in (tags or []) if t.get("Key") == "Name"), "-")


def wait(what: str, check: Callable[[], bool], limit: int = 60) -> None:
    for _ in range(limit):
        if check():
            return
        time.sleep(1)
    raise TimeoutError(f"{what}: {limit}초 안에 끝나지 않음")


# ---------------------------------------------------------------- 감사
def audit(ec2: Any, elbv2: Any, autoscaling: Any) -> tuple[list[tuple[str, str, str]], int]:
    """(종류, ID, 이름) 목록 — Project 태그가 없는 것. 그리고 건너뛴 '유령 루트 볼륨' 수."""
    found: list[tuple[str, str, str]] = []
    terminated = {i["InstanceId"] for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["terminated"]}])
        for r in page["Reservations"] for i in r["Instances"]}
    ghosts = 0

    for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": LIVE_INSTANCE_STATES}]
    ):
        for r in page["Reservations"]:
            for i in r["Instances"]:
                if not has_key(i.get("Tags")):
                    found.append(("ec2:instance", i["InstanceId"], name_of(i.get("Tags"))))

    for page in ec2.get_paginator("describe_volumes").paginate(
        Filters=[{"Name": "status", "Values": ["creating", "available", "in-use"]}]
    ):
        for v in page["Volumes"]:
            att = [a["InstanceId"] for a in v.get("Attachments", [])]
            if att and all(a in terminated for a in att):
                # 에뮬레이터 차이: 종료된 인스턴스의 루트 볼륨(DeleteOnTermination=true)이 in-use 로 남는다.
                # 실제 AWS에서는 지워졌을 볼륨이므로 감사에서 뺀다.
                ghosts += 1
                continue
            # 인스턴스와 함께 만들어진 루트 볼륨은 인스턴스 태그를 자동으로 받지 않는다 → 흔한 누락 지점
            if not has_key(v.get("Tags")):
                found.append(("ec2:volume", v["VolumeId"], name_of(v.get("Tags"))))

    for page in ec2.get_paginator("describe_snapshots").paginate(OwnerIds=["self"]):
        for s in page["Snapshots"]:
            if not has_key(s.get("Tags")):
                found.append(("ec2:snapshot", s["SnapshotId"], name_of(s.get("Tags"))))

    for page in ec2.get_paginator("describe_launch_templates").paginate():
        for lt in page["LaunchTemplates"]:
            if not has_key(lt.get("Tags")):
                found.append(("ec2:launch-template", lt["LaunchTemplateId"], lt["LaunchTemplateName"]))

    arns: dict[str, tuple[str, str]] = {}
    for page in elbv2.get_paginator("describe_load_balancers").paginate():
        for lb in page["LoadBalancers"]:
            arns[lb["LoadBalancerArn"]] = (f"elbv2:{lb['Type']}", lb["LoadBalancerName"])
    for page in elbv2.get_paginator("describe_target_groups").paginate():
        for tg in page["TargetGroups"]:
            arns[tg["TargetGroupArn"]] = ("elbv2:target-group", tg["TargetGroupName"])
    arn_list = list(arns)
    for i in range(0, len(arn_list), 20):  # DescribeTags 는 한 번에 ARN 20개까지
        for d in elbv2.describe_tags(ResourceArns=arn_list[i : i + 20])["TagDescriptions"]:
            if not has_key(d.get("Tags")):
                kind, name = arns[d["ResourceArn"]]
                found.append((kind, d["ResourceArn"].split("/")[-2] if kind == "elbv2:target-group" else name, name))

    for page in autoscaling.get_paginator("describe_auto_scaling_groups").paginate():
        for g in page["AutoScalingGroups"]:
            if not has_key(g.get("Tags")):
                found.append(("autoscaling:group", g["AutoScalingGroupName"], g["AutoScalingGroupName"]))
    return found, ghosts


# ---------------------------------------------------------------- 표본 리소스
def make_samples(ec2: Any, elbv2: Any, autoscaling: Any) -> dict[str, str]:
    ami = boto3.client("ssm").get_parameter(
        Name="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    )["Parameter"]["Value"]
    vpc = ec2.create_vpc(CidrBlock="10.31.0.0/16", TagSpecifications=[
        {"ResourceType": "vpc", "Tags": [{"Key": "Name", "Value": f"{PREFIX}-vpc"}, *SAMPLE_TAG]}])["Vpc"]["VpcId"]
    sa = ec2.create_subnet(VpcId=vpc, CidrBlock="10.31.1.0/24", AvailabilityZone="us-east-1a")["Subnet"]["SubnetId"]
    sb = ec2.create_subnet(VpcId=vpc, CidrBlock="10.31.2.0/24", AvailabilityZone="us-east-1b")["Subnet"]["SubnetId"]

    def tags(name: str, tagged: bool, kind: str) -> list[dict[str, Any]]:
        t = [{"Key": "Name", "Value": name}] + (SAMPLE_TAG if tagged else [])
        return [{"ResourceType": kind, "Tags": t}]

    ids: dict[str, str] = {"vpc": vpc, "subnet_a": sa, "subnet_b": sb}
    ids["inst_ok"] = ec2.run_instances(ImageId=ami, InstanceType="t3.micro", MinCount=1, MaxCount=1, SubnetId=sa,
                                       TagSpecifications=tags(f"{PREFIX}-api-ok", True, "instance"))["Instances"][0]["InstanceId"]
    ids["inst_bad"] = ec2.run_instances(ImageId=ami, InstanceType="t3.micro", MinCount=1, MaxCount=1, SubnetId=sa,
                                        TagSpecifications=tags(f"{PREFIX}-api-notag", False, "instance"))["Instances"][0]["InstanceId"]
    ids["vol_ok"] = ec2.create_volume(AvailabilityZone="us-east-1a", Size=1, VolumeType="gp3",
                                      TagSpecifications=tags(f"{PREFIX}-data-ok", True, "volume"))["VolumeId"]
    ids["vol_bad"] = ec2.create_volume(AvailabilityZone="us-east-1a", Size=1, VolumeType="gp3",
                                       TagSpecifications=tags(f"{PREFIX}-data-notag", False, "volume"))["VolumeId"]
    wait("볼륨 available", lambda: all(v["State"] == "available" for v in ec2.describe_volumes(
        VolumeIds=[ids["vol_ok"], ids["vol_bad"]])["Volumes"]))
    ids["snap_bad"] = ec2.create_snapshot(VolumeId=ids["vol_ok"], Description=f"{PREFIX} untagged snapshot")["SnapshotId"]
    ids["lt_ok"] = ec2.create_launch_template(
        LaunchTemplateName=f"{PREFIX}-lt-ok", LaunchTemplateData={"ImageId": ami, "InstanceType": "t3.micro"},
        TagSpecifications=[{"ResourceType": "launch-template", "Tags": SAMPLE_TAG}])["LaunchTemplate"]["LaunchTemplateId"]
    ids["lt_bad"] = ec2.create_launch_template(
        LaunchTemplateName=f"{PREFIX}-lt-notag", LaunchTemplateData={"ImageId": ami, "InstanceType": "t3.micro"}
    )["LaunchTemplate"]["LaunchTemplateId"]
    ids["alb_bad"] = elbv2.create_load_balancer(Name=f"{PREFIX}-alb", Subnets=[sa, sb], Type="application",
                                                Scheme="internal")["LoadBalancers"][0]["LoadBalancerArn"]
    ids["tg_ok"] = elbv2.create_target_group(Name=f"{PREFIX}-tg", Protocol="HTTP", Port=80, VpcId=vpc,
                                             Tags=SAMPLE_TAG)["TargetGroups"][0]["TargetGroupArn"]
    autoscaling.create_auto_scaling_group(
        AutoScalingGroupName=f"{PREFIX}-asg-notag", LaunchTemplate={"LaunchTemplateId": ids["lt_ok"], "Version": "$Latest"},
        MinSize=0, MaxSize=1, DesiredCapacity=0, VPCZoneIdentifier=sa)
    ids["asg_bad"] = f"{PREFIX}-asg-notag"
    return ids


def remove_samples(ec2: Any, elbv2: Any, autoscaling: Any) -> None:
    """PREFIX 로 시작하는 표본만 지운다 (이전 실행의 흔적 포함). 없으면 조용히 넘어간다."""
    def quiet(fn: Callable[..., Any], **kw: Any) -> None:
        try:
            fn(**kw)
        except ClientError:
            pass

    for g in autoscaling.describe_auto_scaling_groups()["AutoScalingGroups"]:
        if g["AutoScalingGroupName"].startswith(PREFIX):
            quiet(autoscaling.delete_auto_scaling_group, AutoScalingGroupName=g["AutoScalingGroupName"], ForceDelete=True)
    for lb in elbv2.describe_load_balancers()["LoadBalancers"]:
        if lb["LoadBalancerName"].startswith(PREFIX):
            quiet(elbv2.delete_load_balancer, LoadBalancerArn=lb["LoadBalancerArn"])
    for tg in elbv2.describe_target_groups()["TargetGroups"]:
        if tg["TargetGroupName"].startswith(PREFIX):
            quiet(elbv2.delete_target_group, TargetGroupArn=tg["TargetGroupArn"])
    for lt in ec2.describe_launch_templates()["LaunchTemplates"]:
        if lt["LaunchTemplateName"].startswith(PREFIX):
            quiet(ec2.delete_launch_template, LaunchTemplateId=lt["LaunchTemplateId"])
    for s in ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]:
        if s.get("Description", "").startswith(PREFIX):
            quiet(ec2.delete_snapshot, SnapshotId=s["SnapshotId"])
    insts = [i["InstanceId"] for r in ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [f"{PREFIX}-*"]},
        {"Name": "instance-state-name", "Values": LIVE_INSTANCE_STATES}])["Reservations"] for i in r["Instances"]]
    if insts:
        ec2.terminate_instances(InstanceIds=insts)
        wait("인스턴스 종료", lambda: all(i["State"]["Name"] == "terminated" for r in ec2.describe_instances(
            InstanceIds=insts)["Reservations"] for i in r["Instances"]))
    for v in ec2.describe_volumes(Filters=[{"Name": "tag:Name", "Values": [f"{PREFIX}-*"]}])["Volumes"]:
        quiet(ec2.delete_volume, VolumeId=v["VolumeId"])
    for vpc in ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [f"{PREFIX}-vpc"]}])["Vpcs"]:
        # 종료된 인스턴스의 루트 볼륨은 에뮬레이터에서 in-use 로 남지만 서브넷 삭제를 막지는 않는다
        for sn in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc["VpcId"]]}])["Subnets"]:
            quiet(ec2.delete_subnet, SubnetId=sn["SubnetId"])
        quiet(ec2.delete_vpc, VpcId=vpc["VpcId"])


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    ec2, elbv2, autoscaling = boto3.client("ec2"), boto3.client("elbv2"), boto3.client("autoscaling")
    remove_samples(ec2, elbv2, autoscaling)
    ids = make_samples(ec2, elbv2, autoscaling)
    try:
        report, ghosts = audit(ec2, elbv2, autoscaling)
        print(f"'{REQUIRED_KEY}' 태그가 없는 리소스 {len(report)}개 "
              f"(종료된 인스턴스에 붙은 채 남은 루트 볼륨 {ghosts}개는 에뮬레이터 차이라 제외)")
        for kind, rid, name in sorted(report):
            print(f"  {kind:<22} {rid:<28} {name}")

        flagged = {rid for _, rid, _ in report} | {name for _, _, name in report}
        must_flag = {ids["inst_bad"], ids["vol_bad"], ids["snap_bad"], ids["lt_bad"], f"{PREFIX}-alb", ids["asg_bad"]}
        must_pass = {ids["inst_ok"], ids["vol_ok"], ids["lt_ok"], f"{PREFIX}-tg"}
        missing = must_flag - flagged
        wrong = must_pass & flagged
        assert not missing, f"찾아야 할 태그 누락 리소스를 놓쳤다: {missing}"
        assert not wrong, f"태그가 있는데 누락으로 보고했다: {wrong}"
        # 루트 볼륨: 인스턴스에 Project 태그가 있어도 볼륨에는 없다
        roots = [bdm["Ebs"]["VolumeId"] for r in ec2.describe_instances(InstanceIds=[ids["inst_ok"]])["Reservations"]
                 for i in r["Instances"] for bdm in i.get("BlockDeviceMappings", [])]
        print(f"참고: 태그를 단 인스턴스 {ids['inst_ok']} 의 루트 볼륨 {roots} 도 누락으로 잡힌다 "
              f"→ run-instances 의 TagSpecifications 에 ResourceType=volume 도 넣어야 한다")
    finally:
        remove_samples(ec2, elbv2, autoscaling)
    print("SDK untagged_resources OK")


if __name__ == "__main__":
    main()
