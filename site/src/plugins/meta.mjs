// 레슨 둘째 줄 "> 도메인: … · 예상 시간: … · 실습 등급: …" → 메타 칩 + 등급 배지(글자 라벨) + 범례.
// 등급 칸은 원문을 한 글자도 버리지 않는다: 🟢/🟡/🔴 앞뒤의 글(실습별로 나뉜 값, "—", 링크)을 그대로 두고,
// 이모지 자리에만 글자 라벨을 덧붙인 배지를 놓는다.
import fs from 'node:fs';
import path from 'node:path';
import { toString } from 'mdast-util-to-string';
import { REPO_ROOT } from '../lib/repo.mjs';
import { ko } from '../i18n/ko.mjs';
import { box, html, esc } from './util.mjs';

const EMOJI = ['🟢', '🟡', '🔴'];
const CLASS = { '🟢': 'g', '🟡': 'y', '🔴': 'r' };

let legendCache;
/** 저장소 README의 등급 표("| 🟢 재현 | 뜻 |")를 읽는다. 등급의 글자 라벨과 뜻은 원고가 원본이다. */
export function gradeLegend() {
  if (legendCache) return legendCache;
  const text = fs.readFileSync(path.join(REPO_ROOT, 'README.md'), 'utf8');
  const legend = {};
  for (const line of text.split('\n')) {
    const m = /^\|\s*(🟢|🟡|🔴)\s+([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$/.exec(line);
    if (m) legend[m[1]] = { label: m[2], meaning: m[3] };
  }
  for (const e of EMOJI) {
    if (!legend[e]) throw new Error(`README.md의 등급 표에서 ${e} 줄을 찾지 못했다 — 등급 배지의 라벨은 그 표에서 읽는다`);
  }
  legendCache = legend;
  return legend;
}

/** 인라인 노드 목록을 [start,end) 글자 구간으로 자른다. 구간 경계가 텍스트가 아닌 노드 안에 떨어지면 null. */
function sliceInline(children, start, end) {
  const out = [];
  let pos = 0;
  for (const node of children) {
    const len = toString(node).length;
    const a = pos;
    const b = pos + len;
    pos = b;
    if (b <= start || a >= end) continue;
    if (a >= start && b <= end) {
      out.push(node);
      continue;
    }
    if (node.type !== 'text') return null;
    out.push({ type: 'text', value: node.value.slice(Math.max(0, start - a), Math.min(len, end - a)) });
  }
  return out;
}

function badge(emoji) {
  const { label, meaning } = gradeLegend()[emoji];
  return html(
    `<span class="grade-badge grade-${CLASS[emoji]}" title="${esc(`${label}: ${meaning}`)}">` +
      `<span class="grade-emoji" aria-hidden="true">${emoji}</span><span class="grade-label" data-label="${esc(label)}"></span></span>`, // 라벨은 생성 콘텐츠(복사되지 않음)
  );
}

/** 등급 구간의 텍스트에서 이모지마다 배지를 끼운다(텍스트는 그대로 남긴다). */
function withBadges(nodes) {
  const out = [];
  let count = 0;
  for (const node of nodes) {
    if (node.type !== 'text') {
      out.push(node);
      continue;
    }
    const parts = node.value.split(/(🟢|🟡|🔴)/u);
    for (const p of parts) {
      if (!p) continue;
      if (EMOJI.includes(p)) {
        out.push(badge(p));
        count++;
      } else out.push({ type: 'text', value: p });
    }
  }
  return { nodes: out, count };
}

function legendHtml() {
  const lg = gradeLegend();
  const items = EMOJI.map(
    (e) =>
      `<li><span class="grade-badge grade-${CLASS[e]}"><span class="grade-emoji" aria-hidden="true">${e}</span><span class="grade-label" data-label="${esc(lg[e].label)}"></span></span> ${esc(lg[e].meaning)}</li>`,
  ).join('');
  return `<details class="grade-legend"><summary>${esc(ko.meta.legendTitle)}</summary><ul>${items}</ul><p class="grade-legend-src">${esc(ko.meta.legendSource)}</p></details>`;
}

const META_RE = /^도메인:\s*(.*?)\s+·\s+예상 시간:\s*(.*?)\s+·\s+실습 등급:\s*(.*)$/su;

export function transformMeta(tree, ctx) {
  const { rep } = ctx;
  rep.touch('meta');
  const idx = tree.children.findIndex((n) => n.type === 'blockquote');
  const bq = idx >= 0 ? tree.children[idx] : null;
  // 메타 줄은 제목 바로 다음 블록이어야 한다.
  const firstBlock = tree.children.find((n) => n.type !== 'heading' || n.depth !== 1);
  if (!bq || bq !== firstBlock || bq.children[0]?.type !== 'paragraph') {
    rep.unrecognised('meta', '제목 다음에 메타 인용문이 없음', tree.children[0]);
    return;
  }
  const para = bq.children[0];
  const text = toString(para);
  const firstLine = text.split('\n')[0];
  const m = new RegExp(META_RE.source, 'du').exec(firstLine);
  if (!m) {
    rep.unrecognised('meta', `메타 줄 형식이 다름: ${firstLine.slice(0, 60)}`, para);
    return;
  }
  const lineInline = sliceInline(para.children, 0, firstLine.length);
  const segs = [1, 2, 3].map((g) => sliceInline(lineInline || [], m.indices[g][0], m.indices[g][1]));
  if (!lineInline || segs.some((s) => s === null)) {
    rep.unrecognised('meta', '메타 줄의 구분 기호가 링크·서식 안에 있음', para);
    return;
  }
  const gradeText = m[3];
  const { nodes: gradeNodes, count } = withBadges(segs[2]);
  const kind = /^[🟢🟡🔴]$/u.test(gradeText.trim()) ? 'single' : gradeText.trim().startsWith('—') ? 'dash' : 'compound';
  rep.note('meta', `grade:${kind}`);
  if (kind !== 'dash' && count === 0) rep.note('meta', 'grade:no-emoji');

  const chip = (cls, label, children, key) =>
    box('div', { className: ['meta-chip', cls], dataMetaKey: key }, [
      box('dt', {}, [{ type: 'text', value: label }]),
      box('dd', {}, children),
    ]);
  const chips = box('div', { className: ['lesson-meta'] }, [
    box('dl', { className: ['meta-chips'] }, [
      chip('meta-domain', ko.meta.domain, segs[0], 'domain'),
      chip('meta-time', ko.meta.time, segs[1], 'time'),
      chip('meta-grade', ko.meta.grade, gradeNodes, 'grade'),
    ]),
    html(legendHtml()),
  ]);
  // 메타 줄 뒤에 같은 인용문 안에 다른 줄이 있으면(드묾) 인용문으로 남긴다.
  const restText = text.slice(firstLine.length).trim();
  const replacement = [chips];
  if (restText || bq.children.length > 1) {
    const restInline = sliceInline(para.children, firstLine.length, text.length);
    const rest = [];
    if (restInline && restText) rest.push({ type: 'paragraph', children: restInline });
    rest.push(...bq.children.slice(1));
    replacement.push({ type: 'blockquote', children: rest });
    rep.note('meta', 'extra-lines-kept');
  }
  tree.children.splice(idx, 1, ...replacement);
  ctx.meta = { domain: m[1], time: m[2], grade: m[3] };
  rep.handled('meta');
}
