"""M01·M04·M05·M06: IAM 정책이 실제 호출에서 어디까지 집행되는가.

정책 없는 사용자 / 명시적 Deny / AssumeRole 호출자 정책 / 세션 정책 / iam:PassRole /
비활성 액세스 키 / 전역 조건 키를 서비스별로 확인한다.
behavior(ok=True) 는 "실제 AWS와 같다"는 뜻이다.
"""

from __future__ import annotations

import json
from typing import Any, Callable

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from lib import Probe

_CFG = Config(retries={"max_attempts": 1}, connect_timeout=5, read_timeout=30)
_ACCT = "000000000000"


def _doc(*statements: dict[str, Any]) -> str:
    return json.dumps({"Version": "2012-10-17", "Statement": list(statements)})


def _stmt(effect: str, action: Any, resource: str = "*", condition: dict | None = None) -> dict[str, Any]:
    s: dict[str, Any] = {"Effect": effect, "Action": action, "Resource": resource}
    if condition:
        s["Condition"] = condition
    return s


def _denied(code: str) -> bool:
    return any(k in code for k in ("AccessDenied", "Unauthorized", "Forbidden", "InvalidClientTokenId",
                                   "NotAuthorized", "AuthorizationError"))


def _code(fn: Callable[[], Any]) -> str:
    """호출 결과: 'OK' 또는 오류 코드."""
    try:
        fn()
        return "OK"
    except ClientError as e:
        return e.response.get("Error", {}).get("Code", "?")
    except Exception as e:  # noqa: BLE001
        return type(e).__name__


def _user(p: Probe, base: str, policy: str | None = None) -> tuple[str, Any, dict[str, str]]:
    """사용자 + 액세스 키 + (선택) 인라인 정책. (이름, 세션, 키) 를 돌려준다."""
    iam = p.client("iam")
    name = p.name(base)
    iam.create_user(UserName=name)
    key = iam.create_access_key(UserName=name)["AccessKey"]

    def _cleanup() -> None:
        for pn in iam.list_user_policies(UserName=name).get("PolicyNames", []):
            iam.delete_user_policy(UserName=name, PolicyName=pn)
        for k in iam.list_access_keys(UserName=name).get("AccessKeyMetadata", []):
            iam.delete_access_key(UserName=name, AccessKeyId=k["AccessKeyId"])
        iam.delete_user(UserName=name)

    p.cleanup(f"user-{base}", _cleanup)
    if policy:
        iam.put_user_policy(UserName=name, PolicyName="p", PolicyDocument=policy)
    sess = boto3.session.Session(aws_access_key_id=key["AccessKeyId"], aws_secret_access_key=key["SecretAccessKey"],
                                 region_name="us-east-1")
    return name, sess, key


def run_iam_enforcement(p: Probe) -> None:
    iam, s3, sqs, ddb = p.client("iam"), p.client("s3"), p.client("sqs"), p.client("dynamodb")

    # ---------- 관리자가 만든 리소스
    bucket, empty_bucket = p.name("enf"), p.name("enf-empty")
    for b in (bucket, empty_bucket):
        s3.create_bucket(Bucket=b)
    s3.put_object(Bucket=bucket, Key="a.txt", Body=b"x")

    def _rm_buckets() -> None:
        for b in (bucket, empty_bucket, p.name("enf-byuser")):
            try:
                for o in s3.list_objects_v2(Bucket=b).get("Contents", []):
                    s3.delete_object(Bucket=b, Key=o["Key"])
                s3.delete_bucket(Bucket=b)
            except ClientError:
                pass

    p.cleanup("buckets", _rm_buckets)
    qurl = sqs.create_queue(QueueName=p.name("enf"))["QueueUrl"]
    p.cleanup("q", lambda: sqs.delete_queue(QueueUrl=qurl))
    sqs.send_message(QueueUrl=qurl, MessageBody="hello")
    tables = (p.name("enf"), p.name("enf-throwaway"))
    for t in tables:
        ddb.create_table(TableName=t, BillingMode="PAY_PER_REQUEST",
                         AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                         KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])
    for t in tables:
        ddb.get_waiter("table_exists").wait(TableName=t, WaiterConfig={"Delay": 1, "MaxAttempts": 30})

    def _rm_tables() -> None:
        for t in (*tables, p.name("enf-byuser")):
            try:
                ddb.delete_table(TableName=t)
            except ClientError:
                pass

    p.cleanup("tables", _rm_tables)

    # ---------- 1) 정책 없는 사용자
    _, ns, _ = _user(p, "noperm")
    us3, usqs, uddb = ns.client("s3", config=_CFG), ns.client("sqs", config=_CFG), ns.client("dynamodb", config=_CFG)
    matrix: list[tuple[str, str, Callable[[], Any]]] = [
        ("계정", "s3:ListAllMyBuckets(ListBuckets)", lambda: us3.list_buckets()),
        ("계정", "s3:CreateBucket", lambda: us3.create_bucket(Bucket=p.name("enf-byuser"))),
        ("관리", "s3:PutBucketVersioning", lambda: us3.put_bucket_versioning(
            Bucket=bucket, VersioningConfiguration={"Status": "Enabled"})),
        ("관리", "s3:DeleteBucket(관리자가 만든 빈 버킷)", lambda: us3.delete_bucket(Bucket=empty_bucket)),
        ("데이터", "s3:GetObject", lambda: us3.get_object(Bucket=bucket, Key="a.txt")),
        ("데이터", "s3:PutObject", lambda: us3.put_object(Bucket=bucket, Key="b.txt", Body=b"y")),
        ("데이터", "s3:ListBucket(ListObjectsV2)", lambda: us3.list_objects_v2(Bucket=bucket)),
        ("계정", "sqs:ListQueues", lambda: usqs.list_queues()),
        ("계정", "sqs:CreateQueue", lambda: usqs.create_queue(QueueName=p.name("enf-byuser"))),
        ("데이터", "sqs:SendMessage", lambda: usqs.send_message(QueueUrl=qurl, MessageBody="x")),
        ("데이터", "sqs:ReceiveMessage", lambda: usqs.receive_message(QueueUrl=qurl, WaitTimeSeconds=0)),
        ("계정", "dynamodb:ListTables", lambda: uddb.list_tables()),
        ("계정", "dynamodb:CreateTable", lambda: uddb.create_table(
            TableName=p.name("enf-byuser"), BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])),
        ("관리", "dynamodb:DescribeTable", lambda: uddb.describe_table(TableName=tables[0])),
        ("데이터", "dynamodb:PutItem", lambda: uddb.put_item(TableName=tables[0], Item={"pk": {"S": "u"}})),
        ("데이터", "dynamodb:Scan", lambda: uddb.scan(TableName=tables[0])),
        ("관리", "dynamodb:DeleteTable(관리자가 만든 테이블)", lambda: uddb.delete_table(TableName=tables[1])),
    ]
    for level, label, fn in matrix:
        code = _code(fn)
        p.behavior(f"정책 없는 사용자의 {label} 거부(암묵적 Deny) [{level} 수준]", _denied(code),
                   code if code != "OK" else "허용됨")
    # 사용자가 만든 큐 정리
    try:
        sqs.delete_queue(QueueUrl=sqs.get_queue_url(QueueName=p.name("enf-byuser"))["QueueUrl"])
    except ClientError:
        pass

    # ---------- 2) 명시적 Deny (Allow * 위에)
    _, ds, _ = _user(p, "denys3", _doc(_stmt("Allow", "*"), _stmt("Deny", ["s3:GetObject", "s3:ListAllMyBuckets"])))
    ds3 = ds.client("s3", config=_CFG)
    c1 = _code(lambda: ds3.get_object(Bucket=bucket, Key="a.txt"))
    p.behavior("Allow * + 명시적 Deny s3:GetObject → GetObject 거부", _denied(c1), c1 if c1 != "OK" else "허용됨")
    c2 = _code(lambda: ds3.list_buckets())
    p.behavior("Allow * + 명시적 Deny s3:ListAllMyBuckets → ListBuckets 거부", _denied(c2), c2 if c2 != "OK" else "허용됨")

    # ---------- 3) AssumeRole: 호출자 정책의 명시적 Deny
    role = p.name("enf-role")
    trust = _doc({"Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{_ACCT}:root"}, "Action": "sts:AssumeRole"})
    role_arn = iam.create_role(RoleName=role, AssumeRolePolicyDocument=trust)["Role"]["Arn"]
    iam.put_role_policy(RoleName=role, PolicyName="all", PolicyDocument=_doc(_stmt("Allow", "*")))

    def _rm_role() -> None:
        iam.delete_role_policy(RoleName=role, PolicyName="all")
        iam.delete_role(RoleName=role)

    p.cleanup("role", _rm_role)
    _, ars, _ = _user(p, "denyassume", _doc(_stmt("Allow", "*"), _stmt("Deny", "sts:AssumeRole")))
    c = _code(lambda: ars.client("sts", config=_CFG).assume_role(RoleArn=role_arn, RoleSessionName="x1"))
    p.behavior("호출자 정책에 sts:AssumeRole 명시적 Deny → AssumeRole 거부 (신뢰 정책은 계정 루트)", _denied(c),
               c if c != "OK" else "허용됨 — AssumeRole 은 호출자의 자격 증명 정책을 평가하지 않는다")
    _, nas, _ = _user(p, "noassume")
    c = _code(lambda: nas.client("sts", config=_CFG).assume_role(RoleArn=role_arn, RoleSessionName="x2"))
    p.behavior("정책 없는 사용자의 AssumeRole 거부 (신뢰 정책은 계정 루트)", _denied(c),
               c if c != "OK" else "허용됨 — 호출자 정책 미평가")

    # ---------- 4) 세션 정책
    sts = p.client("sts")
    sess_pol = _doc(_stmt("Allow", "*"), _stmt("Deny", ["iam:ListUsers", "ec2:DescribeVpcs"]))
    cred = p.call("AssumeRole(세션 정책: Deny iam:ListUsers·ec2:DescribeVpcs)", sts.assume_role,
                  RoleArn=role_arn, RoleSessionName="sesspol", Policy=sess_pol)
    if cred:
        c_ = cred["Credentials"]
        rs = boto3.session.Session(aws_access_key_id=c_["AccessKeyId"], aws_secret_access_key=c_["SecretAccessKey"],
                                   aws_session_token=c_["SessionToken"], region_name="us-east-1")
        ci = _code(lambda: rs.client("iam", config=_CFG).list_users())
        p.behavior("세션 정책의 Deny 가 IAM ListUsers 에 적용", _denied(ci), ci if ci != "OK" else "허용됨")
        ce = _code(lambda: rs.client("ec2", config=_CFG).describe_vpcs())
        p.behavior("세션 정책의 Deny 가 EC2 DescribeVpcs 에 적용", _denied(ce),
                   ce if ce != "OK" else "허용됨 — EC2 는 세션 정책을 무시")

    # ---------- 5) iam:PassRole
    ec2 = p.client("ec2")
    ip = p.name("enf-ip")
    iam.create_instance_profile(InstanceProfileName=ip)
    iam.add_role_to_instance_profile(InstanceProfileName=ip, RoleName=role)

    def _rm_ip() -> None:
        iam.remove_role_from_instance_profile(InstanceProfileName=ip, RoleName=role)
        iam.delete_instance_profile(InstanceProfileName=ip)

    p.cleanup("ip", _rm_ip)
    ami = None
    try:
        ami = ec2.describe_images(Owners=["amazon"])["Images"][0]["ImageId"]
    except Exception:  # noqa: BLE001
        pass
    if ami:
        _, ps, _ = _user(p, "nopassrole", _doc(
            _stmt("Allow", ["ec2:RunInstances", "ec2:Describe*", "ec2:TerminateInstances", "iam:GetInstanceProfile"]),
            _stmt("Deny", "iam:PassRole")))
        iid: list[str] = []

        def _run() -> None:
            r = ps.client("ec2", config=_CFG).run_instances(ImageId=ami, InstanceType="t3.micro", MinCount=1, MaxCount=1,
                                                            IamInstanceProfile={"Name": ip})
            iid.append(r["Instances"][0]["InstanceId"])

        c = _code(_run)
        if iid:
            p.cleanup("pr-inst", lambda: ec2.terminate_instances(InstanceIds=iid))
        p.behavior("iam:PassRole 명시적 Deny 인 사용자의 run-instances(인스턴스 프로파일) 거부", _denied(c),
                   c if c != "OK" else "허용됨 — PassRole 미검사")
    else:
        p.skip("iam:PassRole", "AMI 없음")

    # ---------- 6) 비활성 액세스 키
    iname, isess, ikey = _user(p, "inactive", _doc(_stmt("Allow", "*")))
    iam.update_access_key(UserName=iname, AccessKeyId=ikey["AccessKeyId"], Status="Inactive")
    for svc, label, fn in (
        ("iam", "IAM ListUsers", lambda c: c.list_users()),
        ("sts", "STS GetCallerIdentity", lambda c: c.get_caller_identity()),
        ("s3", "S3 ListBuckets", lambda c: c.list_buckets()),
        ("ec2", "EC2 DescribeVpcs", lambda c: c.describe_vpcs()),
    ):
        c = _code(lambda fn=fn, svc=svc: fn(isess.client(svc, config=_CFG)))
        p.behavior(f"비활성(Inactive) 액세스 키로 {label} 거부", _denied(c), c if c != "OK" else "허용됨")

    # ---------- 7) 전역 조건 키
    cond_deny = _doc(
        _stmt("Allow", "*"),
        _stmt("Deny", ["ec2:DescribeVpcs", "iam:ListUsers"], condition={"StringEquals": {"aws:RequestedRegion": "eu-west-1"}}),
    )
    _, cds, _ = _user(p, "conddeny", cond_deny)
    for svc, label, fn in (("ec2", "ec2:DescribeVpcs", lambda c: c.describe_vpcs()),
                           ("iam", "iam:ListUsers", lambda c: c.list_users())):
        c = _code(lambda fn=fn, svc=svc: fn(cds.client(svc, config=_CFG)))
        p.behavior(f"Deny 조건 aws:RequestedRegion=eu-west-1 은 us-east-1 호출에 적용되지 않음 ({label} 허용)",
                   c == "OK", "허용" if c == "OK" else f"{c} — 조건이 맞지 않는데도 Deny 적용")
    cond_allow = _doc(_stmt("Allow", ["iam:ListUsers", "ec2:DescribeVpcs"],
                            condition={"StringEquals": {"aws:RequestedRegion": "us-east-1"}}))
    _, cas, _ = _user(p, "condallow", cond_allow)
    for svc, label, fn in (("ec2", "ec2:DescribeVpcs", lambda c: c.describe_vpcs()),
                           ("iam", "iam:ListUsers", lambda c: c.list_users())):
        c = _code(lambda fn=fn, svc=svc: fn(cas.client(svc, config=_CFG)))
        p.behavior(f"Allow 조건 aws:RequestedRegion=us-east-1 이 us-east-1 호출에 적용됨 ({label} 허용)",
                   c == "OK", "허용" if c == "OK" else f"{c} — 조건이 맞는데도 Allow 미적용")
    tls_deny = _doc(_stmt("Allow", "*"),
                    _stmt("Deny", ["ec2:DescribeVpcs", "iam:ListUsers"], condition={"Bool": {"aws:SecureTransport": "false"}}))
    _, tds, _ = _user(p, "tlsdeny", tls_deny)
    for svc, label, fn in (("ec2", "ec2:DescribeVpcs", lambda c: c.describe_vpcs()),
                           ("iam", "iam:ListUsers", lambda c: c.list_users())):
        c = _code(lambda fn=fn, svc=svc: fn(tds.client(svc, config=_CFG)))
        p.behavior(f"Deny 조건 aws:SecureTransport=false 는 HTTPS 호출에 적용되지 않음 ({label} 허용)",
                   c == "OK", "허용" if c == "OK" else f"{c} — HTTPS인데도 Deny 적용")

    # 같은 정책을 시뮬레이터로
    ctx_region = [{"ContextKeyName": "aws:RequestedRegion", "ContextKeyValues": ["us-east-1"], "ContextKeyType": "string"}]
    for label, doc, want in (
        ("Deny(RequestedRegion=eu-west-1)", cond_deny, "allowed"),
        ("Allow(RequestedRegion=us-east-1)", cond_allow, "allowed"),
    ):
        r = p.call(f"SimulateCustomPolicy({label}, 컨텍스트 us-east-1)", iam.simulate_custom_policy,
                   PolicyInputList=[doc], ActionNames=["iam:ListUsers", "ec2:DescribeVpcs"], ContextEntries=ctx_region)
        if r:
            got = {e["EvalActionName"]: e["EvalDecision"] for e in r["EvaluationResults"]}
            p.behavior(f"시뮬레이터가 조건 키를 올바르게 판정: {label} → {want}", all(v == want for v in got.values()), str(got))
    r = p.call("SimulateCustomPolicy(Deny SecureTransport=false, 컨텍스트 true)", iam.simulate_custom_policy,
               PolicyInputList=[tls_deny], ActionNames=["iam:ListUsers"],
               ContextEntries=[{"ContextKeyName": "aws:SecureTransport", "ContextKeyValues": ["true"],
                                "ContextKeyType": "boolean"}])
    if r:
        got = {e["EvalActionName"]: e["EvalDecision"] for e in r["EvaluationResults"]}
        p.behavior("시뮬레이터가 조건 키를 올바르게 판정: Deny(SecureTransport=false) → allowed",
                   got.get("iam:ListUsers") == "allowed", str(got))


CHECKS = {
    "iam-enforcement": run_iam_enforcement,
}
