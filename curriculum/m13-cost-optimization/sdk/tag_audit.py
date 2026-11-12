"""M13 — 비용 할당 태그 정책 준수 감사: 각 서비스의 자체 API로 태그를 읽는다.

"이 리소스의 비용은 누구 것인가?"에 답하려면 모든 리소스에 같은 규칙의 태그가 있어야 한다.
태그 정책(labs/tag-policy.json, AWS Organizations 태그 정책과 같은 문법)을 읽어 다음을 판정한다.
    - 필수 키가 없다                           → MISSING
    - 키는 있는데 대소문자가 다르다(Project)      → WRONG-CASE
    - 값이 허용 목록 밖이다(env=production)       → BAD-VALUE

왜 Resource Groups Tagging API(GetResources) 한 번으로 끝내지 않나?
    실제 AWS 에서는 그게 가장 편한 방법이다. 하지만 에뮬레이터의 GetResources 는 SQS 말고는 거의 찾지 못한다
    (EC2 DescribeTags 도 501). 그래서 서비스마다 자기 API 로 태그를 읽는다 — 이 방법은 실제 AWS 에서도 그대로 동작한다.
        EC2 인스턴스  describe_instances 의 Tags        EBS 볼륨  describe_volumes 의 Tags
        S3 버킷       get_bucket_tagging (없으면 NoSuchTagSet)
        DynamoDB      list_tags_of_resource            SQS  list_queue_tags      SNS  list_tags_for_resource

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m13-cost-optimization/sdk/tag_audit.py                       # 접두사 todayorder-m13-audit-
    uv run python curriculum/m13-cost-optimization/sdk/tag_audit.py todayorder-            # 다른 접두사
마지막 줄: 'NON-COMPLIANT n / m'
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

POLICY_PATH = Path(__file__).resolve().parent.parent / "labs" / "tag-policy.json"


def load_policy(path: Path) -> dict[str, list[str]]:
    """{정확한 키: 허용 값 목록}"""
    raw = json.loads(path.read_text())["tags"]
    return {v["tag_key"]["@@assign"]: v.get("tag_value", {}).get("@@assign", []) for v in raw.values()}


def as_dict(tags: list[dict[str, str]] | None) -> dict[str, str]:
    return {t["Key"]: t["Value"] for t in tags or []}


def inventory(prefix: str) -> list[tuple[str, str, dict[str, str]]]:
    """(서비스, 이름, 태그) 목록. 이름이 prefix 로 시작하는 리소스만."""
    ec2, s3, ddb = boto3.client("ec2"), boto3.client("s3"), boto3.client("dynamodb")
    sqs, sns = boto3.client("sqs"), boto3.client("sns")
    out: list[tuple[str, str, dict[str, str]]] = []

    for r in ec2.describe_instances(Filters=[{"Name": "instance-state-name", "Values": ["pending", "running", "stopped"]}])["Reservations"]:
        for i in r["Instances"]:
            tags = as_dict(i.get("Tags"))
            if tags.get("Name", "").startswith(prefix):
                out.append(("ec2", tags["Name"], tags))
    for v in ec2.describe_volumes()["Volumes"]:
        tags = as_dict(v.get("Tags"))
        if tags.get("Name", "").startswith(prefix):
            out.append(("ebs", tags["Name"], tags))
    for b in s3.list_buckets()["Buckets"]:
        if b["Name"].startswith(prefix):
            try:
                tags = as_dict(s3.get_bucket_tagging(Bucket=b["Name"])["TagSet"])
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchTagSet":
                    raise
                tags = {}
            out.append(("s3", b["Name"], tags))
    for page in ddb.get_paginator("list_tables").paginate():
        for name in page["TableNames"]:
            if name.startswith(prefix):
                arn = ddb.describe_table(TableName=name)["Table"]["TableArn"]
                out.append(("dynamodb", name, as_dict(ddb.list_tags_of_resource(ResourceArn=arn).get("Tags"))))
    for url in sqs.list_queues(QueueNamePrefix=prefix).get("QueueUrls", []):
        out.append(("sqs", url.rsplit("/", 1)[-1], sqs.list_queue_tags(QueueUrl=url).get("Tags", {})))
    for page in sns.get_paginator("list_topics").paginate():
        for t in page["Topics"]:
            name = t["TopicArn"].rsplit(":", 1)[-1]
            if name.startswith(prefix):
                out.append(("sns", name, as_dict(sns.list_tags_for_resource(ResourceArn=t["TopicArn"])["Tags"])))
    return sorted(out)


def check(tags: dict[str, str], policy: dict[str, list[str]]) -> list[str]:
    problems: list[str] = []
    lower = {k.lower(): k for k in tags}
    for key, allowed in policy.items():
        if key in tags:
            if allowed and tags[key] not in allowed:
                problems.append(f"BAD-VALUE {key}={tags[key]}")
        elif key.lower() in lower:
            problems.append(f"WRONG-CASE {lower[key.lower()]}→{key}")
        else:
            problems.append(f"MISSING {key}")
    return problems


def main(argv: list[str]) -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    prefix = argv[0] if argv else "todayorder-m13-audit-"
    policy = load_policy(POLICY_PATH)
    print(f"태그 정책: {', '.join(f'{k}∈{v}' for k, v in policy.items())}")

    resources = inventory(prefix)
    bad = 0
    for svc, name, tags in resources:
        problems = check(tags, policy)
        bad += bool(problems)
        print(f"{'✗' if problems else '✓'} {svc:<9} {name:<36} {'; '.join(problems) or 'OK'}")

    # 비교: Resource Groups Tagging API 가 같은 태그로 찾은 것
    tagging = boto3.client("resourcegroupstaggingapi")
    found = tagging.get_resources(TagFilters=[{"Key": "project", "Values": ["todayorder"]}])["ResourceTagMappingList"]
    found = [m["ResourceARN"] for m in found if prefix in m["ResourceARN"]]
    expected = sum(1 for _, _, t in resources if t.get("project") == "todayorder")
    print(f"참고: Tagging API GetResources(project=todayorder) 가 찾은 리소스 {len(found)}개 "
          f"(서비스별 API 로 확인한 실제 개수 {expected}개) → {', '.join(a.split(':')[2] for a in found) or '없음'}")
    print(f"NON-COMPLIANT {bad} / {len(resources)}")


if __name__ == "__main__":
    main(sys.argv[1:])
