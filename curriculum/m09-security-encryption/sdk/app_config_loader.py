"""M09 — 앱 설정 로더: Parameter Store(일반 설정·SecureString) + Secrets Manager(DB 자격 증명).

TodayOrder 주문 API 가 시작할 때 읽는 설정을 한곳에서 불러오는 작은 라이브러리.
  - 일반 설정과 가벼운 비밀(API 키)은 Parameter Store 의 /todayorder/<env>/ 아래에 계층으로
  - 교체(rotation)가 필요한 DB 자격 증명은 Secrets Manager 에
  - 매 요청마다 AWS 를 부르지 않도록 TTL 캐시를 두고, TTL 이 지나면 다시 읽어 "교체된 비밀"을 따라간다

이 예제는 자기 데이터(/todayorder/sdk-demo/…, todayorder/sdk-demo/orders-db)를 만들어 쓰고 끝에 지운다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m09-security-encryption/sdk/app_config_loader.py
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

ENV = "sdk-demo"
PREFIX = f"/todayorder/{ENV}"
SECRET_ID = f"todayorder/{ENV}/orders-db"


@dataclass(frozen=True)
class AppConfig:
    timeout_ms: int
    allowed_origins: list[str]
    payment_api_key: str
    db_user: str
    db_password: str
    db_host: str


class ConfigLoader:
    """Parameter Store + Secrets Manager 를 읽어 AppConfig 를 만든다. ttl 초 동안 캐시한다.

    clock 은 테스트에서 시간을 직접 움직일 수 있게 주입한다(기본: time.monotonic).
    """

    def __init__(
        self, env: str, secret_id: str, ttl: float = 300.0, clock: Callable[[], float] = time.monotonic
    ) -> None:
        self.clock = clock
        self.prefix = f"/todayorder/{env}"
        self.secret_id = secret_id
        self.ttl = ttl
        self.ssm = boto3.client("ssm")
        self.sm = boto3.client("secretsmanager")
        self._cached: AppConfig | None = None
        self._loaded_at = 0.0
        self.aws_calls = 0

    def _params(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for page in self.ssm.get_paginator("get_parameters_by_path").paginate(
            Path=self.prefix, Recursive=True, WithDecryption=True
        ):
            self.aws_calls += 1
            for p in page["Parameters"]:
                out[p["Name"].removeprefix(self.prefix + "/")] = p["Value"]
        return out

    def _secret(self) -> dict[str, Any]:
        self.aws_calls += 1
        return json.loads(self.sm.get_secret_value(SecretId=self.secret_id)["SecretString"])

    def get(self) -> AppConfig:
        if self._cached and self.clock() - self._loaded_at < self.ttl:
            return self._cached
        p, s = self._params(), self._secret()
        self._cached = AppConfig(
            timeout_ms=int(p["api/timeout-ms"]),
            allowed_origins=p["api/allowed-origins"].split(","),
            payment_api_key=p["payment/api-key"],
            db_user=s["username"],
            db_password=s["password"],
            db_host=s["host"],
        )
        self._loaded_at = self.clock()
        return self._cached

    def invalidate(self) -> None:
        """캐시를 버린다 — 예: DB 인증 오류가 나면 호출해 교체된 비밀을 다시 읽는다."""
        self._cached = None


def seed(ssm, sm) -> None:  # type: ignore[no-untyped-def]
    cleanup(ssm, sm)
    ssm.put_parameter(Name=f"{PREFIX}/api/timeout-ms", Type="String", Value="3000")
    ssm.put_parameter(Name=f"{PREFIX}/api/allowed-origins", Type="StringList", Value="https://todayorder.example,https://admin.todayorder.example")
    ssm.put_parameter(Name=f"{PREFIX}/payment/api-key", Type="SecureString", Value="pk_demo_123")
    sm.create_secret(
        Name=SECRET_ID,
        SecretString=json.dumps({"username": "orders_app", "password": "first-pass", "host": "orders-db.todayorder.invalid"}),
    )


def cleanup(ssm, sm) -> None:  # type: ignore[no-untyped-def]
    for page in ssm.get_paginator("get_parameters_by_path").paginate(Path=PREFIX, Recursive=True):
        for p in page["Parameters"]:
            ssm.delete_parameter(Name=p["Name"])
    try:
        sm.delete_secret(SecretId=SECRET_ID, ForceDeleteWithoutRecovery=True)
    except ClientError:
        return
    deadline = time.monotonic() + 60  # 강제 삭제는 비동기다: 이름을 다시 쓸 수 있을 때까지 기다린다
    while time.monotonic() < deadline:
        try:
            sm.describe_secret(SecretId=SECRET_ID)
        except ClientError:
            return
        time.sleep(1)
    raise TimeoutError(f"{SECRET_ID} 삭제가 60초 안에 끝나지 않았다")


def mask(s: str) -> str:
    """비밀은 앞 글자도 찍지 않는다 — 길이만 보여 준다."""
    return f"<{len(s)}자 숨김>"


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    ssm, sm = boto3.client("ssm"), boto3.client("secretsmanager")
    seed(ssm, sm)

    # 가짜 시계: 실제 시간을 기다리지 않고 TTL 경과를 흉내 낸다 (실행 속도와 무관한 결정적 테스트)
    now = [0.0]
    loader = ConfigLoader(ENV, SECRET_ID, ttl=300.0, clock=lambda: now[0])
    cfg = loader.get()
    print(f"설정 로드: timeout={cfg.timeout_ms}ms origins={cfg.allowed_origins}")
    print(f"           payment_api_key={mask(cfg.payment_api_key)} db={cfg.db_user}@{cfg.db_host} password={mask(cfg.db_password)}")
    calls_after_first = loader.aws_calls

    for _ in range(100):  # 요청 100번 — 캐시 덕분에 AWS 호출은 늘지 않는다
        loader.get()
    print(f"요청 100번 뒤 AWS 호출 수: {loader.aws_calls} (첫 로드 {calls_after_first})")
    assert loader.aws_calls == calls_after_first

    # 비밀이 교체됐다고 하자 (실제로는 교체 Lambda 가 한다 — labs/lab04 참고)
    sm.put_secret_value(
        SecretId=SECRET_ID,
        SecretString=json.dumps({"username": "orders_app", "password": "rotated-pass", "host": "orders-db.todayorder.invalid"}),
    )
    now[0] += 299.0  # TTL(300초) 직전
    stale = loader.get().db_password
    now[0] += 2.0  # TTL 경과
    fresh = loader.get().db_password
    print(f"교체 직후(TTL 안, 캐시): {mask(stale)} · TTL 지난 뒤: {mask(fresh)} · 같은 값? {stale == fresh}")
    assert stale == "first-pass" and fresh == "rotated-pass"
    loader.invalidate()  # 인증 오류 등으로 즉시 다시 읽고 싶을 때
    assert loader.get().db_password == "rotated-pass"

    cleanup(ssm, sm)
    print("정리 완료")
    print("SDK app_config_loader OK")


if __name__ == "__main__":
    main()
