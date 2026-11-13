"""외부 호스트 정적 검사 — 탐침·스크립트·실습 코드가 바깥 호스트를 가리키지 않는지 확인한다.

에뮬레이터는 받은 이미지 주소·URL·구독 엔드포인트를 실제로 따라갈 수 있다
(예: ECS 작업 정의의 이미지를 pull 하려 함). 그래서 코드가 "주소 자리"에 쓰는 호스트는
RFC 2606/6761 예약 이름(.invalid, .test, .example, .localhost)이나 루프백·문서용 IP 뿐이어야 한다.

검사하는 자리
  url    : http(s)/ws(s)/ftp:// 뒤의 호스트
  image  : image / imageUri / ImageUri / --image(-uri) / Dockerfile FROM 값의 레지스트리.
           레지스트리가 없는 이름(nginx:latest)은 Docker Hub 로 가므로 걸린다
  host   : Endpoint / endpoint_url / Issuer / IntegrationUri / FullyQualifiedDomainName 같은
           주소 키에 스킴 없이 들어간 호스트
  email  : 메일 주소의 도메인 (example.com 류는 null MX 라 허용)
  known  : public.ecr.aws, docker.io, ghcr.io, quay.io, gcr.io 는 어디에 있든

같은 줄이나 바로 윗줄 주석에 `external-host-ok: <이유>` 가 있으면 의도된 것으로 보고 건너뛴다
(예: 가드 자체 시험에서 "거부돼야 하는" 실제 AWS 주소, 설치 안내 링크).
Markdown 은 코드 블록(```) 안만 검사한다. 본문의 문서 링크는 학습자가 브라우저로 여는 것이다.

사용법 (저장소 루트에서):
    uv run python tools/probe/no_external_hosts.py                 # 기본 범위, 위반 시 종료 코드 1
    uv run python tools/probe/no_external_hosts.py curriculum      # 경로 지정
    uv run python tools/probe/no_external_hosts.py --report curriculum  # 목록만, 실패하지 않음
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PATHS = ["tools", "scripts", "src", "curriculum/m00-orientation"]
PROBE_PATHS = ["tools/probe"]
SUFFIXES = {".py", ".sh", ".bash", ".zsh", ".json", ".yaml", ".yml", ".toml", ".md", ".txt", ".tf", ".cfg", ".ini", ""}
SKIP_NAMES = {"results.json", "uv.lock"}
SKIP_DIRS = {".git", ".venv", "__pycache__", "node_modules", ".worktrees"}
MARKER = "external-host-ok"

RESERVED_TLDS = (".invalid", ".test", ".example", ".localhost", ".internal")
EMAIL_OK = ("example.com", "example.net", "example.org")
DOC_NETS = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "::1/128", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
KNOWN = re.compile(r"(?i)\b(public\.ecr\.aws|registry-1\.docker\.io|docker\.io|ghcr\.io|quay\.io|gcr\.io|registry\.k8s\.io)\b")

URL = re.compile(r"(?i)\b(?:https?|wss?|ftp)://([^/\s\"'`)<>\]|,;]+)")
IMAGE = re.compile(
    r"(?i)(?:[\"']?\b(?:image|image_?uri)\b[\"']?\s*[:=]\s*|--image(?:-uri)?(?:\s+|=))"
    r"[\"']?([^\s\"',}\)]+)")
DOCKER_FROM = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)")
HOSTKEY = re.compile(
    r"(?i)[\"']?\b(endpoint(?:_url|-url|url)?|issuer|integration_?uri|fullyqualifieddomainname|hostname|"
    r"--endpoint-url|--issuer|--integration-uri)\b[\"']?\s*[:= ]\s*[\"']?([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:(?-i:[a-z]{2,})|\d+))(?=[:/\"'\s,)}]|$)")
EMAIL = re.compile(r"\b[\w.+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\b")


@dataclass
class Hit:
    path: str
    line: int
    kind: str
    value: str
    text: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: [{self.kind}] {self.value}  |  {self.text.strip()[:140]}"


def _dynamic(s: str) -> bool:
    return any(c in s for c in "{}$<>%")


def host_ok(host: str) -> bool:
    h = host.strip().lower()
    if "@" in h:
        h = h.rsplit("@", 1)[1]
    if h.endswith(("-", ".")) and h.count(".") <= 1:
        return True  # "https://cognito-idp." 같은 접두어 비교용 조각
    h = h.rstrip(".")
    if h.startswith("["):
        h = h[1:].split("]", 1)[0]
    elif h.count(":") == 1:
        h = h.split(":", 1)[0]
    if not h or _dynamic(h) or h == "localhost":
        return True
    try:
        ip = ipaddress.ip_address(h)
        return any(ip in n for n in DOC_NETS)
    except ValueError:
        pass
    if re.fullmatch(r"0x[0-9a-f]+(\.\d+)*|\d+", h):  # 0x7f.0.0.1 같은 변형 표기
        return False
    return h.endswith(RESERVED_TLDS)


def image_registry(ref: str) -> str | None:
    """이미지 참조의 레지스트리 호스트. 레지스트리가 없으면 'docker.io(기본)'."""
    ref = ref.strip().strip("\"'")
    if _dynamic(ref) or ref.lower() in {"scratch"} or ref.startswith("sha256:"):
        return None
    first = ref.split("/", 1)[0]
    if "/" in ref and ("." in first or ":" in first or first == "localhost"):
        return first
    return "docker.io(기본)"


def scan_text(path: str, text: str) -> list[Hit]:
    hits: list[Hit] = []
    is_md = path.endswith(".md")
    in_code = False
    skip_block = False
    lines = text.splitlines()
    for no, line in enumerate(lines, 1):
        if is_md and line.lstrip().startswith("```"):
            in_code = not in_code
            skip_block = in_code and line.strip().lower() == "```mermaid"  # 그림은 코드가 아니다
            continue
        if is_md and (not in_code or skip_block):
            continue
        if MARKER in line or (no > 1 and MARKER in lines[no - 2] and lines[no - 2].lstrip().startswith("#")):
            continue
        urls = list(URL.finditer(line))
        for m in urls:
            if re.search(r"xmlns(:\w+)?=[\"']?$", line[:m.start()]):
                continue  # XML 이름공간은 주소가 아니라 식별자다
            if line[m.end():m.end() + 1] in tuple("<{$%"):
                continue  # 런타임에 채우는 호스트 (예: https://cognito-idp.<리전>...)
            if not host_ok(m.group(1)):
                hits.append(Hit(path, no, "url", m.group(1), line))
        images = list(IMAGE.finditer(line))
        if Path(path).name == "Dockerfile":
            images += list(DOCKER_FROM.finditer(line))
        for m in images:
            reg = image_registry(m.group(1))
            if reg and (reg.startswith("docker.io") or not host_ok(reg)):
                hits.append(Hit(path, no, "image", f"{m.group(1)} → {reg}", line))
        for m in HOSTKEY.finditer(line):
            if not host_ok(m.group(2)) and "://" not in line[m.start():m.end() + 3]:
                hits.append(Hit(path, no, "host", m.group(2), line))
        for m in EMAIL.finditer(line):
            if any(u.start() <= m.start() < u.end() for u in urls):
                continue  # URL 의 userinfo 는 url 검사가 다룬다
            d = m.group(1).lower()
            if not (host_ok(d) or d in EMAIL_OK or d.endswith(tuple("." + e for e in EMAIL_OK))):
                hits.append(Hit(path, no, "email", m.group(0), line))
        for m in KNOWN.finditer(line):
            if not any(h.line == no and m.group(1).lower() in h.value.lower() for h in hits):
                hits.append(Hit(path, no, "known", m.group(1), line))
    return hits


def iter_files(paths: list[str]):
    for p in paths:
        base = (ROOT / p) if not Path(p).is_absolute() else Path(p)
        if base.is_file():
            yield base
            continue
        for f in sorted(base.rglob("*")):
            if f.is_file() and f.name not in SKIP_NAMES and f.suffix in SUFFIXES \
                    and not any(part in SKIP_DIRS for part in f.relative_to(ROOT).parts):
                if f.suffix == "" and f.name != "Dockerfile":
                    continue
                yield f


def scan(paths: list[str]) -> list[Hit]:
    hits: list[Hit] = []
    for f in iter_files(paths):
        if f.resolve() == Path(__file__).resolve():
            continue  # 이 파일의 패턴 설명 자체는 대상이 아니다
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        hits.extend(scan_text(str(f.relative_to(ROOT)), text))
    return hits


# 검사기 자체 시험: 이 표본들이 걸리지 않으면 검사기가 망가진 것이다.
BAD_SAMPLES = [
    'containerDefinitions=[{"name": "api", "image": "public.ecr.aws/nginx/nginx:latest"}]',
    '{"image": "nginx:latest"}',
    'image: ghcr.io/org/app:1',
    'aws ecs register-task-definition --image docker.io/library/nginx',
    'ImageUri="123456789012.dkr.ecr.us-east-1.amazonaws.com/app:1"',
    'sns.subscribe(Protocol="https", Endpoint="https://example.com/hook")',
    'IntegrationUri="https://api.todayorder.com/orders"',
    '"Issuer": "https://cognito-idp.us-east-1.amazonaws.com/pool"',
    'aws s3 ls --endpoint-url s3.amazonaws.com',
    'endpoint_url="https://127.0.0.1:9297@s3.amazonaws.com"',
    'Endpoint="ops@todayorder.com"',
]
GOOD_SAMPLES = [
    '{"image": "registry.invalid/todayorder/nginx:latest"}',
    'Endpoint="https://hook.todayorder.invalid/sns"',
    'endpoint_url="https://127.0.0.1:9297"',
    'Principal={"Service": "lambda.amazonaws.com"}',
    'Endpoint="dev@example.com"',
    'curl http://{dns}/hello',
]


def selftest() -> list[str]:
    errs = [f"걸러야 하는데 통과: {s}" for s in BAD_SAMPLES if not scan_text("selftest.py", s)]
    errs += [f"통과해야 하는데 걸림: {s} → {scan_text('selftest.py', s)[0].value}"
             for s in GOOD_SAMPLES if scan_text("selftest.py", s)]
    return errs


def check_or_exit(paths: list[str] | None = None) -> None:
    """탐침 시작 시 호출. 검사기 자체 시험 후, 위반이 있으면 목록을 찍고 종료한다."""
    errs = selftest()
    if errs:
        raise SystemExit("외부 호스트 검사기 자체 시험 실패:\n  " + "\n  ".join(errs))
    hits = scan(paths or PROBE_PATHS)
    if hits:
        print("외부 호스트 정적 검사 실패 — 탐침 코드가 바깥 주소를 가리킨다:", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        print(f"예약 이름(.invalid 등)으로 바꾸거나, 의도된 것이면 같은 줄에 '{MARKER}: <이유>' 를 단다.", file=sys.stderr)
        raise SystemExit(2)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help=f"검사할 경로 (기본: {' '.join(DEFAULT_PATHS)})")
    ap.add_argument("--report", action="store_true", help="목록만 출력하고 실패하지 않는다")
    args = ap.parse_args()
    errs = selftest()
    if errs:
        print("검사기 자체 시험 실패:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 2
    hits = scan(args.paths or DEFAULT_PATHS)
    for h in hits:
        print(h)
    print(f"외부 호스트 정적 검사: {len(hits)}건", file=sys.stderr)
    return 0 if (args.report or not hits) else 1


if __name__ == "__main__":
    raise SystemExit(main())
