"""emulator_guard 자체 시험.

    uv run python -m emulator_guard.selftest            # 오프라인 시험만 (네트워크 호출 없음)
    uv run python -m emulator_guard.selftest --live     # + 지금 셸의 에뮬레이터(env.sh)로 실제 확인
                                                        #   DR_AWS_* 가 있으면(dr-env.sh) 두 번째 사이트도

오프라인 시험은 하위 프로세스를 더미 키·/dev/null 설정·닫힌 포트 프록시로 실행해서, 가드가
**네트워크 호출 전에** 종료하는지 확인한다. 모든 시험이 통과하면 'SELFTEST OK' 를 출력하고 0으로 끝난다.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid

from emulator_guard import validate_endpoint

ACCEPT = [
    "https://127.0.0.1:9297",
    "https://127.0.0.1:9297/",
    "https://127.0.0.1:1024",
]
REJECT = [
    "",
    "http://127.0.0.1:9297",
    "https://localhost:9297",
    "https://127.0.0.1",
    "https://127.0.0.1:",
    "https://127.0.0.1:abc",
    "https://127.0.0.1:99999",
    "https://127.0.0.1:09297",
    "https://127.0.0.1:9320@s3.amazonaws.com",
    "https://user:pw@127.0.0.1:9297",
    "https://127.0.0.1:9297\\@s3.amazonaws.com",
    "https://127.0.0.10:9297",
    "https://127.0.0.1.nip.io:9297",
    "https://0x7f.0.0.1:9297",
    "https://[::1]:9297",
    "https://127.0.0.1:9297/path",
    "https://127.0.0.1:9297?x=1",
    "https://127.0.0.1:9297#frag",
    "https://s3.amazonaws.com",
]

# 네트워크로 나가려 하면 즉시 실패하도록 하는 환경 (실제 키 없음, 사용자 ~/.aws 를 읽지 않음)
_OFFLINE = {
    "AWS_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
    "AWS_SECRET_ACCESS_KEY": "dummy-not-a-real-key",
    "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
    "AWS_CONFIG_FILE": "/dev/null",
    "AWS_EC2_METADATA_DISABLED": "true",
    "AWS_REGION": "us-east-1",
    "HTTPS_PROXY": "http://127.0.0.1:9",
    "HTTP_PROXY": "http://127.0.0.1:9",
    "NO_PROXY": "",
}

failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def run_guard(code: str, env_extra: dict[str, str]) -> tuple[int, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("AWS_", "DR_AWS_", "TODAYORDER_"))}
    env.update(_OFFLINE)
    env.update(env_extra)
    p = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout + p.stderr


def offline() -> None:
    for url in ACCEPT:
        check(f"URL 허용: {url}", validate_endpoint(url) is None, str(validate_endpoint(url)))
    for url in REJECT:
        check(f"URL 거부: {url or '(빈 값)'}", validate_endpoint(url) is not None)

    stage1 = "[emulator_guard] "
    cases = [
        ("AWS_ENDPOINT_URL 없음 → 네트워크 전 거부",
         "from emulator_guard import require_emulator; require_emulator()", {}),
        ("userinfo 우회(https://127.0.0.1:9320@s3.amazonaws.com) → 네트워크 전 거부",
         "from emulator_guard import require_emulator; require_emulator()",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9320@s3.amazonaws.com"}),
        ("서비스별 AWS_ENDPOINT_URL_S3 이 실제 AWS → 네트워크 전 거부",
         "from emulator_guard import require_emulator; require_emulator()",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9297", "AWS_ENDPOINT_URL_S3": "https://s3.amazonaws.com"}),
        ("서비스별 AWS_ENDPOINT_URL_S3 이 다른 로컬 포트(다른 에뮬레이터) → 네트워크 전 거부",
         "from emulator_guard import require_emulator; require_emulator()",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9297", "AWS_ENDPOINT_URL_S3": "https://127.0.0.1:9302"}),
        ("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true → 네트워크 전 거부",
         "from emulator_guard import require_emulator; require_emulator()",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9297", "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true"}),
        ("두 번째 사이트: DR_AWS_* 없음 → 네트워크 전 거부",
         "from emulator_guard import emulator_site; emulator_site('DR_')",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9297"}),
        ("두 번째 사이트: DR 엔드포인트가 실제 AWS → 네트워크 전 거부",
         "from emulator_guard import emulator_site; emulator_site('DR_')",
         {"DR_AWS_ENDPOINT_URL": "https://dynamodb.ap-northeast-1.amazonaws.com", "DR_AWS_CA_BUNDLE": "/dev/null",
          "DR_AWS_SHARED_CREDENTIALS_FILE": "/dev/null", "DR_AWS_CONFIG_FILE": "/dev/null"}),
        ("두 번째 사이트: 주 사이트와 같은 포트 → 네트워크 전 거부",
         "from emulator_guard import emulator_site; emulator_site('DR_')",
         {"AWS_ENDPOINT_URL": "https://127.0.0.1:9297", "DR_AWS_ENDPOINT_URL": "https://127.0.0.1:9297",
          "DR_AWS_CA_BUNDLE": "/dev/null", "DR_AWS_SHARED_CREDENTIALS_FILE": "/dev/null", "DR_AWS_CONFIG_FILE": "/dev/null"}),
    ]
    for name, code, extra in cases:
        rc, out = run_guard(code, extra)
        ok = (rc == 1 and out.startswith(stage1) and "Traceback" not in out and "연결하지 못했습니다" not in out)
        check(name, ok, f"rc={rc} out={out.strip()[:160]}")

    # 1단계를 통과하면 2단계(STS)를 시도한다 — 그 시도는 닫힌 프록시에서 실패해야 하며 Traceback 없이 거부.
    rc, out = run_guard("from emulator_guard import require_emulator; require_emulator()",
                        {"AWS_ENDPOINT_URL": "https://127.0.0.1:9", "NO_PROXY": ""})
    check("1단계 통과 후 연결 실패 → Traceback 없이 종료 코드 1", rc == 1 and "Traceback" not in out, out.strip()[:160])

    # opt-out: 검사를 건너뛰고 경고만 (네트워크 호출 없음 — 클라이언트를 만들기만 한다)
    rc, out = run_guard(
        "from emulator_guard import emulator_site; s = emulator_site('DR_', real_aws_region='ap-northeast-1');"
        "c = s.client('s3'); print('endpoint', s.endpoint, c.meta.region_name)",
        {"TODAYORDER_ALLOW_REAL_AWS": "1"})
    check("opt-out(TODAYORDER_ALLOW_REAL_AWS=1): 경고 후 real_aws_region 세션", rc == 0 and "경고" in out
          and "endpoint None ap-northeast-1" in out, out.strip()[:200])


def live() -> None:
    from emulator_guard import emulator_site, require_emulator

    ep = require_emulator()
    check("live: require_emulator() 통과", ep.startswith("https://127.0.0.1:"), ep)
    primary = emulator_site()
    bucket = f"todayorder-guardtest-{uuid.uuid4().hex[:8]}"
    s3p = primary.client("s3")
    s3p.create_bucket(Bucket=bucket)
    try:
        if not os.environ.get("DR_AWS_ENDPOINT_URL"):
            print("SKIP  live: 두 번째 사이트 (DR_AWS_* 없음 — scripts/dr-env.sh 를 source 하면 시험)")
            return
        dr = emulator_site("DR_")
        check("live: emulator_site('DR_') 통과, 다른 포트", dr.endpoint != primary.endpoint, f"{dr.endpoint}")
        names = [b["Name"] for b in dr.client("s3").list_buckets()["Buckets"]]
        check("live: 주 사이트에 만든 버킷이 두 번째 사이트에는 없음(상태 분리)", bucket not in names)
        who = dr.client("sts").get_caller_identity()["Account"]
        check("live: 두 번째 사이트 계정 000000000000", who == "000000000000", who)
    finally:
        s3p.delete_bucket(Bucket=bucket)


def main() -> int:
    offline()
    if "--live" in sys.argv:
        live()
    if failures:
        print(f"SELFTEST FAIL ({len(failures)}건)")
        return 1
    print("SELFTEST OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
