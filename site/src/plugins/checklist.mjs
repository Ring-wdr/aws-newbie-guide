// capstone-self-check.md → 상태가 저장되는 체크리스트.
// 첫 칸 머리글이 "✔"인 표에서, 각 줄 첫 칸의 ☐/☑를 체크 상자로 바꾼다(원고의 ☑는 처음부터 체크된 예시).
// 줄 수·칸 수는 바꾸지 않는다. 원래 기호는 스크립트가 없을 때 보이도록 남긴다.
import { toString } from 'mdast-util-to-string';
import { ko } from '../i18n/ko.mjs';
import { html, esc } from './util.mjs';

export function transformChecklist(tree, ctx) {
  const { rep } = ctx;
  rep.touch('checklist');
  let section = '';
  let sectionNo = 0;
  for (const node of tree.children) {
    if (node.type === 'heading' && node.depth === 2) {
      sectionNo++;
      const m = /^([A-Z])\./.exec(toString(node));
      section = m ? m[1] : String(sectionNo);
      continue;
    }
    if (node.type !== 'table') continue;
    const [headRow, ...rows] = node.children;
    if (toString(headRow.children[0]).trim() !== '✔') {
      rep.note('checklist', 'other-table');
      continue;
    }
    rows.forEach((row, k) => {
      const cell = row.children[0];
      const mark = toString(cell).trim();
      if (mark !== '☐' && mark !== '☑') {
        rep.unrecognised('checklist', `${section}표 ${k + 1}번째 줄 첫 칸이 ☐/☑가 아님: "${mark}"`, row);
        return;
      }
      const id = `${section}-${k + 1}`;
      const item = toString(row.children[1] || '').trim().slice(0, 60);
      cell.children = [
        html(
          `<label class="check"><input type="checkbox" data-check-id="${id}"${mark === '☑' ? ' checked data-check-default' : ''}>` +
            `<span class="sr-only">${esc(`${ko.checklist.toggle}: ${item}`)}</span></label>` +
            `<span class="check-src" aria-hidden="true">${mark}</span>`,
        ),
      ];
      rep.handled('checklist');
    });
  }
  // 진행 요약: 첫 번째 h2 앞.
  const at = tree.children.findIndex((n) => n.type === 'heading' && n.depth === 2);
  tree.children.splice(
    at < 0 ? 0 : at,
    0,
    html(
      `<aside class="checklist-summary" aria-label="${esc(ko.checklist.heading)}" hidden>` +
        `<p class="checklist-progress" role="status" aria-live="polite"></p>` +
        `<p class="checklist-note">${esc(ko.checklist.note)}</p>` +
        `<button type="button" class="checklist-reset">${esc(ko.checklist.reset)}</button>` +
        `<div data-guide-storage></div></aside>`,
    ),
  );
}
