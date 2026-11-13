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
  };
}
