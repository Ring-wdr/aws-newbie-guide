"""M14 — 캡스톤 환경을 읽어 Well-Architected 6개 기둥별로 점검하는 감사 도구 (읽기 전용).

lab01~lab05 로 지은 TodayOrder 캡스톤을 boto3 로 읽고, 설계 문서(레슨 02)가 약속한 통제가 실제로
구성돼 있는지 "증거"를 모은다. 자기 점검표(capstone-self-check.md)의 자동 판정 부분이다.

각 항목은 PASS / FAIL 과 근거 한 줄을 출력한다. FAIL 이 하나라도 있으면 종료 코드 1.
에뮬레이터가 재현하지 않는 동작(장애 조치, 실제 트래픽, 청구 금액)은 판정하지 않고 "설정"만 본다.

실행 (저장소 루트에서, lab05 까지 실행한 뒤):
    source scripts/env.sh
    uv run python curriculum/m14-capstone-exam/sdk/capstone_audit.py
"""

from __future__ import annotations

import json
import sys
from collections.abc import Callable
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

P = "todayorder-cap"


@dataclass
class Check:
    pillar: str
    name: str
    ok: bool
    evidence: str


def _safe(fn: Callable[[], tuple[bool, str]]) -> tuple[bool, str]:
    try:
        return fn()
    except ClientError as e:
        return False, f"{e.response['Error']['Code']}: {e.response['Error'].get('Message', '')[:80]}"
    except (KeyError, IndexError, StopIteration) as e:
        return False, f"리소스 없음 ({type(e).__name__})"


def run_checks() -> list[Check]:
    ec2, elbv2, asg = boto3.client("ec2"), boto3.client("elbv2"), boto3.client("autoscaling")
    rds, s3, ddb = boto3.client("rds"), boto3.client("s3"), boto3.client("dynamodb")
    sqs, lam, iam = boto3.client("sqs"), boto3.client("lambda"), boto3.client("iam")
    cw, logs, trail = boto3.client("cloudwatch"), boto3.client("logs"), boto3.client("cloudtrail")
    cfn, sm, budgets = boto3.client("cloudformation"), boto3.client("secretsmanager"), boto3.client("budgets")
    checks: list[Check] = []

    def add(pillar: str, name: str, fn: Callable[[], tuple[bool, str]]) -> None:
        ok, ev = _safe(fn)
        checks.append(Check(pillar, name, ok, ev))

    vpc_id = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [f"{P}-vpc"]}])["Vpcs"][0]["VpcId"]
    table = ddb.describe_table(TableName=f"{P}-orders")["Table"]
    bucket = f"{P}-receipts"

    # ---------- 보안 ----------
    def bucket_kms() -> tuple[bool, str]:
        rule = s3.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]["Rules"][0]
        algo = rule["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"]
        return algo == "aws:kms" and rule.get("BucketKeyEnabled", False), f"{algo}, 버킷 키 {rule.get('BucketKeyEnabled')}"

    def bucket_public_blocked() -> tuple[bool, str]:
        cfg = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
        return all(cfg.values()), f"BPA 4개 설정 {sum(cfg.values())}/4 켜짐"

    def bucket_tls_only() -> tuple[bool, str]:
        pol = json.loads(s3.get_bucket_policy(Bucket=bucket)["Policy"])
        deny = [s for s in pol["Statement"] if s["Effect"] == "Deny"
                and s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") == "false"]
        return bool(deny), f"SecureTransport=false Deny 문장 {len(deny)}개"

    def table_cmk() -> tuple[bool, str]:
        sse = table.get("SSEDescription", {})
        return sse.get("SSEType") == "KMS", f"SSEType={sse.get('SSEType')}"

    def secret_cmk() -> tuple[bool, str]:
        kid = sm.describe_secret(SecretId=f"{P}/payment-gateway").get("KmsKeyId")
        return bool(kid), f"KmsKeyId={'있음' if kid else '없음(aws/secretsmanager 기본 키)'}"

    def rds_private_encrypted() -> tuple[bool, str]:
        db = rds.describe_db_instances(DBInstanceIdentifier=f"{P}-settlement-db")["DBInstances"][0]
        return (db["StorageEncrypted"] and not db["PubliclyAccessible"] and "MasterUserSecret" in db,
                f"암호화 {db['StorageEncrypted']}, 공개 {db['PubliclyAccessible']}, 암호 관리 {'Secrets Manager' if 'MasterUserSecret' in db else '직접'}")

    def imdsv2() -> tuple[bool, str]:
        v = ec2.describe_launch_template_versions(LaunchTemplateName=f"{P}-app-lt", Versions=["$Latest"])
        tokens = v["LaunchTemplateVersions"][0]["LaunchTemplateData"]["MetadataOptions"]["HttpTokens"]
        return tokens == "required", f"HttpTokens={tokens}"

    def no_wildcard_actions() -> tuple[bool, str]:
        bad = []
        for role in (f"{P}-order-api-role", f"{P}-order-worker-role"):
            for name in iam.list_role_policies(RoleName=role)["PolicyNames"]:
                doc = iam.get_role_policy(RoleName=role, PolicyName=name)["PolicyDocument"]
                doc = json.loads(doc) if isinstance(doc, str) else doc
                for st in doc["Statement"]:
                    acts = st["Action"] if isinstance(st["Action"], list) else [st["Action"]]
                    bad += [f"{role}:{a}" for a in acts if a == "*" or a.endswith(":*")]
        return not bad, "와일드카드 동작 없음" if not bad else ", ".join(bad)

    def sg_chain() -> tuple[bool, str]:
        groups = {g["GroupName"]: g for g in ec2.describe_security_groups(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["SecurityGroups"]}
        db_src = groups[f"{P}-db-sg"]["IpPermissions"][0]["UserIdGroupPairs"][0]["GroupId"]
        app_src = groups[f"{P}-app-sg"]["IpPermissions"][0]["UserIdGroupPairs"][0]["GroupId"]
        ok = db_src == groups[f"{P}-app-sg"]["GroupId"] and app_src == groups[f"{P}-alb-sg"]["GroupId"]
        return ok, "alb-sg → app-sg(8080) → db-sg(5432) 참조 체인"

    def trail_on() -> tuple[bool, str]:
        st = trail.get_trail_status(Name=f"{P}-trail")
        t = trail.describe_trails(trailNameList=[f"{P}-trail"])["trailList"][0]
        return (st["IsLogging"] and t["IsMultiRegionTrail"] and t["LogFileValidationEnabled"],
                f"로깅 {st['IsLogging']}, 멀티 리전 {t['IsMultiRegionTrail']}, 무결성 검증 {t['LogFileValidationEnabled']}")

    for name, fn in [("영수증 버킷 SSE-KMS + 버킷 키", bucket_kms), ("영수증 버킷 퍼블릭 차단", bucket_public_blocked),
                     ("영수증 버킷 HTTPS 강제", bucket_tls_only), ("주문 테이블 고객 관리형 키", table_cmk),
                     ("결제 비밀 KMS 암호화", secret_cmk), ("정산 DB 비공개·암호화·암호 자동 관리", rds_private_encrypted),
                     ("관리 웹 IMDSv2 필수", imdsv2), ("Lambda 역할 최소 권한", no_wildcard_actions),
                     ("보안 그룹 체이닝", sg_chain), ("CloudTrail 멀티 리전 + 무결성", trail_on)]:
        add("보안", name, fn)

    # ---------- 안정성 ----------
    def nat_per_az() -> tuple[bool, str]:
        nats = ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                                  {"Name": "state", "Values": ["available"]}])["NatGateways"]
        subnets = ec2.describe_subnets(SubnetIds=[n["SubnetId"] for n in nats])["Subnets"] if nats else []
        azs = {s["AvailabilityZone"] for s in subnets}
        return len(azs) >= 2, f"NAT {len(nats)}개, AZ {sorted(azs)}"

    def asg_multi_az() -> tuple[bool, str]:
        g = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[f"{P}-app-asg"])["AutoScalingGroups"][0]
        azs = {i["AvailabilityZone"] for i in g["Instances"]}
        return g["MinSize"] >= 2 and len(azs) >= 2 and g["HealthCheckType"] == "ELB", \
            f"최소 {g['MinSize']}, AZ {sorted(azs)}, 헬스 체크 {g['HealthCheckType']}"

    def rds_multi_az() -> tuple[bool, str]:
        db = rds.describe_db_instances(DBInstanceIdentifier=f"{P}-settlement-db")["DBInstances"][0]
        return db["MultiAZ"] and db["BackupRetentionPeriod"] >= 7, \
            f"Multi-AZ {db['MultiAZ']}, 자동 백업 {db['BackupRetentionPeriod']}일"

    def dlq() -> tuple[bool, str]:
        url = sqs.get_queue_url(QueueName=f"{P}-fulfillment")["QueueUrl"]
        attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["RedrivePolicy", "VisibilityTimeout"])["Attributes"]
        rp = json.loads(attrs["RedrivePolicy"])
        timeout = lam.get_function_configuration(FunctionName=f"{P}-order-worker")["Timeout"]
        vis = int(attrs["VisibilityTimeout"])
        return vis >= 6 * timeout, f"DLQ {rp['deadLetterTargetArn'].split(':')[-1]} (maxReceiveCount {rp['maxReceiveCount']}), 가시성 {vis}s ≥ 함수 {timeout}s×6"

    def pitr() -> tuple[bool, str]:
        s = ddb.describe_continuous_backups(TableName=f"{P}-orders")["ContinuousBackupsDescription"]
        status = s["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"]
        return status == "ENABLED", f"PITR {status}"

    def versioning() -> tuple[bool, str]:
        st = s3.get_bucket_versioning(Bucket=bucket).get("Status")
        return st == "Enabled", f"버전 관리 {st}"

    def alb_two_az() -> tuple[bool, str]:
        lb = elbv2.describe_load_balancers(Names=[f"{P}-alb"])["LoadBalancers"][0]
        azs = [z["ZoneName"] for z in lb["AvailabilityZones"]]
        return len(azs) >= 2, f"ALB 서브넷 AZ {azs}"

    for name, fn in [("NAT 게이트웨이 AZ별", nat_per_az), ("ASG 2개 AZ·ELB 헬스 체크", asg_multi_az),
                     ("ALB 2개 AZ", alb_two_az), ("정산 DB Multi-AZ·백업", rds_multi_az),
                     ("주문 큐 DLQ·가시성 타임아웃", dlq), ("주문 테이블 PITR", pitr), ("영수증 버전 관리", versioning)]:
        add("안정성", name, fn)

    # ---------- 성능 효율성 ----------
    def gsi() -> tuple[bool, str]:
        names = [g["IndexName"] for g in table.get("GlobalSecondaryIndexes", [])]
        return "byCustomer" in names, f"GSI {names} — '고객의 최근 주문'을 Scan 없이 Query"

    def tls_listener() -> tuple[bool, str]:
        lb = elbv2.describe_load_balancers(Names=[f"{P}-alb"])["LoadBalancers"][0]
        ls = elbv2.describe_listeners(LoadBalancerArn=lb["LoadBalancerArn"])["Listeners"]
        https = [x for x in ls if x["Protocol"] == "HTTPS"]
        return bool(https) and "TLS13" in https[0].get("SslPolicy", ""), f"HTTPS 리스너 {https[0].get('SslPolicy') if https else '없음'}"

    for name, fn in [("접근 패턴용 GSI", gsi), ("ALB HTTPS(TLS 1.3 정책)", tls_listener)]:
        add("성능 효율성", name, fn)

    # ---------- 비용 최적화 ----------
    def gateway_endpoints() -> tuple[bool, str]:
        eps = ec2.describe_vpc_endpoints(Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                                  {"Name": "vpc-endpoint-type", "Values": ["Gateway"]}])["VpcEndpoints"]
        svcs = sorted(e["ServiceName"].split(".")[-1] for e in eps)
        return svcs == ["dynamodb", "s3"], f"게이트웨이 엔드포인트 {svcs} (NAT 처리 요금 회피)"

    def lifecycle() -> tuple[bool, str]:
        rules = s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
        tr = [t["StorageClass"] for r in rules for t in r.get("Transitions", [])]
        mpu = any("AbortIncompleteMultipartUpload" in r for r in rules)
        return bool(tr) and mpu, f"전환 {tr}, 미완료 멀티파트 정리 {mpu}"

    def log_retention() -> tuple[bool, str]:
        groups = logs.describe_log_groups(logGroupNamePrefix=f"/aws/lambda/{P}-")["logGroups"]
        days = {g["logGroupName"].split("/")[-1]: g.get("retentionInDays") for g in groups}
        return bool(days) and all(days.values()), f"보존 기간 {days}"

    def on_demand() -> tuple[bool, str]:
        mode = table.get("BillingModeSummary", {}).get("BillingMode", "PROVISIONED")
        return mode == "PAY_PER_REQUEST", f"용량 모드 {mode} (트래픽 예측 불가 초기 단계)"

    def budget() -> tuple[bool, str]:
        b = budgets.describe_budget(AccountId="000000000000", BudgetName=f"{P}-monthly")["Budget"]
        return True, f"예산 {b['BudgetLimit']['Amount']} {b['BudgetLimit']['Unit']}/월"

    for name, fn in [("S3·DynamoDB 게이트웨이 엔드포인트", gateway_endpoints), ("영수증 수명 주기", lifecycle),
                     ("로그 보존 기간", log_retention), ("DynamoDB 온디맨드", on_demand), ("월 예산·알림", budget)]:
        add("비용 최적화", name, fn)

    # ---------- 운영 우수성 ----------
    def alarm_action() -> tuple[bool, str]:
        a = cw.describe_alarms(AlarmNames=[f"{P}-order-failures"])["MetricAlarms"][0]
        return bool(a["AlarmActions"]) and bool(a.get("OKActions")), f"ALARM→{a['AlarmActions'][0].split(':')[-1]}, OK 알림도"

    def stacks() -> tuple[bool, str]:
        st = {n: cfn.describe_stacks(StackName=f"{P}-{n}")["Stacks"][0]["StackStatus"] for n in ("network", "data", "messaging")}
        return all(v == "CREATE_COMPLETE" for v in st.values()), f"IaC 스택 {st}"

    def tagged() -> tuple[bool, str]:
        tags = {t["Key"]: t["Value"] for t in s3.get_bucket_tagging(Bucket=bucket)["TagSet"]}
        fn_tags = lam.list_tags(Resource=lam.get_function(FunctionName=f"{P}-order-worker")["Configuration"]["FunctionArn"])["Tags"]
        ok = tags.get("Project") == "todayorder" and fn_tags.get("Project") == "todayorder"
        return ok, "Project=todayorder 태그(비용 할당·Config 범위)"

    for name, fn in [("실패 알람 → 운영 알림", alarm_action), ("인프라 코드(CloudFormation)", stacks), ("비용 할당 태그", tagged)]:
        add("운영 우수성", name, fn)

    # ---------- 지속 가능성 ----------
    def graviton() -> tuple[bool, str]:
        archs = {f: lam.get_function_configuration(FunctionName=f"{P}-{f}")["Architectures"][0]
                 for f in ("order-api", "order-worker")}
        v = ec2.describe_launch_template_versions(LaunchTemplateName=f"{P}-app-lt", Versions=["$Latest"])
        itype = v["LaunchTemplateVersions"][0]["LaunchTemplateData"]["InstanceType"]
        return all(a == "arm64" for a in archs.values()) and "g." in itype, f"Lambda {archs}, EC2 {itype}"

    add("지속 가능성", "Graviton(arm64)", graviton)
    add("지속 가능성", "콜드 데이터 아카이브 계층", lambda: (
        "DEEP_ARCHIVE" in [t["StorageClass"] for r in s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
                           for t in r.get("Transitions", [])], "오래된 영수증 → Deep Archive"))
    return checks


def main() -> int:
    require_emulator()
    try:
        checks = run_checks()
    except (ClientError, IndexError, KeyError) as e:
        print(f"캡스톤 환경을 찾지 못했습니다({type(e).__name__}). lab05-smoke-test.sh 를 먼저 실행하세요.")
        return 1
    pillar = ""
    for c in checks:
        if c.pillar != pillar:
            pillar = c.pillar
            print(f"\n[{pillar}]")
        print(f"  {'PASS' if c.ok else 'FAIL'}  {c.name:<28} {c.evidence}")
    failed = [c for c in checks if not c.ok]
    print(f"\n점검 {len(checks)}개 · 통과 {len(checks) - len(failed)} · 실패 {len(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
