"""탐침(probe) 공용 프레임워크.

각 checks_*.py 모듈은 `CHECKS: dict[str, Callable[[Probe], None]]` 를 노출한다.
키는 서비스 이름(보고서의 행), 값은 그 서비스를 탐침하는 함수다.

결과 상태
- OK            : 호출이 성공했다
- NOT_IMPL      : HTTP 501 / NotImplemented
- ERROR         : 그 밖의 오류 (코드와 메시지를 기록)
- BEHAVIOR_OK   : 동작(전달·차단·상태 전이 등)이 실제처럼 관찰됐다
- BEHAVIOR_DIFF : 호출은 됐지만 동작이 실제 AWS와 다르다 (note에 무엇이 다른지)
- SKIP          : 선행 단계 실패 등으로 시도하지 못했다
"""

from __future__ import annotations

import ipaddress
import os
import ssl
import subprocess
import time
import urllib.error
import urllib.request
import traceback
import uuid
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from typing import Any, Callable, Iterator

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

OK = "OK"
NOT_IMPL = "NOT_IMPL"
ERROR = "ERROR"
BEHAVIOR_OK = "BEHAVIOR_OK"
BEHAVIOR_DIFF = "BEHAVIOR_DIFF"
SKIP = "SKIP"

_CFG = Config(
    retries={"max_attempts": 1, "mode": "standard"},
    connect_timeout=5,
    read_timeout=30,
)


@dataclass
class Result:
    service: str
    kind: str  # "api" | "behavior"
    name: str  # 오퍼레이션명 또는 동작 설명
    status: str
    detail: str = ""
    elapsed_ms: int = 0


@dataclass
class Probe:
    results: list[Result] = field(default_factory=list)
    suffix: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    verbose: bool = True
    _clients: dict[str, Any] = field(default_factory=dict)
    _cleanups: list[tuple[str, Callable[[], Any]]] = field(default_factory=list)
    current_service: str = "?"

    # ---------- 클라이언트 ----------
    def client(self, name: str) -> Any:
        if name not in self._clients:
            self._clients[name] = boto3.client(name, config=_CFG)
        return self._clients[name]

    def name(self, base: str) -> str:
        """실행마다 겹치지 않는 리소스 이름 (todayorder-probe-<base>-<suffix>)."""
        return f"todayorder-probe-{base}-{self.suffix}"

    # ---------- 기록 ----------
    def _record(self, r: Result) -> None:
        self.results.append(r)
        if self.verbose:
            mark = {
                OK: "ok ",
                NOT_IMPL: "501",
                ERROR: "ERR",
                BEHAVIOR_OK: "B+ ",
                BEHAVIOR_DIFF: "B- ",
                SKIP: "skp",
            }[r.status]
            d = f"  {r.detail}" if r.detail else ""
            print(f"  [{mark}] {r.service:<16} {r.name}{d}"[:300], flush=True)

    def call(self, op: str, fn: Callable[..., Any], *args: Any, note: str = "", **kwargs: Any) -> Any:
        """API 하나를 호출하고 결과를 기록한다. 성공하면 응답, 실패하면 None."""
        t0 = time.monotonic()
        try:
            resp = fn(*args, **kwargs)
        except ClientError as e:
            ms = int((time.monotonic() - t0) * 1000)
            err = e.response.get("Error", {})
            code = err.get("Code", "?")
            msg = (err.get("Message") or "").replace("\n", " ")[:200]
            http = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            status = NOT_IMPL if (http == 501 or code == "NotImplemented") else ERROR
            self._record(Result(self.current_service, "api", op, status, f"HTTP {http} {code}: {msg}", ms))
            return None
        except (BotoCoreError, Exception) as e:  # noqa: BLE001 - 탐침은 모든 실패를 기록해야 한다
            ms = int((time.monotonic() - t0) * 1000)
            self._record(Result(self.current_service, "api", op, ERROR, f"{type(e).__name__}: {str(e)[:200]}", ms))
            return None
        ms = int((time.monotonic() - t0) * 1000)
        self._record(Result(self.current_service, "api", op, OK, note, ms))
        return resp if resp is not None else {}

    def expect_error(self, op: str, fn: Callable[..., Any], expected_code: str, *args: Any, what: str = "", **kwargs: Any) -> str | None:
        """실패해야 정상인 호출(검증 오류, 조건부 쓰기 실패 등). 동작 결과로 기록한다."""
        label = what or f"{op} → {expected_code} 기대"
        try:
            fn(*args, **kwargs)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "?")
            msg = (e.response.get("Error", {}).get("Message") or "")[:160]
            http = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            if http == 501 or code == "NotImplemented":
                self._record(Result(self.current_service, "behavior", label, NOT_IMPL, f"HTTP 501 {code}"))
            elif code == expected_code:
                self._record(Result(self.current_service, "behavior", label, BEHAVIOR_OK, f"{code}: {msg}"))
            else:
                self._record(Result(self.current_service, "behavior", label, BEHAVIOR_DIFF, f"기대 {expected_code}, 실제 {code}: {msg}"))
            return code
        except Exception as e:  # noqa: BLE001
            self._record(Result(self.current_service, "behavior", label, ERROR, f"{type(e).__name__}: {str(e)[:160]}"))
            return None
        self._record(Result(self.current_service, "behavior", label, BEHAVIOR_DIFF, f"기대 {expected_code}, 실제로는 성공했다"))
        return None

    def behavior(self, name: str, ok: bool, detail: str = "") -> bool:
        self._record(Result(self.current_service, "behavior", name, BEHAVIOR_OK if ok else BEHAVIOR_DIFF, detail))
        return ok

    def skip(self, name: str, reason: str) -> None:
        self._record(Result(self.current_service, "behavior", name, SKIP, reason))

    def target_ok(self, name: str, target: str) -> bool:
        """접속 전에 부른다. 대상이 루프백 IP 리터럴이 아니면 그 행을 SKIP 으로 남기고 False.

        에뮬레이터가 돌려준 주소(RDS·ElastiCache 엔드포인트, ALB DNSName 등)는 실제 AWS 형식의
        이름일 수 있다. 그런 이름으로 접속하면 이름 해석만으로도 바깥 DNS 에 질의가 나간다.
        """
        if loopback_host(target) is not None:
            return True
        self.skip(name, f"외부 이름이라 접속 생략: {target}")
        return False

    # ---------- 정리 ----------
    def cleanup(self, label: str, fn: Callable[[], Any]) -> None:
        """서비스 탐침이 끝나면(성공/실패 무관) 역순으로 실행할 정리 작업을 등록한다."""
        self._cleanups.append((label, fn))

    def _run_cleanups(self) -> None:
        while self._cleanups:
            _label, fn = self._cleanups.pop()
            try:
                fn()
            except Exception:  # noqa: BLE001 - 정리 실패는 무시 (깨끗한 에뮬레이터 권장)
                pass

    @contextmanager
    def service(self, name: str) -> Iterator[None]:
        self.current_service = name
        # 서비스마다 새 접미사: 여러 checks 모듈이 같은 기본 이름(p.name("acl") 등)을 써도 충돌하지 않게
        self.suffix = uuid.uuid4().hex[:8]
        if self.verbose:
            print(f"== {name}", flush=True)
        try:
            yield
        except Exception as e:  # noqa: BLE001
            tb = traceback.format_exc(limit=2).replace("\n", " | ")
            self._record(Result(name, "behavior", "탐침 코드 예외(중단)", ERROR, f"{type(e).__name__}: {e} :: {tb}"[:300]))
        finally:
            self._run_cleanups()

    def to_dicts(self) -> list[dict[str, Any]]:
        return [asdict(r) for r in self.results]


def wait_until(pred: Callable[[], bool], timeout: float = 10.0, interval: float = 0.5) -> bool:
    """pred() 가 True 가 될 때까지 기다린다. 예외는 False 로 취급."""
    end = time.monotonic() + timeout
    while True:
        try:
            if pred():
                return True
        except Exception:  # noqa: BLE001
            pass
        if time.monotonic() >= end:
            return False
        time.sleep(interval)


def assert_emulator() -> str:
    """실제 AWS로 나가는 것을 막는 안전 장치. env.sh 를 source 하지 않았으면 중단한다."""
    ep = os.environ.get("AWS_ENDPOINT_URL", "")
    if not ep.startswith("https://127.0.0.1:"):
        raise SystemExit("AWS_ENDPOINT_URL 이 로컬 에뮬레이터가 아닙니다. 먼저 `source scripts/env.sh` 를 실행하세요.")
    acct = boto3.client("sts", config=_CFG).get_caller_identity()["Account"]
    if acct != "000000000000":
        raise SystemExit(f"계정이 000000000000 이 아닙니다({acct}). 중단합니다.")
    return ep


# ---------------------------------------------------------------- 접속 관문
# 탐침이 직접 여는 모든 연결(호스트의 TCP·HTTPS·curl, 컨테이너 안의 TCP·curl)은 아래 함수만 쓴다.
# 대상 호스트가 루프백 IP 리터럴(127.0.0.0/8, ::1)이 아니면 연결하지 않고 ExternalTarget 을 던진다.
# 이름 해석 자체가 바깥으로 나가는 요청이므로 "localhost" 같은 이름도 받지 않는다.

class ExternalTarget(Exception):
    """루프백이 아닌 대상으로 접속하려 했다."""


def loopback_host(target: str) -> str | None:
    """'127.0.0.1', '127.0.0.1:80', 'http://127.0.0.1:80/x', '[::1]:5' 에서 루프백 IP 를 꺼낸다. 아니면 None."""
    t = (target or "").strip()
    if "://" in t:
        t = t.split("://", 1)[1]
    t = t.split("/", 1)[0].split("?", 1)[0]
    if "@" in t:
        return None  # userinfo 로 호스트를 숨기는 형태는 받지 않는다
    if t.startswith("["):
        host = t[1:].split("]", 1)[0]
    elif t.count(":") == 1:
        host = t.split(":", 1)[0]
    else:
        host = t
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return None
    return host if ip.is_loopback else None


def require_loopback(target: str) -> str:
    host = loopback_host(target)
    if host is None:
        raise ExternalTarget(f"루프백이 아닌 대상에는 접속하지 않는다: {target}")
    return host


def container() -> str:
    return f"aws-emulator-{os.environ.get('EMULATOR_PORT', '9297')}"


def container_tcp(host: str, port: int, send: str = "", read_bytes: int = 0) -> str:
    """에뮬레이터 컨테이너 안에서 host:port 로 TCP 연결(bash /dev/tcp). send 가 있으면 보내고 read_bytes 만큼 읽는다.

    send 가 없으면 'OPEN'/'CLOSED', 있으면 읽은 내용을 돌려준다.
    """
    require_loopback(host)
    port = int(port)
    if send:
        cmd = f"exec 3<>/dev/tcp/{host}/{port}; printf '{send}' >&3; timeout 2 head -c {read_bytes} <&3"
    else:
        cmd = f"timeout 3 bash -c 'exec 3<>/dev/tcp/{host}/{port}' && echo OPEN || echo CLOSED"
    try:
        r = subprocess.run(["docker", "exec", container(), "bash", "-c", cmd], capture_output=True, text=True, timeout=15)
    except Exception as e:  # noqa: BLE001
        return type(e).__name__
    return r.stdout if send else (r.stdout.strip() or r.stderr.strip())[:60]


def container_curl(url: str, *curl_args: str, timeout: int = 5) -> subprocess.CompletedProcess[str]:
    """에뮬레이터 컨테이너 안에서 curl. 리디렉션은 따라가지 않는다(-L 금지)."""
    require_loopback(url)
    if any(a in ("-L", "--location") for a in curl_args):
        raise ExternalTarget("리디렉션을 따라가면 바깥 주소로 갈 수 있다")
    return subprocess.run(["docker", "exec", container(), "curl", "-s", "-m", str(timeout), *curl_args, url],
                          capture_output=True, text=True, timeout=timeout + 15)


def host_tcp(host: str, port: int, timeout: float = 2.0) -> str:
    """호스트(이 컴퓨터)에서 TCP 연결. 'OPEN' 또는 예외 이름."""
    import socket

    require_loopback(host)
    try:
        socket.create_connection((host, int(port)), timeout=timeout).close()
        return "OPEN"
    except Exception as e:  # noqa: BLE001
        return type(e).__name__


def host_curl(url: str, *curl_args: str, timeout: int = 20) -> subprocess.CompletedProcess[str]:
    """호스트에서 curl (에뮬레이터 CA 사용). 리디렉션은 따라가지 않는다."""
    require_loopback(url)
    if any(a in ("-L", "--location") for a in curl_args):
        raise ExternalTarget("리디렉션을 따라가면 바깥 주소로 갈 수 있다")
    return subprocess.run(["curl", "-s", "--cacert", os.environ["AWS_CA_BUNDLE"], *curl_args, url],
                          capture_output=True, text=True, timeout=timeout)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a: Any, **k: Any) -> None:  # noqa: D401
        return None


def host_https(url: str, method: str = "GET", body: bytes | None = None,
               headers: dict[str, str] | None = None) -> tuple[int, str]:
    """호스트에서 HTTPS 요청(에뮬레이터 CA). 리디렉션은 따라가지 않는다."""
    require_loopback(url)
    ctx = ssl.create_default_context(cafile=os.environ["AWS_CA_BUNDLE"])
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), _NoRedirect)
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with opener.open(req, timeout=10) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
