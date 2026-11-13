"""외부 호스트 정적 검사 — 탐침·스크립트·실습 코드가 바깥 호스트를 가리키지 않는지 확인한다.

에뮬레이터는 받은 이미지 주소·URL·구독 엔드포인트를 실제로 따라갈 수 있다
(예: ECS 작업 정의의 이미지를 pull 하려 함). 그래서 코드가 "주소 자리"에 쓰는 호스트는
RFC 2606/6761 예약 이름(.invalid, .test, .example, .localhost)이나 루프백·문서용 IP 뿐이어야 한다.

검사하는 자리
  url    : http(s)/ws(s)/ftp:// 뒤의 호스트
  image  : image / imageUri / ImageUri / --image(-uri) / Dockerfile FROM 값의 레지스트리.
           레지스트리가 없는 이름(nginx:latest)은 Docker Hub 로 가므로 걸린다
  host   : Endpoint / endpoint_url / Issuer / IntegrationUri / FullyQualifiedDomainName / ServerName /
           DomainName / DNSName / Value 같은 주소 키에 스킴 없이 들어간 호스트
  email  : 메일 주소의 도메인 (example.com 류는 null MX 라 허용)
  known  : public.ecr.aws, docker.io, ghcr.io, quay.io, gcr.io 는 어디에 있든
  fstr   : (Python) f-string 과 문자열 연결("a" + "b")의 리터럴 부분을 이어 붙인 결과에
           amazonaws.com 이나 예약되지 않은 공개 도메인(.com·.net·.io·.aws 등)이 보이면

예약 이름은 .invalid, .test, .example, .localhost 와 그 아래뿐이다. .internal 은 예약 목록에 없다
(GCP 메타데이터 서버처럼 실제로 해석되는 곳이 있다).

한계 — 이 검사는 소스 텍스트만 본다.
  - 실행 중에 API 응답에서 얻은 주소(예: ElastiCache 가 돌려주는 *.cache.amazonaws.com 엔드포인트)는
    볼 수 없다. 그런 주소로의 접속은 lib.py 의 접속 관문(루프백 IP 리터럴만 허용)이 막는다.
  - 변수에 나눠 담은 호스트, % 서식·str.format·join 으로 만든 이름, 셸 변수 확장("$h.amazonaws.com")은 놓친다.
  - 위 둘을 보완하려고 탐침은 컨테이너 DNS 를 막은 에뮬레이터(--no-dns)에서도 돌려 결과를 비교한다.

같은 줄이나 바로 윗줄 주석에 `external-host-ok: <이유>` 가 있으면 의도된 것으로 보고 건너뛴다
(예: 가드 자체 시험에서 "거부돼야 하는" 실제 AWS 주소, 설치 안내 링크).
Markdown 은 코드 블록(```) 안만 검사한다. 본문의 문서 링크는 학습자가 브라우저로 여는 것이다.
에뮬레이터가 실제로 돌려준 출력처럼 블록 안을 고칠 수 없으면, 여는 ``` 바로 윗줄에
`<!-- external-host-ok: <이유> -->` 를 달아 그 블록 전체를 건너뛴다(이유가 비어 있으면 무효).

기본 범위: tools, scripts, src, curriculum(M00~M14 전체). 탐침 시작 때는 탐침 코드(tools/probe)만 본다.

사용법 (저장소 루트에서):
    uv run python tools/probe/no_external_hosts.py                 # 기본 범위, 위반 시 종료 코드 1
    uv run python tools/probe/no_external_hosts.py curriculum/m08-dns-edge  # 경로 지정
    uv run python tools/probe/no_external_hosts.py --report curriculum  # 목록만, 실패하지 않음
"""

from __future__ import annotations

import argparse
import ast
import ipaddress
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PATHS = ["tools", "scripts", "src", "curriculum"]
PROBE_PATHS = ["tools/probe"]
SUFFIXES = {".py", ".sh", ".bash", ".zsh", ".json", ".yaml", ".yml", ".toml", ".md", ".txt", ".tf", ".cfg", ".ini", ""}
SKIP_NAMES = {"results.json", "uv.lock"}
SKIP_DIRS = {".git", ".venv", "__pycache__", "node_modules", ".worktrees"}
MARKER = "external-host-ok"
# Markdown 코드 블록 전체 표시: 여는 ``` 바로 윗줄의 HTML 주석 (렌더링되지 않으므로 실제 출력 블록을 고치지 않는다)
MD_BLOCK_MARKER = re.compile(r"^\s*<!--\s*" + MARKER + r":\s*\S.*-->\s*$")

RESERVED_TLDS = (".invalid", ".test", ".example", ".localhost")
EMAIL_OK = ("example.com", "example.net", "example.org")
DOC_NETS = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "::1/128", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
KNOWN = re.compile(r"(?i)\b(public\.ecr\.aws|registry-1\.docker\.io|docker\.io|ghcr\.io|quay\.io|gcr\.io|registry\.k8s\.io)\b")

URL = re.compile(r"(?i)\b(?:https?|wss?|ftp)://([^/\s\\\"'`)<>\]|,;]+)")
IMAGE = re.compile(
    r"(?i)(?:[\"']?\b(?:image|image_?uri)\b[\"']?\s*[:=]\s*|--image(?:-uri)?(?:\s+|=))"
    r"[\"']?([^\s\"',}\)]+)")
DOCKER_FROM = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)")
# 주소 키 값에서 호스트로 볼 꼬리: 예약 TLD 와 흔한 공개 TLD (t3.small 같은 값은 호스트로 보지 않는다)
TLDS = "invalid|test|example|localhost|com|net|org|io|aws|dev|app|co|cloud|ai|me|info|biz|kr|jp|us|uk|de|cn|xyz|site|tech|internal"
HOSTKEY = re.compile(
    r"(?i)\\?[\"']?\b(endpoint(?:_url|-url|url)?|issuer|integration_?uri|fullyqualifieddomainname|hostname|"
    r"servername|domainname|dnsname|value|--server-name|--domain-name|--dns-name|"
    r"--endpoint-url|--issuer|--integration-uri)\b\\?[\"']?\s*[:= ]\s*\\?[\"']?([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:(?-i:" + TLDS + r")|\d+))(?=[:/\\\"'\s,)}]|$)")
# 공개 도메인으로 보이는 꼬리. f-string·문자열 연결의 리터럴 부분에서 찾는다.
PUBLIC_SUFFIX = re.compile(
    r"(?i)(?<![\w-])(?:[a-z0-9{}-]+\.)+(?:amazonaws\.com|on\.aws|amazon\.com|cloudfront\.net|"
    r"(?:com|net|org|io|aws|dev|app|co|cloud|ai|me|info|biz|kr|jp|us|uk|de|cn|xyz|site|tech|internal))(?![\w-])")
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
            skip_block = in_code and (line.strip().lower() == "```mermaid"  # 그림은 코드가 아니다
                                      or (no > 1 and MD_BLOCK_MARKER.match(lines[no - 2]) is not None))
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
            v = m.group(2)
            if re.fullmatch(r"[\d.]+", v) and v.count(".") != 3:
                continue  # "Value": "5.0" 같은 숫자는 호스트가 아니다
            if not host_ok(v) and "://" not in line[m.start():m.end() + 3]:
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


def _literal_parts(node: ast.AST) -> str | None:
    """f-string 이나 문자열 연결이면 리터럴 부분을 '{}' 자리 표시로 이어 붙인 문자열, 아니면 None."""
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) and isinstance(v.value, str) else "{}" for v in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        parts = []
        for side in (node.left, node.right):
            if isinstance(side, ast.Constant) and isinstance(side.value, str):
                parts.append(side.value)
            else:
                sub = _literal_parts(side)
                if sub is None:
                    return None if not parts else "".join(parts) + "{}"
                parts.append(sub)
        return "".join(parts)
    return None


def scan_python(path: str, text: str) -> list[Hit]:
    """f-string·문자열 연결 안의 공개 도메인. 일반 문자열 상수(서비스 주체 등)는 보지 않는다."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    lines = text.splitlines()
    hits: list[Hit] = []
    seen: set[int] = set()
    for node in ast.walk(tree):
        joined = _literal_parts(node)
        if joined is None or id(node) in seen:
            continue
        for child in ast.walk(node):
            seen.add(id(child))  # 바깥 연결식만 한 번 본다
        no = getattr(node, "lineno", 0)
        line = lines[no - 1] if 0 < no <= len(lines) else ""
        if MARKER in line or (no > 1 and MARKER in lines[no - 2] and lines[no - 2].lstrip().startswith("#")):
            continue
        for m in list(PUBLIC_SUFFIX.finditer(joined)) + list(KNOWN.finditer(joined)):
            host = m.group(0)
            if not host_ok(host.replace("{}", "x")):
                hits.append(Hit(path, no, "fstr", host, line))
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
        rel = str(f.relative_to(ROOT))
        hits.extend(scan_text(rel, text))
        if f.suffix == ".py":
            have = {(h.line, h.kind) for h in hits}
            hits.extend(h for h in scan_python(rel, text) if (h.line, "url") not in have)
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
    'ServerName="db.todayorder.com"',
    '"Value": "metadata.google.internal"',
    # 셸 큰따옴표 문자열 안의 이스케이프된 JSON
    '--change-batch "{\\"ResourceRecords\\": [{\\"Value\\": \\"d111111abcdef8.cloudfront.net\\"}]}"',
    '\\"AliasTarget\\": {\\"HostedZoneId\\": \\"Z2FDTNDATAQYW2\\", \\"DNSName\\": \\"d111111abcdef8.cloudfront.net\\"}',
]
# Python 전용(f-string·문자열 연결)
BAD_PY_SAMPLES = [
    'x = f"{bucket}.s3.us-east-1.amazonaws.com"',
    'x = "s3." + "amazonaws.com"',
    'x = "public.ecr" + ".aws/nginx/nginx:latest"',
    'x = f"https://{svc}.amazonaws.com/path"',
    'x = f"todayorder-{s}.com"',
]
GOOD_PY_SAMPLES = [
    'x = f"{bucket}.s3.todayorder.invalid"',
    'x = f"http://{dns}/index.html"',
    'x = "lambda.amazonaws.com"',
    'x = f"arn:aws:s3:::{b}/*"',
    'x = f"{name}.json"',
]
GOOD_SAMPLES = [
    '{"image": "registry.invalid/todayorder/nginx:latest"}',
    'Endpoint="https://hook.todayorder.invalid/sns"',
    'endpoint_url="https://127.0.0.1:9297"',
    'Principal={"Service": "lambda.amazonaws.com"}',
    'Endpoint="dev@example.com"',
    'curl http://{dns}/hello',
    '\\"DNSName\\": \\"api.todayorder.example\\"',
    '--endpoint-url \\"https://hook.todayorder.invalid\\"',
]
# Markdown: 블록 표시가 있으면 블록 전체를 건너뛰고, 이유가 없거나 한 줄 떨어져 있으면 무효
MD_BAD_SAMPLES = [
    "```\nhttps://sqs.us-east-1.amazonaws.com/000000000000/q\n```",
    "<!-- external-host-ok: -->\n```\nhttps://sqs.us-east-1.amazonaws.com/000000000000/q\n```",
    "<!-- external-host-ok: 이유 -->\n\n```\nhttps://sqs.us-east-1.amazonaws.com/000000000000/q\n```",
    "<!-- external-host-ok: 앞 블록만 -->\n```\nok\n```\n```\nhttps://sqs.us-east-1.amazonaws.com/000000000000/q\n```",
]
MD_GOOD_SAMPLES = [
    "<!-- external-host-ok: 에뮬레이터가 돌려준 큐 URL -->\n```\nhttps://sqs.us-east-1.amazonaws.com/000000000000/q\n```",
    "본문 링크 https://docs.aws.amazon.com/ 는 검사하지 않는다",
]


def selftest() -> list[str]:
    errs = [f"걸러야 하는데 통과: {s}" for s in BAD_SAMPLES if not scan_text("selftest.py", s)]
    errs += [f"걸러야 하는데 통과: {s}" for s in BAD_PY_SAMPLES if not scan_python("selftest.py", s)]
    errs += [f"통과해야 하는데 걸림: {s} → {scan_python('selftest.py', s)[0].value}"
             for s in GOOD_PY_SAMPLES if scan_python("selftest.py", s)]
    errs += [f"통과해야 하는데 걸림: {s} → {scan_text('selftest.py', s)[0].value}"
             for s in GOOD_SAMPLES if scan_text("selftest.py", s)]
    errs += [f"걸러야 하는데 통과(md): {s!r}" for s in MD_BAD_SAMPLES if not scan_text("selftest.md", s)]
    errs += [f"통과해야 하는데 걸림(md): {s!r}" for s in MD_GOOD_SAMPLES if scan_text("selftest.md", s)]
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
