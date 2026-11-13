"""M09: KMS / Secrets Manager / SSM Parameter Store / ACM / CloudTrail / Config / GuardDuty 탐침."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

from lib import _CFG, Probe, wait_until


def run_kms(p: Probe) -> None:
    kms = p.client("kms")
    k = p.call("CreateKey(대칭)", kms.create_key, Description="probe", Tags=[{"TagKey": "app", "TagValue": "todayorder"}])
    if not k:
        p.skip("KMS 전체", "키 생성 실패")
        return
    kid = k["KeyMetadata"]["KeyId"]
    p.behavior("키 메타데이터(KeySpec SYMMETRIC_DEFAULT, Enabled)",
               k["KeyMetadata"].get("KeySpec") == "SYMMETRIC_DEFAULT" and k["KeyMetadata"].get("Enabled") is True,
               f"KeySpec={k['KeyMetadata'].get('KeySpec')} KeyManager={k['KeyMetadata'].get('KeyManager')}")
    alias = f"alias/{p.name('key')}"
    if p.call("CreateAlias", kms.create_alias, AliasName=alias, TargetKeyId=kid) is not None:
        p.cleanup("alias", lambda: kms.delete_alias(AliasName=alias))

    enc = p.call("Encrypt(별칭으로)", kms.encrypt, KeyId=alias, Plaintext=b"card-1234",
                 EncryptionContext={"order": "1"})
    if enc:
        p.behavior("암호문은 평문과 다름", b"card-1234" not in enc["CiphertextBlob"], f"{len(enc['CiphertextBlob'])}바이트")
        dec = p.call("Decrypt", kms.decrypt, CiphertextBlob=enc["CiphertextBlob"], EncryptionContext={"order": "1"})
        if dec:
            p.behavior("Encrypt → Decrypt 왕복", dec["Plaintext"] == b"card-1234" and dec["KeyId"].endswith(kid))
        p.expect_error("Decrypt(다른 암호화 컨텍스트)", kms.decrypt, "InvalidCiphertextException",
                       CiphertextBlob=enc["CiphertextBlob"], EncryptionContext={"order": "2"},
                       what="암호화 컨텍스트가 다르면 Decrypt 실패")

    dk = p.call("GenerateDataKey(AES_256)", kms.generate_data_key, KeyId=kid, KeySpec="AES_256")
    if dk:
        d2 = kms.decrypt(CiphertextBlob=dk["CiphertextBlob"])
        p.behavior("봉투 암호화: 암호화된 데이터 키를 Decrypt하면 평문 데이터 키와 같음",
                   len(dk["Plaintext"]) == 32 and d2["Plaintext"] == dk["Plaintext"])
    p.call("GenerateDataKeyWithoutPlaintext", kms.generate_data_key_without_plaintext, KeyId=kid, KeySpec="AES_256")

    if p.call("EnableKeyRotation", kms.enable_key_rotation, KeyId=kid) is not None:
        st = p.call("GetKeyRotationStatus", kms.get_key_rotation_status, KeyId=kid)
        if st:
            p.behavior("자동 교체 활성화 조회", st.get("KeyRotationEnabled") is True,
                       f"RotationPeriodInDays={st.get('RotationPeriodInDays')}")
    p.call("RotateKeyOnDemand", kms.rotate_key_on_demand, KeyId=kid)
    p.call("TagResource", kms.tag_resource, KeyId=kid, Tags=[{"TagKey": "env", "TagValue": "probe"}])
    p.call("ListResourceTags", kms.list_resource_tags, KeyId=kid)

    # 키 정책 집행: 기본 주체(user/emulator)에 대해 Decrypt Deny
    pol = {"Version": "2012-10-17", "Statement": [
        {"Sid": "root", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::000000000000:root"}, "Action": "kms:*", "Resource": "*"},
        {"Sid": "deny-decrypt", "Effect": "Deny", "Principal": {"AWS": "*"}, "Action": "kms:Decrypt", "Resource": "*"}]}
    if enc and p.call("PutKeyPolicy(Decrypt Deny)", kms.put_key_policy, KeyId=kid, PolicyName="default",
                      Policy=json.dumps(pol)) is not None:
        try:
            kms.decrypt(CiphertextBlob=enc["CiphertextBlob"], EncryptionContext={"order": "1"})
            p.behavior("키 정책의 명시적 Deny가 Decrypt를 막음", False, "허용됨 — 키 정책을 평가하지 않는다")
        except ClientError as e:
            p.behavior("키 정책의 명시적 Deny가 Decrypt를 막음", "AccessDenied" in e.response["Error"]["Code"],
                       e.response["Error"]["Code"])
        pol["Statement"] = pol["Statement"][:1]
        kms.put_key_policy(KeyId=kid, PolicyName="default", Policy=json.dumps(pol))

    # 비대칭 서명
    ak = p.call("CreateKey(비대칭 RSA_2048 SIGN_VERIFY)", kms.create_key, KeySpec="RSA_2048", KeyUsage="SIGN_VERIFY")
    if ak:
        akid = ak["KeyMetadata"]["KeyId"]
        sig = p.call("Sign", kms.sign, KeyId=akid, Message=b"order-1", SigningAlgorithm="RSASSA_PSS_SHA_256")
        if sig:
            v = p.call("Verify", kms.verify, KeyId=akid, Message=b"order-1", Signature=sig["Signature"],
                       SigningAlgorithm="RSASSA_PSS_SHA_256")
            if v:
                p.behavior("Sign → Verify 성공", v.get("SignatureValid") is True)
            p.expect_error("Verify(변조된 메시지)", kms.verify, "KMSInvalidSignatureException", KeyId=akid,
                           Message=b"order-2", Signature=sig["Signature"], SigningAlgorithm="RSASSA_PSS_SHA_256",
                           what="변조된 메시지의 서명 검증 실패")
        p.call("GetPublicKey", kms.get_public_key, KeyId=akid)
        p.cleanup("ak", lambda: kms.schedule_key_deletion(KeyId=akid, PendingWindowInDays=7))

    mrk = p.call("CreateKey(MultiRegion=True)", kms.create_key, MultiRegion=True, Description="mrk")
    if mrk:
        mid = mrk["KeyMetadata"]["KeyId"]
        p.behavior("다중 리전 키 ID는 mrk- 접두사", mid.startswith("mrk-"), mid[:8])
        p.call("ReplicateKey(us-west-2)", kms.replicate_key, KeyId=mid, ReplicaRegion="us-west-2")
        p.cleanup("mrk", lambda: kms.schedule_key_deletion(KeyId=mid, PendingWindowInDays=7))

    sd = p.call("ScheduleKeyDeletion(7일)", kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)
    if sd:
        st = kms.describe_key(KeyId=kid)["KeyMetadata"]["KeyState"]
        p.behavior("삭제 예약 후 KeyState=PendingDeletion", st == "PendingDeletion", st)
        p.expect_error("Encrypt(삭제 대기 키)", kms.encrypt, "KMSInvalidStateException", KeyId=kid, Plaintext=b"x",
                       what="삭제 대기 중인 키로 Encrypt하면 KMSInvalidStateException")
        p.call("CancelKeyDeletion", kms.cancel_key_deletion, KeyId=kid)
    p.cleanup("key", lambda: kms.schedule_key_deletion(KeyId=kid, PendingWindowInDays=7))
    p.expect_error("ScheduleKeyDeletion(3일)", kms.schedule_key_deletion, "ValidationException", KeyId=kid,
                   PendingWindowInDays=3, what="삭제 대기 기간 7일 미만은 거부")


def run_secretsmanager(p: Probe) -> None:
    sm = p.client("secretsmanager")
    name = p.name("db") + "/password"
    c = p.call("CreateSecret", sm.create_secret, Name=name, SecretString=json.dumps({"username": "app", "password": "v1"}))
    if not c:
        p.skip("Secrets Manager", "생성 실패")
        return
    p.cleanup("secret", lambda: sm.delete_secret(SecretId=name, ForceDeleteWithoutRecovery=True))
    p.behavior("ARN 끝에 무작위 6자 접미사", c["ARN"].rsplit("-", 1)[-1].isalnum() and len(c["ARN"].rsplit("-", 1)[-1]) == 6,
               c["ARN"].rsplit(":", 1)[-1])
    g = p.call("GetSecretValue", sm.get_secret_value, SecretId=name)
    v1 = g["VersionId"] if g else None
    put = p.call("PutSecretValue", sm.put_secret_value, SecretId=name, SecretString=json.dumps({"username": "app", "password": "v2"}))
    if put and v1:
        d = sm.describe_secret(SecretId=name)["VersionIdsToStages"]
        p.behavior("새 값 저장 시 AWSCURRENT → 새 버전, AWSPREVIOUS → 이전 버전",
                   "AWSCURRENT" in d.get(put["VersionId"], []) and "AWSPREVIOUS" in d.get(v1, []), str(d))
        prev = sm.get_secret_value(SecretId=name, VersionStage="AWSPREVIOUS")
        p.behavior("VersionStage=AWSPREVIOUS로 이전 값 조회", '"v1"' in prev["SecretString"])
        p.call("UpdateSecretVersionStage(롤백)", sm.update_secret_version_stage, SecretId=name, VersionStage="AWSCURRENT",
               MoveToVersionId=v1, RemoveFromVersionId=put["VersionId"])
        cur = sm.get_secret_value(SecretId=name)["SecretString"]
        p.behavior("스테이지 이동으로 AWSCURRENT 롤백", '"v1"' in cur, cur)
    p.call("RotateSecret(Lambda ARN 지정)", sm.rotate_secret, SecretId=name,
           RotationLambdaARN="arn:aws:lambda:us-east-1:000000000000:function:todayorder-rotate",
           RotationRules={"AutomaticallyAfterDays": 30})
    p.call("GetRandomPassword", sm.get_random_password, PasswordLength=32)
    p.call("ReplicateSecretToRegions(us-west-2)", sm.replicate_secret_to_regions, SecretId=name,
           AddReplicaRegions=[{"Region": "us-west-2"}])
    name2 = p.name("tmp")
    if p.call("CreateSecret(삭제 테스트)", sm.create_secret, Name=name2, SecretString="x") is not None:
        p.cleanup("s2", lambda: sm.delete_secret(SecretId=name2, ForceDeleteWithoutRecovery=True))
        d = p.call("DeleteSecret(복구 기간 7일)", sm.delete_secret, SecretId=name2, RecoveryWindowInDays=7)
        if d:
            p.expect_error("GetSecretValue(삭제 예약된 비밀)", sm.get_secret_value, "InvalidRequestException",
                           SecretId=name2, what="삭제 예약된 비밀은 조회 불가(InvalidRequestException)")
            p.call("RestoreSecret", sm.restore_secret, SecretId=name2)
            ok = wait_until(lambda: sm.get_secret_value(SecretId=name2)["SecretString"] == "x", 5)
            p.behavior("RestoreSecret 후 다시 조회 가능", ok)


def run_ssm(p: Probe) -> None:
    ssm, kms = p.client("ssm"), p.client("kms")
    base = f"/todayorder/{p.suffix}"
    p.call("PutParameter(String)", ssm.put_parameter, Name=f"{base}/api/timeout", Value="30", Type="String")
    p.call("PutParameter(StringList)", ssm.put_parameter, Name=f"{base}/api/hosts", Value="a,b", Type="StringList")
    key = kms.create_key(Description="ssm")["KeyMetadata"]["KeyId"]
    p.cleanup("key", lambda: kms.schedule_key_deletion(KeyId=key, PendingWindowInDays=7))
    p.call("PutParameter(SecureString, 고객 관리형 키)", ssm.put_parameter, Name=f"{base}/db/password", Value="s3cr3t",
           Type="SecureString", KeyId=key)
    p.call("PutParameter(SecureString, 기본 aws/ssm 키)", ssm.put_parameter, Name=f"{base}/db/token", Value="tok",
           Type="SecureString")
    p.cleanup("params", lambda: ssm.delete_parameters(Names=[f"{base}/api/timeout", f"{base}/api/hosts",
                                                            f"{base}/db/password", f"{base}/db/token", f"{base}/adv"]))
    raw = p.call("GetParameter(SecureString, 복호화 없이)", ssm.get_parameter, Name=f"{base}/db/password")
    if raw:
        v = raw["Parameter"]["Value"]
        p.behavior("WithDecryption 없이 조회하면 암호문이 반환됨", v != "s3cr3t", v[:40])
    dec = p.call("GetParameter(WithDecryption)", ssm.get_parameter, Name=f"{base}/db/password", WithDecryption=True)
    if dec:
        p.behavior("WithDecryption=True면 평문", dec["Parameter"]["Value"] == "s3cr3t")
    gp = p.call("GetParametersByPath(Recursive)", ssm.get_parameters_by_path, Path=base, Recursive=True, WithDecryption=True)
    if gp:
        names = sorted(x["Name"].removeprefix(base) for x in gp["Parameters"])
        p.behavior("계층 경로 재귀 조회로 4개 모두", len(names) == 4, str(names))
    gp2 = ssm.get_parameters_by_path(Path=base, Recursive=False)
    p.behavior("Recursive=False면 바로 아래 단계만(0개)", len(gp2["Parameters"]) == 0, f"{len(gp2['Parameters'])}개")
    ssm.put_parameter(Name=f"{base}/api/timeout", Value="60", Type="String", Overwrite=True)
    h = p.call("GetParameterHistory", ssm.get_parameter_history, Name=f"{base}/api/timeout")
    if h:
        p.behavior("덮어쓰면 버전 2가 됨", [x["Version"] for x in h["Parameters"]] == [1, 2])
    p.call("LabelParameterVersion", ssm.label_parameter_version, Name=f"{base}/api/timeout", ParameterVersion=1, Labels=["stable"])
    lab = p.call("GetParameter(:label)", ssm.get_parameter, Name=f"{base}/api/timeout:stable")
    if lab:
        p.behavior("레이블로 이전 버전 조회", lab["Parameter"]["Value"] == "30", lab["Parameter"]["Value"])
    p.call("PutParameter(Advanced 계층)", ssm.put_parameter, Name=f"{base}/adv", Value="x" * 5000, Type="String", Tier="Advanced")
    p.expect_error("PutParameter(Standard 5KB 초과)", ssm.put_parameter, "ValidationException", Name=f"{base}/big",
                   Value="x" * 5000, Type="String", Tier="Standard", what="Standard 계층 4KB 초과 값은 거부")
    pub = p.call("GetParametersByPath(공개 파라미터 /aws/service/global-infrastructure/regions)", ssm.get_parameters_by_path,
                 Path="/aws/service/global-infrastructure/regions")
    if pub is not None:
        p.behavior("공개 파라미터(리전 목록)가 들어 있음", len(pub["Parameters"]) > 0, f"{len(pub['Parameters'])}개")
    ami = p.call("GetParameter(공개 AL2023 AMI)", ssm.get_parameter,
                 Name="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64")
    if ami:
        p.behavior("최신 AL2023 AMI ID 공개 파라미터", ami["Parameter"]["Value"].startswith("ami-"), ami["Parameter"]["Value"])
    p.call("SendCommand(AWS-RunShellScript)", ssm.send_command, DocumentName="AWS-RunShellScript",
           Targets=[{"Key": "tag:app", "Values": ["todayorder"]}], Parameters={"commands": ["uptime"]})
    p.call("StartSession", ssm.start_session, Target="i-0123456789abcdef0")
    p.call("DescribeInstanceInformation", ssm.describe_instance_information)


def _self_signed() -> tuple[bytes, bytes] | None:
    if not shutil.which("openssl"):
        return None
    with tempfile.TemporaryDirectory() as d:
        k, c = Path(d, "k.pem"), Path(d, "c.pem")
        r = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(k), "-out", str(c),
                            "-days", "30", "-subj", "/CN=import.todayorder.example"], capture_output=True, timeout=30)
        if r.returncode != 0:
            return None
        return c.read_bytes(), k.read_bytes()


def run_acm(p: Probe) -> None:
    acm = p.client("acm")
    dom = f"api.{p.suffix}.todayorder.example"
    r = p.call("RequestCertificate(DNS 검증)", acm.request_certificate, DomainName=dom, ValidationMethod="DNS",
               SubjectAlternativeNames=[f"www.{p.suffix}.todayorder.example"])
    if r:
        arn = r["CertificateArn"]
        p.cleanup("cert", lambda: acm.delete_certificate(CertificateArn=arn))
        wait_until(lambda: acm.describe_certificate(CertificateArn=arn)["Certificate"].get("DomainValidationOptions", [{}])[0]
                   .get("ResourceRecord") is not None, 5)
        d = p.call("DescribeCertificate", acm.describe_certificate, CertificateArn=arn)
        if d:
            c = d["Certificate"]
            dvo = c.get("DomainValidationOptions", [])
            p.behavior("DNS 검증용 CNAME 레코드(ResourceRecord) 제공", bool(dvo and dvo[0].get("ResourceRecord")),
                       f"Status={c.get('Status')} RR={dvo[0].get('ResourceRecord') if dvo else None}"[:200])
            ok = wait_until(lambda: acm.describe_certificate(CertificateArn=arn)["Certificate"]["Status"] == "ISSUED", 10)
            cc = acm.describe_certificate(CertificateArn=arn)["Certificate"]
            p.behavior("검증 레코드가 없으면 ISSUED가 되지 않음", not ok,
                       f"{cc['Status']} {cc.get('FailureReason') or ''} — .example 등 예약 도메인은 수 초 만에 FAILED(ADDITIONAL_VERIFICATION_REQUIRED)")
    # Route 53 에 검증 CNAME 을 만들면 ISSUED 가 되는가
    r53 = p.client("route53")
    # 에뮬레이터 ACM 은 예약 TLD(.invalid·.test·.example)를 즉시 FAILED(ADDITIONAL_VERIFICATION_REQUIRED)로 만든다(직접 확인).
    # 그래서 이 행만 .com 을 쓴다. 영역은 에뮬레이터의 Route 53 안에만 있고, 리뷰 DNS 기록에 이 이름의 질의는 없었다.
    # external-host-ok: ACM 이 예약 TLD 를 거부해 .com 이 필요(DNS 질의 없음 확인)
    zone_name = f"todayorder-{p.suffix}.com"
    hz = r53.create_hosted_zone(Name=zone_name, CallerReference=p.name("acmhz"))["HostedZone"]["Id"]
    r2 = p.call("RequestCertificate(Route 53 영역 도메인)", acm.request_certificate, DomainName=f"api.{zone_name}",
                ValidationMethod="DNS")
    if r2:
        arn2 = r2["CertificateArn"]
        p.cleanup("cert2", lambda: acm.delete_certificate(CertificateArn=arn2))
        got = wait_until(lambda: acm.describe_certificate(CertificateArn=arn2)["Certificate"]["DomainValidationOptions"][0]
                         .get("ResourceRecord") is not None, 5)
        if got:
            rr = acm.describe_certificate(CertificateArn=arn2)["Certificate"]["DomainValidationOptions"][0]["ResourceRecord"]
            r53.change_resource_record_sets(HostedZoneId=hz, ChangeBatch={"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
                "Name": rr["Name"], "Type": "CNAME", "TTL": 60, "ResourceRecords": [{"Value": rr["Value"]}]}}]})
            ok = wait_until(lambda: acm.describe_certificate(CertificateArn=arn2)["Certificate"]["Status"] == "ISSUED", 20)
            p.behavior("Route 53에 검증 CNAME을 만들면 ISSUED로 전환(20초 대기)", ok,
                       acm.describe_certificate(CertificateArn=arn2)["Certificate"]["Status"])

    def _del_hz() -> None:
        recs = r53.list_resource_record_sets(HostedZoneId=hz)["ResourceRecordSets"]
        ch = [{"Action": "DELETE", "ResourceRecordSet": x} for x in recs if x["Type"] not in ("NS", "SOA")]
        if ch:
            r53.change_resource_record_sets(HostedZoneId=hz, ChangeBatch={"Changes": ch})
        r53.delete_hosted_zone(Id=hz)

    p.cleanup("hz", _del_hz)
    pair = _self_signed()
    if pair:
        imp = p.call("ImportCertificate(자체 서명)", acm.import_certificate, Certificate=pair[0], PrivateKey=pair[1])
        if imp:
            ia = imp["CertificateArn"]
            p.cleanup("imp", lambda: acm.delete_certificate(CertificateArn=ia))
            t = acm.describe_certificate(CertificateArn=ia)["Certificate"]
            p.behavior("가져온 인증서 Type=IMPORTED", t.get("Type") == "IMPORTED", f"Type={t.get('Type')} Status={t.get('Status')}")
    else:
        p.skip("ImportCertificate", "openssl 없음")
    p.call("ListCertificates", acm.list_certificates)


def run_cloudtrail(p: Probe) -> None:
    ct, s3 = p.client("cloudtrail"), p.client("s3")
    bucket = p.name("trail")
    s3.create_bucket(Bucket=bucket)
    p.cleanup("bucket", lambda: (
        [s3.delete_object(Bucket=bucket, Key=o["Key"]) for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])],
        s3.delete_bucket(Bucket=bucket)))
    s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"}, "Action": "s3:GetBucketAcl",
         "Resource": f"arn:aws:s3:::{bucket}"},
        {"Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"}, "Action": "s3:PutObject",
         "Resource": f"arn:aws:s3:::{bucket}/AWSLogs/000000000000/*"}]}))
    name = p.name("trail")
    t = p.call("CreateTrail(멀티 리전)", ct.create_trail, Name=name, S3BucketName=bucket, IsMultiRegionTrail=True,
               EnableLogFileValidation=True)
    if t:
        p.cleanup("trail", lambda: ct.delete_trail(Name=name))
        p.call("StartLogging", ct.start_logging, Name=name)
        st = p.call("GetTrailStatus", ct.get_trail_status, Name=name)
        if st:
            p.behavior("GetTrailStatus IsLogging=True", st.get("IsLogging") is True)
        p.call("PutEventSelectors(S3 데이터 이벤트)", ct.put_event_selectors, TrailName=name, EventSelectors=[{
            "ReadWriteType": "All", "IncludeManagementEvents": True,
            "DataResources": [{"Type": "AWS::S3::Object", "Values": [f"arn:aws:s3:::{bucket}/"]}]}])
    # 관리 이벤트 기록 여부: 방금 호출한 API 가 LookupEvents 로 보이는가 (서비스별로 다를 수 있다)
    def _seen(event_name: str, marker: str) -> bool:
        evs = ct.lookup_events(LookupAttributes=[{"AttributeKey": "EventName", "AttributeValue": event_name}],
                               MaxResults=50)["Events"]
        return any(marker in (e.get("CloudTrailEvent") or "") or
                   any(r.get("ResourceName") == marker for r in e.get("Resources", [])) for e in evs)

    iam = p.client("iam")
    u = p.name("ctuser")
    iam.create_user(UserName=u)
    p.cleanup("u", lambda: iam.delete_user(UserName=u))
    p.behavior("IAM CreateUser가 LookupEvents(이벤트 기록)에 나타남", wait_until(lambda: _seen("CreateUser", u), 10))
    marker = p.name("evt")
    s3.create_bucket(Bucket=marker)
    p.cleanup("marker", lambda: s3.delete_bucket(Bucket=marker))
    p.behavior("S3 CreateBucket이 LookupEvents(이벤트 기록)에 나타남", wait_until(lambda: _seen("CreateBucket", marker), 10))
    p.call("LookupEvents", ct.lookup_events, MaxResults=5)
    if t:
        has_logs = wait_until(lambda: s3.list_objects_v2(Bucket=bucket).get("KeyCount", 0) > 0, 10)
        p.behavior("추적이 S3 버킷에 로그 파일을 씀(10초 대기)", has_logs,
                   f"객체 {s3.list_objects_v2(Bucket=bucket).get('KeyCount', 0)}개 — 실제 AWS는 약 5분 간격")


def run_config(p: Probe) -> None:
    cfg, s3, iam = p.client("config"), p.client("s3"), p.client("iam")
    bucket = p.name("config")
    s3.create_bucket(Bucket=bucket)
    p.cleanup("bucket", lambda: (
        [s3.delete_object(Bucket=bucket, Key=o["Key"]) for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])],
        s3.delete_bucket(Bucket=bucket)))
    s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": ["s3:GetBucketAcl", "s3:ListBucket"],
         "Resource": f"arn:aws:s3:::{bucket}"},
        {"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": "s3:PutObject",
         "Resource": f"arn:aws:s3:::{bucket}/AWSLogs/000000000000/Config/*"}]}))
    role = iam.create_role(RoleName=p.name("cfgrole"), AssumeRolePolicyDocument=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"},
                                                 "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("role", lambda: iam.delete_role(RoleName=role["RoleName"]))
    nb_early = p.name("nopolicy")
    s3.create_bucket(Bucket=nb_early)
    p.cleanup("nbe", lambda: s3.delete_bucket(Bucket=nb_early))
    p.call("PutConfigurationRecorder", cfg.put_configuration_recorder, ConfigurationRecorder={
        "name": "default", "roleARN": role["Arn"], "recordingGroup": {"allSupported": True, "includeGlobalResourceTypes": True}})
    p.expect_error("PutDeliveryChannel(버킷 정책 없는 버킷)", cfg.put_delivery_channel, "InsufficientDeliveryPolicyException",
                   DeliveryChannel={"name": "default", "s3BucketName": nb_early},
                   what="Config 전달 채널: 버킷 정책이 없으면 거부(버킷 정책을 평가함)")
    p.call("PutDeliveryChannel", cfg.put_delivery_channel, DeliveryChannel={"name": "default", "s3BucketName": bucket})
    p.call("StartConfigurationRecorder", cfg.start_configuration_recorder, ConfigurationRecorderName="default")
    st = p.call("DescribeConfigurationRecorderStatus", cfg.describe_configuration_recorder_status)
    if st and st.get("ConfigurationRecordersStatus"):
        p.behavior("기록기 recording=True", st["ConfigurationRecordersStatus"][0].get("recording") is True)

    def _stop() -> None:
        cfg.stop_configuration_recorder(ConfigurationRecorderName="default")
        cfg.delete_delivery_channel(DeliveryChannelName="default")
        cfg.delete_configuration_recorder(ConfigurationRecorderName="default")

    p.cleanup("recorder", _stop)
    nb = p.name("unversioned")
    s3.create_bucket(Bucket=nb)
    p.cleanup("nb", lambda: s3.delete_bucket(Bucket=nb))
    rule = p.name("s3ver")
    r = p.call("PutConfigRule(관리형 S3_BUCKET_VERSIONING_ENABLED)", cfg.put_config_rule, ConfigRule={
        "ConfigRuleName": rule, "Source": {"Owner": "AWS", "SourceIdentifier": "S3_BUCKET_VERSIONING_ENABLED"},
        "Scope": {"ComplianceResourceTypes": ["AWS::S3::Bucket"]}})
    if r is not None:
        p.cleanup("rule", lambda: cfg.delete_config_rule(ConfigRuleName=rule))
        p.call("StartConfigRulesEvaluation", cfg.start_config_rules_evaluation, ConfigRuleNames=[rule])
        ok = wait_until(lambda: bool(cfg.describe_compliance_by_config_rule(ConfigRuleNames=[rule])["ComplianceByConfigRules"]
                                     [0].get("Compliance", {}).get("ComplianceType") not in (None, "INSUFFICIENT_DATA")), 15)
        c = cfg.describe_compliance_by_config_rule(ConfigRuleNames=[rule])["ComplianceByConfigRules"]
        p.behavior("규칙이 실제로 평가됨(버전 관리 꺼진 버킷 → NON_COMPLIANT)", ok,
                   f"{c[0].get('Compliance') if c else None}")
    p.call("ListDiscoveredResources(S3 버킷)", cfg.list_discovered_resources, resourceType="AWS::S3::Bucket")
    p.call("PutConformancePack", cfg.put_conformance_pack, ConformancePackName=p.name("pack")[:50],
           TemplateBody="Resources:\n  R:\n    Type: AWS::Config::ConfigRule\n    Properties:\n      ConfigRuleName: x\n"
                        "      Source:\n        Owner: AWS\n        SourceIdentifier: S3_BUCKET_VERSIONING_ENABLED\n")


def run_guardduty(p: Probe) -> None:
    gd = p.client("guardduty")
    existing = gd.list_detectors().get("DetectorIds", [])
    det = p.call("CreateDetector", gd.create_detector, Enable=True, FindingPublishingFrequency="FIFTEEN_MINUTES")
    did = det["DetectorId"] if det else (existing[0] if existing else None)
    if not did:
        p.skip("GuardDuty", "탐지기 없음")
        return
    if det:
        p.cleanup("det", lambda: gd.delete_detector(DetectorId=did))
    g = p.call("GetDetector", gd.get_detector, DetectorId=did)
    if g:
        p.behavior("탐지기 Status=ENABLED", g.get("Status") == "ENABLED", g.get("Status", ""))
    if p.call("CreateSampleFindings", gd.create_sample_findings, DetectorId=did,
              FindingTypes=["Recon:EC2/PortProbeUnprotectedPort"]) is not None:
        ok = wait_until(lambda: len(gd.list_findings(DetectorId=did)["FindingIds"]) > 0, 10)
        n = len(gd.list_findings(DetectorId=did)["FindingIds"])
        p.behavior("샘플 결과(finding)가 ListFindings에 나타남", ok, f"{n}건")
    p.call("ListFindings", gd.list_findings, DetectorId=did)
    for svc, label, fn in (
        ("inspector2", "inspector2 Enable(EC2)", lambda c: c.enable(resourceTypes=["EC2"])),
        ("macie2", "macie2 EnableMacie", lambda c: c.enable_macie()),
        ("securityhub", "securityhub EnableSecurityHub", lambda c: c.enable_security_hub(EnableDefaultStandards=False)),
        ("detective", "detective CreateGraph", lambda c: c.create_graph()),
    ):
        p.call(label, fn, boto3.client(svc, config=_CFG))


CHECKS = {
    "kms": run_kms,
    "secretsmanager": run_secretsmanager,
    "ssm": run_ssm,
    "acm": run_acm,
    "cloudtrail": run_cloudtrail,
    "config": run_config,
    "guardduty": run_guardduty,
}
