"""모듈 저자·리뷰어가 찾은 정정 사항을 탐침으로 다시 확인한다 (M03·M04·M06~M11).

behavior ok=True 는 "실제 AWS와 같다", ok=False 는 "AWS와 다르다(차이)" 를 뜻한다.
외부(실제 AWS·인터넷)에 연결하는 동작은 시험하지 않는다.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import re
import subprocess
import time
import uuid
from typing import Any

from botocore.exceptions import ClientError

from checks_serverless import _https, _role, _zip
from lib import Probe, wait_until

PORT = os.environ.get("EMULATOR_PORT", "")
CONTAINER = f"aws-emulator-{PORT}"


def _endpoint() -> str:
    return os.environ["AWS_ENDPOINT_URL"].rstrip("/")


def _docker_ok() -> bool:
    try:
        return subprocess.run(["docker", "exec", CONTAINER, "true"], capture_output=True, timeout=10).returncode == 0
    except Exception:  # noqa: BLE001
        return False


def _in_container_curl(url: str, *args: str) -> str:
    r = subprocess.run(["docker", "exec", CONTAINER, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "5", *args, url],
                       capture_output=True, text=True, timeout=20)
    return r.stdout.strip()


def _mem_mib() -> float | None:
    try:
        out = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", CONTAINER],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:  # noqa: BLE001
        return None
    m = re.match(r"\s*([\d.]+)\s*(KiB|MiB|GiB|B)", out)
    if not m:
        return None
    v, unit = float(m.group(1)), m.group(2)
    return v * {"B": 1 / 1048576, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}[unit]


def _wait_active(lam: Any, fn: str) -> None:
    wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("State") == "Active", timeout=30)


def _function(p: Probe, base: str, src: str, role_arn: str, timeout: int = 10) -> str | None:
    lam = p.client("lambda")
    fn = p.name(base)[:64]
    r = p.call(f"CreateFunction({base})", lam.create_function, FunctionName=fn, Runtime="python3.12", Role=role_arn,
               Handler="app.handler", Code={"ZipFile": _zip(src)}, Timeout=timeout)
    if r is None:
        return None
    p.cleanup(f"fn-{base}", lambda: lam.delete_function(FunctionName=fn))
    _wait_active(lam, fn)
    return fn


def _table(p: Probe, base: str) -> str:
    ddb = p.client("dynamodb")
    t = p.name(base)
    ddb.create_table(TableName=t, AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                     KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}], BillingMode="PAY_PER_REQUEST")
    p.cleanup(f"tbl-{base}", lambda: ddb.delete_table(TableName=t))
    ddb.get_waiter("table_exists").wait(TableName=t, WaiterConfig={"Delay": 1, "MaxAttempts": 30})
    return t


def _items_with_prefix(p: Probe, table: str, prefix: str) -> int:
    items = p.client("dynamodb").scan(TableName=table).get("Items", [])
    return sum(1 for i in items if i["pk"]["S"].startswith(prefix))


def _invoke(lam: Any, fn: str, payload: dict) -> dict:
    r = lam.invoke(FunctionName=fn, Payload=json.dumps(payload).encode())
    body = r["Payload"].read().decode()
    try:
        return json.loads(body) if body else {}
    except json.JSONDecodeError:
        return {"raw": body}


# ---------------------------------------------------------------- Lambda 실행 환경
RUNTIME_SRC = '''
import json, sys, uuid
import boto3

def handler(event, context):
    op = event.get("op")
    if op == "version":
        return {"version": sys.version}
    if op == "put":
        try:
            boto3.client("dynamodb").put_item(TableName=event["table"], Item={"pk": {"S": event["pk"]}})
            return {"ok": True}
        except Exception as e:
            return {"ok": False, "err": str(e)[:300]}
    if op == "fail":
        boto3.client("dynamodb").put_item(TableName=event["table"], Item={"pk": {"S": event["prefix"] + str(uuid.uuid4())}})
        raise ValueError("async-fail")
    return {"noop": True}
'''


def run_lambda_runtime(p: Probe) -> None:
    lam, iam, sqs = p.client("lambda"), p.client("iam"), p.client("sqs")
    role_arn = _role(p, "rtrole", "lambda.amazonaws.com", ["logs:*"])
    role_name = role_arn.split("/")[-1]
    table = _table(p, "rt")
    fn = _function(p, "rtfn", RUNTIME_SRC, role_arn)
    if not fn:
        p.skip("Lambda 실행 환경", "함수 생성 실패")
        return
    v = _invoke(lam, fn, {"op": "version"}).get("version", "")
    p.behavior("Lambda python3.12 런타임이 CPython", "RustPython" not in v and v.startswith("3.12"), f"sys.version={v[:90]}".replace("\n", " "))

    r1 = _invoke(lam, fn, {"op": "put", "table": table, "pk": "denied"})
    p.behavior("실행 역할에 dynamodb 권한이 없으면 함수 안 PutItem 이 AccessDenied (역할 정책 집행)",
               r1.get("ok") is False and "AccessDenied" in r1.get("err", ""), json.dumps(r1)[:160])
    iam.put_role_policy(RoleName=role_name, PolicyName="ddb", PolicyDocument=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": ["dynamodb:PutItem"], "Resource": "*"}]}))
    p.cleanup("ddbpol", lambda: iam.delete_role_policy(RoleName=role_name, PolicyName="ddb"))
    time.sleep(1)
    r2 = _invoke(lam, fn, {"op": "put", "table": table, "pk": "allowed"})
    p.behavior("dynamodb:PutItem 을 허용하면 함수 안 PutItem 성공", r2.get("ok") is True, json.dumps(r2)[:160])

    # 비동기 실패 → OnFailure 대상, MaximumRetryAttempts=0
    q = sqs.create_queue(QueueName=p.name("rtdlq"))["QueueUrl"]
    p.cleanup("rtq", lambda: sqs.delete_queue(QueueUrl=q))
    qarn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    iam.put_role_policy(RoleName=role_name, PolicyName="sqs", PolicyDocument=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": ["sqs:SendMessage"], "Resource": "*"}]}))
    p.cleanup("sqspol", lambda: iam.delete_role_policy(RoleName=role_name, PolicyName="sqs"))
    p.call("PutFunctionEventInvokeConfig(재시도 0, OnFailure → SQS)", lam.put_function_event_invoke_config,
           FunctionName=fn, MaximumRetryAttempts=0, DestinationConfig={"OnFailure": {"Destination": qarn}})
    prefix = f"fail-{uuid.uuid4().hex[:6]}-"
    p.call("Invoke(Event, 실패하는 핸들러)", lam.invoke, FunctionName=fn, InvocationType="Event",
           Payload=json.dumps({"op": "fail", "table": table, "prefix": prefix}).encode())
    got: list[Any] = []
    end = time.monotonic() + 35
    while time.monotonic() < end and not got:
        got = sqs.receive_message(QueueUrl=q, WaitTimeSeconds=5, MaxNumberOfMessages=10).get("Messages", [])
    runs = _items_with_prefix(p, table, prefix)
    p.behavior("비동기 실패가 OnFailure 대상(SQS)에 전달됨", len(got) >= 1, f"35초 안에 {len(got)}건")
    p.behavior("MaximumRetryAttempts=0 이면 비동기 실패 함수가 1번만 실행됨", runs == 1, f"실행 {runs}번")

    # 함수 자체의 DLQ(DeadLetterConfig) — OnFailure 대상 없이, 재시도 0
    q2 = sqs.create_queue(QueueName=p.name("rtfndlq"))["QueueUrl"]
    p.cleanup("rtq2", lambda: sqs.delete_queue(QueueUrl=q2))
    q2arn = sqs.get_queue_attributes(QueueUrl=q2, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    p.call("PutFunctionEventInvokeConfig(재시도 0, 대상 없음)", lam.put_function_event_invoke_config,
           FunctionName=fn, MaximumRetryAttempts=0, DestinationConfig={})
    if p.call("UpdateFunctionConfiguration(DeadLetterConfig → SQS)", lam.update_function_configuration,
              FunctionName=fn, DeadLetterConfig={"TargetArn": q2arn}) is not None:
        wait_until(lambda: lam.get_function_configuration(FunctionName=fn).get("LastUpdateStatus") != "InProgress", 30)
        cfg_dlq = lam.get_function_configuration(FunctionName=fn).get("DeadLetterConfig", {}).get("TargetArn")
        p.behavior("함수 DeadLetterConfig 설정이 조회됨", cfg_dlq == q2arn, str(cfg_dlq))
        prefix2 = f"dlq-{uuid.uuid4().hex[:6]}-"
        lam.invoke(FunctionName=fn, InvocationType="Event",
                   Payload=json.dumps({"op": "fail", "table": table, "prefix": prefix2}).encode())
        got2: list[Any] = []
        end = time.monotonic() + 35
        while time.monotonic() < end and not got2:
            got2 = sqs.receive_message(QueueUrl=q2, WaitTimeSeconds=5, MaxNumberOfMessages=10).get("Messages", [])
        runs2 = _items_with_prefix(p, table, prefix2)
        p.behavior("비동기 실패가 함수 DLQ(DeadLetterConfig, SQS)에 전달됨", len(got2) >= 1,
                   f"35초 안에 {len(got2)}건 (함수 실행 {runs2}번)")

    # 메모리: 동기 호출 15번 전후
    before = _mem_mib()
    for _ in range(15):
        _invoke(lam, fn, {"op": "noop"})
    time.sleep(3)
    after = _mem_mib()
    if before is not None and after is not None:
        per = (after - before) / 15
        p.behavior("동기 Invoke 를 반복해도 에뮬레이터 메모리가 늘지 않음", per < 1.0,
                   f"{before:.0f} → {after:.0f} MiB, 호출당 약 {per:.1f} MiB 증가(회수되지 않음)")
    else:
        p.skip("Invoke 메모리 측정", "docker stats 를 읽지 못함")


# ---------------------------------------------------------------- Lambda 리소스 정책(호출 권한)
PERM_SRC = '''
import json
import boto3

def handler(event, context):
    recs = event.get("Records") or []
    if recs and recs[0].get("EventSource") == "aws:sns":
        msg = json.loads(recs[0]["Sns"]["Message"])
        boto3.client("dynamodb").put_item(TableName=msg["table"], Item={"pk": {"S": msg["pk"]}})
        return {"sns": True}
    return {"statusCode": 200, "body": json.dumps({"ok": True})}
'''


def run_lambda_permissions(p: Probe) -> None:
    lam, apig, sns, s3 = p.client("lambda"), p.client("apigateway"), p.client("sns"), p.client("s3")
    role_arn = _role(p, "permrole", "lambda.amazonaws.com", ["logs:*", "dynamodb:*"])
    table = _table(p, "perm")
    fn = _function(p, "permfn", PERM_SRC, role_arn)
    if not fn:
        p.skip("Lambda 권한", "함수 생성 실패")
        return
    fn_arn = lam.get_function(FunctionName=fn)["Configuration"]["FunctionArn"]

    # REST API AWS_PROXY, add-permission 없이
    api = apig.create_rest_api(name=p.name("permrest"))
    api_id = api["id"]
    p.cleanup("rest", lambda: apig.delete_rest_api(restApiId=api_id))
    root = [r for r in apig.get_resources(restApiId=api_id)["items"] if r["path"] == "/"][0]["id"]
    res = apig.create_resource(restApiId=api_id, parentId=root, pathPart="orders")["id"]
    apig.put_method(restApiId=api_id, resourceId=res, httpMethod="GET", authorizationType="NONE")
    apig.put_integration(restApiId=api_id, resourceId=res, httpMethod="GET", type="AWS_PROXY", integrationHttpMethod="POST",
                         uri=f"arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/{fn_arn}/invocations")
    apig.create_deployment(restApiId=api_id, stageName="dev")
    url = f"{_endpoint()}/_aws/execute-api/{api_id}/dev/orders"
    code, body = _https(url)
    p.behavior("REST API(AWS_PROXY) → Lambda: 리소스 정책(add-permission) 없으면 실패(500)", code == 500, f"HTTP {code} {body[:80]}")
    p.call("AddPermission(apigateway.amazonaws.com)", lam.add_permission, FunctionName=fn, StatementId="apigw",
           Action="lambda:InvokeFunction", Principal="apigateway.amazonaws.com",
           SourceArn=f"arn:aws:execute-api:us-east-1:000000000000:{api_id}/*/GET/orders")
    code2, _ = _https(url)
    p.behavior("REST API: add-permission 후 200", code2 == 200, f"HTTP {code2}")

    # SNS → Lambda, add-permission 없이
    topic = sns.create_topic(Name=p.name("permtopic"))["TopicArn"]
    p.cleanup("topic", lambda: sns.delete_topic(TopicArn=topic))
    p.call("Subscribe(lambda, add-permission 없음)", sns.subscribe, TopicArn=topic, Protocol="lambda", Endpoint=fn_arn)
    sns.publish(TopicArn=topic, Message=json.dumps({"table": table, "pk": "sns-noperm"}))
    time.sleep(10)
    n0 = _items_with_prefix(p, table, "sns-noperm")
    p.behavior("SNS → Lambda: 리소스 정책 없으면 함수가 실행되지 않음", n0 == 0,
               f"10초 뒤 항목 {n0}개 (AWS도 실행하지 않지만 전달 실패를 지표·로그로 남긴다)")
    lam.add_permission(FunctionName=fn, StatementId="sns", Action="lambda:InvokeFunction", Principal="sns.amazonaws.com",
                       SourceArn=topic)
    sns.publish(TopicArn=topic, Message=json.dumps({"table": table, "pk": "sns-perm"}))
    ok = wait_until(lambda: _items_with_prefix(p, table, "sns-perm") >= 1, timeout=20)
    p.behavior("SNS → Lambda: add-permission 후 함수 실행", ok, "")

    # S3 → Lambda 알림, add-permission 없이
    b = p.name("permbkt")
    s3.create_bucket(Bucket=b)
    p.cleanup("bkt", lambda: s3.delete_bucket(Bucket=b))
    p.expect_error("PutBucketNotificationConfiguration(Lambda, 권한 없음)", s3.put_bucket_notification_configuration,
                   "InvalidArgument", Bucket=b, NotificationConfiguration={"LambdaFunctionConfigurations": [
                       {"LambdaFunctionArn": fn_arn, "Events": ["s3:ObjectCreated:*"]}]},
                   what="S3 → Lambda 알림: 리소스 정책 없으면 구성 거부(InvalidArgument)")


# ---------------------------------------------------------------- S3 차이
def _empty_bucket(s3: Any, b: str) -> None:
    try:
        for page in s3.get_paginator("list_object_versions").paginate(Bucket=b):
            for v in page.get("Versions", []) + page.get("DeleteMarkers", []):
                try:
                    s3.delete_object(Bucket=b, Key=v["Key"], VersionId=v["VersionId"], BypassGovernanceRetention=True)
                except ClientError:
                    pass
        s3.delete_bucket(Bucket=b)
    except ClientError:
        pass


def _bucket(p: Probe, base: str, **kw: Any) -> str:
    s3 = p.client("s3")
    b = p.name(base)
    s3.create_bucket(Bucket=b, **kw)
    p.cleanup(f"b-{base}", lambda: _empty_bucket(s3, b))
    return b


def run_s3_gaps(p: Probe) -> None:
    s3 = p.client("s3")
    # MFA Delete
    b = _bucket(p, "mfa")
    r = p.call("PutBucketVersioning(MFADelete=Enabled, 임의 MFA 코드)", s3.put_bucket_versioning, Bucket=b,
               MFA="arn:aws:iam::000000000000:mfa/nobody 123456",
               VersioningConfiguration={"Status": "Enabled", "MFADelete": "Enabled"})
    p.behavior("존재하지 않는 MFA 장치·임의 코드로 MFA Delete 를 켤 수 없음", r is None, "받아 줌" if r is not None else "거부")
    if r is not None:
        v = s3.put_object(Bucket=b, Key="k", Body=b"x")["VersionId"]
        p.expect_error("DeleteObject(VersionId, MFA 없음)", s3.delete_object, "AccessDenied", Bucket=b, Key="k", VersionId=v,
                       what="MFA Delete 켠 버킷에서 MFA 없이 버전 영구 삭제 → 거부")
    # 객체 잠금 + 버전 관리 일시 중지
    lb = _bucket(p, "lockver", ObjectLockEnabledForBucket=True)
    p.expect_error("PutBucketVersioning(Suspended, 객체 잠금 버킷)", s3.put_bucket_versioning, "InvalidBucketState", Bucket=lb,
                   VersioningConfiguration={"Status": "Suspended"}, what="객체 잠금 버킷의 버전 관리 일시 중지 → 거부")
    # 복제 구성 검증
    src = _bucket(p, "replsrc")
    s3.put_bucket_versioning(Bucket=src, VersioningConfiguration={"Status": "Enabled"})
    dst = _bucket(p, "repldst")  # 버전 관리 없음
    p.expect_error("PutBucketReplication(대상 버전 관리 없음)", s3.put_bucket_replication, "InvalidRequest", Bucket=src,
                   ReplicationConfiguration={"Role": "arn:aws:iam::000000000000:role/todayorder-probe-nope", "Rules": [
                       {"ID": "r", "Status": "Enabled", "Priority": 1, "Filter": {}, "DeleteMarkerReplication": {"Status": "Disabled"},
                        "Destination": {"Bucket": f"arn:aws:s3:::{dst}"}}]},
                   what="버전 관리 없는 대상 버킷으로 복제 구성 → 거부")
    p.expect_error("PutBucketReplication(없는 대상 버킷)", s3.put_bucket_replication, "InvalidRequest", Bucket=src,
                   ReplicationConfiguration={"Role": "arn:aws:iam::000000000000:role/todayorder-probe-nope", "Rules": [
                       {"ID": "r", "Status": "Enabled", "Priority": 1, "Filter": {}, "DeleteMarkerReplication": {"Status": "Disabled"},
                        "Destination": {"Bucket": f"arn:aws:s3:::{p.name('nosuchbucket')}"}}]},
                   what="존재하지 않는 대상 버킷으로 복제 구성 → 거부")
    # SSE-C 차단
    cb = _bucket(p, "ssec")
    enc = s3.get_bucket_encryption(Bucket=cb)
    blocked = "SSE-C" in json.dumps(enc.get("ServerSideEncryptionConfiguration", {}), default=str)
    key = os.urandom(32)
    try:
        s3.put_object(Bucket=cb, Key="c", Body=b"secret", SSECustomerAlgorithm="AES256", SSECustomerKey=key)
        p.behavior("기본 암호화 설정이 SSE-C 를 차단하면 SSE-C 업로드 거부", not blocked,
                   f"BlockedEncryptionTypes 에 SSE-C {'있음' if blocked else '없음'}, 업로드 성공")
    except ClientError as e:
        p.behavior("기본 암호화 설정이 SSE-C 를 차단하면 SSE-C 업로드 거부", blocked, e.response["Error"]["Code"])
    # 퍼블릭 정책 + BPA 해제 → 익명 GET
    pb = _bucket(p, "public")
    s3.put_public_access_block(Bucket=pb, PublicAccessBlockConfiguration={
        "BlockPublicAcls": False, "IgnorePublicAcls": False, "BlockPublicPolicy": False, "RestrictPublicBuckets": False})
    s3.put_bucket_policy(Bucket=pb, Policy=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": f"arn:aws:s3:::{pb}/*"}]}))
    s3.put_object(Bucket=pb, Key="index.html", Body=b"hello")
    st = s3.get_bucket_policy_status(Bucket=pb)["PolicyStatus"]["IsPublic"]
    code, _ = _https(f"{_endpoint()}/{pb}/index.html")
    p.behavior("퍼블릭 정책(BPA 해제) 버킷의 객체를 익명 GET 하면 200", code == 200, f"IsPublic={st}, 익명 GET HTTP {code}")
    s3.delete_bucket_policy(Bucket=pb)
    # DataSync S3 → S3
    ds, iam = p.client("datasync"), p.client("iam")
    dsrc, ddst = _bucket(p, "dssrc"), _bucket(p, "dsdst")
    for i in range(3):
        s3.put_object(Bucket=dsrc, Key=f"f{i}.txt", Body=b"data")
    role = iam.create_role(RoleName=p.name("dsrole"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "datasync.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("dsrole", lambda: iam.delete_role(RoleName=role["RoleName"]))
    l1 = p.call("CreateLocationS3(원본)", ds.create_location_s3, S3BucketArn=f"arn:aws:s3:::{dsrc}",
                S3Config={"BucketAccessRoleArn": role["Arn"]})
    l2 = p.call("CreateLocationS3(대상)", ds.create_location_s3, S3BucketArn=f"arn:aws:s3:::{ddst}",
                S3Config={"BucketAccessRoleArn": role["Arn"]})
    if l1 and l2:
        t = p.call("CreateTask", ds.create_task, SourceLocationArn=l1["LocationArn"], DestinationLocationArn=l2["LocationArn"])
        if t:
            first_task = ds.describe_task(TaskArn=t["TaskArn"]).get("Status")
            wait_until(lambda: ds.describe_task(TaskArn=t["TaskArn"]).get("Status") == "AVAILABLE", timeout=30)
            p.behavior("DataSync 작업 상태(생성 직후 → 대기 후)", True,
                       f"{first_task} → {ds.describe_task(TaskArn=t['TaskArn']).get('Status')} (AWS도 CREATING 을 거친다)")
            ex = p.call("StartTaskExecution", ds.start_task_execution, TaskArn=t["TaskArn"])
            if ex:
                ea = ex["TaskExecutionArn"]
                first = ds.describe_task_execution(TaskExecutionArn=ea).get("Status")
                wait_until(lambda: ds.describe_task_execution(TaskExecutionArn=ea).get("Status") in ("SUCCESS", "ERROR"), timeout=30)
                d = ds.describe_task_execution(TaskExecutionArn=ea)
                copied = s3.list_objects_v2(Bucket=ddst).get("KeyCount", 0)
                p.behavior("DataSync S3→S3 작업이 파일을 실제로 복사", copied == 3,
                           f"처음 상태 {first} → {d.get('Status')}, FilesTransferred={d.get('FilesTransferred')}, 대상 객체 {copied}개")
        p.call("CreateLocationNfs", ds.create_location_nfs, ServerHostname="10.0.0.10", Subdirectory="/exports",
               OnPremConfig={"AgentArns": ["arn:aws:datasync:us-east-1:000000000000:agent/agent-0123456789abcdef0"]})
    # Storage Gateway
    sg = p.client("storagegateway")
    g = p.call("ActivateGateway(임의 활성화 키, FILE_S3)", sg.activate_gateway, ActivationKey="AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
               GatewayName=p.name("gw"), GatewayTimezone="GMT", GatewayRegion="us-east-1", GatewayType="FILE_S3")
    if g:
        garn = g["GatewayARN"]
        p.call("CreateSMBFileShare", sg.create_smb_file_share, ClientToken=uuid.uuid4().hex, GatewayARN=garn,
               Role=role["Arn"], LocationARN=f"arn:aws:s3:::{dsrc}")
        p.call("ListTapes", sg.list_tapes)


# ---------------------------------------------------------------- CloudFormation 진행 방식·드리프트
VPC_NAT_TEMPLATE = {
    "AWSTemplateFormatVersion": "2010-09-09",
    "Resources": {
        "Vpc": {"Type": "AWS::EC2::VPC", "Properties": {"CidrBlock": "10.60.0.0/16"}},
        "Igw": {"Type": "AWS::EC2::InternetGateway"},
        "IgwAttach": {"Type": "AWS::EC2::VPCGatewayAttachment", "Properties": {"VpcId": {"Ref": "Vpc"}, "InternetGatewayId": {"Ref": "Igw"}}},
        "Public": {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": {"Ref": "Vpc"}, "CidrBlock": "10.60.1.0/24", "AvailabilityZone": "us-east-1a"}},
        "Private": {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": {"Ref": "Vpc"}, "CidrBlock": "10.60.2.0/24", "AvailabilityZone": "us-east-1a"}},
        "PublicRt": {"Type": "AWS::EC2::RouteTable", "Properties": {"VpcId": {"Ref": "Vpc"}}},
        "PublicDefault": {"Type": "AWS::EC2::Route", "DependsOn": "IgwAttach",
                          "Properties": {"RouteTableId": {"Ref": "PublicRt"}, "DestinationCidrBlock": "0.0.0.0/0", "GatewayId": {"Ref": "Igw"}}},
        "PublicAssoc": {"Type": "AWS::EC2::SubnetRouteTableAssociation", "Properties": {"SubnetId": {"Ref": "Public"}, "RouteTableId": {"Ref": "PublicRt"}}},
        "NatEip": {"Type": "AWS::EC2::EIP", "Properties": {"Domain": "vpc"}},
        "Nat": {"Type": "AWS::EC2::NatGateway", "Properties": {"SubnetId": {"Ref": "Public"}, "AllocationId": {"Fn::GetAtt": ["NatEip", "AllocationId"]}}},
        "PrivateRt": {"Type": "AWS::EC2::RouteTable", "Properties": {"VpcId": {"Ref": "Vpc"}}},
        "PrivateDefault": {"Type": "AWS::EC2::Route",
                           "Properties": {"RouteTableId": {"Ref": "PrivateRt"}, "DestinationCidrBlock": "0.0.0.0/0", "NatGatewayId": {"Ref": "Nat"}}},
        "PrivateAssoc": {"Type": "AWS::EC2::SubnetRouteTableAssociation", "Properties": {"SubnetId": {"Ref": "Private"}, "RouteTableId": {"Ref": "PrivateRt"}}},
        "WebSg": {"Type": "AWS::EC2::SecurityGroup", "Properties": {"GroupDescription": "web", "VpcId": {"Ref": "Vpc"},
                  "SecurityGroupIngress": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "CidrIp": "0.0.0.0/0"}]}},
    },
}
TERMINAL = ("CREATE_COMPLETE", "ROLLBACK_COMPLETE", "CREATE_FAILED", "ROLLBACK_FAILED")


def run_cfn_timing(p: Probe) -> None:
    cfn = p.client("cloudformation")
    body = json.dumps(VPC_NAT_TEMPLATE)

    def create(base: str) -> str:
        name = p.name(base)
        cfn.create_stack(StackName=name, TemplateBody=body)
        p.cleanup(f"stk-{base}", lambda: cfn.delete_stack(StackName=name))
        return name

    def status(name: str) -> str:
        return cfn.describe_stacks(StackName=name)["Stacks"][0]["StackStatus"]

    # A: CLI 웨이터처럼 0초·30초(·60초)에만 조회
    a = create("cfnwaiter")
    seen = [status(a)]
    for _ in range(2):
        if seen[-1] in TERMINAL:
            break
        time.sleep(30)
        seen.append(status(a))
    reason = ""
    if seen[-1] != "CREATE_COMPLETE":
        ev = cfn.describe_stack_events(StackName=a)["StackEvents"]
        reason = next((e.get("ResourceStatusReason", "") for e in ev if e.get("ResourceStatus") == "CREATE_FAILED"), "")
    p.behavior("CLI 웨이터처럼 30초 간격으로만 조회해도 NAT·경로가 있는 VPC 스택이 CREATE_COMPLETE",
               seen[-1] == "CREATE_COMPLETE", f"관찰 {' → '.join(seen)} {reason[:120]}")
    # B: 2초 간격
    b = create("cfnpoll")
    t0 = time.monotonic()
    st = status(b)
    while st not in TERMINAL and time.monotonic() - t0 < 60:
        time.sleep(2)
        st = status(b)
    p.behavior("2초 간격 조회로 같은 스택이 CREATE_COMPLETE", st == "CREATE_COMPLETE", f"{st} ({time.monotonic() - t0:.0f}초)")
    if st != "CREATE_COMPLETE":
        return
    # 드리프트: 아무것도 바꾸지 않은 상태 + SG 규칙 하나를 밖에서 추가
    ec2 = p.client("ec2")
    res = {r["LogicalResourceId"]: r["PhysicalResourceId"] for r in cfn.describe_stack_resources(StackName=b)["StackResources"]}
    ec2.authorize_security_group_ingress(GroupId=res["WebSg"], IpPermissions=[
        {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}])
    did = p.call("DetectStackDrift", cfn.detect_stack_drift, StackName=b)
    if not did:
        return
    wait_until(lambda: cfn.describe_stack_drift_detection_status(StackDriftDetectionId=did["StackDriftDetectionId"])
               ["DetectionStatus"] != "DETECTION_IN_PROGRESS", timeout=30)
    drifts = {d["LogicalResourceId"]: d["StackResourceDriftStatus"]
              for d in cfn.describe_stack_resource_drifts(StackName=b)["StackResourceDrifts"]}
    untouched = {k: drifts.get(k) for k in ("Igw", "IgwAttach", "PublicDefault", "PrivateDefault", "Nat", "NatEip", "PublicRt")}
    wrong = {k: v for k, v in untouched.items() if v not in ("IN_SYNC", None)}
    p.behavior("드리프트: 손대지 않은 IGW·경로·NAT·EIP·라우팅 테이블은 IN_SYNC", not wrong, json.dumps(untouched))
    p.behavior("드리프트: 스택 밖에서 SG 인바운드 규칙을 추가하면 MODIFIED", drifts.get("WebSg") == "MODIFIED",
               f"WebSg={drifts.get('WebSg')}")
    ec2.revoke_security_group_ingress(GroupId=res["WebSg"], IpPermissions=[
        {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}])


# ---------------------------------------------------------------- 분석 서비스 차이
GLUE_SCRIPT = '''
import boto3
boto3.client("s3").put_object(Bucket="{bucket}", Key="glue-out/done.txt", Body=b"glue-ok")
'''


def run_analytics_gaps(p: Probe) -> None:
    s3, glue, ath, iam, fh = (p.client(n) for n in ("s3", "glue", "athena", "iam", "firehose"))
    b = _bucket(p, "lake")
    db = p.name("db").replace("-", "_")
    glue.create_database(DatabaseInput={"Name": db})
    p.cleanup("db", lambda: glue.delete_database(Name=db))
    glue.create_table(DatabaseName=db, TableInput={
        "Name": "orders", "TableType": "EXTERNAL_TABLE", "PartitionKeys": [{"Name": "dt", "Type": "string"}],
        "StorageDescriptor": {"Columns": [{"Name": "id", "Type": "string"}, {"Name": "amount", "Type": "int"}],
                              "Location": f"s3://{b}/orders/",
                              "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
                              "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
                              "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}}})
    s3.put_object(Bucket=b, Key="orders/dt=2026-11-01/a.json", Body=b'{"id":"a","amount":10}\n{"id":"b","amount":20}\n')
    s3.put_object(Bucket=b, Key="orders/dt=2026-11-02/b.json", Body=b'{"id":"c","amount":30}\n')
    glue.batch_create_partition(DatabaseName=db, TableName="orders", PartitionInputList=[{
        "Values": ["2026-11-01"], "StorageDescriptor": {"Location": f"s3://{b}/orders/dt=2026-11-01/",
                                                         "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}}}])
    wg = p.name("wg")
    ath.create_work_group(Name=wg, Configuration={"ResultConfiguration": {"OutputLocation": f"s3://{b}/athena-results/"}})

    def q(sql: str) -> tuple[str, Any]:
        qid = ath.start_query_execution(QueryString=sql, WorkGroup=wg, QueryExecutionContext={"Database": db})["QueryExecutionId"]
        wait_until(lambda: ath.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
                   in ("SUCCEEDED", "FAILED", "CANCELLED"), timeout=30)
        stt = ath.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        if stt["State"] != "SUCCEEDED":
            return stt["State"], stt.get("StateChangeReason", "")
        rows = ath.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]
        return "SUCCEEDED", [[c.get("VarCharValue") for c in r["Data"]] for r in rows[1:]]

    s1, r1 = q("SELECT count(*) FROM orders")
    p.behavior("Athena: 등록된 파티션(dt=2026-11-01) 데이터만 읽음 (2건)", s1 == "SUCCEEDED" and r1 == [["2"]], f"{s1} {r1}")
    s2, r2 = q("SELECT count(*) FROM orders WHERE dt = '2026-11-01'")
    p.behavior("Athena: 파티션 열 dt 로 WHERE 필터", s2 == "SUCCEEDED", f"{s2} {str(r2)[:120]}")
    s3_, r3 = q("SELECT date_trunc('day', from_iso8601_timestamp('2026-11-01T10:00:00Z'))")
    p.behavior("Athena: Trino 함수 date_trunc·from_iso8601_timestamp", s3_ == "SUCCEEDED", f"{s3_} {str(r3)[:120]}")
    p.call("ListWorkGroups", ath.list_work_groups)
    p.call("ListNamedQueries", ath.list_named_queries)
    p.call("DeleteWorkGroup", ath.delete_work_group, WorkGroup=wg, RecursiveDeleteOption=True)

    # Glue Python shell 작업
    s3.put_object(Bucket=b, Key="scripts/job.py", Body=GLUE_SCRIPT.format(bucket=b).encode())
    grole = iam.create_role(RoleName=p.name("gluerole"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "glue.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("grole", lambda: iam.delete_role(RoleName=grole["RoleName"]))
    iam.put_role_policy(RoleName=grole["RoleName"], PolicyName="s3", PolicyDocument=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:*", "Resource": "*"}]}))
    p.cleanup("gpol", lambda: iam.delete_role_policy(RoleName=grole["RoleName"], PolicyName="s3"))
    job = p.name("pyshell")
    if p.call("CreateJob(pythonshell)", glue.create_job, Name=job, Role=grole["Arn"],
              Command={"Name": "pythonshell", "ScriptLocation": f"s3://{b}/scripts/job.py", "PythonVersion": "3.9"}) is not None:
        p.cleanup("job", lambda: glue.delete_job(JobName=job))
        run = glue.start_job_run(JobName=job)["JobRunId"]
        wait_until(lambda: glue.get_job_run(JobName=job, RunId=run)["JobRun"]["JobRunState"] in ("SUCCEEDED", "FAILED", "ERROR", "TIMEOUT"),
                   timeout=60, interval=2)
        state = glue.get_job_run(JobName=job, RunId=run)["JobRun"]["JobRunState"]
        made = s3.list_objects_v2(Bucket=b, Prefix="glue-out/").get("KeyCount", 0)
        p.behavior("Glue Python shell 작업이 스크립트를 실제로 실행(S3 객체 생성)", state == "SUCCEEDED" and made == 1,
                   f"JobRunState={state}, glue-out 객체 {made}개")

    # Firehose: 신뢰 정책만 맞고 S3 권한이 없는 역할
    frole = iam.create_role(RoleName=p.name("fhrole"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "firehose.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("frole", lambda: iam.delete_role(RoleName=frole["RoleName"]))
    stream = p.name("fhnoperm")
    if p.call("CreateDeliveryStream(S3 권한 없는 역할)", fh.create_delivery_stream, DeliveryStreamName=stream,
              DeliveryStreamType="DirectPut", ExtendedS3DestinationConfiguration={
                  "RoleARN": frole["Arn"], "BucketARN": f"arn:aws:s3:::{b}", "Prefix": "fh/",
                  "BufferingHints": {"IntervalInSeconds": 60, "SizeInMBs": 1}}) is not None:
        p.cleanup("fh", lambda: fh.delete_delivery_stream(DeliveryStreamName=stream))
        wait_until(lambda: fh.describe_delivery_stream(DeliveryStreamName=stream)["DeliveryStreamDescription"]
                   ["DeliveryStreamStatus"] == "ACTIVE", timeout=30)
        fh.put_record(DeliveryStreamName=stream, Record={"Data": b'{"id":"z"}\n'})
        got = wait_until(lambda: s3.list_objects_v2(Bucket=b, Prefix="fh/").get("KeyCount", 0) > 0, timeout=30)
        p.behavior("Firehose: 역할에 S3 권한이 없으면 배달하지 못함", not got, "배달됨(권한 정책 미검사)" if got else "배달 안 됨")


# ---------------------------------------------------------------- 보안 서비스
ROTATE_SRC = '''
import boto3

def handler(event, context):
    sm = boto3.client("secretsmanager")
    arn, token, step = event["SecretId"], event["ClientRequestToken"], event["Step"]
    if step == "createSecret":
        try:
            sm.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        except sm.exceptions.ResourceNotFoundException:
            sm.put_secret_value(SecretId=arn, ClientRequestToken=token, SecretString="rotated-" + token[:8],
                                VersionStages=["AWSPENDING"])
    elif step == "finishSecret":
        meta = sm.describe_secret(SecretId=arn)
        cur = [v for v, s in meta["VersionIdsToStages"].items() if "AWSCURRENT" in s][0]
        if cur != token:
            sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT", MoveToVersionId=token,
                                           RemoveFromVersionId=cur)
    return {"step": step}
'''


def run_security_better(p: Probe) -> None:
    kms, ssm, sm, lam, iam, s3, cfg, ct = (p.client(n) for n in
                                           ("kms", "ssm", "secretsmanager", "lambda", "iam", "s3", "config", "cloudtrail"))
    # KMS 비활성화 키
    k = kms.create_key(Description="probe-disabled")["KeyMetadata"]["KeyId"]
    p.cleanup("k", lambda: kms.schedule_key_deletion(KeyId=k, PendingWindowInDays=7))
    blob = kms.encrypt(KeyId=k, Plaintext=b"order")["CiphertextBlob"]
    kms.disable_key(KeyId=k)
    p.expect_error("Decrypt(비활성화된 키)", kms.decrypt, "DisabledException", CiphertextBlob=blob,
                   what="비활성화된 KMS 키로 Decrypt → DisabledException")
    kms.enable_key(KeyId=k)
    # SSM SecureString + 비활성화된 CMK
    k2 = kms.create_key(Description="probe-ssm")["KeyMetadata"]["KeyId"]
    p.cleanup("k2", lambda: kms.schedule_key_deletion(KeyId=k2, PendingWindowInDays=7))
    pname = f"/todayorder/probe/{p.suffix}/db-password"
    ssm.put_parameter(Name=pname, Value="s3cr3t", Type="SecureString", KeyId=k2)
    p.cleanup("param", lambda: ssm.delete_parameter(Name=pname))
    kms.disable_key(KeyId=k2)
    try:
        v = ssm.get_parameter(Name=pname, WithDecryption=True)["Parameter"]["Value"]
        p.behavior("CMK 를 비활성화하면 SecureString 복호화(WithDecryption) 실패", False, f"복호화됨({v == 's3cr3t'})")
    except ClientError as e:
        p.behavior("CMK 를 비활성화하면 SecureString 복호화(WithDecryption) 실패", True, e.response["Error"]["Code"])
    kms.enable_key(KeyId=k2)

    # Secrets Manager 교체
    role_arn = _role(p, "rotrole", "lambda.amazonaws.com", ["secretsmanager:*", "logs:*"])
    fn = _function(p, "rotfn", ROTATE_SRC, role_arn, timeout=30)
    sec = p.name("rotsecret")
    sm.create_secret(Name=sec, SecretString="initial")
    p.cleanup("sec", lambda: sm.delete_secret(SecretId=sec, ForceDeleteWithoutRecovery=True))
    if fn:
        fn_arn = lam.get_function(FunctionName=fn)["Configuration"]["FunctionArn"]
        lam.add_permission(FunctionName=fn, StatementId="sm", Action="lambda:InvokeFunction", Principal="secretsmanager.amazonaws.com")
        if p.call("RotateSecret(add-permission 후)", sm.rotate_secret, SecretId=sec, RotationLambdaARN=fn_arn,
                  RotationRules={"AutomaticallyAfterDays": 30}) is not None:
            ok = wait_until(lambda: sm.get_secret_value(SecretId=sec)["SecretString"].startswith("rotated-"), timeout=30)
            val = sm.get_secret_value(SecretId=sec)["SecretString"]
            p.behavior("Secrets Manager 교체가 Lambda 를 실제로 호출해 AWSCURRENT 값을 바꿈", ok, f"AWSCURRENT={val[:20]}")

    # Config 자동 수정
    logb = _bucket(p, "cfglog")
    s3.put_bucket_policy(Bucket=logb, Policy=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": ["s3:GetBucketAcl", "s3:ListBucket"],
         "Resource": f"arn:aws:s3:::{logb}"},
        {"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": "s3:PutObject",
         "Resource": f"arn:aws:s3:::{logb}/AWSLogs/000000000000/Config/*"}]}))
    crole = iam.create_role(RoleName=p.name("cfgrole2"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("crole", lambda: iam.delete_role(RoleName=crole["RoleName"]))
    fixrole = iam.create_role(RoleName=p.name("fixrole"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "ssm.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("fixrole", lambda: iam.delete_role(RoleName=fixrole["RoleName"]))
    iam.put_role_policy(RoleName=fixrole["RoleName"], PolicyName="ver", PolicyDocument=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": ["s3:PutBucketVersioning", "s3:GetBucketVersioning"],
                                                 "Resource": "arn:aws:s3:::*"}]}))
    p.cleanup("fixpol", lambda: iam.delete_role_policy(RoleName=fixrole["RoleName"], PolicyName="ver"))
    cfg.put_configuration_recorder(ConfigurationRecorder={"name": "default", "roleARN": crole["Arn"],
                                                          "recordingGroup": {"allSupported": True, "includeGlobalResourceTypes": True}})
    cfg.put_delivery_channel(DeliveryChannel={"name": "default", "s3BucketName": logb})
    cfg.start_configuration_recorder(ConfigurationRecorderName="default")

    def _stop() -> None:
        cfg.stop_configuration_recorder(ConfigurationRecorderName="default")
        cfg.delete_delivery_channel(DeliveryChannelName="default")
        cfg.delete_configuration_recorder(ConfigurationRecorderName="default")

    p.cleanup("recorder", _stop)
    tagv = f"probe-{p.suffix}"
    rule = p.name("autofix")
    cfg.put_config_rule(ConfigRule={"ConfigRuleName": rule,
                                    "Source": {"Owner": "AWS", "SourceIdentifier": "S3_BUCKET_VERSIONING_ENABLED"},
                                    "Scope": {"ComplianceResourceTypes": ["AWS::S3::Bucket"], "TagKey": "probe", "TagValue": tagv}})
    p.cleanup("rule", lambda: cfg.delete_config_rule(ConfigRuleName=rule))
    if p.call("PutRemediationConfigurations(Automatic, AWS-ConfigureS3BucketVersioning)", cfg.put_remediation_configurations,
              RemediationConfigurations=[{
                  "ConfigRuleName": rule, "TargetType": "SSM_DOCUMENT", "TargetId": "AWS-ConfigureS3BucketVersioning",
                  "Automatic": True, "MaximumAutomaticAttempts": 3, "RetryAttemptSeconds": 60,
                  "Parameters": {"BucketName": {"ResourceValue": {"Value": "RESOURCE_ID"}},
                                 "AutomationAssumeRole": {"StaticValue": {"Values": [fixrole["Arn"]]}}}}]) is not None:
        p.cleanup("remed", lambda: cfg.delete_remediation_configuration(ConfigRuleName=rule))
        ab = _bucket(p, "autofixb")
        s3.put_bucket_tagging(Bucket=ab, Tagging={"TagSet": [{"Key": "probe", "Value": tagv}]})
        cfg.start_config_rules_evaluation(ConfigRuleNames=[rule])
        ok = wait_until(lambda: s3.get_bucket_versioning(Bucket=ab).get("Status") == "Enabled", timeout=60, interval=2)
        p.behavior("Config 자동 수정(SSM Automation)이 실제로 실행되어 버전 관리를 켬", ok,
                   f"Status={s3.get_bucket_versioning(Bucket=ab).get('Status')}")

    p.call("auditmanager GetAccountStatus", p.client("auditmanager").get_account_status)

    # CloudTrail LookupEvents 범위
    kms.create_key(Description="probe-trail")
    u = p.name("trailuser")
    iam.create_user(UserName=u)
    p.cleanup("tu", lambda: iam.delete_user(UserName=u))
    time.sleep(3)

    def count(src: str) -> int:
        return len(ct.lookup_events(LookupAttributes=[{"AttributeKey": "EventSource", "AttributeValue": src}],
                                    MaxResults=50).get("Events", []))

    p.behavior("CloudTrail LookupEvents 에 IAM 관리 이벤트가 나타남", count("iam.amazonaws.com") > 0, "")
    p.behavior("CloudTrail LookupEvents 에 KMS 관리 이벤트(CreateKey)가 나타남", count("kms.amazonaws.com") > 0, "")


# ---------------------------------------------------------------- 엣지
def run_edge_better(p: Probe) -> None:
    ec2, elb, waf, r53 = (p.client(n) for n in ("ec2", "elbv2", "wafv2", "route53"))
    # WAF on ALB
    vpc = ec2.create_vpc(CidrBlock="10.83.0.0/16")["Vpc"]["VpcId"]
    s1 = ec2.create_subnet(VpcId=vpc, CidrBlock="10.83.1.0/24", AvailabilityZone="us-east-1a")["Subnet"]["SubnetId"]
    s2 = ec2.create_subnet(VpcId=vpc, CidrBlock="10.83.2.0/24", AvailabilityZone="us-east-1b")["Subnet"]["SubnetId"]
    igw = ec2.create_internet_gateway()["InternetGateway"]["InternetGatewayId"]
    ec2.attach_internet_gateway(VpcId=vpc, InternetGatewayId=igw)
    lb = elb.create_load_balancer(Name=p.name("wafalb")[:32], Subnets=[s1, s2])["LoadBalancers"][0]
    lb_arn, dns = lb["LoadBalancerArn"], lb["DNSName"]

    def _cleanup_net() -> None:
        try:
            waf.disassociate_web_acl(ResourceArn=lb_arn)
        except ClientError:
            pass
        elb.delete_load_balancer(LoadBalancerArn=lb_arn)
        time.sleep(1)
        for s in (s1, s2):
            ec2.delete_subnet(SubnetId=s)
        ec2.detach_internet_gateway(VpcId=vpc, InternetGatewayId=igw)
        ec2.delete_internet_gateway(InternetGatewayId=igw)
        ec2.delete_vpc(VpcId=vpc)

    p.cleanup("net", _cleanup_net)
    elb.create_listener(LoadBalancerArn=lb_arn, Protocol="HTTP", Port=80, DefaultActions=[
        {"Type": "fixed-response", "FixedResponseConfig": {"StatusCode": "200", "ContentType": "text/plain", "MessageBody": "ok"}}])
    wait_until(lambda: elb.describe_load_balancers(LoadBalancerArns=[lb_arn])["LoadBalancers"][0]["State"]["Code"] == "active", timeout=30)
    ipset = waf.create_ip_set(Name=p.name("bad"), Scope="REGIONAL", IPAddressVersion="IPV4", Addresses=["203.0.113.0/24"])["Summary"]
    p.cleanup("ipset", lambda: waf.delete_ip_set(Name=ipset["Name"], Scope="REGIONAL", Id=ipset["Id"],
                                                 LockToken=waf.get_ip_set(Name=ipset["Name"], Scope="REGIONAL", Id=ipset["Id"])["LockToken"]))
    acl = waf.create_web_acl(Name=p.name("acl"), Scope="REGIONAL", DefaultAction={"Allow": {}}, VisibilityConfig={
        "SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "probeAcl"}, Rules=[{
            "Name": "block-bad-ips", "Priority": 0, "Action": {"Block": {}},
            "Statement": {"IPSetReferenceStatement": {"ARN": ipset["ARN"], "IPSetForwardedIPConfig": {
                "HeaderName": "X-Forwarded-For", "FallbackBehavior": "NO_MATCH", "Position": "FIRST"}}},
            "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "badIps"}}])["Summary"]
    p.cleanup("acl", lambda: waf.delete_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"],
                                                LockToken=waf.get_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"])["LockToken"]))
    waf.associate_web_acl(WebACLArn=acl["ARN"], ResourceArn=lb_arn)
    if _docker_ok():
        normal = _in_container_curl(f"http://{dns}/")
        bad = _in_container_curl(f"http://{dns}/", "-H", "X-Forwarded-For: 203.0.113.5")
        p.behavior("ALB 에 연결한 WAF Web ACL 이 차단 목록 IP 요청을 실제로 403 으로 막음(컨테이너 안에서 확인)",
                   normal == "200" and bad == "403", f"정상 {normal}, 차단 목록 IP {bad}")
    else:
        p.skip("WAF 차단 관찰", "docker exec 불가")

    # Route 53
    zone = r53.create_hosted_zone(Name=f"edge{p.suffix}.example.com", CallerReference=uuid.uuid4().hex)["HostedZone"]["Id"]

    def _del_zone() -> None:
        for rr in r53.list_resource_record_sets(HostedZoneId=zone)["ResourceRecordSets"]:
            if rr["Type"] not in ("NS", "SOA"):
                r53.change_resource_record_sets(HostedZoneId=zone, ChangeBatch={"Changes": [{"Action": "DELETE", "ResourceRecordSet": rr}]})
        r53.delete_hosted_zone(Id=zone)

    p.cleanup("zone", _del_zone)
    name = f"api.edge{p.suffix}.example.com"

    def rr(region: str, ip: str) -> dict:
        return {"Action": "CREATE", "ResourceRecordSet": {"Name": name, "Type": "A", "SetIdentifier": region, "Region": region,
                                                          "TTL": 60, "ResourceRecords": [{"Value": ip}]}}

    r53.change_resource_record_sets(HostedZoneId=zone, ChangeBatch={"Changes": [rr("us-east-1", "192.0.2.10"),
                                                                                rr("ap-northeast-2", "192.0.2.20")]})

    def answer(resolver: str) -> list[str]:
        return r53.test_dns_answer(HostedZoneId=zone, RecordName=name, RecordType="A", ResolverIP=resolver)["RecordData"]

    us, kr = answer("3.80.0.1"), answer("3.34.0.1")
    p.behavior("지연 시간 레코드: 질의자 위치(리졸버 IP)에 따라 다른 답", us != kr, f"미국 리졸버 {us}, 서울 리졸버 {kr}")
    mix = f"mix.edge{p.suffix}.example.com"
    r53.change_resource_record_sets(HostedZoneId=zone, ChangeBatch={"Changes": [{"Action": "CREATE", "ResourceRecordSet": {
        "Name": mix, "Type": "A", "SetIdentifier": "w1", "Weight": 10, "TTL": 60, "ResourceRecords": [{"Value": "192.0.2.30"}]}}]})
    p.expect_error("ChangeResourceRecordSets(같은 이름에 가중치+지연 시간)", r53.change_resource_record_sets, "InvalidChangeBatch",
                   HostedZoneId=zone, ChangeBatch={"Changes": [{"Action": "CREATE", "ResourceRecordSet": {
                       "Name": mix, "Type": "A", "SetIdentifier": "l1", "Region": "us-east-1", "TTL": 60,
                       "ResourceRecords": [{"Value": "192.0.2.31"}]}}]},
                   what="같은 이름·유형에 서로 다른 라우팅 정책(가중치+지연 시간) → InvalidChangeBatch")
    p.call("ListCidrCollections", r53.list_cidr_collections)


# ---------------------------------------------------------------- 통합 서비스
FAIL_SRC = '''
def handler(event, context):
    raise ValueError("payment declined")
'''


def run_integration_better(p: Probe) -> None:
    sfn, iam, lam, idp, apig2, sch, sqs = (p.client(n) for n in
                                          ("stepfunctions", "iam", "lambda", "cognito-idp", "apigatewayv2", "scheduler", "sqs"))
    # Step Functions Retry/Catch
    fn = _function(p, "sfnfail", FAIL_SRC, _role(p, "sfnfailrole", "lambda.amazonaws.com", ["logs:*"]))
    if fn:
        fn_arn = lam.get_function(FunctionName=fn)["Configuration"]["FunctionArn"]
        srole = _role(p, "sfnrole2", "states.amazonaws.com", ["lambda:InvokeFunction"])
        definition = {"StartAt": "Pay", "States": {
            "Pay": {"Type": "Task", "Resource": fn_arn,
                    "Retry": [{"ErrorEquals": ["ValueError"], "IntervalSeconds": 1, "MaxAttempts": 2, "BackoffRate": 1.0}],
                    "Catch": [{"ErrorEquals": ["States.ALL"], "Next": "Handled"}], "End": True},
            "Handled": {"Type": "Pass", "Result": "compensated", "End": True}}}
        sm_arn = sfn.create_state_machine(name=p.name("retry"), definition=json.dumps(definition), roleArn=srole)["stateMachineArn"]
        p.cleanup("sm", lambda: sfn.delete_state_machine(stateMachineArn=sm_arn))
        ex = sfn.start_execution(stateMachineArn=sm_arn, input="{}")["executionArn"]
        wait_until(lambda: sfn.describe_execution(executionArn=ex)["status"] != "RUNNING", timeout=30)
        status = sfn.describe_execution(executionArn=ex)["status"]
        hist = sfn.get_execution_history(executionArn=ex, maxResults=200)["events"]
        failed = sum(1 for e in hist if e["type"] in ("TaskFailed", "LambdaFunctionFailed"))
        p.behavior("Step Functions Retry(MaxAttempts 2) → Task 3번 실패 후 Catch(States.ALL)로 SUCCEEDED",
                   failed == 3 and status == "SUCCEEDED", f"실패 이벤트 {failed}건, 실행 {status}")

    # Cognito + HTTP API JWT 권한 부여자
    pool = idp.create_user_pool(PoolName=p.name("jwtpool"))["UserPool"]["Id"]
    p.cleanup("pool", lambda: idp.delete_user_pool(UserPoolId=pool))
    client = idp.create_user_pool_client(UserPoolId=pool, ClientName="web", ExplicitAuthFlows=[
        "ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"])["UserPoolClient"]["ClientId"]
    idp.admin_create_user(UserPoolId=pool, Username="alice", MessageAction="SUPPRESS")
    idp.admin_set_user_password(UserPoolId=pool, Username="alice", Password="Todayorder-Pass-123!", Permanent=True)
    tok = idp.initiate_auth(ClientId=client, AuthFlow="USER_PASSWORD_AUTH",
                            AuthParameters={"USERNAME": "alice", "PASSWORD": "Todayorder-Pass-123!"})["AuthenticationResult"]["IdToken"]
    payload = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))
    iss = payload.get("iss", "")
    p.behavior("Cognito 토큰 iss 가 https://cognito-idp.<리전>.amazonaws.com/<풀 ID>", iss.startswith("https://cognito-idp."), iss)
    afn = _function(p, "jwtfn", "def handler(e, c):\n    return {'statusCode': 200, 'body': 'me'}\n",
                    _role(p, "jwtfnrole", "lambda.amazonaws.com", ["logs:*"]))
    if afn:
        afn_arn = lam.get_function(FunctionName=afn)["Configuration"]["FunctionArn"]
        api = apig2.create_api(Name=p.name("jwtapi"), ProtocolType="HTTP")
        api_id = api["ApiId"]
        p.cleanup("api", lambda: apig2.delete_api(ApiId=api_id))
        lam.add_permission(FunctionName=afn, StatementId="apigw", Action="lambda:InvokeFunction", Principal="apigateway.amazonaws.com")
        authz = apig2.create_authorizer(ApiId=api_id, AuthorizerType="JWT", Name="cognito", IdentitySource=["$request.header.Authorization"],
                                        JwtConfiguration={"Issuer": iss, "Audience": [client]})["AuthorizerId"]
        integ = apig2.create_integration(ApiId=api_id, IntegrationType="AWS_PROXY", IntegrationUri=afn_arn,
                                         PayloadFormatVersion="2.0")["IntegrationId"]
        apig2.create_route(ApiId=api_id, RouteKey="GET /me", Target=f"integrations/{integ}", AuthorizationType="JWT", AuthorizerId=authz)
        apig2.create_stage(ApiId=api_id, StageName="$default", AutoDeploy=True)
        c0, _ = _https(api["ApiEndpoint"] + "/me")
        c1, _ = _https(api["ApiEndpoint"] + "/me", headers={"Authorization": tok})
        p.behavior("HTTP API JWT 권한 부여자: 토큰 없으면 401, 유효한 IdToken 이면 200", c0 == 401 and c1 == 200,
                   f"토큰 없음 {c0}, 토큰 {c1} (Issuer 는 토큰의 iss 를 그대로 사용)")

    # EventBridge Scheduler at() 10분 뒤
    q = sqs.create_queue(QueueName=p.name("schq"))["QueueUrl"]
    p.cleanup("schq", lambda: sqs.delete_queue(QueueUrl=q))
    qarn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    srole2 = _role(p, "schrole", "scheduler.amazonaws.com", ["sqs:SendMessage"])
    at = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%S")
    sname = p.name("at10")
    if p.call("CreateSchedule(at() 10분 뒤)", sch.create_schedule, Name=sname, ScheduleExpression=f"at({at})",
              ScheduleExpressionTimezone="UTC", FlexibleTimeWindow={"Mode": "OFF"},
              Target={"Arn": qarn, "RoleArn": srole2, "Input": '{"job":"settle"}'}) is not None:
        p.cleanup("sch", lambda: sch.delete_schedule(Name=sname))
        t0 = time.monotonic()
        got: list[Any] = []
        while time.monotonic() - t0 < 30 and not got:
            got = sqs.receive_message(QueueUrl=q, WaitTimeSeconds=5).get("Messages", [])
        p.behavior("Scheduler at() 일정은 지정 시각(10분 뒤) 전에는 발화하지 않음", not got,
                   f"{time.monotonic() - t0:.0f}초 만에 전달됨" if got else "30초 동안 전달 없음")


CHECKS = {
    "lambda-runtime": run_lambda_runtime,
    "lambda-permissions": run_lambda_permissions,
    "s3-gaps": run_s3_gaps,
    "cfn-timing": run_cfn_timing,
    "analytics-gaps": run_analytics_gaps,
    "security-better": run_security_better,
    "edge-better": run_edge_better,
    "integration-better": run_integration_better,
}
