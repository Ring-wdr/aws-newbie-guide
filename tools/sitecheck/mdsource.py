"""원고 Markdown에서 검사에 필요한 것만 읽는다(사이트 변환기와 독립된 구현 — 같은 버그를 공유하지 않게).

- 제목(H1), 펜스 코드 블록(바이트 그대로), 표의 행·열 수, 레슨 메타 줄, 퀴즈 정답.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

FENCE_OPEN = re.compile(r"^(?P<indent>[ \t]*(?:>[ \t]?)*[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
TABLE_DELIM = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")


@dataclass
class CodeBlock:
    lang: str
    text: str
    line: int


@dataclass
class Source:
    title: str
    codes: list[CodeBlock] = field(default_factory=list)
    tables: list[tuple[int, int, int]] = field(default_factory=list)  # (줄, 본문 행 수, 열 수)
    meta: str | None = None
    headings: list[tuple[int, int, str]] = field(default_factory=list)  # (줄, 단계, 글자) — H2~H6


def strip_inline(md: str) -> str:
    """제목·메타 비교용: 링크 [글](주소) → 글, 굵게·기울임·코드 표시를 뺀다."""
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", md)
    s = re.sub(r"(\*\*|__)(.+?)\1", r"\2", s)
    # CommonMark: ASCII 구두점 앞의 백슬래시만 이스케이프로 푼다. 코드 스팬 안은 그대로 둔다.
    parts = re.split(r"(`[^`]*`)", s)
    s = "".join(p[1:-1] if p.startswith("`") and p.endswith("`") and len(p) > 1
                else re.sub(r"\\([!-/:-@\[-`{-~])", r"\1", p) for p in parts)
    return re.sub(r"\s+", " ", s).strip()


def split_cells(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return re.split(r"(?<!\\)\|", s)


def parse(text: str, is_lesson: bool = False) -> Source:
    lines = text.split("\n")
    title = ""
    for ln in lines:
        if ln.strip():
            m = re.match(r"^#\s+(.+?)\s*#*\s*$", ln)
            title = strip_inline(m.group(1)) if m else ""
            break
    src = Source(title=title)
    # 메타 줄: 제목 다음의 "> 도메인: …"
    for ln in lines[1:4] if is_lesson else []:
        if ln.startswith("> 도메인:"):
            src.meta = strip_inline(ln[2:])
            break
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i]
        m = FENCE_OPEN.match(ln)
        if m and not (m.group("fence")[0] == "`" and "`" in m.group("info")):
            fence = m.group("fence")
            prefix = m.group("indent")
            indent = len(prefix.replace("\t", "    "))
            quote = ">" in prefix
            lang = m.group("info").strip().split(" ")[0] if m.group("info").strip() else ""
            body: list[str] = []
            j = i + 1
            close = re.compile(r"^[ \t]*(?:>[ \t]?)*[ \t]*" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*$")
            while j < n and not close.match(lines[j]):
                raw = lines[j]
                if quote:
                    raw = re.sub(r"^[ \t]*>[ \t]?", "", raw)
                    body.append(raw)
                else:
                    # 여는 펜스의 들여쓰기만큼 앞 공백을 걷어 낸다(CommonMark)
                    k = 0
                    while k < indent and k < len(raw) and raw[k] == " ":
                        k += 1
                    body.append(raw[k:])
                j += 1
            src.codes.append(CodeBlock(lang=lang, text="\n".join(body), line=i + 1))
            i = j + 1
            continue
        h = re.match(r"^ {0,3}(#{2,6})\s+(.+?)\s*#*\s*$", ln)
        if h:
            src.headings.append((i + 1, len(h.group(1)), strip_inline(h.group(2))))
        # GFM 표: 머리글 줄 + 구분 줄 (인용문 안의 표도 센다)
        unq = lambda s: re.sub(r"^\s*(?:>\s?)+", "", s)  # noqa: E731
        if "|" in ln and i + 1 < n and TABLE_DELIM.match(unq(lines[i + 1])) and "-" in lines[i + 1]:
            cols = len(split_cells(unq(ln)))
            j = i + 2
            rows = 0
            while j < n and unq(lines[j]).strip() and "|" in lines[j] and not FENCE_OPEN.match(lines[j]):
                rows += 1
                j += 1
            src.tables.append((i + 1, rows, cols))
            i = j
            continue
        i += 1
    return src


QUIZ_Q = re.compile(r"^\*\*(\d+)\.\*\*")
QUIZ_ANSWER = re.compile(r"^\*\*([A-F](?:\s*,\s*[A-F])*)\.?\*\*")


def quiz_answers(text: str) -> tuple[dict[int, str], int | None]:
    """퀴즈 원고 → {문항 번호: 정답 글자}, 통과 기준 %."""
    answers: dict[int, str] = {}
    current = None
    in_details = False
    for ln in text.split("\n"):
        m = QUIZ_Q.match(ln)
        if m:
            current = int(m.group(1))
            in_details = False
            continue
        if ln.startswith("<details>"):
            in_details = True
            continue
        if in_details and current is not None and current not in answers:
            a = QUIZ_ANSWER.match(ln.strip())
            if a:
                answers[current] = re.sub(r"[\s,]", "", a.group(1))
    head = "\n".join(ln for ln in text.split("\n")[:6] if ln.startswith(">"))
    pm = re.search(r"(\d+)%", head)
    return answers, (int(pm.group(1)) if pm else None)
