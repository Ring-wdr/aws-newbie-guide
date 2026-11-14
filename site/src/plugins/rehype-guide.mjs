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
  };
}

// "알림·정산"처럼 가운뎃점(·)으로 이은 낱말이 줄 끝에서 "알림 / ·정산"으로 갈리지 않게 한 덩어리로 묶는다.
// (word-break: keep-all 은 한글과 가운뎃점 사이의 줄바꿈을 막지 못한다.) 글자는 바꾸지 않고 <span>으로 감싸기만 한다.
// 덩어리가 한 줄보다 길면 inline-block 안에서 다시 줄바꿈된다. 코드·SVG 안은 건드리지 않는다.
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
        out.push({ type: 'element', tagName: 'span', properties: { className: ['nb'] }, children: [{ type: 'text', value: m[0] }] });
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
