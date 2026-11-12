"""M09 — 봉투 암호화(envelope encryption)를 boto3로: KMS 데이터 키 + 로컬 AES-256-GCM.

흐름 (실제 AWS 와 같다)
  1. kms.generate_data_key()  → 평문 데이터 키(32바이트) + KMS 로 암호화된 데이터 키
  2. 평문 데이터 키로 "로컬에서" 영수증을 AES-256-GCM 으로 암호화한다
     - 메시지마다 새 무작위 96비트(12바이트) nonce
     - KMS 암호화 컨텍스트를 GCM 의 AAD(추가 인증 데이터)로 묶는다 → 컨텍스트를 바꿔치기하면 복호화 실패
  3. 암호문(+ GCM 태그) + 암호화된 데이터 키 + nonce + 컨텍스트를 한 덩어리(JSON)로 S3 에 저장한다
  4. 읽을 때: kms.decrypt(암호화된 데이터 키, 컨텍스트) → 평문 데이터 키 → 로컬 AES-GCM 복호화(태그 검증)

로컬 AES 는 `cryptography` 패키지(프로젝트 의존성)를 쓴다. import 에 실패하면 저장소 루트에서
`uv sync` 를 다시 실행한다. 실서비스에서는 이 조립을 직접 하기보다 AWS Encryption SDK 나
S3 SSE-KMS 를 쓰는 편이 안전하다 — 이 예제는 그 안에서 일어나는 일을 보여 주기 위한 것이다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m09-security-encryption/sdk/envelope_encryption.py
"""

from __future__ import annotations

import base64
import json
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from emulator_guard import require_emulator

ALIAS = "alias/todayorder-m09-sdk-envelope"
BUCKET = "todayorder-m09-sdk-receipts"
KEY = "receipts/2026/11/A-1001.receipt.enc.json"
ALG = "AES-256-GCM"
NONCE_BYTES = 12  # GCM 표준 nonce 길이(96비트). 같은 키로 nonce 를 절대 재사용하지 않는다.


def aad_of(context: dict[str, str]) -> bytes:
    """암호화 컨텍스트를 AAD 로 쓰기 위한 정규화된 바이트(키 정렬)."""
    return json.dumps(context, sort_keys=True, separators=(",", ":")).encode()


def seal(kms, key_id: str, plaintext: bytes, context: dict[str, str]) -> dict[str, Any]:  # type: ignore[no-untyped-def]
    """봉투 암호화. 평문 데이터 키는 이 함수 안에서만 쓰고 바깥으로 돌려주지 않는다.

    호출할 때마다 KMS 에서 새 데이터 키를 받으므로 데이터 키 하나가 암호화하는 메시지는 객체 하나뿐이다.
    그래서 무작위 96비트 nonce 가 같은 키에서 겹칠 걱정이 없다(nonce 재사용 금지 규칙을 이 구조가 지켜 준다).

    솔직하게: 파이썬은 bytes 객체를 덮어쓸 수 없고 언제 메모리에서 지워질지(GC)도 보장하지 않는다.
    응답 dict(dk) 에도 같은 평문이 들어 있으므로 `del` 로 지워지는 것은 없다. 할 수 있는 것은
    평문 키를 반환·저장·로그하지 않고, 짧은 범위에서만 쓰는 것뿐이다.
    """
    dk = kms.generate_data_key(KeyId=key_id, KeySpec="AES_256", EncryptionContext=context)
    nonce = os.urandom(NONCE_BYTES)
    ciphertext = AESGCM(dk["Plaintext"]).encrypt(nonce, plaintext, aad_of(context))  # 끝 16바이트가 GCM 태그
    return {
        "alg": ALG,
        "encrypted_data_key": base64.b64encode(dk["CiphertextBlob"]).decode(),
        "context": context,
        "nonce": base64.b64encode(nonce).decode(),
        "ct": base64.b64encode(ciphertext).decode(),
    }


def open_box(kms, envelope: dict[str, Any]) -> bytes:  # type: ignore[no-untyped-def]
    """봉투 복호화: 암호화된 데이터 키를 KMS 로 풀고(컨텍스트 필요), 로컬에서 태그를 검증하며 푼다."""
    if envelope.get("alg") != ALG:
        raise ValueError(f"지원하지 않는 알고리즘: {envelope.get('alg')}")
    data_key = kms.decrypt(
        CiphertextBlob=base64.b64decode(envelope["encrypted_data_key"]), EncryptionContext=envelope["context"]
    )["Plaintext"]
    return AESGCM(data_key).decrypt(
        base64.b64decode(envelope["nonce"]), base64.b64decode(envelope["ct"]), aad_of(envelope["context"])
    )


def ensure_key(kms) -> str:  # type: ignore[no-untyped-def]
    for page in kms.get_paginator("list_aliases").paginate():
        for a in page["Aliases"]:
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
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=BUCKET):
        for obj in page.get("Versions", []) + page.get("DeleteMarkers", []):
            s3.delete_object(Bucket=BUCKET, Key=obj["Key"], VersionId=obj["VersionId"])
    s3.delete_bucket(Bucket=BUCKET)


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    kms = boto3.client("kms")
    s3 = boto3.client("s3")
    print(f"로컬 암호: {ALG} (cryptography), nonce {NONCE_BYTES * 8}비트, 암호화 컨텍스트 = AAD")
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

    again = seal(kms, ALIAS, receipt, context)
    print(f"같은 평문을 다시 암호화: nonce 다름={again['nonce'] != envelope['nonce']}, 암호문 다름={again['ct'] != envelope['ct']}")
    assert again["nonce"] != envelope["nonce"] and again["ct"] != envelope["ct"]

    # 1) 암호문 1바이트 변조 → GCM 태그 검증 실패
    ct = bytearray(base64.b64decode(stored["ct"]))
    ct[10] ^= 0x01
    tampered = dict(stored, ct=base64.b64encode(bytes(ct)).decode())
    try:
        open_box(kms, tampered)
        raise AssertionError("변조가 탐지되지 않았다")
    except InvalidTag:
        print("변조된 암호문 → InvalidTag (GCM 태그 검증 실패)")

    # 2) 다른 암호화 컨텍스트 → KMS 가 데이터 키를 풀어 주지 않는다
    wrong = dict(stored, context={"orderId": "A-9999", "purpose": "receipt"})
    try:
        open_box(kms, wrong)
        raise AssertionError("다른 컨텍스트로 열렸다")
    except ClientError as e:
        print(f"다른 암호화 컨텍스트 → {e.response['Error']['Code']} (KMS 단계에서 거부)")

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
