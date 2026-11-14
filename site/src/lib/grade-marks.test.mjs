import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gradeMarksInHtml } from './grade-marks.mjs';

const L = { '🟢': { label: '재현', meaning: '실제로 동작' }, '🟡': { label: '부분', meaning: '일부' }, '🔴': { label: '개념', meaning: '설명만' } };

test('글자 노드의 이모지에 이름과 보이는 라벨 칸을 붙이고 글자·앵커는 그대로 둔다', () => {
  const html = '<a href="#bpa-🔴"><span>계정 수준 BPA 🔴</span></a>';
  const out = gradeMarksInHtml(html, L);
  assert.ok(out.startsWith('<a href="#bpa-🔴"><span>계정 수준 BPA <span class="grade-mark grade-mark-r" title="개념: 설명만">'));
  assert.match(out, /<span role="img" aria-label="개념">🔴<\/span><span class="grade-mark-label" data-label="개념" aria-hidden="true"><\/span>/);
  // 라벨 글자는 생성 콘텐츠라, 태그를 걷어 낸 글자는 원고 제목과 같다
  assert.equal(out.replace(/<[^>]+>/g, ''), '계정 수준 BPA 🔴');
});

test('뒤에 라벨 글자가 이미 있으면 이모지만 감싼다', () => {
  assert.equal(gradeMarksInHtml('<span>🟢 재현</span>', L), '<span><span class="grade-mark grade-mark-g" title="재현: 실제로 동작">🟢</span> 재현</span>');
});

test('script·style 안과 이미 라벨이 붙은 표시 안은 건드리지 않는다', () => {
  const html = '<script>const a = "🟡";</script><span class="grade-mark"><span role="img" aria-label="부분">🟡</span><span class="grade-mark-label" data-label="부분" aria-hidden="true"></span></span> 뒤 🟢';
  const out = gradeMarksInHtml(html, L);
  assert.ok(out.startsWith('<script>const a = "🟡";</script><span class="grade-mark"><span role="img" aria-label="부분">🟡</span>'));
  assert.equal((out.match(/grade-mark-label/g) || []).length, 2);
});

test('이모지가 없으면 그대로', () => {
  assert.equal(gradeMarksInHtml('<ul><li>개요</li></ul>', L), '<ul><li>개요</li></ul>');
});
