"""boto3 예제용 안전 장치: 요청이 로컬 aws-emulator로만 가는지 확인한다.

기본 사용 (사이트 하나 — scripts/env.sh 를 source 한 셸):

    from emulator_guard import require_emulator
    require_emulator()              # 클라이언트를 만들기 전에. 이후 평소처럼 boto3.client("s3")

두 번째 에뮬레이터("DR 리전" 등 — scripts/dr-env.sh 가 DR_ 접두사 변수를 만든 셸):

    from emulator_guard import emulator_site
    primary = emulator_site(real_aws_region="ap-northeast-2")         # AWS_* 변수의 사이트
    dr = emulator_site("DR_", real_aws_region="ap-northeast-1")       # DR_AWS_* 변수의 사이트
    primary.client("dynamodb").scan(...);  dr.client("dynamodb").put_item(...)

검사 순서 (각 사이트마다)
1. 네트워크 호출 없이 환경 변수만 본다. 엔드포인트 URL을 **파싱해서**
   scheme=https, 호스트=정확히 127.0.0.1, userinfo 없음, 숫자 포트(1~65535), 경로·쿼리·조각 없음을
   요구한다(`https://127.0.0.1:9320@<실제 AWS 호스트>` 같은 값은 거부). 주 사이트는 서비스별
   AWS_ENDPOINT_URL_* 도 같은 규칙으로 검사하고, AWS_IGNORE_CONFIGURED_ENDPOINT_URLS 가 켜져 있으면 거부한다.
2. 그 사이트의 엔드포인트·자격 증명·CA로만 STS GetCallerIdentity 를 호출해 계정이 000000000000 인지 확인한다.
어느 단계든 어긋나면 한국어 안내를 출력하고 종료 코드 1로 끝낸다.

실제 AWS에서 같은 코드를 돌리고 싶을 때만 TODAYORDER_ALLOW_REAL_AWS=1 을 설정한다(기본 꺼짐).
그러면 검사를 건너뛰고 경고만 출력하며, emulator_site() 는 엔드포인트를 지정하지 않은
boto3.Session(region_name=real_aws_region) 을 쓰는 사이트를 돌려준다. 주의: 이때 DR_AWS_* 변수는
쓰이지 않으므로 **두 번째 사이트도 주 사이트와 같은 환경(AWS_ENDPOINT_URL·자격 증명)을 따른다** —
env.sh 를 source 한 셸에서 opt-out 을 켜면 DR 요청도 주 에뮬레이터로 간다. 실제 AWS에서 두 리전을
쓰려면 env.sh 없이(새 셸) 실제 자격 증명으로 실행해 real_aws_region 만 다르게 한다.
"""

from __future__ import annotations

import configparser
import os
import sys
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

__all__ = ["require_emulator", "emulator_site", "EmulatorSite", "OPT_OUT_ENV", "EMULATOR_ACCOUNT", "validate_endpoint"]

OPT_OUT_ENV = "TODAYORDER_ALLOW_REAL_AWS"
EMULATOR_ACCOUNT = "000000000000"
_HOST = "127.0.0.1"
_SITE_KEYS = ("AWS_ENDPOINT_URL", "AWS_CA_BUNDLE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CONFIG_FILE")
_HINT = "먼저 저장소 루트에서 'source scripts/env.sh' 를 실행하세요 (에뮬레이터: scripts/emulator-up.sh)."
_DR_HINT = "먼저 'source scripts/env.sh' 다음 'source scripts/dr-env.sh' 를 실행하세요 (에뮬레이터: scripts/emulator-up.sh <포트>)."


def _fail(msg: str, hint: str = "") -> None:
    print(f"[emulator_guard] {msg}", file=sys.stderr)
    if hint:
        print(f"                 {hint}", file=sys.stderr)
    raise SystemExit(1)


def validate_endpoint(value: str) -> str | None:
    """에뮬레이터 엔드포인트 URL이면 None, 아니면 거부 사유(한국어)를 돌려준다. 네트워크를 쓰지 않는다."""
    if not value:
        return "설정 안 됨"
    try:
        parts = urlsplit(value)
        port = parts.port  # 숫자가 아니거나 범위를 벗어나면 ValueError
    except ValueError as e:
        return f"URL을 해석할 수 없음({e})"
    if parts.scheme != "https":
        return f"scheme 이 https 가 아님({parts.scheme or '없음'})"
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        return "사용자 정보(@)가 들어 있음"
    if parts.hostname != _HOST:
        return f"호스트가 {_HOST} 가 아님({parts.hostname})"
    if port is None or not 1 <= port <= 65535:
        return "포트가 없음"
    if parts.netloc != f"{_HOST}:{port}":
        return f"호스트·포트 표기가 정확히 '{_HOST}:<포트>' 가 아님({parts.netloc})"
    if parts.path not in ("", "/") or parts.query or parts.fragment:
        return "경로·쿼리·조각이 붙어 있음"
    return None


@dataclass(frozen=True)
class EmulatorSite:
    """검사를 통과한 한 사이트(에뮬레이터 하나). client()/resource() 가 그 사이트의 엔드포인트로 고정된다."""

    prefix: str
    endpoint: str | None  # opt-out(실제 AWS)일 때만 None
    session: Any  # boto3.Session

    def client(self, service_name: str, **kwargs: Any) -> Any:
        if self.endpoint is not None:
            kwargs.setdefault("endpoint_url", self.endpoint)
        return self.session.client(service_name, **kwargs)

    def resource(self, service_name: str, **kwargs: Any) -> Any:
        if self.endpoint is not None:
            kwargs.setdefault("endpoint_url", self.endpoint)
        return self.session.resource(service_name, **kwargs)


def _env(prefix: str, key: str) -> str:
    return os.environ.get(prefix + key, "")


def _stage1(prefix: str) -> dict[str, str]:
    """네트워크 없이 사이트 변수를 검사하고 값을 돌려준다."""
    hint = _DR_HINT if prefix else _HINT
    name = f"{prefix}AWS_ENDPOINT_URL"
    endpoint = _env(prefix, "AWS_ENDPOINT_URL")
    why = validate_endpoint(endpoint)
    if why:
        _fail(f"{name} 이 로컬 에뮬레이터(https://{_HOST}:<포트>)가 아닙니다: '{endpoint or '설정 안 됨'}' — {why}. "
              "이대로 실행하면 실제 AWS로 요청이 갈 수 있어 중단합니다.", hint)
    if not prefix:
        main_port = urlsplit(endpoint).port
        for key, value in os.environ.items():
            if key.startswith("AWS_ENDPOINT_URL_"):
                why = validate_endpoint(value)
                if why:
                    _fail(f"{key}={value} 가 에뮬레이터가 아닌 곳을 가리킵니다 — {why}. 중단합니다.", hint)
                # 같은 컴퓨터의 다른 에뮬레이터(다른 사람·에이전트의 포트)로 새는 것도 막는다.
                if urlsplit(value).port != main_port:
                    _fail(f"{key}={value} 의 포트가 AWS_ENDPOINT_URL({endpoint})과 다릅니다. "
                          "다른 에뮬레이터로 요청이 갈 수 있어 중단합니다.", hint)
        if os.environ.get("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "").lower() == "true":
            _fail("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true 이면 엔드포인트 설정이 무시됩니다. 중단합니다.", hint)
    values = {k: _env(prefix, k) for k in _SITE_KEYS}
    if prefix:
        missing = [prefix + k for k, v in values.items() if not v]
        if missing:
            _fail(f"{', '.join(missing)} 가 없습니다.", hint)
        port = urlsplit(endpoint).port
        primary = os.environ.get("AWS_ENDPOINT_URL", "")
        if primary and validate_endpoint(primary) is None and urlsplit(primary).port == port:
            _fail(f"{prefix} 사이트의 포트({port})가 주 사이트와 같습니다. 서로 다른 에뮬레이터여야 합니다.", hint)
    return values


def _build_session(prefix: str, values: dict[str, str]) -> Any:
    import boto3
    import botocore.session

    if not prefix:
        # 주 사이트: boto3 기본 동작(환경 변수)과 같은 세션. CA는 AWS_CA_BUNDLE 이 이미 가리킨다.
        return boto3.Session()
    # 접두사 사이트: 이 사이트의 파일만 쓰도록 명시한다. 환경 변수(AWS_*)보다 우선한다.
    creds = configparser.ConfigParser()
    if not creds.read(values["AWS_SHARED_CREDENTIALS_FILE"]) or "default" not in creds:
        _fail(f"{prefix}AWS_SHARED_CREDENTIALS_FILE({values['AWS_SHARED_CREDENTIALS_FILE']})를 읽을 수 없습니다.", _DR_HINT)
    bs = botocore.session.Session()
    bs.set_config_variable("ca_bundle", values["AWS_CA_BUNDLE"])
    bs.set_config_variable("config_file", values["AWS_CONFIG_FILE"])
    bs.set_config_variable("credentials_file", values["AWS_SHARED_CREDENTIALS_FILE"])
    return boto3.Session(
        botocore_session=bs,
        aws_access_key_id=creds["default"].get("aws_access_key_id"),
        aws_secret_access_key=creds["default"].get("aws_secret_access_key"),
        region_name=os.environ.get(f"{prefix}AWS_REGION") or os.environ.get("AWS_REGION") or "us-east-1",
    )


def emulator_site(prefix: str = "", *, real_aws_region: str | None = None) -> EmulatorSite:
    """`{prefix}AWS_ENDPOINT_URL` 등의 변수로 정의된 사이트를 검사하고, 그 사이트로 고정된 클라이언트 공장을 돌려준다.

    prefix=""     : scripts/env.sh 의 AWS_* 변수 (주 사이트)
    prefix="DR_"  : scripts/dr-env.sh 의 DR_AWS_* 변수 (두 번째 에뮬레이터)
    real_aws_region: TODAYORDER_ALLOW_REAL_AWS=1 로 실제 AWS에서 실행할 때 쓸 리전 (에뮬레이터에서는 쓰지 않음).
                     opt-out 일 때는 prefix 와 무관하게 주 사이트의 환경(AWS_*)을 따른다.
    """
    if os.environ.get(OPT_OUT_ENV) == "1":
        import boto3

        print(f"[emulator_guard] 경고: {OPT_OUT_ENV}=1 — {prefix or '주'} 사이트의 에뮬레이터 확인을 건너뜁니다. "
              "실제 AWS 계정에 요청이 갈 수 있고 요금이 나올 수 있습니다.", file=sys.stderr)
        return EmulatorSite(prefix, None, boto3.Session(region_name=real_aws_region))

    values = _stage1(prefix)
    endpoint = values["AWS_ENDPOINT_URL"]
    session = _build_session(prefix, values)
    site = EmulatorSite(prefix, endpoint, session)

    # 2단계: 이 사이트로만 STS 한 번
    from botocore.config import Config

    try:
        account = site.client(
            "sts", config=Config(retries={"max_attempts": 1}, connect_timeout=3, read_timeout=10)
        ).get_caller_identity()["Account"]
    except Exception as e:  # noqa: BLE001 - 어떤 실패든 안전하게 중단
        code = getattr(e, "response", {}).get("Error", {}).get("Code", "") if hasattr(e, "response") else ""
        hint = "scripts/emulator-status.sh 로 에뮬레이터가 떠 있는지 확인하세요."
        if code in ("SignatureDoesNotMatch", "RequestTimeTooSkewed", "InvalidSignatureException"):
            hint = ("서명이 거부됐습니다. 노트북이 잠든 뒤 Colima VM 시계가 어긋났을 수 있습니다 "
                    "(M00 레슨 3 '문제 해결'의 시계 어긋남 참고).")
        _fail(f"{prefix or '주'} 사이트 에뮬레이터({endpoint})에 연결하지 못했습니다: {type(e).__name__}: {e}", hint)
    if account != EMULATOR_ACCOUNT:
        _fail(f"계정이 {EMULATOR_ACCOUNT} 이 아닙니다({account}). 실제 AWS일 수 있어 중단합니다.", _DR_HINT if prefix else _HINT)
    return site


def require_emulator(prefix: str = "") -> str:
    """사이트가 에뮬레이터가 아니면 프로그램을 종료한다. 통과하면 엔드포인트 URL을 돌려준다(opt-out이면 '').

    주 사이트는 이후 평소처럼 boto3.client(...) 를 쓰면 된다. 접두사 사이트(prefix="DR_")는
    환경 변수가 boto3 기본 이름이 아니므로 emulator_site(prefix).client(...) 를 쓴다.
    """
    return emulator_site(prefix).endpoint or ""
