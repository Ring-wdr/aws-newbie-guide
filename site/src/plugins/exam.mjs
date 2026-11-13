// M14 모의고사.
// questions.md: "## 문항 N" 절마다 보기 목록("- A. …")을 고를 수 있는 입력으로 바꾸고(복수 응답은 체크박스),
//               첫 문항 앞에 시험 모드 장치 자리(data-guide-component="exam")를 둔다.
// answer-key.md: "### N번 — …" 해설 절을 <section data-exam-explain="N">로 감싸 시험 모드의 검토 화면이 가져다 쓴다.
import { toString } from 'mdast-util-to-string';
import { ko } from '../i18n/ko.mjs';
import { box, html, esc } from './util.mjs';

function sectionRanges(kids, depth, re) {
  const out = [];
  for (let i = 0; i < kids.length; i++) {
    const h = kids[i];
    if (h.type !== 'heading' || h.depth !== depth) continue;
    const m = re.exec(toString(h));
    if (!m) continue;
    let j = i + 1;
    while (j < kids.length && !(kids[j].type === 'heading' && kids[j].depth <= depth) && kids[j].type !== 'thematicBreak') j++;
    out.push({ n: Number(m[1]), start: i, end: j });
  }
  return out;
}

export function transformExamQuestions(tree, ctx) {
  const { rep } = ctx;
  rep.touch('exam');
  const kids = tree.children;
  const ranges = sectionRanges(kids, 2, /^문항 (\d+)$/);
  // 뒤에서부터 바꿔야 앞 구간의 위치가 유지된다.
  for (const r of [...ranges].reverse()) {
    const body = kids.slice(r.start, r.end);
    const text = body.map((n) => toString(n)).join('\n');
    const choose = text.includes('(두 개를 고르시오.)') ? 2 : text.includes('(세 개를 고르시오.)') ? 3 : 1;
    const li = body.findIndex((n) => n.type === 'list');
    const list = body[li];
    const items = list?.children.map((it) => ({ p: it.children[0], ok: it.children.length === 1 && it.children[0]?.type === 'paragraph' }));
    const letters = items?.map((it) => (it.ok ? /^([A-F])\.\s/.exec(toString(it.p))?.[1] : null));
    if (!list || letters.some((l) => !l)) {
      rep.unrecognised('exam', `문항 ${r.n}: 보기 목록 "- A. …"을 찾지 못함`, kids[r.start]);
      continue;
    }
    const type = choose === 1 ? 'radio' : 'checkbox';
    const fieldset = box('fieldset', { className: ['exam-options'], dataChoose: String(choose) }, [
      html(`<legend class="sr-only">${esc(`${ko.exam.question(r.n)} — ${choose === 1 ? ko.quiz.choose : ko.exam.chooseN(choose)}`)}</legend>`),
      ...items.map((it, k) =>
        box('label', { className: ['exam-option'], dataLetter: letters[k] }, [
          html(`<input type="${type}" name="exam-q${r.n}" value="${letters[k]}">`),
          box('span', { className: ['exam-option-text'] }, it.p.children),
        ]),
      ),
    ]);
    body[li] = fieldset;
    const section = box('section', { className: ['exam-q'], dataQ: String(r.n), dataChoose: String(choose) }, body);
    kids.splice(r.start, r.end - r.start, section);
    rep.handled('exam');
    rep.note('exam', choose === 1 ? 'single' : `multi-${choose}`);
  }
  // 시험 장치 자리: 첫 문항(또는 그 앞의 구분선) 앞.
  const first = kids.findIndex((n) => n.type === 'guideBox' && n.data.hProperties.className?.includes('exam-q'));
  if (first >= 0) {
    const at = first > 0 && kids[first - 1].type === 'thematicBreak' ? first - 1 : first;
    kids.splice(at, 0, html('<div data-guide-component="exam"></div>'));
    ctx.widgets ??= [];
  } else {
    rep.unrecognised('exam', '문항 절("## 문항 N")이 하나도 없음', kids[0]);
  }
}

export function transformExamKey(tree, ctx) {
  const { rep } = ctx;
  rep.touch('exam');
  const kids = tree.children;
  const ranges = sectionRanges(kids, 3, /^(\d+)번\s+—/);
  for (const r of [...ranges].reverse()) {
    const body = kids.slice(r.start, r.end);
    kids.splice(r.start, r.end - r.start, box('section', { className: ['exam-explain'], dataExamExplain: String(r.n) }, body));
    rep.handled('exam');
    rep.note('exam', 'explanation');
  }
  if (!ranges.length) rep.unrecognised('exam', '해설 절("### N번 — …")이 없음', kids[0]);
}
