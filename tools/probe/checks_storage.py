"""M04: S3 / EFS 탐침."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from typing import Any

from botocore.exceptions import ClientError

from lib import Probe, wait_until


def _empty_bucket(s3: Any, bucket: str) -> None:
    try:
        vs = s3.list_object_versions(Bucket=bucket)
        objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in vs.get("Versions", []) + vs.get("DeleteMarkers", [])]
    except Exception:  # noqa: BLE001
        objs = []
    try:
        objs += [{"Key": o["Key"]} for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])]
    except Exception:  # noqa: BLE001
        pass
    for o in objs:
        try:
            s3.delete_object(Bucket=bucket, **o, BypassGovernanceRetention=True) if "VersionId" in o else s3.delete_object(Bucket=bucket, Key=o["Key"])
        except Exception:  # noqa: BLE001
            pass
    s3.delete_bucket(Bucket=bucket)


def _bucket(p: Probe, base: str, **kw: Any) -> str | None:
    s3 = p.client("s3")
    b = p.name(base)
    if p.call(f"CreateBucket({base})", s3.create_bucket, Bucket=b, **kw) is None:
        return None
    p.cleanup(f"bucket-{base}", lambda: _empty_bucket(s3, b))
    return b


def _curl(args: list[str]) -> tuple[int, str]:
    ca = os.environ["AWS_CA_BUNDLE"]
    r = subprocess.run(["curl", "-s", "-o", "-", "-w", "\n%{http_code}", "--cacert", ca, *args],
                       capture_output=True, text=True, timeout=20)
    body, _, code = r.stdout.rpartition("\n")
    return int(code or 0), body


def run_s3(p: Probe) -> None:
    s3 = p.client("s3")
    b = _bucket(p, "main")
    if not b:
        return
    try:
        s3.create_bucket(Bucket=b)
        p.behavior("us-east-1에서 내 버킷과 같은 이름으로 재생성 → 200(AWS도 us-east-1만 예외적으로 성공)", True, "성공")
    except ClientError as e:
        p.behavior("us-east-1에서 내 버킷과 같은 이름으로 재생성 → 200(AWS도 us-east-1만 예외적으로 성공)", False,
                   e.response["Error"]["Code"])
    p.expect_error("CreateBucket(대문자 이름)", s3.create_bucket, "InvalidBucketName", Bucket="TodayOrder-Upper",
                   what="대문자 버킷 이름 → InvalidBucketName")
    p.call("PutObject", s3.put_object, Bucket=b, Key="receipts/1.txt", Body=b"hello", ContentType="text/plain",
           Metadata={"order-id": "1"})
    g = p.call("GetObject", s3.get_object, Bucket=b, Key="receipts/1.txt")
    if g:
        p.behavior("GetObject 본문·메타데이터 왕복", g["Body"].read() == b"hello" and g["Metadata"].get("order-id") == "1",
                   f"ETag={g['ETag']}")
    p.call("HeadObject", s3.head_object, Bucket=b, Key="receipts/1.txt")
    lst = p.call("ListObjectsV2(Prefix, Delimiter)", s3.list_objects_v2, Bucket=b, Prefix="receipts/", Delimiter="/")
    if lst:
        p.behavior("ListObjectsV2 prefix 조회", lst.get("KeyCount") == 1, f"KeyCount={lst.get('KeyCount')}")
    p.call("CopyObject", s3.copy_object, Bucket=b, Key="receipts/1-copy.txt", CopySource={"Bucket": b, "Key": "receipts/1.txt"})
    p.call("DeleteObject", s3.delete_object, Bucket=b, Key="receipts/1-copy.txt")
    p.expect_error("GetObject(없는 키)", s3.get_object, "NoSuchKey", Bucket=b, Key="nope",
                   what="없는 키 → NoSuchKey")
    p.call("PutObjectTagging", s3.put_object_tagging, Bucket=b, Key="receipts/1.txt",
           Tagging={"TagSet": [{"Key": "class", "Value": "receipt"}]})
    p.call("PutBucketTagging", s3.put_bucket_tagging, Bucket=b, Tagging={"TagSet": [{"Key": "team", "Value": "order"}]})

    # 버전 관리 + 삭제 마커
    p.call("PutBucketVersioning(Enabled)", s3.put_bucket_versioning, Bucket=b, VersioningConfiguration={"Status": "Enabled"})
    v1 = s3.put_object(Bucket=b, Key="v.txt", Body=b"one").get("VersionId")
    v2 = s3.put_object(Bucket=b, Key="v.txt", Body=b"two").get("VersionId")
    p.behavior("버전 관리 켠 뒤 PutObject마다 VersionId 발급", bool(v1) and bool(v2) and v1 != v2, f"{v1} / {v2}")
    d = p.call("DeleteObject(버전 관리 버킷)", s3.delete_object, Bucket=b, Key="v.txt")
    if d:
        p.behavior("삭제하면 삭제 마커(DeleteMarker=true)가 생김", d.get("DeleteMarker") is True, f"VersionId={d.get('VersionId')}")
    p.expect_error("GetObject(삭제 마커 뒤)", s3.get_object, "NoSuchKey", Bucket=b, Key="v.txt",
                   what="삭제 마커가 최신이면 GetObject → NoSuchKey")
    lv = p.call("ListObjectVersions", s3.list_object_versions, Bucket=b, Prefix="v.txt")
    if lv:
        p.behavior("ListObjectVersions: 버전 2개 + 삭제 마커 1개",
                   len(lv.get("Versions", [])) == 2 and len(lv.get("DeleteMarkers", [])) == 1,
                   f"Versions={len(lv.get('Versions', []))} DeleteMarkers={len(lv.get('DeleteMarkers', []))}")
    if v1:
        g1 = p.call("GetObject(VersionId=첫 버전)", s3.get_object, Bucket=b, Key="v.txt", VersionId=v1)
        if g1:
            p.behavior("이전 버전 내용 복구 가능", g1["Body"].read() == b"one", "")
    if d and d.get("VersionId"):
        s3.delete_object(Bucket=b, Key="v.txt", VersionId=d["VersionId"])
        try:
            p.behavior("삭제 마커를 지우면 객체가 되살아남", s3.get_object(Bucket=b, Key="v.txt")["Body"].read() == b"two", "")
        except ClientError as e:
            p.behavior("삭제 마커를 지우면 객체가 되살아남", False, e.response["Error"]["Code"])

    # 수명 주기
    lc = {"Rules": [{"ID": "receipts-tiering", "Status": "Enabled", "Filter": {"Prefix": "receipts/"},
                     "Transitions": [{"Days": 30, "StorageClass": "STANDARD_IA"}, {"Days": 90, "StorageClass": "GLACIER"}],
                     "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
                     "Expiration": {"Days": 365}}]}
    p.call("PutBucketLifecycleConfiguration", s3.put_bucket_lifecycle_configuration, Bucket=b, LifecycleConfiguration=lc)
    glc = p.call("GetBucketLifecycleConfiguration", s3.get_bucket_lifecycle_configuration, Bucket=b)
    if glc:
        p.behavior("수명 주기 규칙 왕복(전환은 시간이 지나도 실제로 일어나지 않음 — 확인 불가)",
                   glc["Rules"][0].get("Transitions", [{}])[0].get("StorageClass") == "STANDARD_IA", "")
    # 2026-07-16 AWS 발표("Amazon S3 removes 30-day minimum for transitions to S3 Standard-IA and S3 One Zone-IA"):
    # STANDARD_IA·ONEZONE_IA 로의 전환에 "STANDARD 에서 30일" 제한이 없어졌다(30일 최소 보관 요금은 그대로).
    def _lc(rules: list[dict]) -> dict:
        return {"Rules": rules}

    def _rule(rid: str, transitions: list[dict], **extra: object) -> dict:
        return {"ID": rid, "Status": "Enabled", "Filter": {"Prefix": "lc/"}, "Transitions": transitions, **extra}

    for days, cls in ((10, "STANDARD_IA"), (7, "ONEZONE_IA"), (0, "STANDARD_IA")):
        try:
            s3.put_bucket_lifecycle_configuration(Bucket=b, LifecycleConfiguration=_lc([_rule("ia", [{"Days": days, "StorageClass": cls}])]))
            p.behavior(f"{cls} {days}일 전환 규칙 수락 (2026-07 이후 AWS와 같음)", True)
        except ClientError as e:
            p.behavior(f"{cls} {days}일 전환 규칙 수락 (2026-07 이후 AWS와 같음)", False, e.response["Error"]["Code"])
    p.expect_error("PutBucketLifecycleConfiguration(GLACIER_IR 4일 → DEEP_ARCHIVE 20일)", s3.put_bucket_lifecycle_configuration,
                   "InvalidArgument", Bucket=b,
                   LifecycleConfiguration=_lc([_rule("chain", [{"Days": 4, "StorageClass": "GLACIER_IR"},
                                                              {"Days": 20, "StorageClass": "DEEP_ARCHIVE"}])]),
                   what="최소 보관 기간(Glacier IR 90일)보다 빠른 연쇄 전환 → InvalidArgument")
    p.expect_error("PutBucketLifecycleConfiguration(GLACIER 30일 → STANDARD_IA 60일)", s3.put_bucket_lifecycle_configuration,
                   "InvalidArgument", Bucket=b,
                   LifecycleConfiguration=_lc([_rule("reverse", [{"Days": 30, "StorageClass": "GLACIER"},
                                                                {"Days": 60, "StorageClass": "STANDARD_IA"}])]),
                   what="거꾸로 된 전환(GLACIER → STANDARD_IA) → InvalidArgument")
    p.expect_error("PutBucketLifecycleConfiguration(규칙 ID 중복)", s3.put_bucket_lifecycle_configuration, "InvalidArgument",
                   Bucket=b, LifecycleConfiguration=_lc([_rule("dup", [{"Days": 30, "StorageClass": "STANDARD_IA"}]),
                                                          _rule("dup", [{"Days": 60, "StorageClass": "GLACIER"}])]),
                   what="같은 규칙 ID 두 개 → InvalidArgument")
    p.expect_error("PutBucketLifecycleConfiguration(만료 0일)", s3.put_bucket_lifecycle_configuration, "InvalidArgument",
                   Bucket=b, LifecycleConfiguration=_lc([{"ID": "exp0", "Status": "Enabled", "Filter": {"Prefix": "lc/"},
                                                           "Expiration": {"Days": 0}}]),
                   what="만료 0일 → InvalidArgument")

    # 미리 서명된 URL
    s3.put_object(Bucket=b, Key="presigned.txt", Body=b"presigned-ok")
    url = s3.generate_presigned_url("get_object", Params={"Bucket": b, "Key": "presigned.txt"}, ExpiresIn=60)
    code, body = _curl([url])
    p.behavior("미리 서명된 GET URL을 curl로 다운로드", code == 200 and body == "presigned-ok", f"HTTP {code}")
    code, body = _curl([url.replace("Signature=", "Signature=0")])
    p.behavior("서명을 바꾼 URL은 거부", code == 403, f"HTTP {code} {body[:80]}")
    url_exp = s3.generate_presigned_url("get_object", Params={"Bucket": b, "Key": "presigned.txt"}, ExpiresIn=1)
    import time as _t
    _t.sleep(2)
    code, body = _curl([url_exp])
    p.behavior("만료된 미리 서명 URL은 거부", code == 403, f"HTTP {code} {body[:80]}")
    put_url = s3.generate_presigned_url("put_object", Params={"Bucket": b, "Key": "uploaded.txt"}, ExpiresIn=60)
    code, _ = _curl(["-X", "PUT", "--data-binary", "via-curl", put_url])
    ok = code == 200
    try:
        ok = ok and s3.get_object(Bucket=b, Key="uploaded.txt")["Body"].read() == b"via-curl"
    except ClientError:
        ok = False
    p.behavior("미리 서명된 PUT URL로 curl 업로드", ok, f"HTTP {code}")
    code, _ = _curl([f"{os.environ['AWS_ENDPOINT_URL']}/{b}/presigned.txt"])
    p.behavior("서명 없는 GET(퍼블릭 아님)은 거부", code in (403, 401), f"HTTP {code}")

    # 멀티파트
    mp = p.call("CreateMultipartUpload", s3.create_multipart_upload, Bucket=b, Key="big.bin")
    if mp:
        uid = mp["UploadId"]
        parts = []
        for i, size in ((1, 5 * 1024 * 1024), (2, 1024)):
            r = p.call(f"UploadPart({i})", s3.upload_part, Bucket=b, Key="big.bin", UploadId=uid, PartNumber=i, Body=b"x" * size)
            if r:
                parts.append({"PartNumber": i, "ETag": r["ETag"]})
        p.call("ListParts", s3.list_parts, Bucket=b, Key="big.bin", UploadId=uid)
        c = p.call("CompleteMultipartUpload", s3.complete_multipart_upload, Bucket=b, Key="big.bin", UploadId=uid,
                   MultipartUpload={"Parts": parts})
        if c:
            h = s3.head_object(Bucket=b, Key="big.bin")
            p.behavior("멀티파트 결과 크기·ETag(-2 접미사)", h["ContentLength"] == 5 * 1024 * 1024 + 1024 and h["ETag"].endswith('-2"'),
                       f"{h['ContentLength']} {h['ETag']}")
        mp2 = s3.create_multipart_upload(Bucket=b, Key="small.bin")
        s3.upload_part(Bucket=b, Key="small.bin", UploadId=mp2["UploadId"], PartNumber=1, Body=b"a" * 100)
        r2 = s3.upload_part(Bucket=b, Key="small.bin", UploadId=mp2["UploadId"], PartNumber=2, Body=b"b" * 100)
        r1 = s3.list_parts(Bucket=b, Key="small.bin", UploadId=mp2["UploadId"])["Parts"]
        p.expect_error("CompleteMultipartUpload(5MiB 미만 파트)", s3.complete_multipart_upload, "EntityTooSmall",
                       Bucket=b, Key="small.bin", UploadId=mp2["UploadId"],
                       MultipartUpload={"Parts": [{"PartNumber": x["PartNumber"], "ETag": x["ETag"]} for x in r1] or
                                        [{"PartNumber": 2, "ETag": r2["ETag"]}]},
                       what="마지막이 아닌 파트가 5MiB 미만 → EntityTooSmall")
        p.call("AbortMultipartUpload", s3.abort_multipart_upload, Bucket=b, Key="small.bin", UploadId=mp2["UploadId"])
    p.call("upload_file(boto3 TransferManager, 자동 멀티파트)", _upload_file, s3, b)

    # 버킷 정책 집행 여부
    pol = {"Version": "2012-10-17", "Statement": [{"Sid": "DenyGet", "Effect": "Deny", "Principal": "*",
                                                   "Action": "s3:GetObject", "Resource": f"arn:aws:s3:::{b}/*"}]}
    if p.call("PutBucketPolicy(Deny GetObject *)", s3.put_bucket_policy, Bucket=b, Policy=json.dumps(pol)) is not None:
        gp = p.call("GetBucketPolicy", s3.get_bucket_policy, Bucket=b)
        if gp:
            p.behavior("버킷 정책 왕복", json.loads(gp["Policy"])["Statement"][0]["Sid"] == "DenyGet", "")
        try:
            s3.get_object(Bucket=b, Key="presigned.txt")
            p.behavior("버킷 정책의 명시적 Deny가 GetObject를 막음", False, "허용됨 — 버킷 정책은 평가되지 않는다")
        except ClientError as e:
            p.behavior("버킷 정책의 명시적 Deny가 GetObject를 막음", e.response["Error"]["Code"] == "AccessDenied",
                       e.response["Error"]["Code"])
        s3.delete_bucket_policy(Bucket=b)
    p.expect_error("PutBucketPolicy(잘못된 JSON)", s3.put_bucket_policy, "MalformedPolicy", Bucket=b, Policy="{not json",
                   what="잘못된 정책 JSON → MalformedPolicy")

    # 퍼블릭 액세스 차단
    pab = {"BlockPublicAcls": True, "IgnorePublicAcls": True, "BlockPublicPolicy": True, "RestrictPublicBuckets": True}
    p.call("PutPublicAccessBlock(버킷 수준)", s3.put_public_access_block, Bucket=b, PublicAccessBlockConfiguration=pab)
    g = p.call("GetPublicAccessBlock", s3.get_public_access_block, Bucket=b)
    pub = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": "*", "Action": "s3:GetObject",
                                                   "Resource": f"arn:aws:s3:::{b}/*"}]}
    if g:
        p.expect_error("PutBucketPolicy(퍼블릭, BlockPublicPolicy=true)", s3.put_bucket_policy, "AccessDenied",
                       Bucket=b, Policy=json.dumps(pub), what="퍼블릭 액세스 차단 상태에서 퍼블릭 정책 → AccessDenied")
        try:
            s3.delete_bucket_policy(Bucket=b)
        except Exception:  # noqa: BLE001
            pass
    p.call("GetBucketOwnershipControls", s3.get_bucket_ownership_controls, Bucket=b)
    p.expect_error("PutBucketAcl(public-read)", s3.put_bucket_acl, "AccessControlListNotSupported", Bucket=b, ACL="public-read",
                   what="기본 객체 소유권(BucketOwnerEnforced)에서 ACL 설정 → AccessControlListNotSupported")

    # 암호화
    p.call("PutBucketEncryption(SSE-S3)", s3.put_bucket_encryption, Bucket=b, ServerSideEncryptionConfiguration={
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]})
    s3.put_object(Bucket=b, Key="enc.txt", Body=b"x")
    h = s3.head_object(Bucket=b, Key="enc.txt")
    p.behavior("기본 암호화 SSE-S3 → HeadObject ServerSideEncryption=AES256", h.get("ServerSideEncryption") == "AES256",
               str(h.get("ServerSideEncryption")))
    kms = p.client("kms")
    try:
        kid = kms.create_key(Description="probe s3")["KeyMetadata"]["KeyId"]
        p.cleanup("kms", lambda: kms.schedule_key_deletion(KeyId=kid, PendingWindowInDays=7))
    except Exception:  # noqa: BLE001
        kid = None
    if kid:
        r = p.call("PutObject(SSE-KMS)", s3.put_object, Bucket=b, Key="kms.txt", Body=b"secret",
                   ServerSideEncryption="aws:kms", SSEKMSKeyId=kid)
        if r:
            h = s3.head_object(Bucket=b, Key="kms.txt")
            p.behavior("SSE-KMS 객체 HeadObject에 aws:kms·키 ID", h.get("ServerSideEncryption") == "aws:kms"
                       and kid in (h.get("SSEKMSKeyId") or ""), f"{h.get('ServerSideEncryption')} {h.get('SSEKMSKeyId')}")
            kms.disable_key(KeyId=kid)
            try:
                s3.get_object(Bucket=b, Key="kms.txt")["Body"].read()
                p.behavior("KMS 키를 비활성화하면 SSE-KMS 객체 읽기 실패", False, "읽힘 — S3가 KMS 키 상태를 확인하지 않음")
            except ClientError as e:
                p.behavior("KMS 키를 비활성화하면 SSE-KMS 객체 읽기 실패", True, e.response["Error"]["Code"])
            kms.enable_key(KeyId=kid)
        p.call("PutBucketEncryption(SSE-KMS, BucketKey)", s3.put_bucket_encryption, Bucket=b,
               ServerSideEncryptionConfiguration={"Rules": [{"ApplyServerSideEncryptionByDefault": {
                   "SSEAlgorithm": "aws:kms", "KMSMasterKeyID": kid}, "BucketKeyEnabled": True}]})
    p.call("PutObject(SSE-C)", s3.put_object, Bucket=b, Key="ssec.txt", Body=b"c", SSECustomerAlgorithm="AES256",
           SSECustomerKey="k" * 32)
    p.expect_error("GetObject(SSE-C 객체를 키 없이)", s3.get_object, "InvalidRequest", Bucket=b, Key="ssec.txt",
                   what="SSE-C 객체를 키 없이 읽기 → InvalidRequest")

    # 복제
    dst = _bucket(p, "replica")
    if dst:
        s3.put_bucket_versioning(Bucket=dst, VersioningConfiguration={"Status": "Enabled"})
        rep = p.call("PutBucketReplication", s3.put_bucket_replication, Bucket=b, ReplicationConfiguration={
            "Role": "arn:aws:iam::000000000000:role/s3-replication",
            "Rules": [{"ID": "all", "Status": "Enabled", "Priority": 1, "Filter": {"Prefix": ""},
                       "DeleteMarkerReplication": {"Status": "Disabled"},
                       "Destination": {"Bucket": f"arn:aws:s3:::{dst}", "StorageClass": "STANDARD_IA"}}]})
        if rep is not None:
            s3.put_object(Bucket=b, Key="rep.txt", Body=b"replicate-me")
            ok = wait_until(lambda: s3.head_object(Bucket=dst, Key="rep.txt") is not None, 10)
            st = s3.head_object(Bucket=b, Key="rep.txt").get("ReplicationStatus")
            p.behavior("복제 규칙 → 새 객체가 대상 버킷에 실제로 복제됨", ok, f"원본 ReplicationStatus={st}")
        nov = _bucket(p, "nover")
        if nov:
            p.expect_error("PutBucketReplication(원본 버전 관리 꺼짐)", s3.put_bucket_replication, "InvalidRequest",
                           Bucket=nov, ReplicationConfiguration={"Role": "arn:aws:iam::000000000000:role/r", "Rules": [
                               {"ID": "a", "Status": "Enabled", "Priority": 1, "Filter": {"Prefix": ""},
                                "DeleteMarkerReplication": {"Status": "Disabled"},
                                "Destination": {"Bucket": f"arn:aws:s3:::{dst}"}}]},
                           what="버전 관리 없는 버킷에 복제 → InvalidRequest")

    # 이벤트 알림 → SQS
    sqs = p.client("sqs")
    try:
        qurl = sqs.create_queue(QueueName=p.name("s3events"))["QueueUrl"]
        qarn = sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        p.cleanup("q", lambda: sqs.delete_queue(QueueUrl=qurl))
        sqs.set_queue_attributes(QueueUrl=qurl, Attributes={"Policy": json.dumps({
            "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "s3.amazonaws.com"},
                                                    "Action": "sqs:SendMessage", "Resource": qarn}]})})
    except Exception:  # noqa: BLE001
        qurl = None
    if qurl:
        nb = _bucket(p, "notify")
        if nb:
            n = p.call("PutBucketNotificationConfiguration(SQS)", s3.put_bucket_notification_configuration, Bucket=nb,
                       NotificationConfiguration={"QueueConfigurations": [{"QueueArn": qarn, "Events": ["s3:ObjectCreated:*"],
                                                  "Filter": {"Key": {"FilterRules": [{"Name": "prefix", "Value": "uploads/"}]}}}]})
            if n is not None:
                s3.put_object(Bucket=nb, Key="uploads/a.jpg", Body=b"img")
                s3.put_object(Bucket=nb, Key="other/b.jpg", Body=b"img")
                got: list[dict[str, Any]] = []

                def _recv() -> bool:
                    for m in sqs.receive_message(QueueUrl=qurl, MaxNumberOfMessages=10, WaitTimeSeconds=1).get("Messages", []):
                        got.append(json.loads(m["Body"]))
                        sqs.delete_message(QueueUrl=qurl, ReceiptHandle=m["ReceiptHandle"])
                    return any("Records" in x for x in got)
                ok = wait_until(_recv, 10)
                keys = [r["s3"]["object"]["key"] for x in got for r in x.get("Records", [])]
                p.behavior("S3 ObjectCreated 이벤트가 SQS 큐에 실제로 도착", ok, f"수신 키 {keys}; 기타 {[x.get('Event') for x in got if 'Records' not in x]}")
                if ok:
                    p.behavior("prefix 필터(uploads/)만 전달", keys == ["uploads/a.jpg"], str(keys))

    # 정적 웹 사이트
    p.call("PutBucketWebsite", s3.put_bucket_website, Bucket=b, WebsiteConfiguration={
        "IndexDocument": {"Suffix": "index.html"}, "ErrorDocument": {"Key": "error.html"}})
    p.call("GetBucketWebsite", s3.get_bucket_website, Bucket=b)

    # 객체 잠금
    lb = p.name("lock")
    if p.call("CreateBucket(ObjectLockEnabledForBucket)", s3.create_bucket, Bucket=lb, ObjectLockEnabledForBucket=True) is not None:
        p.cleanup("lockb", lambda: _empty_bucket(s3, lb))
        p.call("PutObjectLockConfiguration(GOVERNANCE 1일)", s3.put_object_lock_configuration, Bucket=lb,
               ObjectLockConfiguration={"ObjectLockEnabled": "Enabled",
                                        "Rule": {"DefaultRetention": {"Mode": "GOVERNANCE", "Days": 1}}})
        r = s3.put_object(Bucket=lb, Key="worm.txt", Body=b"w")
        vid = r.get("VersionId")
        h = s3.head_object(Bucket=lb, Key="worm.txt")
        p.behavior("기본 보존 기간이 객체에 적용됨", h.get("ObjectLockMode") == "GOVERNANCE",
                   f"{h.get('ObjectLockMode')} {h.get('ObjectLockRetainUntilDate')}")
        if vid:
            p.expect_error("DeleteObject(VersionId, 보존 중)", s3.delete_object, "AccessDenied", Bucket=lb, Key="worm.txt",
                           VersionId=vid, what="보존 중인 객체 버전 삭제 → AccessDenied")

    # 스토리지 클래스 + 복원
    p.call("PutObject(StorageClass=GLACIER)", s3.put_object, Bucket=b, Key="archive.txt", Body=b"old", StorageClass="GLACIER")
    h = s3.head_object(Bucket=b, Key="archive.txt")
    p.behavior("StorageClass=GLACIER 저장", h.get("StorageClass") == "GLACIER", str(h.get("StorageClass")))
    p.expect_error("GetObject(GLACIER, 복원 전)", s3.get_object, "InvalidObjectState", Bucket=b, Key="archive.txt",
                   what="복원 전 GLACIER 객체 읽기 → InvalidObjectState")
    rr = p.call("RestoreObject(Days=1, Standard)", s3.restore_object, Bucket=b, Key="archive.txt",
                RestoreRequest={"Days": 1, "GlacierJobParameters": {"Tier": "Standard"}})
    if rr is not None:
        h = s3.head_object(Bucket=b, Key="archive.txt")
        p.behavior("복원 요청 후 HeadObject Restore 헤더", bool(h.get("Restore")), str(h.get("Restore")))
    p.call("PutObject(INTELLIGENT_TIERING)", s3.put_object, Bucket=b, Key="it.txt", Body=b"i", StorageClass="INTELLIGENT_TIERING")
    p.call("PutBucketAccelerateConfiguration", s3.put_bucket_accelerate_configuration, Bucket=b,
           AccelerateConfiguration={"Status": "Enabled"})
    p.call("PutBucketRequestPayment(Requester)", s3.put_bucket_request_payment, Bucket=b,
           RequestPaymentConfiguration={"Payer": "Requester"})


def _upload_file(s3: Any, bucket: str) -> dict[str, Any]:
    from boto3.s3.transfer import TransferConfig
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(os.urandom(9 * 1024 * 1024))
        path = f.name
    try:
        s3.upload_file(path, bucket, "auto-mp.bin", Config=TransferConfig(multipart_threshold=8 * 1024 * 1024))
        return s3.head_object(Bucket=bucket, Key="auto-mp.bin")
    finally:
        os.unlink(path)


def run_efs(p: Probe) -> None:
    efs, ec2 = p.client("efs"), p.client("ec2")
    fs = p.call("CreateFileSystem(generalPurpose, Encrypted)", efs.create_file_system, CreationToken=p.name("efs"),
                PerformanceMode="generalPurpose", ThroughputMode="elastic", Encrypted=True,
                Tags=[{"Key": "Name", "Value": p.name("efs")}])
    if not fs:
        return
    fid = fs["FileSystemId"]
    p.cleanup("fs", lambda: efs.delete_file_system(FileSystemId=fid))
    ok = wait_until(lambda: efs.describe_file_systems(FileSystemId=fid)["FileSystems"][0]["LifeCycleState"] == "available", 15)
    p.behavior("파일 시스템 creating→available", ok, f"생성 직후 {fs['LifeCycleState']}")
    p.expect_error("CreateFileSystem(같은 CreationToken)", efs.create_file_system, "FileSystemAlreadyExists",
                   CreationToken=p.name("efs"), what="같은 CreationToken 재사용 → FileSystemAlreadyExists(멱등성)")
    try:
        vpc = ec2.create_vpc(CidrBlock="10.30.0.0/16")["Vpc"]["VpcId"]
        p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
        subs = []
        for az, c in (("us-east-1a", "10.30.1.0/24"), ("us-east-1b", "10.30.2.0/24")):
            sid = ec2.create_subnet(VpcId=vpc, CidrBlock=c, AvailabilityZone=az)["Subnet"]["SubnetId"]
            subs.append(sid)
            p.cleanup("sn", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
        sg = ec2.create_security_group(GroupName=p.name("efs-sg"), Description="efs", VpcId=vpc)["GroupId"]
        p.cleanup("sg", lambda: ec2.delete_security_group(GroupId=sg))
    except Exception as e:  # noqa: BLE001
        p.skip("마운트 타깃", f"VPC 준비 실패: {e}")
        return
    mts = []
    for sid in subs:
        mt = p.call("CreateMountTarget", efs.create_mount_target, FileSystemId=fid, SubnetId=sid, SecurityGroups=[sg])
        if mt:
            mts.append(mt["MountTargetId"])
            p.cleanup("mt", lambda m=mt["MountTargetId"]: efs.delete_mount_target(MountTargetId=m))
    if mts:
        d = efs.describe_mount_targets(FileSystemId=fid)["MountTargets"]
        p.behavior("AZ별 마운트 타깃 IP가 해당 서브넷(10.30.x.x) 안에 있음",
                   len(d) == 2 and all((x.get("IpAddress") or "").startswith("10.30.") for x in d),
                   str([(x.get("AvailabilityZoneName"), x.get("IpAddress"), x.get("LifeCycleState")) for x in d]))
        p.expect_error("CreateMountTarget(같은 AZ 두 번째)", efs.create_mount_target, "MountTargetConflict",
                       FileSystemId=fid, SubnetId=subs[0], SecurityGroups=[sg],
                       what="같은 AZ에 마운트 타깃 두 번 → MountTargetConflict")
    ap = p.call("CreateAccessPoint", efs.create_access_point, FileSystemId=fid, PosixUser={"Uid": 1000, "Gid": 1000},
                RootDirectory={"Path": "/receipts"})
    if ap:
        p.cleanup("ap", lambda: efs.delete_access_point(AccessPointId=ap["AccessPointId"]))
    p.call("PutLifecycleConfiguration(AFTER_30_DAYS → IA)", efs.put_lifecycle_configuration, FileSystemId=fid,
           LifecyclePolicies=[{"TransitionToIA": "AFTER_30_DAYS"}, {"TransitionToPrimaryStorageClass": "AFTER_1_ACCESS"}])
    p.call("PutBackupPolicy", efs.put_backup_policy, FileSystemId=fid, BackupPolicy={"Status": "ENABLED"})
    p.call("PutFileSystemPolicy(TLS 강제)", efs.put_file_system_policy, FileSystemId=fid, BypassPolicyLockoutSafetyCheck=True,
           Policy=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Effect": "Deny", "Principal": {"AWS": "*"}, "Action": "*",
                                                "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]}))
    p.expect_error("DeleteFileSystem(마운트 타깃 있음)", efs.delete_file_system, "FileSystemInUse", FileSystemId=fid,
                   what="마운트 타깃이 남은 파일 시스템 삭제 → FileSystemInUse")


CHECKS = {
    "s3": run_s3,
    "efs": run_efs,
}
