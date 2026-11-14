// Mermaid 그림 전용 글꼴("Guide Diagram") — 빌드할 때 원고의 Mermaid 글자만으로 부분집합을 만들어 사이트에 싣는다.
//
// 왜: 그림의 라벨 상자 크기는 빌드할 때 Chromium 이 잰 글자 폭으로 정해진다. 시스템 글꼴로 재면 빌드한 기계와 보는 기계의
// 글꼴이 다를 때(ubuntu 에서 빌드 → macOS 에서 봄 등) 줄이 바뀌고 상자 밖 글자가 잘린다. 그래서 재는 글꼴과 보이는 글꼴을
// 같은 파일로 고정한다. 외부 CDN 은 쓰지 않는다 — 글꼴 파일은 같은 사이트(/fonts/…woff2)에서 나간다.
//
// 글꼴(모두 SIL OFL 1.1, 예약 글꼴 이름 없음 — 부분집합을 만들어 실어도 이름 제약이 없다):
//   1. Noto Sans KR(@fontsource/noto-sans-kr) — 한글·영문·대부분의 기호. "korean" 조각이 한글 11,172자와 ASCII 를 담고,
//      화살표·원 숫자·수학 기호는 번호 조각에 흩어져 있다.
//   2. Noto Sans Symbols 2(@fontsource/noto-sans-symbols-2) — Noto Sans KR 에 없는 ✕ 등.
// 그림 글자(이모지 — 😱, 선택자가 붙은 ☁️)는 싣지 않는다: Chromium 은 그림 글자 모양을 고른 글자를 색 그림 글자 글꼴로만
// 그리고(흑백 글꼴을 목록에 넣어도 건너뛴다), Safari 는 Noto Color Emoji 의 COLRv1 을 그리지 못해 글자가 사라질 수 있다.
// 그래서 그림 글자는 보는 기계의 것을 쓰고, 빌드 때 그 폭이 0.35em 더 넓어져도 라벨이 잘리지 않는지 따로 확인한다
// (mermaid-render.mjs verifyRendered).
// 글자마다 위 순서로 처음 가진 글꼴을 고르고, 글꼴 조각마다 쓰인 글자만 남긴 woff2 를 만든다(@font-face 의 unicode-range 로
// 한 글꼴 이름 아래 묶는다 — 브라우저는 그 페이지에 실제로 있는 글자의 조각만 받는다).
// 어느 글꼴에도 없는 글자가 그림에 있으면 빌드가 실패한다(시스템 글꼴로 대신 그려지면 OS 마다 폭이 달라진다).
//
// 결정적: 같은 원고·같은 패키지 버전이면 같은 바이트(harfbuzz 부분집합 + woff2 압축). 파일 이름에 내용 해시를 넣는다.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { REPO_ROOT, allContentFiles } from '../lib/repo.mjs';

const require = createRequire(import.meta.url);

export const DIAGRAM_FAMILY = 'Guide Diagram';
// 실린 글꼴이 막히거나 못 받았을 때의 대체(시스템 글꼴). 이때는 폭이 달라질 수 있어 라벨이 넘칠 수 있지만,
// guide.css 와 단독 SVG 의 overflow: visible 로 잘리지는 않는다(diagrams 관문의 "대체 글꼴" 조건이 확인한다).
export const SYSTEM_STACK =
  '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", "Segoe UI", sans-serif';
export const FONT_STACK = `"${DIAGRAM_FAMILY}", ${SYSTEM_STACK}`;

// 글꼴 원본(우선순위 순). 조각 순서: 이름 붙은 조각(korean·latin 등)을 정한 순서로, 그다음 번호 조각을 번호순으로.
const SOURCES = [
  { pkg: '@fontsource/noto-sans-kr', name: 'Noto Sans KR', prefix: 'noto-sans-kr', first: ['korean', 'latin', 'latin-ext'] },
  { pkg: '@fontsource/noto-sans-symbols-2', name: 'Noto Sans Symbols 2', prefix: 'noto-sans-symbols-2', first: ['symbols', 'math', 'latin', 'latin-ext'] },
];

// 글자 폭이 없는 제어 문자·이음 표시(ZWJ)·모양 선택자(VS15/16)는 글꼴이 필요 없다.
const IGNORABLE = (cp) => cp < 0x20 || cp === 0x7f || cp === 0x200d || cp === 0xfe0e || cp === 0xfe0f;
/** 그림 글자(이모지) 묶음: 기본이 그림 모양인 글자, 또는 VS16 이 붙은 글자(이음 표시로 이어진 것까지). */
export const EMOJI_SEQ = /(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F)(?:\u200D\p{Extended_Pictographic}\uFE0F?)*/gu;

/** 원고(페이지로 만드는 Markdown 전부)에서 ```mermaid 블록의 원문을 꺼낸다. */
export function mermaidSourcesInContent() {
  const out = [];
  for (const rel of allContentFiles()) {
    const text = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    const fence = /^([ \t]*)(`{3,}|~{3,})[ \t]*mermaid[ \t]*\r?\n([\s\S]*?)^\1\2[ \t]*$/gm;
    for (const m of text.matchAll(fence)) out.push(m[3]);
  }
  return out;
}

/** Mermaid 원문이 화면에 내는 글자: 원문 글자 + 엔티티 코드(#35; #quot; …)를 푼 글자. */
export function charsOf(text) {
  const set = new Set();
  const add = (s) => {
    for (const ch of s.replace(EMOJI_SEQ, '')) if (!IGNORABLE(ch.codePointAt(0))) set.add(ch.codePointAt(0));
  };
  add(text);
  for (const m of text.matchAll(/#(\d+);/g)) add(String.fromCodePoint(Number(m[1])));
  const named = { quot: '"', amp: '&', lt: '<', gt: '>', nbsp: ' ', apos: "'" };
  for (const m of text.matchAll(/#([a-z]+);/g)) if (named[m[1]]) add(named[m[1]]);
  return set;
}

// 원고가 바뀌어도 자주 쓰는 글자는 언제나 넣어 둔다(ASCII 인쇄 가능 문자, nbsp).
function baseChars() {
  const s = new Set([0xa0]);
  for (let c = 0x20; c < 0x7f; c++) s.add(c);
  return s;
}

// ---------------------------------------------------------------- harfbuzz 부분집합
let hbSubset;
async function harfbuzzSubset() {
  if (!hbSubset) {
    hbSubset = (async () => {
      const wasm = fs.readFileSync(require.resolve('harfbuzzjs/dist/harfbuzz-subset.wasm'));
      const { instance } = await WebAssembly.instantiate(wasm);
      instance.exports._initialize();
      return instance.exports;
    })();
  }
  return hbSubset;
}
const tag = (s) => [...s].reduce((a, ch) => (a << 8) + ch.charCodeAt(0), 0) >>> 0;
const HB_MEMORY_MODE_WRITABLE = 2;
const HB_SUBSET_SETS_NAME_ID = 4;
const HB_SUBSET_SETS_LAYOUT_FEATURE_TAG = 6;

/** sfnt(TTF) 바이트를 주어진 코드 포인트만 남기게 줄인다. 이름 표의 저작권·라이선스(0~6, 13, 14)는 남긴다. */
async function subsetSfnt(sfnt, codepoints) {
  const hb = await harfbuzzSubset();
  const heap = () => new Uint8Array(hb.memory.buffer);
  const input = hb.hb_subset_input_create_or_fail();
  if (!input) throw new Error('harfbuzz: hb_subset_input_create_or_fail 실패');
  const buf = hb.malloc(sfnt.byteLength);
  heap().set(sfnt, buf);
  const blob = hb.hb_blob_create(buf, sfnt.byteLength, HB_MEMORY_MODE_WRITABLE, 0, 0);
  const face = hb.hb_face_create(blob, 0);
  hb.hb_blob_destroy(blob);
  try {
    // 모든 OpenType 기능(커닝 등)을 남긴다 — 원래 글꼴과 같은 폭으로 그려지게.
    const feats = hb.hb_subset_input_set(input, HB_SUBSET_SETS_LAYOUT_FEATURE_TAG);
    hb.hb_set_clear(feats);
    hb.hb_set_invert(feats);
    const names = hb.hb_subset_input_set(input, HB_SUBSET_SETS_NAME_ID);
    for (const id of [0, 1, 2, 3, 4, 5, 6, 13, 14]) hb.hb_set_add(names, id);
    const uni = hb.hb_subset_input_unicode_set(input);
    for (const cp of [...codepoints].sort((a, b) => a - b)) hb.hb_set_add(uni, cp);
    const sub = hb.hb_subset_or_fail(face, input);
    if (!sub) throw new Error('harfbuzz: hb_subset_or_fail 실패');
    const out = hb.hb_face_reference_blob(sub);
    const ptr = hb.hb_blob_get_data(out, 0);
    const len = hb.hb_blob_get_length(out);
    const bytes = heap().slice(ptr, ptr + len);
    hb.hb_blob_destroy(out);
    hb.hb_face_destroy(sub);
    return bytes;
  } finally {
    hb.hb_subset_input_destroy(input);
    hb.hb_face_destroy(face);
    hb.free(buf);
  }
}

// ---------------------------------------------------------------- 원본 조각과 그 글자 목록
let sliceCache;
async function slices() {
  if (!sliceCache) {
    sliceCache = (async () => {
      const hb = await import('harfbuzzjs');
      const woff2 = require('wawoff2');
      const out = [];
      for (const src of SOURCES) {
        const dir = path.join(path.dirname(require.resolve(`${src.pkg}/package.json`)), 'files');
        const re = new RegExp(`^${src.prefix}-(.+)-400-normal\\.woff2$`);
        const found = fs.readdirSync(dir).map((f) => [f, re.exec(f)?.[1]]).filter(([, k]) => k);
        const rank = ([, k]) => {
          const i = src.first.indexOf(k);
          if (i >= 0) return [0, i];
          return /^\d+$/.test(k) ? [1, Number(k)] : [2, k];
        };
        found.sort((a, b) => {
          const [x, y] = [rank(a), rank(b)];
          return x[0] - y[0] || (x[1] < y[1] ? -1 : x[1] > y[1] ? 1 : 0);
        });
        for (const [file, key] of found) {
          const file_ = path.join(dir, file);
          let sfnt; // 필요할 때만 푼다
          out.push({
            source: src.name,
            pkg: src.pkg,
            key,
            file: file_,
            async sfnt() {
              sfnt ??= new Uint8Array(await woff2.decompress(fs.readFileSync(file_)));
              return sfnt;
            },
            async cmap() {
              this._cmap ??= new Set(new hb.Face(new hb.Blob(await this.sfnt())).collectUnicodes());
              return this._cmap;
            },
          });
        }
      }
      return out;
    })();
  }
  return sliceCache;
}

/** 글자 집합 → 조각별 배정. 어느 조각에도 없는 글자는 missing. */
async function assign(chars) {
  const left = new Set(chars);
  const plan = [];
  for (const s of await slices()) {
    if (!left.size) break;
    const cm = await s.cmap();
    const mine = [...left].filter((c) => cm.has(c));
    if (!mine.length) continue;
    for (const c of mine) left.delete(c);
    plan.push({ slice: s, chars: new Set(mine) });
  }
  return { plan, missing: [...left].sort((a, b) => a - b) };
}

const hex = (cp) => cp.toString(16).toUpperCase();
/** 코드 포인트 집합 → CSS unicode-range 값(연속 구간은 묶는다). */
export function unicodeRange(cps) {
  const s = [...cps].sort((a, b) => a - b);
  const parts = [];
  for (let i = 0; i < s.length; ) {
    let j = i;
    while (j + 1 < s.length && s[j + 1] === s[j] + 1) j++;
    parts.push(i === j ? `U+${hex(s[i])}` : `U+${hex(s[i])}-${hex(s[j])}`);
    i = j + 1;
  }
  return parts.join(', ');
}

function describe(cps) {
  return cps.map((c) => `${String.fromCodePoint(c)}(U+${hex(c).padStart(4, '0')})`).join(' ');
}

// ---------------------------------------------------------------- 사이트 전체 글꼴
let fontCache;
/**
 * 사이트에 싣는 다이어그램 글꼴. 원고의 Mermaid 글자 + ASCII 로 정한다(빌드마다 같은 결과).
 * @returns {Promise<{hash: string, chars: Set<number>, faces: Array<{file: string, bytes: Uint8Array, chars: Set<number>, source: string, slice: string}>}>}
 */
export function diagramFonts() {
  if (!fontCache) {
    fontCache = (async () => {
      const chars = baseChars();
      for (const src of mermaidSourcesInContent()) for (const c of charsOf(src)) chars.add(c);
      const { plan, missing } = await assign(chars);
      if (missing.length) {
        throw new Error(
          `다이어그램 글꼴에 없는 글자: ${describe(missing)} — 그림에 이 글자를 쓰면 보는 기계의 시스템 글꼴로 그려져 폭이 달라진다. ` +
            `원고의 글자를 바꾸거나 site/src/plugins/diagram-font.mjs 의 SOURCES 에 그 글자가 있는 OFL 글꼴을 더한다.`,
        );
      }
      const woff2 = require('wawoff2');
      const faces = [];
      for (const [i, p] of plan.entries()) {
        const bytes = new Uint8Array(await woff2.compress(await subsetSfnt(await p.slice.sfnt(), p.chars)));
        const h = crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 10);
        faces.push({ file: `diagram-${i}-${h}.woff2`, bytes, chars: p.chars, source: p.slice.source, slice: `${p.slice.pkg}:${p.slice.key}` });
      }
      const hash = crypto.createHash('sha256').update(faces.map((f) => f.file).join('\n')).digest('hex').slice(0, 12);
      return { hash, chars, faces };
    })();
  }
  return fontCache;
}

/** 글자가 사이트 글꼴에 다 있는지. 없으면 빌드 실패(그 그림의 원문 일부와 함께). */
export async function assertCovered(text, where) {
  const { chars } = await diagramFonts();
  const miss = [...charsOf(text)].filter((c) => !chars.has(c));
  if (miss.length) throw new Error(`${where}: 다이어그램 글꼴 부분집합에 없는 글자 ${describe(miss)}`);
}

const FACE_STYLE = 'font-style:normal;font-weight:400;font-display:swap';

/** 페이지용 @font-face 규칙(같은 사이트의 /fonts/… 주소). urlFor: 파일 이름 → 주소(base 포함). */
export async function fontFaceCss(urlFor) {
  const { faces } = await diagramFonts();
  return faces
    .map((f) => `@font-face{font-family:"${DIAGRAM_FAMILY}";src:url("${urlFor(f.file)}") format("woff2");${FACE_STYLE};unicode-range:${unicodeRange(f.chars)}}`)
    .join('');
}

/** 빌드 시점 측정·그리기용 @font-face(글꼴 바이트를 data: 주소로 — 요청 없이 확실히 읽힌다). */
export async function fontFaceCssInline() {
  const { faces } = await diagramFonts();
  return faces
    .map((f) => `@font-face{font-family:"${DIAGRAM_FAMILY}";src:url(data:font/woff2;base64,${Buffer.from(f.bytes).toString('base64')}) format("woff2");${FACE_STYLE};unicode-range:${unicodeRange(f.chars)}}`)
    .join('');
}

const embedCache = new Map();
/**
 * 단독 SVG 파일에 넣을 @font-face(그 그림의 글자만 남긴 부분집합을 data: 주소로).
 * 단독 SVG 는 <img>·새 탭에서 열리며 바깥 스타일시트를 읽지 않으므로 글꼴을 파일 안에 담는다.
 */
export async function embeddedFontCss(text) {
  const need = charsOf(text);
  const key = [...need].sort((a, b) => a - b).join(',');
  if (embedCache.has(key)) return embedCache.get(key);
  const { faces } = await diagramFonts();
  const sl = await slices();
  const woff2 = require('wawoff2');
  let css = '';
  for (const f of faces) {
    const mine = [...need].filter((c) => f.chars.has(c));
    if (!mine.length) continue;
    const slice = sl.find((s) => `${s.pkg}:${s.key}` === f.slice);
    const bytes = await woff2.compress(await subsetSfnt(await slice.sfnt(), new Set(mine)));
    css += `@font-face{font-family:"${DIAGRAM_FAMILY}";src:url(data:font/woff2;base64,${Buffer.from(bytes).toString('base64')}) format("woff2");${FACE_STYLE};unicode-range:${unicodeRange(mine)}}`;
  }
  embedCache.set(key, css);
  return css;
}
