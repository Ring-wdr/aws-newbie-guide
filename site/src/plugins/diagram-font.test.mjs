// 다이어그램 글꼴(diagram-font.mjs) 시험: 글자 집합, unicode-range, 부분집합에 없는 글자에서의 실패, 결정성.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { charsOf, unicodeRange, diagramFonts, assertCovered, embeddedFontCss, mermaidSourcesInContent, shippedNames, sfntNames, fontLicenceText, DIAGRAM_FAMILY } from './diagram-font.mjs';

// 예약 글꼴 이름(Noto Sans KR 의 'Source')이 있으면 안 되는 이름 표 ID:
// 1 가족·3 고유 식별자·4 전체·6 PostScript·16 대표 가족·17 대표 하위 가족(OFL 은 수정본의 "이름"에 예약 이름을 금한다).
const NAME_IDS = [1, 3, 4, 6, 16, 17];
const noReservedName = (names, where) => {
  for (const id of NAME_IDS) for (const s of names[id] ?? []) assert.doesNotMatch(s, /source/i, `${where} 이름 ID ${id}`);
};

/** CSS 의 @font-face data: 글꼴(woff2)마다 이름 표. */
async function embeddedNames(css) {
  const woff2 = createRequire(import.meta.url)('wawoff2');
  const out = [];
  for (const m of css.matchAll(/url\(data:font\/woff2;base64,([A-Za-z0-9+/=]+)\)/g)) out.push(sfntNames(new Uint8Array(await woff2.decompress(Buffer.from(m[1], 'base64')))));
  return out;
}

test('라이선스: 실린 글꼴의 저작권 줄과 OFL 본문을 싣고, 예약 글꼴 이름(Source)을 이름에 쓰지 않는다', async () => {
  const named = await shippedNames();
  const kr = named.filter((n) => n.source === 'Noto Sans KR');
  assert.ok(kr.length > 0);
  for (const n of kr) assert.match(n.names[0].join('\n'), /Reserved Font Name 'Source'/, `${n.file} 저작권 줄`);
  // 예약 이름은 Noto Sans KR 의 'Source' 뿐 — 싣는 글꼴 이름과 남긴 이름 표(1 가족·4 전체·6 PostScript)에 없어야 한다.
  assert.doesNotMatch(DIAGRAM_FAMILY, /source/i);
  for (const n of named) noReservedName(n.names, n.file);
  const text = await fontLicenceText();
  assert.match(text, /with Reserved Font Name 'Source'/);
  assert.equal(text.match(/SIL OPEN FONT LICENSE Version 1\.1 - 26 February 2007/g)?.length, new Set(named.map((n) => n.source)).size);
  for (const n of named) for (const c of n.names[0]) assert.ok(text.includes(c), c);
});

test('라이선스: 단독 SVG 에 data: 로 담는 글꼴도 예약 글꼴 이름(Source)을 이름에 쓰지 않는다', async () => {
  // 단독 SVG(/diagrams/<id>.svg)는 그림마다 embeddedFontCss 로 부분집합을 새로 만든다 — /fonts/ 의 파일과 다른 바이트라 따로 본다.
  // 원고의 모든 Mermaid 글자를 한 번에 넣어 모든 조각(글꼴 원본)이 나오게 한다.
  const css = await embeddedFontCss(mermaidSourcesInContent().join('\n'));
  const named = await embeddedNames(css);
  assert.equal(named.length, (await diagramFonts()).faces.length, '모든 조각의 글꼴이 담긴다');
  for (const [i, names] of named.entries()) {
    assert.ok(names[0]?.length, `담은 글꼴 ${i}: 저작권 줄(이름 ID 0)이 남는다`);
    noReservedName(names, `담은 글꼴 ${i}`);
  }
  assert.ok(named.some((n) => /Reserved Font Name 'Source'/.test(n[0].join('\n'))), "Noto Sans KR 조각의 저작권 줄에 예약 이름 고지가 남는다");
});

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
