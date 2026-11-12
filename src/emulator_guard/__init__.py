"""boto3 예제용 안전 장치: 요청이 로컬 aws-emulator로만 가는지 확인한다.

모든 sdk 예제는 **클라이언트를 만들기 전에** 다음 두 줄을 실행한다.

    from emulator_guard import require_emulator
    require_emulator()

검사 순서
1. (네트워크 호출 없이) 환경 변수만 본다.
   - AWS_ENDPOINT_URL 이 https://127.0.0.1: 로 시작해야 한다.
   - 서비스별 덮어쓰기(AWS_ENDPOINT_URL_S3 등)가 있다면 그것도 127.0.0.1 이어야 한다.
   - AWS_IGNORE_CONFIGURED_ENDPOINT_URLS 가 켜져 있으면 안 된다.
   하나라도 어긋나면 한국어 안내를 출력하고 종료 코드 1로 끝낸다. 이 단계에서는
   어떤 AWS 요청도 보내지 않는다.
2. 그다음 STS GetCallerIdentity(에뮬레이터 엔드포인트로만)로 계정이 000000000000 인지 확인한다.

실제 AWS에서 같은 코드를 돌리고 싶을 때(학습자가 자기 계정에서 직접 해 볼 때)만
TODAYORDER_ALLOW_REAL_AWS=1 을 설정한다. 그러면 검사를 건너뛰고 경고만 출력한다.
기본값은 꺼짐이다. 이 저장소의 실습 스크립트와 verify.sh 는 이 변수를 절대 설정하지 않는다.
"""

from __future__ import annotations

import os
import sys

__all__ = ["require_emulator", "OPT_OUT_ENV", "EMULATOR_ACCOUNT"]

OPT_OUT_ENV = "TODAYORDER_ALLOW_REAL_AWS"
EMULATOR_ACCOUNT = "000000000000"
_LOCAL_PREFIX = "https://127.0.0.1:"


def _fail(msg: str, hint: str = "") -> None:
    print(f"[emulator_guard] {msg}", file=sys.stderr)
    if hint:
        print(f"                 {hint}", file=sys.stderr)
    raise SystemExit(1)


def require_emulator() -> str:
    """에뮬레이터가 아니면 프로그램을 종료한다. 통과하면 엔드포인트 URL을 돌려준다."""
    if os.environ.get(OPT_OUT_ENV) == "1":
        print(
            f"[emulator_guard] 경고: {OPT_OUT_ENV}=1 — 에뮬레이터 확인을 건너뜁니다. "
            "실제 AWS 계정에 요청이 갈 수 있고 요금이 나올 수 있습니다.",
            file=sys.stderr,
        )
        return os.environ.get("AWS_ENDPOINT_URL", "")

    hint = "먼저 저장소 루트에서 'source scripts/env.sh' 를 실행하세요 (에뮬레이터: scripts/emulator-up.sh)."
    endpoint = os.environ.get("AWS_ENDPOINT_URL", "")
    if not endpoint.startswith(_LOCAL_PREFIX):
        _fail(
            f"AWS_ENDPOINT_URL 이 로컬 에뮬레이터({_LOCAL_PREFIX}<포트>)가 아닙니다: '{endpoint or '설정 안 됨'}'. "
            "이대로 실행하면 실제 AWS로 요청이 갈 수 있어 중단합니다.",
            hint,
        )
    for key, value in os.environ.items():
        if key.startswith("AWS_ENDPOINT_URL_") and not value.startswith(_LOCAL_PREFIX):
            _fail(f"{key}={value} 가 에뮬레이터가 아닌 곳을 가리킵니다. 중단합니다.", hint)
    if os.environ.get("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "").lower() == "true":
        _fail("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true 이면 엔드포인트 설정이 무시됩니다. 중단합니다.", hint)

    # 여기서부터 네트워크 사용: 에뮬레이터 엔드포인트를 명시해 STS 한 번만 호출한다.
    import boto3
    from botocore.config import Config

    try:
        account = boto3.client(
            "sts",
            endpoint_url=endpoint,
            config=Config(retries={"max_attempts": 1}, connect_timeout=3, read_timeout=10),
        ).get_caller_identity()["Account"]
    except Exception as e:  # noqa: BLE001 - 어떤 실패든 안전하게 중단
        _fail(f"에뮬레이터({endpoint})에 연결하지 못했습니다: {type(e).__name__}: {e}",
              "scripts/emulator-status.sh 로 에뮬레이터가 떠 있는지 확인하세요.")
    if account != EMULATOR_ACCOUNT:
        _fail(f"계정이 {EMULATOR_ACCOUNT} 이 아닙니다({account}). 실제 AWS일 수 있어 중단합니다.", hint)
    return endpoint
