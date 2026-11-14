"""검사기 자체 시험: 정적 관문과 실행 명령 관문에 결함을 하나씩 심어, 각각 실패하는지(그리고 결함 없는 사본은 통과하는지) 본다.

브라우저 오프라인 관문의 통로별 시험은 site/tests/offline-selftest.mjs 가 한다.
사용: uv run python tools/sitecheck/selftest.py
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import sitecheck  # noqa: E402

CLEAN_HTML = "<!doctype html><html lang=ko><body><main><p>WebSocket 이라는 글자는 본문이라 괜찮다</p></main></body></html>"

# (이름, 심을 곳, 파일, 내용) — src 는 site/src, dist 는 빌드 산출물
STATIC_CASES = [
    ("src: 외부 주소", "src", "components/A.astro", '<link rel="stylesheet" href="https://fonts.selftest.invalid/a.css" />'),
    ("src: 시험 스크립트의 루프백처럼 보이는 외부 주소", "src", "widgets/m99/w/keyboard.check.mjs", "const base = `http://127.0.0.1.selftest.invalid:${port}`;"),
    ("src: 시험 스크립트의 사용자 정보 뒤 외부 호스트", "src", "widgets/m99/w/model.test.mjs", "const u = 'http://127.0.0.1:80@x.selftest.invalid/';"),
    ("src: 시험이 아닌 소스의 루프백 주소", "src", "scripts/h.ts", "const u = `http://127.0.0.1:${port}/`;"),
    ("src: WebSocket", "src", "scripts/a.ts", "const u = location.host; new WebSocket('ws://' + u);"),
    ("src: EventSource", "src", "scripts/b.ts", "new EventSource(path);"),
    ("src: sendBeacon", "src", "scripts/c.ts", "navigator.sendBeacon(path, data);"),
    ("src: service worker", "src", "scripts/d.ts", "navigator.serviceWorker.register('/sw.js');"),
    ("src: WebRTC", "src", "scripts/e.ts", "const pc = new RTCPeerConnection(cfg);"),
    ("src: Worker", "src", "scripts/f.ts", "const w = new Worker(url);"),
    ("src: importScripts", "src", "scripts/g.ts", "importScripts(url);"),
    ("src: preconnect", "src", "components/B.astro", '<link rel="preconnect" href={host} />'),
    ("dist: 외부 <img>", "dist", "p1/index.html", '<img alt="" src="https://cdn.selftest.invalid/x.png">'),
    ("dist: <link preconnect>", "dist", "p2/index.html", '<link rel="preconnect" href="https://cdn.selftest.invalid">'),
    ("dist: <link dns-prefetch>", "dist", "p3/index.html", '<link rel="dns-prefetch" href="//cdn.selftest.invalid">'),
    ("dist: CSS @import", "dist", "a.css", '@import "https://cdn.selftest.invalid/x.css";'),
    ("dist: 문서 안 스크립트의 WebSocket", "dist", "p4/index.html", "<script>new WebSocket('w'+'ss://x.selftest.invalid')</script>"),
    ("dist: 스크립트 파일의 EventSource", "dist", "_astro/a.js", "new EventSource(u)"),
    ("dist: 스크립트 파일의 sendBeacon", "dist", "_astro/b.js", "navigator.sendBeacon(u,d)"),
    ("dist: 스크립트의 RTCPeerConnection", "dist", "_astro/c.js", "new RTCPeerConnection(c)"),
    ("dist: 스크립트의 service worker", "dist", "_astro/d.js", "navigator.serviceWorker.register(u)"),
    ("dist: fetch 외부 주소", "dist", "_astro/e.js", 'fetch("https://api.selftest.invalid/x")'),
    ("dist: window.open 외부 주소", "dist", "_astro/f.js", 'window.open("https://popup.selftest.invalid/x")'),
    ("dist: location.href 외부 주소", "dist", "p6/index.html", "<script>location.href = 'https://away.selftest.invalid/'</script>"),
    ("dist: location.assign 외부 주소", "dist", "_astro/g.js", "location.assign(`https://away.selftest.invalid/2`)"),
    ("dist: <object data>", "dist", "p7/index.html", '<object data="https://obj.selftest.invalid/o.svg"></object>'),
    ("dist: srcset 2x 후보", "dist", "p8/index.html", '<img alt="" src="/a.png" srcset="/a.png 1x, https://img.selftest.invalid/a-2x.png 2x">'),
    ("dist: meta refresh", "dist", "p5/index.html", '<meta http-equiv="refresh" content="0; url=https://x.selftest.invalid">'),
]


def make_tree(root: Path) -> tuple[Path, Path]:
    site = root / "site"
    (site / "src").mkdir(parents=True)
    (site / "src/ok.ts").write_text("export const ok = 1;\n", encoding="utf-8")
    # 위젯 검사·시험 스크립트의 루프백 주소는 허용된다(결함 없는 사본에 둔다)
    (site / "src/widgets/m99/w").mkdir(parents=True)
    (site / "src/widgets/m99/w/keyboard.check.mjs").write_text(
        "const base = `http://127.0.0.1:${port}`;\nawait page.goto(`http://127.0.0.1:${port}${PAGE}`);\nconst a = 'http://localhost:4321/x'; const b = 'http://[::1]:4321/';\n",
        encoding="utf-8",
    )
    dist = site / "dist"
    dist.mkdir()
    (dist / "index.html").write_text(CLEAN_HTML, encoding="utf-8")
    return site, dist


def run_static(site: Path, dist: Path) -> sitecheck.Gate:
    sitecheck.SITE = site
    return sitecheck.gate_static(dist, verbose=False)


def main() -> int:
    original_site = sitecheck.SITE
    failures: list[str] = []
    try:
        with tempfile.TemporaryDirectory(prefix="sitecheck-selftest-") as d:
            site, dist = make_tree(Path(d) / "clean")
            g = run_static(site, dist)
            ok = not g.failures
            print(f"{'ok  ' if ok else 'BAD '} 정적 관문: 결함 없는 사본 → {'통과' if ok else g.failures}")
            if not ok:
                failures.append("clean")
            for i, (name, where, rel, content) in enumerate(STATIC_CASES):
                site, dist = make_tree(Path(d) / f"case{i}")
                target = (site / "src" if where == "src" else dist) / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content if not rel.endswith(".html") else f"<!doctype html><html><head>{content}</head><body></body></html>", encoding="utf-8")
                g = run_static(site, dist)
                ok = bool(g.failures)
                print(f"{'ok  ' if ok else 'MISS'} 정적 관문: {name} → {g.failures[0] if g.failures else '(못 잡음)'}")
                if not ok:
                    failures.append(name)
            # 실행 명령 관문: 실행할 수 없는 도우미(lab-wait.sh)·모듈(probe/lib.py)에 명령을 붙인 페이지와, 근거 있는 페이지
            for name, rel, cmd, want_fail in [
                ("source 도우미에 실행 명령", "scripts/lab-wait.sh", "scripts/lab-wait.sh", True),
                ("__main__ 없는 모듈에 실행 명령", "tools/probe/lib.py", "uv run python tools/probe/lib.py", True),
                ("원고와 다른 인자를 지어냄", "scripts/emulator-up.sh", "scripts/emulator-up.sh 9999", True),
                ("원고에 쓰인 명령(근거 있음)", "scripts/env.sh", "source scripts/env.sh", False),
                ("labs 이름 규칙의 실행 파일", "curriculum/m06-integration-messaging/labs/lab01-sqs-basics.sh",
                 "bash curriculum/m06-integration-messaging/labs/lab01-sqs-basics.sh", False),
            ]:
                dist = Path(d) / f"run-{abs(hash(name))}"
                page = dist / "files" / rel / "index.html"
                page.parent.mkdir(parents=True)
                page.write_text(f'<main><div class="source-run"><pre><code>{cmd}</code></pre></div></main>', encoding="utf-8")
                g = sitecheck.gate_run_commands(dist)
                ok = bool(g.failures) == want_fail
                print(f"{'ok  ' if ok else 'BAD '} 실행 명령 관문: {name} → {g.failures[0] if g.failures else '통과'}")
                if not ok:
                    failures.append(name)
        # 내용 동등성: 원고 메타 줄의 백슬래시 이스케이프(CommonMark)는 화면 글자와 같게 풀고, 코드 스팬 안은 둔다
        from mdsource import strip_inline
        for md, want in [
            (r"D1\~D4, 2\~3시간", "D1~D4, 2~3시간"),
            (r"\*별표\* \a `x\~y`", r"*별표* \a x\~y"),
        ]:
            got = strip_inline(md)
            ok = got == want
            print(f"{'ok  ' if ok else 'BAD '} 내용 동등성 이스케이프: {md!r} → {got!r}")
            if not ok:
                failures.append(f"escape {md}")
        # 등급 이모지 관문: 라벨 없는 이모지를 심으면 잡고, 라벨이 붙은 것·코드 안은 통과
        import htmlbuilt
        for name, html, want_bare in [
            ("표 칸의 맨 이모지", '<div class="sl-markdown-content"><table><tr><td>\U0001F7E2</td></tr></table></div>', True),
            ("라벨 붙은 이모지", '<div class="sl-markdown-content"><p><span class="grade-mark"><span role="img" aria-label="부분">\U0001F7E1</span><span class="grade-mark-label" data-label="부분" aria-hidden="true"></span></span></p></div>', False),
            ("빈 라벨(data-label=\"\")", '<div class="sl-markdown-content"><p><span class="grade-mark"><span role="img" aria-label="부분">\U0001F7E1</span><span class="grade-mark-label" data-label="" aria-hidden="true"></span></span></p></div>', True),
            ("라벨 속성 없음", '<div class="sl-markdown-content"><p><span class="grade-badge"><span class="grade-emoji" role="img" aria-label="재현">\U0001F7E2</span><span class="grade-label" aria-hidden="true"></span></span></p></div>', True),
            ("빈 aria-label", '<div class="sl-markdown-content"><p><span class="grade-mark"><span role="img" aria-label=" ">\U0001F534</span><span class="grade-mark-label" data-label="개념" aria-hidden="true"></span></span></p></div>', True),
            ("이름 없이 숨긴 이모지", '<div class="sl-markdown-content"><p><span class="grade-mark"><span aria-hidden="true">\U0001F534</span><span class="grade-mark-label" data-label="개념" aria-hidden="true"></span></span></p></div>', True),
            ("보이는 라벨 없이 이름만(제목 안 옛 구조)", '<div class="sl-markdown-content"><h2 id="x">실습 <span class="grade-mark" role="img" aria-label="재현">\U0001F7E2</span></h2></div>', True),
            ("보이는 라벨 없이 이름만(라벨 칸 없음)", '<div class="sl-markdown-content"><p>등급 <span class="grade-mark"><span role="img" aria-label="개념">\U0001F534</span></span></p></div>', True),
            ("뒤에 라벨 글자가 있는 이모지", '<div class="sl-markdown-content"><p><span class="grade-mark">\U0001F7E2</span> 재현</p></div>', False),
            ("코드 안의 이모지", '<div class="sl-markdown-content"><pre><code># (\U0001F534)</code></pre></div>', False),
        ]:
            got = bool(sitecheck.bare_grade_emoji(htmlbuilt.content_root(htmlbuilt.parse(html))))
            ok = got == want_bare
            print(f"{'ok  ' if ok else 'BAD '} 등급 이모지 관문: {name} → {'잡음' if got else '통과'}")
            if not ok:
                failures.append(f"grades {name}")
        # 목차·사이드바: 본문은 라벨이 붙었는데 Starlight 가 같은 제목을 목차·사이드바에 이모지만으로 실은 경우를 잡는다
        body_ok = '<div class="sl-markdown-content"><h2 id="x">BPA <span class="grade-mark"><span role="img" aria-label="개념">\U0001F534</span><span class="grade-mark-label" data-label="개념" aria-hidden="true"></span></span></h2></div>'
        toc_ok = '<a href="#x"><span>BPA <span class="grade-mark"><span role="img" aria-label="개념">\U0001F534</span><span class="grade-mark-label" data-label="개념" aria-hidden="true"></span></span></span></a>'
        for name, html, want in [
            ("목차의 맨 이모지", f'{body_ok}<starlight-toc><nav><ul><li><a href="#x"><span>BPA \U0001F534</span></a></li></ul></nav></starlight-toc>', "목차"),
            ("좁은 화면 목차의 맨 이모지", f'{body_ok}<mobile-starlight-toc><nav><ul><li><a href="#x"><span>BPA \U0001F534</span></a></li></ul></nav></mobile-starlight-toc>', "좁은 화면 목차"),
            ("사이드바의 맨 이모지", f'{body_ok}<nav class="sidebar" aria-label="메인"><ul><li><a href="/a/"><span>실습 \U0001F7E2</span></a></li></ul></nav>', "사이드바"),
            ("라벨 붙은 목차·사이드바", f'{body_ok}<starlight-toc><nav><ul><li>{toc_ok}</li></ul></nav></starlight-toc><nav class="sidebar"><ul><li>{toc_ok}</li></ul></nav>', None),
        ]:
            hit = [w for w, n in sitecheck.grade_regions(htmlbuilt.parse(html)) if sitecheck.bare_grade_emoji(n)]
            ok = hit == ([want] if want else [])
            print(f"{'ok  ' if ok else 'BAD '} 등급 이모지 관문(목차·사이드바): {name} → {hit or '통과'}")
            if not ok:
                failures.append(f"grades {name}")
    finally:
        sitecheck.SITE = original_site
    if failures:
        print(f"FAIL selftest: {failures}")
        return 1
    print(f"PASS selftest: 정적 관문에 심은 결함 {len(STATIC_CASES)}가지와 실행 명령 결함 3가지를 모두 잡고, 근거 있는 경우는 통과, 메타 줄 이스케이프 2가지 일치, 등급 이모지 10가지(빈 라벨·빈 이름·이름만 있는 라벨 포함)와 목차·사이드바 4가지")
    return 0


if __name__ == "__main__":
    sys.exit(main())
