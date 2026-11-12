"""M14 모의고사 채점기 — 답안 파일을 정답표(answer-key.md)와 비교해 도메인별 점수를 낸다.

AWS를 호출하지 않는 로컬 도구다(그래서 sdk/ 가 아니라 여기에 있고, emulator_guard 를 쓰지 않는다).

사용법 (저장소 루트에서):
    uv run python curriculum/m14-capstone-exam/mock-exam/grade.py my-answers.txt   # 채점
    uv run python curriculum/m14-capstone-exam/mock-exam/grade.py --stats          # 문항 통계·형식 점검
    uv run python curriculum/m14-capstone-exam/mock-exam/grade.py --key            # 정답을 답안 형식으로 출력(자가 시험용)

답안 파일 형식: 한 줄에 "번호 답" (예: "1 C", "6 BD", "34 B,D,F"). 답 뒤의 "?"는 "확신 없음" 표시.
빈 답·없는 번호는 오답(실제 시험도 무응답은 오답이며 추측에 감점이 없다). "#" 뒤는 주석.
복수 응답은 고른 글자 집합이 정답과 정확히 같아야 정답이다(부분 점수 없음).
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEY_FILE = HERE / "answer-key.md"
QUESTIONS_FILE = HERE / "questions.md"
DOMAINS = {"D1": "보안 아키텍처", "D2": "복원력 있는 아키텍처", "D3": "고성능 아키텍처", "D4": "비용 최적화 아키텍처"}
WEIGHTS = {"D1": 30, "D2": 26, "D3": 24, "D4": 20}  # 시험 가이드의 도메인 비중(%)
PASS_PCT = 72.0  # docs/CURRICULUM.md §7 의 자체 기준
TOTAL = 65


@dataclass(frozen=True)
class KeyItem:
    number: int
    answer: frozenset[str]
    domain: str
    task: str
    kind: str
    topic: str


def load_key(path: Path = KEY_FILE) -> dict[int, KeyItem]:
    row = re.compile(r"^\|\s*(\d+)\s*\|\s*([A-F]+)\s*\|\s*(D[1-4])\s*\|\s*([1-4]\.\d)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$")
    key: dict[int, KeyItem] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = row.match(line)
        if m:
            n = int(m.group(1))
            key[n] = KeyItem(n, frozenset(m.group(2)), m.group(3), m.group(4), m.group(5), m.group(6))
    return key


def load_questions(path: Path = QUESTIONS_FILE) -> dict[int, dict[str, object]]:
    """문항 번호 → {"options": [보기 글자...], "choose": 고를 개수}"""
    qs: dict[int, dict[str, object]] = {}
    current: int | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        h = re.match(r"^## 문항 (\d+)\s*$", line)
        if h:
            current = int(h.group(1))
            qs[current] = {"options": [], "choose": 1}
            continue
        if current is None:
            continue
        o = re.match(r"^- ([A-F])\. ", line)
        if o:
            qs[current]["options"].append(o.group(1))  # type: ignore[union-attr]
        if "(두 개를 고르시오.)" in line:
            qs[current]["choose"] = 2
        elif "(세 개를 고르시오.)" in line:
            qs[current]["choose"] = 3
    return qs


def check_consistency(key: dict[int, KeyItem], qs: dict[int, dict[str, object]]) -> list[str]:
    """정답표와 문제 파일이 서로 맞는지, 분포가 설계대로인지 점검. 문제 목록을 돌려준다(없으면 빈 목록)."""
    problems: list[str] = []
    if sorted(key) != list(range(1, TOTAL + 1)):
        problems.append(f"정답표 문항 번호가 1~{TOTAL}이 아님: {len(key)}개")
    if sorted(qs) != list(range(1, TOTAL + 1)):
        problems.append(f"문제 파일 문항 번호가 1~{TOTAL}이 아님: {len(qs)}개")
    for n, item in key.items():
        q = qs.get(n)
        if not q:
            continue
        opts, choose = q["options"], q["choose"]
        expected_opts = {1: 4, 2: 5, 3: 6}[choose]  # type: ignore[index]
        if len(opts) != expected_opts:  # type: ignore[arg-type]
            problems.append(f"{n}번: 보기 {len(opts)}개(기대 {expected_opts})")  # type: ignore[arg-type]
        if len(item.answer) != choose:
            problems.append(f"{n}번: 정답 {len(item.answer)}개인데 문제는 {choose}개 선택")
        if not item.answer <= set(opts):  # type: ignore[arg-type]
            problems.append(f"{n}번: 정답 {''.join(sorted(item.answer))} 이 보기에 없음")
        kind_ok = (item.kind == "단일") == (choose == 1)
        if not kind_ok:
            problems.append(f"{n}번: 유형 표기 '{item.kind}' 와 선택 개수 {choose} 불일치")
    # 해설 제목("### 6번 — B, D · D2(2.2) · 복수")의 정답·도메인이 정답표와 같은지
    heads = re.findall(r"^### (\d+)번 — ([A-F, ]+?) · (D[1-4])\(([1-4]\.\d)\)", KEY_FILE.read_text(encoding="utf-8"), re.M)
    seen = set()
    for n_s, ans, dom, task in heads:
        n = int(n_s)
        seen.add(n)
        item = key.get(n)
        if item and (frozenset(re.findall(r"[A-F]", ans)) != item.answer or dom != item.domain or task != item.task):
            problems.append(f"{n}번: 해설 제목({ans} {dom} {task})이 정답표와 다름")
    if seen != set(key):
        problems.append(f"해설이 없는 문항: {sorted(set(key) - seen)}")
    counts = Counter(i.domain for i in key.values())
    for d, w in WEIGHTS.items():
        target = round(TOTAL * w / 100)
        if abs(counts[d] - TOTAL * w / 100) > 1:
            problems.append(f"{d} 문항 수 {counts[d]} — 비중 {w}%(≈{target})에서 1문항 넘게 벗어남")
    singles = [next(iter(i.answer)) for i in key.values() if len(i.answer) == 1]
    for letter, c in Counter(singles).items():
        if singles and c / len(singles) > 0.30:
            problems.append(f"단일 응답 정답 {letter} 이 {c}/{len(singles)} = {c / len(singles):.0%} (30% 초과)")
    return problems


def print_stats(key: dict[int, KeyItem], qs: dict[int, dict[str, object]]) -> int:
    counts = Counter(i.domain for i in key.values())
    print("도메인별 문항 수 (시험 가이드 비중)")
    for d, name in DOMAINS.items():
        print(f"  {d} {name:<14} {counts[d]:>2}문항  {counts[d] / TOTAL:6.1%}  (가이드 {WEIGHTS[d]}%)")
    singles = [i for i in key.values() if len(i.answer) == 1]
    multis = [i for i in key.values() if len(i.answer) > 1]
    print(f"유형: 단일 응답 {len(singles)} · 복수 응답 {len(multis)} "
          f"(2개 선택 {sum(len(i.answer) == 2 for i in multis)}, 3개 선택 {sum(len(i.answer) == 3 for i in multis)})")
    sc = Counter(next(iter(i.answer)) for i in singles)
    print("단일 응답 정답 분포: " + " · ".join(f"{k} {sc[k]} ({sc[k] / len(singles):.1%})" for k in "ABCD"))
    mc = Counter(letter for i in multis for letter in i.answer)
    print("복수 응답 정답 글자: " + " · ".join(f"{k} {mc[k]}" for k in "ABCDEF"))
    tasks = Counter(i.task for i in key.values())
    print("과제(Task)별: " + " · ".join(f"{t} {tasks[t]}" for t in sorted(tasks)))
    problems = check_consistency(key, qs)
    if problems:
        print("\n형식 점검 실패:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("\n형식 점검 통과: 정답표와 문제 파일이 일치하고 분포 기준을 만족한다.")
    return 0


def parse_answers(path: Path) -> tuple[dict[int, frozenset[str]], set[int]]:
    answers: dict[int, frozenset[str]] = {}
    unsure: set[int] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"^(\d+)\s*[.:)]?\s*(.*)$", line)
        if not m:
            raise SystemExit(f"답안 형식을 읽을 수 없습니다: {raw!r} (예: '1 C', '6 BD')")
        n, rest = int(m.group(1)), m.group(2).upper()
        if "?" in rest:
            unsure.add(n)
        letters = frozenset(re.findall(r"[A-F]", rest))
        if letters:
            answers[n] = letters
    return answers, unsure


def grade(key: dict[int, KeyItem], answers: dict[int, frozenset[str]], unsure: set[int]) -> int:
    per = {d: [0, 0] for d in DOMAINS}
    wrong: list[KeyItem] = []
    lucky: list[int] = []
    for n, item in sorted(key.items()):
        per[item.domain][1] += 1
        if answers.get(n) == item.answer:
            per[item.domain][0] += 1
            if n in unsure:
                lucky.append(n)
        else:
            wrong.append(item)
    total_ok = sum(v[0] for v in per.values())
    print("도메인별 결과")
    weak = []
    for d, name in DOMAINS.items():
        ok, tot = per[d]
        pct = 100 * ok / tot
        bar = "█" * round(pct / 5) + "·" * (20 - round(pct / 5))
        print(f"  {d} {name:<14} {ok:>2}/{tot:<2} {pct:5.1f}%  {bar}")
        if pct < 65:
            weak.append(f"{d} {name}")
    pct = 100 * total_ok / len(key)
    print(f"\n전체 {total_ok}/{len(key)} = {pct:.1f}%   (무응답 {len(key) - len(answers.keys() & key.keys())}문항)")
    if pct >= PASS_PCT:
        print(f"판정: 통과 — 이 커리큘럼의 기준(정답률 {PASS_PCT:.0f}% 이상, CURRICULUM §7)을 넘었다.")
    else:
        print(f"판정: 미달 — 기준 {PASS_PCT:.0f}%까지 {PASS_PCT * len(key) / 100 - total_ok:.0f}문항 더 필요하다.")
    print("주의: 실제 시험의 720점은 100~1,000 환산 점수이고 채점 대상 50문항 기준이라 정답률과 1:1로 대응하지 않는다.")
    if weak:
        print("약한 도메인(65% 미만): " + ", ".join(weak) + " → 04 레슨의 마지막 주 계획에서 해당 모듈을 먼저 복습")
    if wrong:
        print("\n틀린 문항 (answer-key.md 의 해설과 '복습' 링크를 볼 것)")
        for i in wrong:
            mine = "".join(sorted(answers.get(i.number, frozenset()))) or "무응답"
            print(f"  {i.number:>2}번 {i.domain} {i.task} 내 답 {mine:<4} 정답 {''.join(sorted(i.answer)):<4} {i.topic}")
    if lucky:
        print("\n'?' 를 붙였지만 맞힌 문항(운일 수 있음 — 해설 확인): " + ", ".join(map(str, lucky)))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="M14 모의고사 채점기")
    ap.add_argument("answers", nargs="?", help="답안 파일 (한 줄에 '번호 답')")
    ap.add_argument("--stats", action="store_true", help="문항 통계와 형식 점검")
    ap.add_argument("--key", action="store_true", help="정답을 답안 형식으로 출력")
    args = ap.parse_args(argv)
    key = load_key()
    if args.stats:
        return print_stats(key, load_questions())
    if args.key:
        for n, item in sorted(key.items()):
            print(f"{n} {''.join(sorted(item.answer))}")
        return 0
    if not args.answers:
        ap.print_help()
        return 2
    answers, unsure = parse_answers(Path(args.answers))
    return grade(key, answers, unsure)


if __name__ == "__main__":
    sys.exit(main())
