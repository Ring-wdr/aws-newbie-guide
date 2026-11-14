// 레슨 구조 점검과 "스스로 확인" 답 가리기.
// - AUTHORING 2장의 절 순서(왜 필요한가 → 핵심 개념 → 직접 해 보기 → 실제 AWS에서는 → 시험 포인트 → 스스로 확인)와
//   다른 제목은 보고서에 적는다(화면은 원고 그대로).
// - "스스로 확인" 절의 <details>는 답 가리기/펼치기 상자로 표시한다(브라우저 기본 <details>라 스크립트 없이도 동작).
import { toString } from 'mdast-util-to-string';

export const LESSON_SECTIONS = ['왜 필요한가', '핵심 개념', '직접 해 보기', '실제 AWS에서는', '시험 포인트', '스스로 확인'];

export function checkLessonSections(tree, ctx) {
  const { rep } = ctx;
  rep.touch('sections');
  const h2 = tree.children.filter((n) => n.type === 'heading' && n.depth === 2).map((n) => toString(n).trim());
  const missing = LESSON_SECTIONS.filter((s) => !h2.includes(s));
  const variants = h2.filter((t) => !LESSON_SECTIONS.includes(t));
  for (const v of variants) {
    const base = LESSON_SECTIONS.find((s) => v.startsWith(s));
    rep.note('sections', base ? 'variant-title' : 'extra-section');
    if (base) rep.unrecognised('sections', `변형 제목 "${v}"`, null);
  }
  for (const m of missing) rep.unrecognised('sections', `표준 절 "${m}" 없음`, null);
  if (!missing.length) rep.handled('sections');
}

const isOpen = (n) => n?.type === 'html' && /^<details>/.test(n.value.trim());

export function transformSelfCheck(tree, ctx) {
  const { rep } = ctx;
  rep.touch('selfcheck');
  let inSection = false;
  let found = 0;
  for (const node of tree.children) {
    if (node.type === 'heading' && node.depth <= 2) inSection = toString(node).trim() === '스스로 확인';
    if (!isOpen(node)) continue;
    if (inSection) {
      node.value = node.value.replace(/^(\s*)<details>/, '$1<details class="self-check">');
      found++;
      rep.handled('selfcheck');
    } else {
      // 워크시트 답 등 다른 절의 <details>도 같은 모양의 답 가리기 상자로 보인다.
      node.value = node.value.replace(/^(\s*)<details>/, '$1<details class="reveal">');
      rep.note('selfcheck', 'details-outside-self-check');
    }
  }
  if (!found) rep.unrecognised('selfcheck', '"스스로 확인" 절에 <details>가 없음', null);
}
