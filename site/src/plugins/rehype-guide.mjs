// HTML 단계 마무리: 넓은 표를 자체 스크롤 상자로 감싼다(360px 화면에서 본문은 가로로 밀리지 않고 표만 스크롤).
// 상자는 키보드로도 스크롤할 수 있게 tabindex를 준다.
import { ko } from '../i18n/ko.mjs';

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

