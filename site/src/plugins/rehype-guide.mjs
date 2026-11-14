// HTML 단계 마무리: 넓은 표를 자체 스크롤 상자로 감싼다(360px 화면에서 본문은 가로로 밀리지 않고 표만 스크롤).
// 상자는 키보드로도 스크롤할 수 있게 tabindex를 준다.
import { ko } from '../i18n/ko.mjs';
import { gradeLegend } from './meta.mjs';

export function rehypeGuide() {
  return (tree) => {
    let n = 0;
    const walk = (node) => {
      if (!node.children) return;
      for (let i = 0; i < node.children.length; i++) {
        const c = node.children[i];
        if (c.type === 'element' && c.tagName === 'table') {
          n++;
          node.children[i] = {
            type: 'element',
            tagName: 'div',
            properties: { className: ['table-scroll'], tabIndex: 0, role: 'region', ariaLabel: ko.table.region(n) },
            children: [c],
          };
          continue;
        }
        walk(c);
      }
    };
    walk(tree);
    gradeMarks(tree, false);
    labelTaskCheckboxes(tree);
    keepMiddleDotRuns(tree);
    breakableTokensInCells(tree, false);
  };
}

// "알림·정산"처럼 가운뎃점(·)으로 이은 낱말이 줄 끝에서 "알림 / ·정산"으로 갈리지 않게 묶는다.
// (word-break: keep-all 은 한글과 가운뎃점 사이의 줄바꿈을 막지 못한다.) 글자는 바꾸지 않고 <span>으로 감싸기만 한다.
// 묶음은 가운뎃점 뒤에서만 줄을 바꿀 수 있게 조각("알림·", "정산")마다 inline-block 으로 감싸고 조각 사이에 <wbr>을 둔다.
// (예전처럼 묶음 전체를 한 덩어리로 두면 표 칸보다 긴 묶음이 칸을 넘어 옆 칸과 겹쳤다.) 코드·SVG 안은 건드리지 않는다.
const SKIP = new Set(['pre', 'code', 'svg', 'script', 'style', 'kbd', 'foreignObject']);
const RUN = /[^\s·]+(?:·[^\s·]+)+/g;
function keepMiddleDotRuns(node) {
  if (!node.children) return;
  if (node.type === 'element' && SKIP.has(node.tagName)) return;
  const out = [];
  for (const c of node.children) {
    if (c.type === 'text' && c.value.includes('·')) {
      let last = 0;
      for (const m of c.value.matchAll(RUN)) {
        if (m.index > last) out.push({ type: 'text', value: c.value.slice(last, m.index) });
        m[0].split(/(?<=·)/).forEach((piece, k) => {
          if (k > 0) out.push({ type: 'element', tagName: 'wbr', properties: {}, children: [] });
          out.push({ type: 'element', tagName: 'span', properties: { className: ['nb'] }, children: [{ type: 'text', value: piece }] });
        });
        last = m.index + m[0].length;
      }
      if (last < c.value.length) out.push({ type: 'text', value: c.value.slice(last) });
      continue;
    }
    keepMiddleDotRuns(c);
    out.push(c);
  }
  node.children = out;
}

// 표 칸 안의 긴 영문·기호 토큰(공백 없는 ASCII 16자 이상: API 이름, JSON, 주소)은 어디서든 끊을 수 있게 표시한다(.brk).
// 한국어 낱말은 그대로 keep-all 이라 낱말 중간에서 끊기지 않는다. 인라인 코드는 CSS 가 같은 규칙을 준다.
const LONG_TOKEN = /[!-~]{16,}/g;
// 칸 안 인라인 코드의 줄바꿈 자리: 구분 기호(. / :: , _ = · ( 등) 뒤와 낱말 경계(소문자→대문자) 앞에 <wbr>.
// 글자는 그대로이고(복사해도 같다) <wbr>은 "여기서 끊어도 된다"는 표시일 뿐이다.
const CODE_BREAK = /(?<=[./,_=·(&|]|::)(?=[^\s.,:)])|(?<=[a-z0-9])(?=[A-Z][a-z])/g;
function wbrCode(code) {
  const out = [];
  for (const c of code.children) {
    if (c.type !== 'text' || c.value.length < 12) {
      out.push(c);
      continue;
    }
    c.value.split(CODE_BREAK).forEach((piece, k) => {
      if (k > 0) out.push({ type: 'element', tagName: 'wbr', properties: {}, children: [] });
      out.push({ type: 'text', value: piece });
    });
  }
  code.children = out;
}
function breakableTokensInCells(node, inCell) {
  if (!node.children) return;
  if (inCell && node.type === 'element' && node.tagName === 'code') return wbrCode(node);
  if (node.type === 'element' && SKIP.has(node.tagName)) return;
  const here = inCell || (node.type === 'element' && (node.tagName === 'td' || node.tagName === 'th'));
  const out = [];
  for (const c of node.children) {
    if (here && c.type === 'text' && /^\s*·\s*$/.test(c.value)) {
      // `A`·`B` 처럼 코드 사이에 놓인 가운뎃점: 그 뒤에서 줄을 바꿀 수 있게
      out.push(c, { type: 'element', tagName: 'wbr', properties: {}, children: [] });
      continue;
    }
    if (here && c.type === 'text' && LONG_TOKEN.test(c.value)) {
      LONG_TOKEN.lastIndex = 0;
      let last = 0;
      for (const m of c.value.matchAll(LONG_TOKEN)) {
        if (m.index > last) out.push({ type: 'text', value: c.value.slice(last, m.index) });
        out.push({ type: 'element', tagName: 'span', properties: { className: ['brk'] }, children: [{ type: 'text', value: m[0] }] });
        last = m.index + m[0].length;
      }
      if (last < c.value.length) out.push({ type: 'text', value: c.value.slice(last) });
      continue;
    }
    LONG_TOKEN.lastIndex = 0;
    breakableTokensInCells(c, here);
    out.push(c);
  }
  node.children = out;
}

// 본문(표 칸·문단)의 등급 이모지 🟢/🟡/🔴 에 글자 라벨을 붙인다(원칙 6: 색만으로 정보를 전달하지 않는다).
// 원고 글자(이모지)는 그대로 두고 뒤에 작은 라벨(.grade-mark-label, 원고 README 등급 표의 "재현/부분/개념")을 덧붙인다.
// 바로 뒤에 같은 라벨이 이미 적혀 있으면("🟢 재현") 덧붙이지 않는다. 제목(h1~h6)은 글자를 더하면 앵커가 바뀌므로
// 라벨 대신 접근 가능한 이름(role=img + aria-label)만 준다. 메타 칩의 배지·범례와 코드 안은 건드리지 않는다.
const GRADE_CLASS = { '🟢': 'g', '🟡': 'y', '🔴': 'r' };
const GRADE_RE = /(🟢|🟡|🔴)/u;
const GRADE_SKIP_CLASS = ['grade-badge', 'grade-legend', 'meta-chip', 'grade-mark'];
function gradeMarks(node, inHeading) {
  if (!node.children) return;
  if (node.type === 'element') {
    if (SKIP.has(node.tagName) || node.tagName === 'title') return;
    const cls = node.properties?.className || [];
    if (GRADE_SKIP_CLASS.some((c) => cls.includes(c))) return;
    if (/^h[1-6]$/.test(node.tagName)) inHeading = true;
  }
  const legend = gradeLegend();
  const out = [];
  const kids = node.children;
  for (let i = 0; i < kids.length; i++) {
    const c = kids[i];
    if (c.type !== 'text' || !GRADE_RE.test(c.value)) {
      gradeMarks(c, inHeading);
      out.push(c);
      continue;
    }
    const parts = c.value.split(/(🟢|🟡|🔴)/u);
    parts.forEach((part, k) => {
      if (!part) return;
      if (!GRADE_CLASS[part]) return out.push({ type: 'text', value: part });
      const { label, meaning } = legend[part];
      const after = (parts.slice(k + 1).join('') || (kids[i + 1]?.type === 'text' ? kids[i + 1].value : '')).trimStart();
      const props = { className: ['grade-mark', `grade-mark-${GRADE_CLASS[part]}`], title: `${label}: ${meaning}` };
      if (inHeading) {
        out.push({ type: 'element', tagName: 'span', properties: { ...props, role: 'img', ariaLabel: label }, children: [{ type: 'text', value: part }] });
      } else if (after.startsWith(label)) {
        out.push({ type: 'element', tagName: 'span', properties: props, children: [{ type: 'text', value: part }] });
      } else {
        out.push({
          type: 'element',
          tagName: 'span',
          properties: props,
          children: [
            { type: 'element', tagName: 'span', properties: { ariaHidden: 'true' }, children: [{ type: 'text', value: part }] },
            { type: 'element', tagName: 'span', properties: { className: ['grade-mark-label'] }, children: [{ type: 'text', value: label }] },
          ],
        });
      }
    });
  }
  node.children = out;
}

// GFM 작업 목록(- [ ] 항목)의 체크 상자는 글자 라벨이 없어 스크린 리더에 이름 없이 읽힌다(axe label 규칙).
// 그 항목의 글을 접근 가능한 이름으로 준다(화면은 그대로).
const textOf = (n) => (n.type === 'text' ? n.value : (n.children || []).map(textOf).join(''));
function labelTaskCheckboxes(node) {
  if (!node.children) return;
  if (node.type === 'element' && node.tagName === 'li' && (node.properties?.className || []).includes('task-list-item')) {
    const box = node.children.find((c) => c.type === 'element' && c.tagName === 'input' && c.properties?.type === 'checkbox');
    if (box && !box.properties.ariaLabel) {
      const label = textOf(node).replace(/\s+/g, ' ').trim().slice(0, 120);
      if (label) box.properties.ariaLabel = label;
    }
  }
  for (const c of node.children) labelTaskCheckboxes(c);
}
