"""M09 — 봉투 암호화(envelope encryption)를 boto3로: KMS 데이터 키 + 로컬 대칭 암호.

흐름 (실제 AWS 와 같다)
  1. kms.generate_data_key()  → 평문 데이터 키(32바이트) + KMS 로 암호화된 데이터 키
  2. 평문 데이터 키로 "로컬에서" 영수증 파일을 암호화하고, 평문 키는 메모리에서 버린다
  3. 암호문 + 암호화된 데이터 키 + nonce 를 한 덩어리(JSON)로 S3 에 저장한다
  4. 읽을 때: kms.decrypt(암호화된 데이터 키) → 평문 데이터 키 → 로컬 복호화

!! 로컬 암호에 대해 솔직하게 !!
  이 저장소는 boto3 와 표준 라이브러리만 의존한다. 표준 라이브러리에는 AES 가 없다.
  - `cryptography` 패키지가 설치돼 있으면 AES-256-GCM(인증 암호화)을 쓴다 ← 실제 서비스에서 쓸 방식
  - 없으면 표준 라이브러리만으로 만든 **교육용 대체 암호**(HMAC-SHA256 카운터 모드 키스트림 XOR +
    HMAC-SHA256 태그, encrypt-then-MAC)를 쓴다. AES 가 아니며 검증된 구현이 아니므로 **실서비스에 쓰지 말 것**.
    봉투 암호화의 "흐름"(어떤 키가 어디에 있고 무엇이 KMS 를 거치는가)은 두 경우가 완전히 같다.
  셸 판(labs/lab03-envelope-encryption.sh)은 openssl 의 진짜 AES-256 을 쓴다.
  실서비스에서는 직접 조립하기보다 AWS Encryption SDK 나 S3 SSE-KMS 를 쓰는 편이 안전하다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m09-security-encryption/sdk/envelope_encryption.py
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

ALIAS = "alias/todayorder-m09-sdk-envelope"
BUCKET = "todayorder-m09-sdk-receipts"
KEY = "receipts/2026/11/A-1001.receipt.enc.json"

try:  # 선택 의존성: 있으면 진짜 AES-GCM
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # type: ignore[import-not-found]

    CIPHER = "AES-256-GCM (cryptography)"
except ImportError:  # 표준 라이브러리만 있는 기본 환경
    AESGCM = None
    CIPHER = "교육용 대체 암호: HMAC-SHA256-CTR + HMAC 태그 (표준 라이브러리, AES 아님)"


class TamperedError(Exception):
    """암호문이나 태그가 바뀌었다."""


def _keystream(key: bytes, nonce: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        out += hmac.new(key, nonce + counter.to_bytes(8, "big"), hashlib.sha256).digest()
        counter += 1
    return bytes(out[:length])


def local_encrypt(data_key: bytes, plaintext: bytes, aad: bytes) -> dict[str, str]:
    nonce = os.urandom(12)
    if AESGCM is not None:
        ct = AESGCM(data_key).encrypt(nonce, plaintext, aad)
        return {"alg": "AES-256-GCM", "nonce": base64.b64encode(nonce).decode(), "ct": base64.b64encode(ct).decode()}
    enc_key = hmac.new(data_key, b"enc", hashlib.sha256).digest()
    mac_key = hmac.new(data_key, b"mac", hashlib.sha256).digest()
    ct = bytes(a ^ b for a, b in zip(plaintext, _keystream(enc_key, nonce, len(plaintext))))
    tag = hmac.new(mac_key, aad + nonce + ct, hashlib.sha256).digest()
    return {
        "alg": "TEACHING-HMAC-CTR",
        "nonce": base64.b64encode(nonce).decode(),
        "ct": base64.b64encode(ct).decode(),
        "tag": base64.b64encode(tag).decode(),
    }


def local_decrypt(data_key: bytes, box: dict[str, str], aad: bytes) -> bytes:
    nonce, ct = base64.b64decode(box["nonce"]), base64.b64decode(box["ct"])
    if box["alg"] == "AES-256-GCM":
        if AESGCM is None:
            raise RuntimeError("이 파일은 AES-GCM 으로 암호화됐다. 'cryptography' 패키지가 필요하다")
        try:
            return AESGCM(data_key).decrypt(nonce, ct, aad)
        except Exception as e:  # cryptography.exceptions.InvalidTag
            raise TamperedError(str(e)) from e
    enc_key = hmac.new(data_key, b"enc", hashlib.sha256).digest()
    mac_key = hmac.new(data_key, b"mac", hashlib.sha256).digest()
    expected = hmac.new(mac_key, aad + nonce + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, base64.b64decode(box["tag"])):
        raise TamperedError("태그 불일치")
    return bytes(a ^ b for a, b in zip(ct, _keystream(enc_key, nonce, len(ct))))


def seal(kms, key_id: str, plaintext: bytes, context: dict[str, str]) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    """봉투 암호화: 데이터 키를 받아 로컬에서 암호화하고, 평문 키는 버린다."""
    dk = kms.generate_data_key(KeyId=key_id, KeySpec="AES_256", EncryptionContext=context)
    data_key = dk["Plaintext"]
    try:
        aad = json.dumps(context, sort_keys=True).encode()
        box = local_encrypt(data_key, plaintext, aad)
    finally:
        del data_key  # 파이썬에서는 메모리를 확실히 지울 수 없다 — 참조라도 빨리 끊는다
    return {"encrypted_data_key": base64.b64encode(dk["CiphertextBlob"]).decode(), "context": context, **box}


def open_box(kms, envelope: dict[str, Any]) -> bytes:  # type: ignore[no-untyped-def]
    """봉투 복호화: 암호화된 데이터 키를 KMS 로 풀고, 로컬에서 본문을 푼다."""
    data_key = kms.decrypt(
        CiphertextBlob=base64.b64decode(envelope["encrypted_data_key"]), EncryptionContext=envelope["context"]
    )["Plaintext"]
    aad = json.dumps(envelope["context"], sort_keys=True).encode()
    return local_decrypt(data_key, envelope, aad)


def ensure_key(kms) -> str:  # type: ignore[no-untyped-def]
    for alias in kms.get_paginator("list_aliases").paginate():
        for a in alias["Aliases"]:
            if a["AliasName"] == ALIAS and a.get("TargetKeyId"):
                if kms.describe_key(KeyId=a["TargetKeyId"])["KeyMetadata"]["KeyState"] == "Enabled":
                    return a["TargetKeyId"]
                kms.delete_alias(AliasName=ALIAS)
    key_id = kms.create_key(Description="TodayOrder 영수증 봉투 암호화 (M09 sdk)")["KeyMetadata"]["KeyId"]
    kms.create_alias(AliasName=ALIAS, TargetKeyId=key_id)
    return key_id


def reset_bucket(s3) -> None:  # type: ignore[no-untyped-def]
    try:
        s3.head_bucket(Bucket=BUCKET)
    except ClientError:
        return
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
        for obj in page.get("Contents", []):
            s3.delete_object(Bucket=BUCKET, Key=obj["Key"])
    s3.delete_bucket(Bucket=BUCKET)


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    kms = boto3.client("kms")
    s3 = boto3.client("s3")
    print(f"로컬 암호: {CIPHER}")
    key_id = ensure_key(kms)
    reset_bucket(s3)
    s3.create_bucket(Bucket=BUCKET)

    receipt = json.dumps(
        {"orderId": "A-1001", "items": [{"sku": f"SKU-{i:04d}", "qty": 1, "price": 1000 + i} for i in range(200)]}
    ).encode()
    context = {"orderId": "A-1001", "purpose": "receipt"}
    print(f"영수증 평문 {len(receipt):,}바이트 (KMS Encrypt 한도 4,096바이트 초과 → 봉투 암호화)")

    envelope = seal(kms, ALIAS, receipt, context)
    body = json.dumps(envelope).encode()
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=body, ContentType="application/json")
    print(f"저장: s3://{BUCKET}/{KEY} ({len(body):,}바이트) 필드={sorted(envelope)}")
    assert b"SKU-0001" not in body, "평문이 저장됐다"

    stored = json.loads(s3.get_object(Bucket=BUCKET, Key=KEY)["Body"].read())
    restored = open_box(kms, stored)
    print(f"복호화: {len(restored):,}바이트, 원본과 같음={restored == receipt}")
    assert restored == receipt

    # 1) 암호문 1바이트 변조 → 태그 검증 실패
    tampered = dict(stored)
    ct = bytearray(base64.b64decode(tampered["ct"]))
    ct[10] ^= 0x01
    tampered["ct"] = base64.b64encode(bytes(ct)).decode()
    try:
        open_box(kms, tampered)
        raise AssertionError("변조가 탐지되지 않았다")
    except TamperedError:
        print("변조된 암호문 → 거부 (무결성 검사)")

    # 2) 다른 암호화 컨텍스트 → KMS 가 데이터 키를 풀어 주지 않는다
    wrong = dict(stored, context={"orderId": "A-9999", "purpose": "receipt"})
    try:
        open_box(kms, wrong)
        raise AssertionError("다른 컨텍스트로 열렸다")
    except ClientError as e:
        print(f"다른 암호화 컨텍스트 → {e.response['Error']['Code']}")

    # 3) KMS 키 비활성화 → 데이터 키를 못 풀어 파일 전체가 잠긴다
    kms.disable_key(KeyId=key_id)
    try:
        open_box(kms, stored)
        raise AssertionError("비활성 키로 열렸다")
    except ClientError as e:
        print(f"KMS 키 비활성화 → {e.response['Error']['Code']}")
    finally:
        kms.enable_key(KeyId=key_id)

    reset_bucket(s3)
    print("정리 완료 (KMS 키는 별칭과 함께 다음 실행에 재사용)")
    print("SDK envelope_encryption OK")


if __name__ == "__main__":
    main()
