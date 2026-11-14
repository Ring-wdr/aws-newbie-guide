// 다이어그램 글꼴(diagram-font.mjs) 시험: 글자 집합, unicode-range, 부분집합에 없는 글자에서의 실패, 결정성.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { charsOf, unicodeRange, diagramFonts, assertCovered, embeddedFontCss, mermaidSourcesInContent } from './diagram-font.mjs';

test('charsOf: 엔티티 코드를 풀고, 그림 글자(이모지)·제어 문자는 뺀다', () => {
  const s = charsOf('A[#quot;가#35;]\n오류 😱 ☁️ ☁');
  for (const ch of ['A', '[', '"', '가', '#', ']', '오', '류', '☁']) assert.ok(s.has(ch.codePointAt(0)), ch);
  assert.ok(!s.has(0x1f631), '😱 은 그림 글자라 싣지 않는다');
  assert.ok(!s.has(0xfe0f), '모양 선택자는 글꼴이 필요 없다');
  assert.ok(!s.has(0x0a), '줄바꿈');
});

test('unicodeRange: 연속 구간을 묶는다', () => {
  assert.equal(unicodeRange(new Set([0x41, 0x42, 0x43, 0xac00, 0x2192])), 'U+41-43, U+2192, U+AC00');
});

test('diagramFonts: 원고의 모든 Mermaid 글자를 담고, 파일 이름에 내용 해시가 있다', async () => {
  const { faces, chars } = await diagramFonts();
  assert.ok(mermaidSourcesInContent().length > 0);
  for (const src of mermaidSourcesInContent()) await assertCovered(src, 'test');
  const union = new Set(faces.flatMap((f) => [...f.chars]));
  assert.deepEqual([...chars].sort(), [...union].sort(), '모든 글자가 어느 한 조각에 배정된다');
  for (const f of faces) {
    assert.match(f.file, /^diagram-\d+-[0-9a-f]{10}\.woff2$/);
    assert.equal(String.fromCharCode(...f.bytes.slice(0, 4)), 'wOF2');
  }
});

test('assertCovered: 부분집합에 없는 글자는 실패한다', async () => {
  await assert.rejects(() => assertCovered('flowchart LR\n A[กขค]', '심은 결함'), /부분집합에 없는 글자/);
});

test('embeddedFontCss: 그림의 글자만 담은 data: 글꼴, 같은 입력이면 같은 결과', async () => {
  const a = await embeddedFontCss('주문 → 결제');
  const b = await embeddedFontCss('주문 → 결제');
  assert.equal(a, b);
  assert.match(a, /src:url\(data:font\/woff2;base64,/);
  assert.ok(!/https?:/.test(a), '외부 주소가 없다');
});
