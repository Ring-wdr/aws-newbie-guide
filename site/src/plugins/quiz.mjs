// 퀴즈(quiz.md) → 채점되는 문항 카드.
// 원고 형식: "---"로 나뉜 문항마다 "**N.** 질문" 문단, "- A. …" 보기 목록, <details><summary>정답과 해설</summary>
// 바로 다음 문단의 첫 굵은 글씨 "**B.**"(또는 "**B**")가 정답이다. 통과 기준은 머리말 인용문의 "NN%"에서 읽는다.
// 스크립트가 없으면 원고 그대로(보기 목록 + 펼치는 해설)처럼 읽힌다.
import { toString } from 'mdast-util-to-string';
import { ko } from '../i18n/ko.mjs';
import { box, html, esc } from './util.mjs';

const Q_RE = /^(\d+)\.$/;
const OPT_RE = /^([A-F])\.\s/;

function questionNumber(node) {
  if (node?.type !== 'paragraph') return null;
  const first = node.children[0];
  if (first?.type !== 'strong') return null;
  const m = Q_RE.exec(toString(first).trim());
  return m ? Number(m[1]) : null;
}

const isDetailsOpen = (n) => n?.type === 'html' && /^<details>\s*<summary>/.test(n.value.trim());
const isDetailsClose = (n) => n?.type === 'html' && /^<\/details>\s*$/.test(n.value.trim());

/** 해설 첫 문단의 첫 굵은 글씨에서 정답 글자를 읽는다("B." / "B" / "B, D."). */
export function answerFrom(node) {
  if (node?.type !== 'paragraph') return null;
  const first = node.children[0];
  if (first?.type !== 'strong') return null;
  const m = /^([A-F](?:\s*,\s*[A-F])*)\.?$/.exec(toString(first).trim());
  return m ? m[1].replace(/[\s,]/g, '') : null;
}

function optionsFrom(list, qn) {
  const opts = [];
  for (const item of list.children) {
    const p = item.children[0];
    if (item.children.length !== 1 || p?.type !== 'paragraph') return null;
    const m = OPT_RE.exec(toString(p));
    if (!m) return null;
    opts.push({ letter: m[1], inline: p.children });
  }
  const choose = 1;
  const inputs = opts.map((o) =>
    box('label', { className: ['quiz-option'], dataLetter: o.letter }, [
      html(`<input type="radio" name="quiz-q${qn}" value="${o.letter}">`),
      box('span', { className: ['quiz-option-text'] }, o.inline),
    ]),
  );
  return {
    letters: opts.map((o) => o.letter),
    choose,
    node: box('fieldset', { className: ['quiz-options'] }, [
      html(`<legend class="sr-only">${esc(`${ko.quiz.question} ${qn} — ${ko.quiz.choose}`)}</legend>`),
      ...inputs,
    ]),
  };
}

export function passPercentFrom(tree) {
  const bq = tree.children.find((n) => n.type === 'blockquote');
  const m = bq ? /(\d+)%/.exec(toString(bq)) : null;
  return m ? Number(m[1]) : null;
}

export function transformQuiz(tree, ctx) {
  const { rep } = ctx;
  rep.touch('quiz');
  const kids = tree.children;
  const out = [];
  const questions = [];
  let i = 0;
  while (i < kids.length) {
    const qn = questionNumber(kids[i]);
    if (qn === null) {
      out.push(kids[i++]);
      continue;
    }
    // 문항 하나: 질문 문단 … 보기 목록 … <details> … </details>
    let j = i + 1;
    const stem = [kids[i]];
    while (j < kids.length && kids[j].type !== 'list' && !isDetailsOpen(kids[j]) && kids[j].type !== 'thematicBreak') stem.push(kids[j++]);
    const list = kids[j]?.type === 'list' ? kids[j] : null;
    if (list) j++;
    const open = isDetailsOpen(kids[j]) ? kids[j] : null;
    let close = -1;
    if (open) {
      for (let k = j + 1; k < kids.length; k++) {
        if (isDetailsClose(kids[k])) {
          close = k;
          break;
        }
        if (kids[k].type === 'thematicBreak' || questionNumber(kids[k]) !== null) break;
      }
    }
    const opts = list ? optionsFrom(list, qn) : null;
    const answer = open && close > j ? answerFrom(kids[j + 1]) : null;
    const problems = [];
    if (!list) problems.push('보기 목록 없음');
    else if (!opts) problems.push('보기 형식이 "- A. …"가 아님');
    if (!open || close < 0) problems.push('<details> 해설 없음');
    else if (!answer) problems.push('해설 첫 굵은 글씨에서 정답 글자를 못 읽음');
    if (opts && answer && ![...answer].every((a) => opts.letters.includes(a))) problems.push(`정답 ${answer}이 보기에 없음`);
    if (problems.length) {
      rep.unrecognised('quiz', `${qn}번: ${problems.join(', ')}`, kids[i]);
      out.push(kids[i++]);
      continue;
    }
    const explain = kids.slice(j + 1, close);
    const openHtml = open.value.replace(/^<details>/, '<details class="quiz-explain">');
    const card = box(
      'section',
      { className: ['quiz-q'], dataQ: String(qn), dataAnswer: answer, ariaLabel: `${ko.quiz.question} ${qn}` },
      [
        ...stem,
        opts.node,
        html(
          `<div class="quiz-actions" hidden><button type="button" class="quiz-check" disabled>${esc(ko.quiz.submit)}</button>` +
            `<p class="quiz-verdict" role="status" aria-live="polite" tabindex="-1"></p></div>`,
        ),
        html(openHtml),
        ...explain,
        kids[close],
      ],
    );
    out.push(card);
    questions.push({ n: qn, answer });
    rep.handled('quiz');
    i = close + 1;
  }
  if (!questions.length) {
    tree.children = out;
    rep.note('quiz', 'no-questions');
    return;
  }
  const pass = passPercentFrom(tree);
  if (pass === null) rep.unrecognised('quiz', '머리말에서 통과 기준(NN%)을 못 읽음 — 80%로 둔다', tree.children[0]);
  const pct = pass ?? 80;
  const need = Math.ceil((questions.length * pct) / 100);
  const summary = html(
    `<aside class="quiz-summary" data-pass="${pct}" data-total="${questions.length}" data-need="${need}" aria-label="${esc(ko.quiz.heading)}">` +
      `<p class="quiz-passmark">${esc(ko.quiz.passMark(pct, need, questions.length))}</p>` +
      `<div class="quiz-progress" hidden><p class="quiz-score" role="status" aria-live="polite"></p>` +
      `<button type="button" class="quiz-reset">${esc(ko.quiz.reset)}</button></div>` +
      `<p class="quiz-noscript">${esc(ko.quiz.noScriptNote)}</p>` +
      `<div data-guide-storage></div>` +
      `</aside>`,
  );
  // 요약은 첫 문항 앞(머리말 뒤)에 둔다.
  const firstQ = out.findIndex((n) => n.type === 'guideBox' && n.data.hProperties.className?.includes('quiz-q'));
  out.splice(Math.max(0, firstQ > 0 && out[firstQ - 1].type === 'thematicBreak' ? firstQ - 1 : firstQ), 0, summary);
  tree.children = out;
  ctx.quiz = { pass: pct, questions };
}
