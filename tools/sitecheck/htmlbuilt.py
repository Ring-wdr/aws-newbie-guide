"""빌드 산출물(HTML)에서 검사에 필요한 것을 읽는다 — 표준 라이브러리 html.parser 만 쓴다."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


@dataclass
class Node:
    tag: str
    attrs: dict[str, str]
    children: list["Node | str"] = field(default_factory=list)
    parent: "Node | None" = None

    def cls(self) -> set[str]:
        return set(self.attrs.get("class", "").split())

    def text(self) -> str:
        out: list[str] = []

        def walk(n: "Node | str") -> None:
            if isinstance(n, str):
                out.append(n)
            elif n.tag not in ("template", "script", "style"):
                for c in n.children:
                    walk(c)

        walk(self)
        return "".join(out)

    def iter(self):
        yield self
        for c in self.children:
            if isinstance(c, Node):
                yield from c.iter()

    def find_all(self, pred):
        return [n for n in self.iter() if pred(n)]

    def ancestors(self):
        p = self.parent
        while p:
            yield p
            p = p.parent


class _Builder(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("#root", {})
        self.cur = self.root

    def handle_starttag(self, tag, attrs):
        node = Node(tag, {k: (v or "") for k, v in attrs}, parent=self.cur)
        self.cur.children.append(node)
        if tag not in VOID:
            self.cur = node

    def handle_startendtag(self, tag, attrs):
        self.cur.children.append(Node(tag, {k: (v or "") for k, v in attrs}, parent=self.cur))

    def handle_endtag(self, tag):
        n = self.cur
        while n is not self.root and n.tag != tag:
            n = n.parent  # type: ignore[assignment]
        if n is not self.root:
            self.cur = n.parent  # type: ignore[assignment]

    def handle_data(self, data):
        self.cur.children.append(data)


def parse(html: str) -> Node:
    b = _Builder()
    b.feed(html)
    b.close()
    return b.root


def content_root(doc: Node) -> Node | None:
    found = doc.find_all(lambda n: "sl-markdown-content" in n.cls())
    return found[0] if found else None


def outside_widgets(n: Node) -> bool:
    return not any(("exam-app" in a.cls() or "guide-widget" in a.cls()) for a in n.ancestors())


def page_title(doc: Node) -> str:
    h = doc.find_all(lambda n: n.tag == "h1" and n.attrs.get("id") == "_top")
    return re.sub(r"\s+", " ", h[0].text()).strip() if h else ""


def code_blocks(content: Node) -> list[str]:
    return [p.text() for p in content.find_all(lambda n: n.tag == "pre") if outside_widgets(p)]


def tables(content: Node) -> list[tuple[int, int]]:
    out = []
    for t in content.find_all(lambda n: n.tag == "table"):
        if not outside_widgets(t):
            continue
        rows = t.find_all(lambda n: n.tag == "tr")
        body = [r for r in rows if not any(a.tag == "thead" for a in r.ancestors())]
        cols = max((len([c for c in r.children if isinstance(c, Node) and c.tag in ("td", "th")]) for r in rows), default=0)
        out.append((len(body), cols))
    return out


def meta_text(content: Node) -> str | None:
    chips = content.find_all(lambda n: "meta-chip" in n.cls())
    if not chips:
        return None
    parts = []
    for chip in chips:
        dt = chip.find_all(lambda n: n.tag == "dt")[0].text()
        dd = chip.find_all(lambda n: n.tag == "dd")[0]

        def text_wo_labels(n) -> str:
            if isinstance(n, str):
                return n
            if "grade-label" in n.cls():
                return ""
            return "".join(text_wo_labels(c) for c in n.children)

        parts.append(f"{dt}: {text_wo_labels(dd)}")
    return re.sub(r"\s+", " ", " · ".join(parts)).strip()


def headings(content: Node) -> list[tuple[int, str]]:
    out = []
    for n in content.find_all(lambda n: n.tag in ("h2", "h3", "h4", "h5", "h6")):
        if outside_widgets(n):
            out.append((int(n.tag[1]), re.sub(r"\s+", " ", n.text()).strip()))
    return out
