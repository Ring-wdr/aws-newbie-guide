"""가이드 사이트 검사기 — docs/GUIDE-SITE.md 5장의 PR 관문.

사용 (저장소 루트에서, 먼저 `pnpm --dir site build`):

    uv run python tools/sitecheck/sitecheck.py all --port 4390            # 모든 관문(시범 페이지)
    uv run python tools/sitecheck/sitecheck.py parity --pages all         # 내용 동등성(전 페이지)
    uv run python tools/sitecheck/sitecheck.py parity --pages /curriculum/m06-integration-messaging/02-sqs/
    uv run python tools/sitecheck/sitecheck.py quiz | exam | links | static
    uv run python tools/sitecheck/sitecheck.py browser --port 4390        # 오프라인·접근성·키보드(Node, site/ 안의 Playwright)

관문마다 "PASS"/"FAIL" 요약 줄을 내고, 하나라도 실패하면 종료 코드 1.
브라우저 검사는 지정한 포트의 127.0.0.1 에서만 서버를 연다(에이전트마다 전용 포트 — GUIDE-SITE 6장).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import htmlbuilt  # noqa: E402
import mdsource  # noqa: E402

REPO = HERE.parent.parent
SITE = REPO / "site"
EXAM_DIR = REPO / "curriculum/m14-capstone-exam/mock-exam"
DIST_IN_USE = SITE / "dist"

# 시범(P1)에서 확인하는 원고 — site/src/lib/repo.mjs 의 PILOT_FILES 와 같다(검사기가 그 파일을 읽어 맞춘다).
def pilot_files() -> list[str]:
    text = (SITE / "src/lib/repo.mjs").read_text(encoding="utf-8")
    block = re.search(r"PILOT_FILES = \[(.*?)\];", text, re.S)
    return re.findall(r"'([^']+\.md)'", block.group(1)) if block else []


def all_content_files() -> list[str]:
    files = ["README.md"] if (REPO / "README.md").exists() else []
    files += sorted(f"docs/{p.name}" for p in (REPO / "docs").glob("*.md"))
    files += sorted(str(p.relative_to(REPO)) for p in (REPO / "curriculum").rglob("*.md"))
    return files


def route_for(rel: str) -> str:
    p = re.sub(r"\.md$", "", rel)
    if p == "README":
        return "/"
    p = re.sub(r"/README$", "", p)
    return f"/{p.lower()}/"


def html_for_route(dist: Path, route: str) -> Path:
    return dist / route.strip("/") / "index.html" if route != "/" else dist / "index.html"


class Gate:
    def __init__(self, name: str) -> None:
        self.name = name
        self.failures: list[str] = []
        self.checked = 0

    def fail(self, msg: str) -> None:
        self.failures.append(msg)

    def summary(self) -> str:
        status = "PASS" if not self.failures else "FAIL"
        return f"{status} {self.name}: 검사 {self.checked}건, 실패 {len(self.failures)}건"

    def report(self, limit: int = 30) -> bool:
        for f in self.failures[:limit]:
            print(f"  - {f}")
        if len(self.failures) > limit:
            print(f"  … 외 {len(self.failures) - limit}건")
        print(self.summary())
        return not self.failures


def select_files(pages: str) -> list[str]:
    if pages == "pilot":
        return pilot_files()
    if pages == "all":
        return all_content_files()
    wanted = set(p if p.endswith("/") else p + "/" for p in pages.split(","))
    return [f for f in all_content_files() if route_for(f) in wanted]


# ---------------------------------------------------------------- 내용 동등성
def gate_parity(dist: Path, files: list[str]) -> Gate:
    g = Gate("내용 동등성(제목·H2~H6 순서·코드 블록 바이트·표 행/열·메타 줄)")
    for rel in files:
        html_path = html_for_route(dist, route_for(rel))
        if not html_path.exists():
            g.fail(f"{rel}: 빌드된 페이지가 없음 ({html_path.relative_to(dist)})")
            continue
        g.checked += 1
        src = mdsource.parse((REPO / rel).read_text(encoding="utf-8"), is_lesson=bool(re.search(r"/\d\d-[^/]+\.md$", rel)))
        doc = htmlbuilt.parse(html_path.read_text(encoding="utf-8"))
        content = htmlbuilt.content_root(doc)
        if content is None:
            g.fail(f"{rel}: 본문(.sl-markdown-content)이 없음")
            continue
        title = htmlbuilt.page_title(doc)
        if title != src.title:
            g.fail(f"{rel}: 제목 다름 — 원고 {src.title!r} / 페이지 {title!r}")
        built = htmlbuilt.code_blocks(content)
        want = [c.text for c in src.codes]
        if len(built) != len(want):
            g.fail(f"{rel}: 코드 블록 수 다름 — 원고 {len(want)} / 페이지 {len(built)}")
        for k, (a, b) in enumerate(zip(want, built)):
            if a != b:
                at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
                g.fail(
                    f"{rel}: 코드 블록 {k + 1}번째(원고 {src.codes[k].line}줄)가 바이트 단위로 다름 — "
                    f"{at}번째 글자부터 원고 {a[at:at + 40]!r} / 페이지 {b[at:at + 40]!r}"
                )
                break
        bt = htmlbuilt.tables(content)
        st = [(r, c) for _, r, c in src.tables]
        if bt != st:
            diff = next((i for i, (x, y) in enumerate(zip(st, bt)) if x != y), min(len(st), len(bt)))
            line = src.tables[diff][0] if diff < len(src.tables) else "?"
            g.fail(f"{rel}: 표 다름 — 원고 {len(st)}개 / 페이지 {len(bt)}개, {diff + 1}번째 표(원고 {line}줄) 원고 행·열 {st[diff:diff + 1]} / 페이지 {bt[diff:diff + 1]}")
        bh = htmlbuilt.headings(content)
        sh = [(lv, t) for _, lv, t in src.headings]
        if bh != sh:
            k = next((i for i, (x, y) in enumerate(zip(sh, bh)) if x != y), min(len(sh), len(bh)))
            line = src.headings[k][0] if k < len(src.headings) else "?"
            g.fail(f"{rel}: 제목(H2~H6) 다름 — 원고 {len(sh)}개 / 페이지 {len(bh)}개, {k + 1}번째(원고 {line}줄) 원고 {sh[k:k + 1]} / 페이지 {bh[k:k + 1]}")
        if src.meta is not None:
            mt = htmlbuilt.meta_text(content)
            if mt != src.meta:
                g.fail(f"{rel}: 메타 줄 글자가 다름 — 원고 {src.meta!r} / 페이지 {mt!r}")
    return g


# ---------------------------------------------------------------- 퀴즈 정답
def gate_quiz(dist: Path, files: list[str]) -> Gate:
    g = Gate("퀴즈 정답·통과 기준")
    for rel in files:
        if not rel.endswith("/quiz.md"):
            continue
        answers, pass_pct = mdsource.quiz_answers((REPO / rel).read_text(encoding="utf-8"))
        if not answers:
            continue  # M14 퀴즈는 모의고사로 대신한다(문항 없음)
        html_path = html_for_route(dist, route_for(rel))
        if not html_path.exists():
            g.fail(f"{rel}: 빌드된 페이지 없음")
            continue
        g.checked += 1
        doc = htmlbuilt.parse(html_path.read_text(encoding="utf-8"))
        cards = doc.find_all(lambda n: n.tag == "section" and "quiz-q" in n.cls())
        built = {int(c.attrs["data-q"]): c.attrs.get("data-answer", "") for c in cards}
        if built != answers:
            diff = sorted(set(answers.items()) ^ set(built.items()))
            g.fail(f"{rel}: 정답이 원고와 다름 — 차이 {diff[:6]}")
        summ = doc.find_all(lambda n: "quiz-summary" in n.cls())
        if not summ or int(summ[0].attrs.get("data-pass", "0")) != (pass_pct or 80):
            g.fail(f"{rel}: 통과 기준이 원고({pass_pct}%)와 다름")
        if summ and int(summ[0].attrs.get("data-total", "0")) != len(answers):
            g.fail(f"{rel}: 문항 수가 원고({len(answers)})와 다름")
    return g


# ---------------------------------------------------------------- 모의고사 채점
def parse_grade_py_output(out: str) -> dict:
    dom = re.findall(r"^\s+(D[1-4]) .+?\s+(\d+)/(\d+)\s+([\d.]+)%", out, re.M)
    total = re.search(r"^전체 (\d+)/(\d+) = ([\d.]+)%\s+\(무응답 (\d+)문항\)", out, re.M)
    passed = "판정: 통과" in out
    more = re.search(r"기준 \d+%까지 (-?\d+)문항 더 필요", out)
    weak = re.search(r"^약한 도메인\(65% 미만\): (.+?) →", out, re.M)
    wrong = re.findall(r"^\s+(\d+)번 D[1-4] [\d.]+ 내 답 (\S+)\s+정답 (\S+)", out, re.M)
    lucky = re.search(r"맞힌 문항\(운일 수 있음 — 해설 확인\): (.+)$", out, re.M)
    if not total:
        raise ValueError(f"grade.py 출력을 읽지 못했다:\n{out}")
    return {
        "domains": [{"domain": d, "ok": int(a), "total": int(b), "pct": p} for d, a, b, p in dom],
        "totalOk": int(total.group(1)),
        "totalQ": int(total.group(2)),
        "pct": total.group(3),
        "blank": int(total.group(4)),
        "pass": passed,
        "more": int(more.group(1)) if more else None,
        "weak": [w.split()[0] for w in weak.group(1).split(", ")] if weak else [],
        "wrong": [{"n": int(n), "mine": m, "key": k} for n, m, k in wrong],
        "lucky": [int(x) for x in lucky.group(1).split(", ")] if lucky else [],
    }


def run_grade_py(sheet: Path) -> dict:
    p = subprocess.run(
        [sys.executable, str(EXAM_DIR / "grade.py"), str(sheet)], capture_output=True, text=True, cwd=REPO, check=True
    )
    return parse_grade_py_output(p.stdout)


def run_site_scorer(sheets: list[Path]) -> dict:
    p = subprocess.run(
        ["node", "scripts/grade-sheet.mjs", *map(str, sheets)], capture_output=True, text=True, cwd=SITE, check=True
    )
    return json.loads(p.stdout)


def make_sheets(tmp: Path) -> list[Path]:
    """grade.py 와 사이트 채점기에 똑같이 먹일 답안 파일들."""
    key_out = subprocess.run([sys.executable, str(EXAM_DIR / "grade.py"), "--key"], capture_output=True, text=True, check=True).stdout
    key = {int(n): a for n, a in (ln.split() for ln in key_out.strip().splitlines())}
    multi = [n for n, a in key.items() if len(a) > 1]
    sheets: dict[str, str] = {}
    sheets["01-all-correct.txt"] = key_out
    sheets["02-all-blank.txt"] = (EXAM_DIR / "answer-sheet.txt").read_text(encoding="utf-8")  # 원고의 빈 답안지 그대로
    # 섞인 답안: 정답·오답·무응답·"?" 표시가 결정적으로 섞인다
    lines = ["# 섞인 답안 (정답·오답·무응답·확신 없음)"]
    for n, a in sorted(key.items()):
        r = (n * 7) % 10
        if r < 6:
            lines.append(f"{n} {a}{'?' if r == 0 else ''}")
        elif r < 8:
            wrong = "".join(sorted({"A": "B", "B": "C", "C": "D", "D": "A", "E": "A", "F": "A"}[x] for x in a))
            lines.append(f"{n} {wrong}{'?' if r == 6 else ''}")
        else:
            lines.append(f"{n} ")
    sheets["03-mixed.txt"] = "\n".join(lines) + "\n"
    # 복수 응답을 일부만 맞힌 답안(부분 점수 없음을 확인), 나머지는 정답
    lines = []
    for n, a in sorted(key.items()):
        lines.append(f"{n} {a[0] if n in multi else a}")
    sheets["04-multi-partial.txt"] = "\n".join(lines) + "\n"
    # 복수 응답을 하나 더 고른 답안 + 형식 변형(쉼표, 소문자, 콜론, 주석, 중복, 없는 번호)
    lines = ["# 형식 변형"]
    for n, a in sorted(key.items()):
        if n in multi:
            extra = next(x for x in "ABCDEF" if x not in a)
            lines.append(f"{n}: {','.join(a.lower())},{extra.lower()}  # 하나 더 고름")
        elif n % 9 == 0:
            lines.append(f"{n}) {a}")
            lines.append(f"{n} A")  # 같은 번호가 두 번 — 뒤의 답을 쓴다
        else:
            lines.append(f"{n}. {a.lower()}")
    lines.append("99 C")
    sheets["05-format-variants.txt"] = "\n".join(lines) + "\n"
    # 통과선 바로 아래/위 (72%: 65문항 중 47)
    for name, ok in (("06-just-below.txt", 46), ("07-just-pass.txt", 47)):
        lines = []
        for i, (n, a) in enumerate(sorted(key.items())):
            lines.append(f"{n} {a}" if i < ok else f"{n} {'A' if a != 'A' else 'B'}")
        sheets[name] = "\n".join(lines) + "\n"
    out = []
    for name, text in sheets.items():
        p = tmp / name
        p.write_text(text, encoding="utf-8")
        out.append(p)
    return out


def gate_exam(extra_sheets: list[Path] | None = None) -> Gate:
    g = Gate("모의고사 채점 = grade.py")
    with tempfile.TemporaryDirectory(prefix="sitecheck-exam-") as d:
        sheets = make_sheets(Path(d)) + list(extra_sheets or [])
        site = run_site_scorer(sheets)
        for s in sheets:
            g.checked += 1
            want = run_grade_py(s)
            got = {k: v for k, v in site[str(s)].items() if k != "warnings"}
            for k in want:
                if k == "more" and want["pass"]:
                    continue  # 통과면 grade.py 는 남은 문항 수를 출력하지 않는다
                if want[k] != got.get(k):
                    g.fail(f"{s.name}: {k} 다름 — grade.py {want[k]!r} / 사이트 {got.get(k)!r}")
            print(f"  {s.name}: grade.py {want['totalOk']}/{want['totalQ']} = {want['pct']}% {'통과' if want['pass'] else '미달'} · 사이트 {got['totalOk']}/{got['totalQ']} = {got['pct']}% {'통과' if got['pass'] else '미달'}")
    return g


# ---------------------------------------------------------------- 내부 링크·앵커
def gate_links(dist: Path, routes: list[str] | None) -> Gate:
    g = Gate("내부 링크·앵커")
    ids_cache: dict[Path, set[str]] = {}

    def ids_of(p: Path) -> set[str]:
        if p not in ids_cache:
            text = p.read_text(encoding="utf-8")
            ids_cache[p] = set(re.findall(r'\sid="([^"]+)"', text)) | set(re.findall(r'\sname="([^"]+)"', text))
        return ids_cache[p]

    pages = sorted(dist.rglob("*.html"))
    if routes is not None:
        wanted = {html_for_route(dist, r) for r in routes}
        pages = [p for p in pages if p in wanted]
    import html as htmllib
    from urllib.parse import unquote, urlsplit

    for page in pages:
        text = page.read_text(encoding="utf-8")
        for attr, raw in re.findall(r'<(?:a|link|script|img|source|use)\b[^>]*?\s(href|src)="([^"]*)"', text):
            url = htmllib.unescape(raw)
            if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("//"):
                continue  # 외부 링크(탐색용 <a>)는 여기서 보지 않는다 — static 관문이 리소스 참조를 본다
            g.checked += 1
            parts = urlsplit(url)
            if parts.path:
                target = (dist / unquote(parts.path).lstrip("/")) if parts.path.startswith("/") else (page.parent / unquote(parts.path))
                if target.is_dir() or parts.path.endswith("/"):
                    target = target / "index.html"
            else:
                target = page
            if not target.exists():
                g.fail(f"{page.relative_to(dist)}: 없는 대상 {url}")
                continue
            if parts.fragment and target.suffix == ".html":
                frag = unquote(parts.fragment)
                if frag not in ids_of(target) and frag != "_top":
                    g.fail(f"{page.relative_to(dist)}: 앵커 없음 {url}")
    return g


# ---------------------------------------------------------------- 소스 보기의 실행 명령
def strip_shell_comment(line: str) -> str:
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
            continue
        if c in "'\"":
            q = c
        elif c == "#" and i > 0 and line[i - 1].isspace():
            return line[:i].rstrip()
    return line.rstrip()


def invokes(line: str, rel: str) -> bool:
    return re.match(
        r"^\s*(?:[A-Z_][A-Z0-9_]*=\S*\s+)*(?:bash\s+|sh\s+|source\s+|\.\s+|uv\s+run\s+(?:--\S+\s+)*python3?\s+|python3?\s+)?(?:\./)?"
        + re.escape(rel) + r"(?=\s|$|;|&&|\|)", line) is not None


_bash_lines: list[str] | None = None


def manuscript_bash_lines() -> list[str]:
    global _bash_lines
    if _bash_lines is None:
        _bash_lines = []
        for rel in all_content_files():
            for cb in mdsource.parse((REPO / rel).read_text(encoding="utf-8")).codes:
                if cb.lang.lower() != "bash":
                    continue
                raw = cb.text.split("\n")
                i = 0
                while i < len(raw):
                    ln = raw[i]
                    while re.search(r"\\\s*$", ln) and i + 1 < len(raw):
                        i += 1
                        ln = re.sub(r"\\\s*$", "", ln) + " " + raw[i].strip()
                    _bash_lines.append(strip_shell_comment(ln).strip())
                    i += 1
    return _bash_lines


def entry_command(rel: str) -> str | None:
    """실행 진입점이면 그 형태의 명령, 아니면 None."""
    p = REPO / rel
    base = p.name
    if rel.endswith(".sh"):
        if base.startswith("_"):
            return None
        if os.access(p, os.X_OK) or re.search(r"(^|/)labs/(lab\d\d-[^/]+|verify)\.sh$", rel):
            return f"bash {rel}" if rel.startswith("curriculum/") else rel
        return None
    if rel.endswith(".py"):
        if re.search(r"^if __name__ == [\"']__main__[\"']\s*:", p.read_text(encoding="utf-8"), re.M):
            return f"uv run python {rel}"
    return None


def gate_run_commands(dist: Path) -> Gate:
    g = Gate("소스 보기 실행 명령의 근거(원고 또는 실행 진입점)")
    root = dist / "files"
    if not root.exists():
        return g
    for page in sorted(root.rglob("index.html")):
        rel = str(page.parent.relative_to(root))
        doc = htmlbuilt.parse(page.read_text(encoding="utf-8"))
        runs = doc.find_all(lambda n: "source-run" in n.cls())
        for box in runs:
            g.checked += 1
            pres = box.find_all(lambda n: n.tag == "pre")
            cmd = pres[0].text().strip() if pres else ""
            if not (REPO / rel).is_file():
                g.fail(f"/files/{rel}/: 저장소에 없는 파일에 실행 명령 {cmd!r}")
                continue
            grounded = cmd in manuscript_bash_lines() and invokes(cmd, rel)
            entry = entry_command(rel)
            if not grounded and cmd != entry:
                why = "실행 진입점이 아님(실행 비트·labs 이름 규칙·__main__ 없음)" if entry is None else f"진입점 형태는 {entry!r}"
                g.fail(f"/files/{rel}/: 근거 없는 실행 명령 {cmd!r} — 원고에 이 명령이 없고 {why}")
    return g


# ---------------------------------------------------------------- 외부 리소스 정적 검사
URL_RE = re.compile(r"(?:https?|wss?|ftp):\/\/[^\s\"'<>)\\]+", re.I)
NAMESPACE_OK = re.compile(r"^https?://www\.w3\.org/(1999/xhtml|2000/svg|1999/xlink|1998/Math/MathML|XML/1998/namespace|2000/xmlns/?)")
RESOURCE_HTML = re.compile(
    r"<(script|link|img|source|iframe|video|audio|embed|object|track|image|use|input|form)\b[^>]*?\s(src|href|srcset|data|poster|xlink:href|action|formaction)\s*=\s*\"([^\"]*)\"",
    re.I,
)
CSS_URL = re.compile(r"(?:url\(\s*['\"]?|@import\s+['\"])((?:https?:)?//[^'\")\s]+)", re.I)
JS_LOAD = re.compile(
    r"(?:fetch|import|importScripts|sendBeacon|WebSocket|EventSource|XMLHttpRequest[^;]{0,80}open)\s*\(\s*[^)]{0,40}?['\"`]((?:https?|wss?):)?//[^'\"`]+",
    re.I,
)


# 네트워크로 나갈 수 있는 브라우저 API. 오프라인 브라우저 관문(site/tests/lib/harness.mjs)이 기록하는 통로와 같은 목록이다.
NET_APIS = re.compile(
    r"\b(?:new\s+WebSocket|WebSocket\s*\(|new\s+EventSource|sendBeacon\s*\(|serviceWorker\s*\.\s*register|RTCPeerConnection"
    r"|importScripts\s*\(|new\s+(?:Shared)?Worker\s*\(|navigator\s*\.\s*connection)"
)
LINK_HINT = re.compile(r"\b(?:preconnect|dns-prefetch|prefetch|prerender|modulepreload)\b")
INLINE_SCRIPT = re.compile(r"<script\b([^>]*)>([\s\S]*?)</script>", re.I)
# 산출물에서 알려진 동일 출처 사용(주소를 정적으로 판정할 수 없어 브라우저 관문이 실제 요청을 본다):
#  Pagefind 검색이 같은 폴더의 pagefind-worker.js 를 Worker 로 연다.
DIST_API_ALLOW = {("pagefind/pagefind.js", "new Worker(")}


def gate_static(dist: Path, verbose: bool = True) -> Gate:
    g = Gate("외부 리소스 정적 검사(site/src·빌드 산출물)")
    # 1) site/src: 주소 자체가 없어야 한다(SVG 이름공간 제외, 줄에 'sitecheck-allow:' 표시가 있으면 예외)
    for p in sorted((SITE / "src").rglob("*")):
        if not p.is_file() or p.suffix in {".png", ".jpg", ".ico", ".woff", ".woff2"}:
            continue
        g.checked += 1
        for i, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if "sitecheck-allow:" in line:
                continue
            where = f"site/src/{p.relative_to(SITE / 'src')}:{i}"
            for u in URL_RE.findall(line):
                if not NAMESPACE_OK.match(u):
                    g.fail(f"{where}: 외부 주소 {u}")
            # 네트워크 API·연결 예고는 사이트 공용부에서 쓰지 않는다(쓰려면 줄에 sitecheck-allow: 이유)
            for m in NET_APIS.finditer(line):
                g.fail(f"{where}: 네트워크 API {m.group(0)!r}")
            if re.search(r"<link\b", line) and LINK_HINT.search(line):
                g.fail(f"{where}: 연결 예고 <link rel={LINK_HINT.search(line).group(0)}>")
    # 2) 산출물: 리소스를 불러오는 자리(HTML 속성, CSS url/@import, JS 로딩 호출)에 루프백 밖 주소가 없어야 한다
    nav_links = 0
    for p in sorted(dist.rglob("*")):
        if not p.is_file() or p.suffix not in {".html", ".css", ".js", ".mjs", ".svg", ".json", ".webmanifest", ".xml"}:
            continue
        g.checked += 1
        text = p.read_text(encoding="utf-8", errors="replace")
        rel = p.relative_to(dist)
        if p.suffix in {".html", ".svg"}:
            for tag, attr, val in RESOURCE_HTML.findall(text):
                for u in re.split(r"\s*,\s*", val):
                    u = u.strip().split(" ")[0]
                    if re.match(r"^(?:[a-z]+:)?//", u, re.I) and not re.match(r"^(?:https?:)?//(127\.0\.0\.1|localhost)(:|/|$)", u) and not NAMESPACE_OK.match(u):
                        g.fail(f"{rel}: <{tag} {attr}> 외부 리소스 {u}")
            for m in re.finditer(r'<meta[^>]+http-equiv="refresh"[^>]*>', text, re.I):
                g.fail(f"{rel}: meta refresh {m.group(0)[:80]}")
            nav_links += len(re.findall(r'<a\b[^>]*\shref="https?://', text))
        for u in CSS_URL.findall(text):
            if not NAMESPACE_OK.match(u):
                g.fail(f"{rel}: CSS 외부 참조 {u}")
        if p.suffix in {".js", ".mjs", ".html"}:
            for m in JS_LOAD.finditer(text):
                g.fail(f"{rel}: 스크립트가 외부 주소를 불러옴 {m.group(0)[:100]}")
            # 스크립트 코드(파일 또는 문서 안 <script>)에 네트워크 API가 있으면 실패. 본문 글자는 보지 않는다.
            if p.suffix == ".html":
                code = "\n".join(body for attrs, body in INLINE_SCRIPT.findall(text) if "application/json" not in attrs)
            else:
                code = text
            for m in NET_APIS.finditer(code):
                if (str(rel), re.sub(r"\s+", " ", m.group(0))) in DIST_API_ALLOW:
                    continue
                g.fail(f"{rel}: 스크립트의 네트워크 API {m.group(0)!r}")
    if verbose:
        print(f"  (참고) 원고의 외부 하이퍼링크 <a href=\"http…\"> {nav_links}개 — 누를 때만 이동하는 탐색 링크이며 페이지가 불러오는 리소스가 아니다")
    return g


# ---------------------------------------------------------------- 브라우저 검사(Node)
def gate_browser(port: int, which: str) -> Gate:
    g = Gate(f"브라우저 검사({which})")
    script = {"offline": "tests/offline.mjs", "a11y": "tests/a11y.mjs", "keyboard": "tests/keyboard.mjs", "diagrams": "tests/diagrams.mjs"}[which]
    if which == "offline":
        # 관문이 잡는다고 주장하는 통로마다 결함을 심어 실제로 잡는지 먼저 확인한다.
        st = subprocess.run(["node", "tests/offline-selftest.mjs", "--port", str(port)], capture_output=True, text=True, cwd=SITE)
        sys.stdout.write(st.stdout.splitlines()[-1] + "\n" if st.stdout else st.stderr[-2000:])
        if st.returncode != 0:
            sys.stdout.write(st.stdout)
            g.fail("offline-selftest: 심은 결함을 잡지 못한 통로가 있다")
    with tempfile.TemporaryDirectory(prefix="sitecheck-browser-") as d:
        env = {**os.environ, "GUIDE_DIST": str(DIST_IN_USE)}
        args = ["--fail"] if which == "diagrams" else ["--out", d]
        p = subprocess.run(["node", script, "--port", str(port), *args], capture_output=True, text=True, cwd=SITE, env=env)
        sys.stdout.write(p.stdout)
        if p.returncode != 0:
            sys.stdout.write(p.stderr[-3000:])
            g.fail(f"{script} 종료 코드 {p.returncode}")
        g.checked = 1
        if which == "keyboard" and p.returncode == 0:
            # 키보드로 끝까지 푼 모의고사 답안을 grade.py 로도 채점해 화면 결과와 맞춘다.
            sheet = Path(d) / "keyboard-answers.txt"
            shown = json.loads((Path(d) / "keyboard-result.json").read_text(encoding="utf-8"))
            want = run_grade_py(sheet)
            if (want["totalOk"], want["pct"], want["pass"]) != (shown["totalOk"], shown["pct"], shown["pass"]):
                g.fail(f"키보드로 푼 시험: 화면 {shown} / grade.py {want['totalOk']} {want['pct']} {want['pass']}")
            else:
                print(f"  키보드로 푼 시험의 내보낸 답안: grade.py {want['totalOk']}/{want['totalQ']} = {want['pct']}% — 화면과 같다")
    return g


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="가이드 사이트 검사기 (GUIDE-SITE 5장)")
    ap.add_argument("check", choices=["all", "parity", "quiz", "exam", "links", "run-commands", "static", "selftest", "offline", "a11y", "keyboard", "diagrams", "browser"])
    ap.add_argument("--pages", default="pilot", help="pilot(기본) | all | 쉼표로 구분한 경로(/curriculum/.../)")
    ap.add_argument("--dist", default=None, help="빌드 산출물 폴더(기본: site/dist)")
    ap.add_argument("--site", default=None, help="site/ 폴더(기본: 저장소의 site/) — 검사기 자체를 시험할 때 사본을 가리킨다")
    ap.add_argument("--port", type=int, default=int(os.environ.get("GUIDE_PORT", "0")) or None, help="브라우저 검사용 127.0.0.1 포트(필수)")
    args = ap.parse_args(argv)
    global SITE
    if args.site:
        SITE = Path(args.site).resolve()
    dist = Path(args.dist) if args.dist else SITE / "dist"
    if not (dist / "index.html").exists() and not any(dist.glob("**/index.html")):
        print(f"빌드 산출물이 없다: {dist} — 먼저 pnpm --dir site build", file=sys.stderr)
        return 2
    global DIST_IN_USE
    DIST_IN_USE = dist.resolve()
    files = select_files(args.pages)
    routes = None if args.pages == "all" else [route_for(f) for f in files]
    gates: list[Gate] = []
    c = args.check
    if c in ("all", "parity"):
        gates.append(gate_parity(dist, files))
    if c in ("all", "quiz"):
        gates.append(gate_quiz(dist, files if args.pages != "pilot" else [f for f in all_content_files() if f in files]))
    if c in ("all", "exam"):
        gates.append(gate_exam())
    if c in ("all", "links"):
        gates.append(gate_links(dist, routes))
    if c in ("all", "selftest"):
        g = Gate("검사기 자체 시험(정적·실행 명령 관문에 심은 결함)")
        st = subprocess.run([sys.executable, str(HERE / "selftest.py")], capture_output=True, text=True)
        g.checked = 1
        print(st.stdout.splitlines()[-1] if st.stdout else st.stderr[-2000:])
        if st.returncode != 0:
            print(st.stdout)
            g.fail("selftest.py 실패")
        gates.append(g)
    if c in ("all", "run-commands"):
        gates.append(gate_run_commands(dist))
    if c in ("all", "static"):
        gates.append(gate_static(dist))
    browser = {"all": ["offline", "a11y", "keyboard", "diagrams"], "browser": ["offline", "a11y", "keyboard", "diagrams"]}.get(
        c, [c] if c in ("offline", "a11y", "keyboard", "diagrams") else [])
    if browser and not args.port:
        print("브라우저 검사에는 --port 가 필요하다(에이전트 전용 포트, 127.0.0.1 에만 연다)", file=sys.stderr)
        return 2
    for b in browser:
        gates.append(gate_browser(args.port, b))
    ok = True
    print()
    for gt in gates:
        print(f"== {gt.name}")
        ok = gt.report() and ok
    print()
    for gt in gates:
        print(gt.summary())
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
