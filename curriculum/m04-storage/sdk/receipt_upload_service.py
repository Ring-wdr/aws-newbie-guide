"""M04 — 영수증 업로드 서비스 (boto3).

TodayOrder 앱은 영수증 PDF를 "API 서버를 거치지 않고" S3에 직접 올린다.
API 서버는 ① 업로드용 presigned PUT URL을 발급하고 ② 업로드가 끝났는지 확인하고
③ 다운로드용 presigned GET URL을 발급하는 일만 한다. 큰 파일이 API 서버의 메모리·대역폭을
지나가지 않으니 서버가 가벼워진다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m04-storage/sdk/receipt_upload_service.py

코드에는 엔드포인트도 자격 증명도 없다(환경 변수로 주입). main() 첫 줄의 require_emulator() 가
클라이언트를 만들기 전에 에뮬레이터인지 확인한다. (실제 AWS: TODAYORDER_ALLOW_REAL_AWS=1 — 요금 주의,
버킷 이름은 전 세계에서 유일해야 하므로 RECEIPT_BUCKET 환경 변수로 바꿀 것)
"""

from __future__ import annotations

import os
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

BUCKET = os.environ.get("RECEIPT_BUCKET", "todayorder-m04-receipts-sdk")
PDF = "application/pdf"


@dataclass(frozen=True)
class UploadTicket:
    """클라이언트(앱)에게 돌려줄 업로드 정보."""

    key: str
    url: str
    content_type: str
    expires_in: int


class ReceiptStore:
    """영수증 버킷을 다루는 얇은 저장소 계층."""

    def __init__(self, s3: Any, bucket: str) -> None:
        self.s3 = s3
        self.bucket = bucket

    # ---- 버킷 준비: 비공개 + 버전 관리 + 기본 암호화 + 오래된 버전 정리
    def ensure_bucket(self) -> None:
        try:
            self.s3.head_bucket(Bucket=self.bucket)
        except ClientError:
            self.s3.create_bucket(Bucket=self.bucket)  # us-east-1 은 LocationConstraint 를 주지 않는다
        self.s3.put_public_access_block(
            Bucket=self.bucket,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
        self.s3.put_bucket_versioning(Bucket=self.bucket, VersioningConfiguration={"Status": "Enabled"})
        self.s3.put_bucket_encryption(
            Bucket=self.bucket,
            ServerSideEncryptionConfiguration={
                "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
            },
        )
        self.s3.put_bucket_lifecycle_configuration(
            Bucket=self.bucket,
            LifecycleConfiguration={
                "Rules": [
                    {
                        "ID": "receipts-tiering",
                        "Status": "Enabled",
                        "Filter": {"Prefix": "receipts/"},
                        "Transitions": [{"Days": 30, "StorageClass": "STANDARD_IA"}],
                        "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
                        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7},
                    }
                ]
            },
        )

    @staticmethod
    def key_for(order_id: str, day: date) -> str:
        # 날짜 접두사 → "그날 영수증" 목록 조회가 쉬움. 접두사마다 초당 요청 한도가 따로 잡힌다.
        return f"receipts/{day:%Y/%m/%d}/{order_id}.pdf"

    def issue_upload(self, order_id: str, day: date, expires_in: int = 300) -> UploadTicket:
        key = self.key_for(order_id, day)
        url = self.s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": self.bucket, "Key": key, "ContentType": PDF},
            ExpiresIn=expires_in,
        )
        return UploadTicket(key=key, url=url, content_type=PDF, expires_in=expires_in)

    def confirm_upload(self, key: str, max_bytes: int = 10 * 1024 * 1024) -> dict[str, Any]:
        """업로드가 정말 끝났는지, 형식·크기가 맞는지 서버가 확인한다 (클라이언트를 믿지 않는다)."""
        head = self.s3.head_object(Bucket=self.bucket, Key=key)
        if head["ContentType"] != PDF:
            raise ValueError(f"PDF가 아님: {head['ContentType']}")
        if head["ContentLength"] > max_bytes:
            raise ValueError(f"너무 큼: {head['ContentLength']} bytes")
        self.s3.put_object_tagging(
            Bucket=self.bucket, Key=key, Tagging={"TagSet": [{"Key": "status", "Value": "confirmed"}]}
        )
        return {"size": head["ContentLength"], "sse": head.get("ServerSideEncryption"), "version": head.get("VersionId")}

    def issue_download(self, key: str, expires_in: int = 60) -> str:
        return self.s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": key,
                # 브라우저가 파일로 저장하도록 응답 헤더를 바꿔 달라고 서명에 넣는다
                "ResponseContentDisposition": f'attachment; filename="{key.rsplit("/", 1)[-1]}"',
            },
            ExpiresIn=expires_in,
        )

    def list_day(self, day: date) -> list[str]:
        prefix = f"receipts/{day:%Y/%m/%d}/"
        keys: list[str] = []
        for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=prefix):
            keys += [o["Key"] for o in page.get("Contents", [])]
        return keys

    def destroy(self) -> None:
        """실습 정리: 모든 버전·삭제 마커까지 지우고 버킷 삭제."""
        try:
            self.s3.head_bucket(Bucket=self.bucket)
        except ClientError:
            return
        for page in self.s3.get_paginator("list_object_versions").paginate(Bucket=self.bucket):
            for v in page.get("Versions", []) + page.get("DeleteMarkers", []):
                self.s3.delete_object(Bucket=self.bucket, Key=v["Key"], VersionId=v["VersionId"])
        self.s3.delete_bucket(Bucket=self.bucket)


def _ssl_context() -> ssl.SSLContext:
    # 에뮬레이터는 자체 CA 인증서를 쓴다. env.sh 가 AWS_CA_BUNDLE 로 알려 준다 (실제 AWS에서는 비어 있음).
    return ssl.create_default_context(cafile=os.environ.get("AWS_CA_BUNDLE") or None)


def http(method: str, url: str, body: bytes | None = None, headers: dict[str, str] | None = None) -> tuple[int, bytes, dict[str, str]]:
    """앱(클라이언트) 흉내: AWS SDK 없이 평범한 HTTP 로 presigned URL 을 호출한다."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, context=_ssl_context(), timeout=10) as r:
            return r.status, r.read(), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, e.read(), {k.lower(): v for k, v in e.headers.items()}


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    store = ReceiptStore(boto3.client("s3"), BUCKET)
    store.destroy()
    store.ensure_bucket()
    print(f"버킷 준비: {BUCKET} (비공개·버전 관리·SSE-S3·수명 주기)")

    today = date(2026, 11, 12)
    pdf = b"%PDF-1.4\n% TodayOrder receipt A-5001\n"

    # 1) 서버: 업로드 URL 발급 → 2) 앱: 그 URL 로 PUT
    ticket = store.issue_upload("A-5001", today)
    print(f"업로드 키: {ticket.key} (URL 유효 {ticket.expires_in}초)")
    status, _, _ = http("PUT", ticket.url, pdf, {"Content-Type": ticket.content_type})
    print(f"앱 → presigned PUT: HTTP {status}")
    assert status == 200

    # 앱이 Content-Type 을 속이면? 서명에 포함된 헤더가 달라 S3 가 거부한다
    status_bad, body_bad, _ = http("PUT", ticket.url, pdf, {"Content-Type": "text/html"})
    print(f"앱 → Content-Type 을 바꿔 PUT: HTTP {status_bad} ({_error_code(body_bad)})")
    assert status_bad == 403

    # 3) 서버: 업로드 확인
    info = store.confirm_upload(ticket.key)
    print(f"확인: {info['size']} bytes, SSE={info['sse']}, 버전 있음={info['version'] is not None}")
    assert info["sse"] == "AES256"

    # 4) 같은 주문 영수증을 다시 올리면 → 덮어쓰지만 이전 버전이 남는다
    ticket2 = store.issue_upload("A-5001", today)
    http("PUT", ticket2.url, pdf + b"% reissued\n", {"Content-Type": PDF})
    versions = store.s3.list_object_versions(Bucket=BUCKET, Prefix=ticket.key).get("Versions", [])
    print(f"재발급 후 버전 수: {len(versions)}")
    assert len(versions) == 2

    # 5) 서버: 다운로드 URL 발급 → 앱: GET
    url = store.issue_download(ticket.key)
    status, data, headers = http("GET", url)
    print(f"앱 → presigned GET: HTTP {status}, Content-Disposition={headers.get('content-disposition')}")
    assert status == 200 and data.endswith(b"% reissued\n")
    assert headers.get("content-disposition", "").startswith("attachment")

    # 6) 서명 없이 같은 객체에 접근하면 → 403 (버킷은 비공개)
    plain = url.split("?", 1)[0]
    status, _, _ = http("GET", plain)
    print(f"서명 없이 GET: HTTP {status}")
    assert status == 403

    print(f"오늘의 영수증: {store.list_day(today)}")
    store.destroy()
    print("정리 완료")
    print("SDK receipt_upload_service OK")


def _error_code(body: bytes) -> str:
    text = body.decode(errors="replace")
    start = text.find("<Code>")
    return text[start + 6 : text.find("</Code>")] if start >= 0 else text[:60]


if __name__ == "__main__":
    main()
