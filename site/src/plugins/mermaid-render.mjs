// Mermaid 다이어그램을 빌드할 때 SVG로 그린다(라이트·다크 두 벌). 브라우저에는 Mermaid 스크립트를 보내지 않는다.
// 그리기는 mermaid-isomorphic이 Playwright 헤드리스 Chromium 안에서 한다(로컬 파일만 읽는다).
// 같은 원문은 디스크 캐시(node_modules/.cache/guide-mermaid)에서 재사용한다.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { SITE_DIR } from '../lib/repo.mjs';
import { FONT_STACK, DIAGRAM_FAMILY, EMOJI_SEQ, diagramFonts, fontFaceCssInline, assertCovered } from './diagram-font.mjs';

const require = createRequire(import.meta.url);
const CACHE_DIR = path.join(SITE_DIR, 'node_modules/.cache/guide-mermaid');

// 그림 글자는 사이트에 실은 다이어그램 글꼴("Guide Diagram", diagram-font.mjs)로 재고 그 글꼴로 보인다.
// 시스템 글꼴로 재면 빌드한 기계와 보는 기계의 글꼴이 다를 때 라벨이 줄바꿈되어 상자 밖으로 넘치고 잘린다.
export { FONT_STACK };

// 라벨 안 글자를 상자 밖으로 넘쳐도 자르지 않는다(대체 글꼴로 그려질 때의 방어선 — guide.css 와 단독 SVG 도 같다).
export const OVERFLOW_CSS = 'svg[id^="mmd-"],svg[id^="mmd-"] foreignObject{overflow:visible}';

// 그리기·재기 페이지에 넣는 글꼴 스타일시트(data: 주소 — 요청 없이 읽힌다). mermaid-isomorphic 은 스타일시트를 주소로만 받는다.
let fontCssUrl;
async function fontStylesheet() {
  if (!fontCssUrl) {
    fontCssUrl = (async () => {
      const css = await fontFaceCssInline();
      const { hash } = await diagramFonts();
      fs.mkdirSync(CACHE_DIR, { recursive: true });
      const file = path.join(CACHE_DIR, `font-${hash}.css`);
      fs.writeFileSync(file, css);
      return { url: pathToFileURL(file).href, css };
    })();
  }
  return fontCssUrl;
}

const THEMES = {
  light: { theme: 'default' },
  // Mermaid 'dark' 테마의 간선 라벨(회색 바탕 + 회색 글자)은 명암비가 WCAG AA(4.5:1)에 못 미쳐 바탕만 어둡게 바꾼다.
  dark: { theme: 'dark', themeVariables: { edgeLabelBackground: '#1b1e24', labelBackground: '#1b1e24' } },
};

let versionTag;
function cacheVersion() {
  if (!versionTag) {
    const v = (name) => {
      try {
        return JSON.parse(fs.readFileSync(require.resolve(`${name}/package.json`), 'utf8')).version;
      } catch {
        return '?';
      }
    };
    versionTag = `mi${v('mermaid-isomorphic')}-pw${v('playwright')}-v9-${DOC_LANG}`;
  }
  return versionTag;
}

// 사이트 문서의 언어(<html lang="ko">). 글꼴은 언어에 따라 글자 폭이 달라질 수 있다(Noto Sans KR 의 공백은 lang=ko 에서
// 4.48px, 그 밖에서 3.58px — 16px). mermaid-isomorphic 의 그리기 페이지는 lang="en" 이라, 같은 언어로 재도록 바꾼다.
export const DOC_LANG = 'ko';
const SET_LANG = `(() => { const set = () => { document.documentElement.lang = ${JSON.stringify(DOC_LANG)}; }; document.addEventListener('DOMContentLoaded', set); })();`;

let renderer;
async function getRenderer() {
  if (!renderer) {
    const { createMermaidRenderer } = await import('mermaid-isomorphic');
    const { chromium } = await import('playwright');
    // 그리기 페이지마다 문서 언어를 사이트와 같게(init 스크립트). mermaid-isomorphic 은 browserType.launch → newContext → newPage 를 쓴다.
    const browserType = {
      async launch(opts) {
        const browser = await chromium.launch(opts);
        const newContext = browser.newContext.bind(browser);
        browser.newContext = async (o) => {
          const ctx = await newContext(o);
          await ctx.addInitScript(SET_LANG);
          return ctx;
        };
        return browser;
      },
    };
    renderer = createMermaidRenderer({ browserType });
  }
  return renderer;
}

// 그림에 넣는 CSS(시퀀스 자동 번호 글꼴, 글자 폭 계산 방식). 캐시 열쇠에도 넣는다.
// text-rendering: geometricPrecision — Linux 의 Chromium 은 기본으로 글자 폭(advance)을 정수 px 로 맞춰(힌팅) 재고,
// macOS·Windows 는 소수점까지 잰다. 같은 글꼴이어도 빌드한 OS 에 따라 라벨 폭이 1px 안팎 달라져 보는 쪽에서 줄이 바뀐다.
// geometricPrecision 이면 Linux 에서도 힌팅 없이 소수점 폭(선형 글자 폭)으로 재고 그려 OS 와 상관없이 같은 폭이 된다.
// (Mermaid 는 이 CSS 를 그림 id 아래로 묶으며 선택자를 소문자로 바꾼다 — SVG 요소 이름(foreignObject)으로는 고르지 못하므로
//  그림 안 모든 요소(*)에 준다. 라벨 넘침 허용은 guide.css·단독 SVG 의 OVERFLOW_CSS 가 맡는다.)
const THEME_CSS = `*{text-rendering:geometricPrecision}.sequenceNumber{font-family:${FONT_STACK}}`;

function keyFor(source, theme, fontHash) {
  return crypto.createHash('sha256').update(`${cacheVersion()}\0${fontHash}\0${FONT_STACK}\0${THEME_CSS}\0${JSON.stringify(THEMES[theme])}\0${source}`).digest('hex').slice(0, 24);
}

// 다이어그램마다 고유한 id 접두어. SVG 안의 <style>이 id로 범위를 잡으므로 한 페이지 안에서 겹치면 안 된다.
export function prefixFor(source, theme) {
  return `mmd-${crypto.createHash('sha256').update(source).digest('hex').slice(0, 10)}-${theme}`;
}

// Mermaid 기본 배치(dagre)는 서브그래프 제목이 내용보다 넓으면 이웃 서브그래프와 겹쳐 라벨을 가린다.
// 그런 그림과 간선 라벨이 노드·제목에 가려지는 그림만, 내용은 그대로 두고 간격을 넓힌 배치로 다시 그린다
// (겹침이 없어지는 첫 설정, 없으면 겹침이 가장 적은 설정).
const LAYOUTS = [
  { name: 'default', spacing: {} },
  { name: 'spacious', spacing: { nodeSpacing: 90, rankSpacing: 60, padding: 30 } },
  { name: 'wide', spacing: { nodeSpacing: 120, rankSpacing: 70, padding: 40 } },
  { name: 'widest', spacing: { nodeSpacing: 150, rankSpacing: 90, padding: 40 } },
  { name: 'tall', spacing: { nodeSpacing: 90, rankSpacing: 130, padding: 40 } },
];

// 겹침을 재는 브라우저는 여러 원고가 동시에 쓰므로, 쓰는 쪽이 하나도 없을 때만 닫는다(열어 두면 빌드가 끝나지 않는다).
let browserPromise;
let active = 0;
async function measurePageFor() {
  if (!browserPromise) {
    browserPromise = import('playwright').then(async ({ chromium }) => {
      const browser = await chromium.launch();
      return { browser };
    });
  }
  return browserPromise;
}
async function withMeasurePage(svg, width, fn) {
  const { browser } = await measurePageFor();
  const measurePage = await browser.newPage({ viewport: { width: 1600, height: 1200 } });
  try {
    const { css } = await fontStylesheet();
    await measurePage.setContent(`<!doctype html><html lang="${DOC_LANG}"><head><style>${css}${OVERFLOW_CSS}</style></head><body><div style="width:${Math.ceil(width)}px">${svg}</div></body></html>`);
    // 실린 글꼴이 실제로 읽혔는지 확인한다(못 읽으면 시스템 글꼴로 재게 되어 다른 기계에서 잘린다 → 빌드 실패).
    const fonts = await measurePage.evaluate(async (family) => {
      await document.fonts.ready;
      const faces = [...document.fonts].filter((f) => f.family.replace(/"/g, '') === family);
      return { total: faces.length, bad: faces.filter((f) => f.status === 'error').length };
    }, DIAGRAM_FAMILY);
    if (!fonts.total || fonts.bad) throw new Error(`다이어그램 글꼴을 읽지 못했다(@font-face ${fonts.total}개 중 오류 ${fonts.bad}개)`);
    return await fn(measurePage);
  } finally {
    await measurePage.close().catch(() => {});
  }
}
async function overlaps(svg, width) {
  return withMeasurePage(svg, width, measure);
}

/**
 * 고른 그림을 실린 글꼴로 다시 열어 확인한다(빌드 실패 조건):
 *  - 모든 글자가 실린 글꼴로 그려졌다(Chromium 이 실제로 쓴 글꼴 — DevTools 프로토콜 CSS.getPlatformFontsForNode).
 *    시스템 글꼴로 대신 그려진 글자가 있으면 보는 기계마다 폭이 달라진다. 그림 글자(이모지)만 예외(diagram-font.mjs).
 *  - HTML 라벨(foreignObject) 안 내용이 상자보다 넓거나 높지 않다(잰 글꼴 = 보이는 글꼴이면 잘림이 없어야 한다).
 *  - 그림 글자가 든 라벨은 그림 글자마다 0.35em 넓혀도 넘치지 않는다(OS 마다 그림 글자 폭이 다르다).
 */
async function verifyRendered(svg, width, what) {
  return withMeasurePage(svg, width, async (page) => {
    const clipCheck = () =>
      page.evaluate(() => {
        const out = [];
        for (const fo of document.querySelectorAll('foreignObject')) {
          const inner = fo.firstElementChild;
          if (!inner) continue;
          const fr = fo.getBoundingClientRect();
          const ir = inner.getBoundingClientRect();
          // 잰 글꼴 = 보이는 글꼴이므로 오차는 반올림 정도뿐이다(0.1px 넘게 넓으면 그리기와 재기의 조건이 다르다는 뜻).
          if (ir.width - fr.width > 0.1 || ir.height - fr.height > 0.5) out.push(`"${inner.textContent.trim().slice(0, 30)}" (+${(ir.width - fr.width).toFixed(2)}×+${(ir.height - fr.height).toFixed(2)}px)`);
        }
        return out;
      });
    const clipped = await clipCheck();
    const emojiSrc = EMOJI_SEQ.source;
    await page.evaluate(() => {
      let n = 0;
      const walker = document.createTreeWalker(document.querySelector('svg'), NodeFilter.SHOW_TEXT);
      for (let t = walker.nextNode(); t; t = walker.nextNode()) {
        if (!t.nodeValue.trim() || t.parentElement.closest('style, title, desc')) continue;
        if (!t.parentElement.hasAttribute('data-fchk')) t.parentElement.setAttribute('data-fchk', String(n++));
      }
    });
    const cdp = await page.context().newCDPSession(page);
    const foreign = [];
    try {
      await cdp.send('DOM.enable');
      await cdp.send('CSS.enable');
      const { root } = await cdp.send('DOM.getDocument', { depth: -1 });
      const { nodeIds } = await cdp.send('DOM.querySelectorAll', { nodeId: root.nodeId, selector: '[data-fchk]' });
      for (const nodeId of nodeIds) {
        const { fonts } = await cdp.send('CSS.getPlatformFontsForNode', { nodeId });
        const sys = fonts.filter((f) => !f.isCustomFont && f.glyphCount > 0);
        if (!sys.length) continue;
        const { outerHTML } = await cdp.send('DOM.getOuterHTML', { nodeId });
        const text = outerHTML.replace(/<[^>]+>/g, '');
        const emoji = (text.match(new RegExp(emojiSrc, 'gu')) || []).length;
        const sysGlyphs = sys.reduce((a, f) => a + f.glyphCount, 0);
        if (sysGlyphs > emoji) foreign.push(`${sys.map((f) => `${f.familyName} ${f.glyphCount}자`).join(', ')}: ${text.trim().slice(0, 40)}`);
      }
    } finally {
      await cdp.detach().catch(() => {});
    }
    // 그림 글자 여유: 그림 글자 묶음마다 0.35em 의 빈 폭을 붙여 다시 잰다.
    const wideEmoji = await page.evaluate((src) => {
      const re = new RegExp(src, 'gu');
      let n = 0;
      for (const fo of document.querySelectorAll('foreignObject')) {
        const walker = document.createTreeWalker(fo, NodeFilter.SHOW_TEXT);
        const texts = [];
        for (let t = walker.nextNode(); t; t = walker.nextNode()) if (re.test(t.nodeValue)) texts.push(t);
        for (const t of texts) {
          re.lastIndex = 0;
          const html = t.nodeValue.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]).replace(re, (m) => `<span style="padding-inline-end:.35em">${m}</span>`);
          const span = document.createElement('span');
          span.innerHTML = html;
          t.replaceWith(...span.childNodes);
          n++;
        }
      }
      return n;
    }, emojiSrc);
    const emojiClipped = wideEmoji ? await clipCheck() : [];
    const problems = [
      ...clipped.map((c) => `라벨 잘림 ${c}`),
      ...foreign.map((f) => `시스템 글꼴로 그려진 글자(${f})`),
      ...emojiClipped.filter((c) => !clipped.includes(c)).map((c) => `그림 글자(이모지) 폭이 조금만 넓어도 라벨이 잘림 ${c} — 그 줄을 짧게 하거나 줄을 나눈다`),
    ];
    if (problems.length) throw new Error(`${what}: 실린 글꼴로 다시 재 보니 ${problems.slice(0, 5).join('; ')}`);
  });
}
async function measure(measurePage) {
  return measurePage.evaluate(() => {
    const inter = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    const con = (a, b) => a.left <= b.left + 1 && a.right >= b.right - 1 && a.top <= b.top + 1 && a.bottom >= b.bottom - 1;
    const cl = [...document.querySelectorAll('g.cluster > rect')].map((r) => r.getBoundingClientRect());
    const nd = [...document.querySelectorAll('g.node')].map((r) => r.getBoundingClientRect());
    // 간선 라벨이 노드·서브그래프 제목·다른 간선 라벨에 가려지는 경우(tests/diagrams.mjs 와 같은 기준)
    const lb = [...document.querySelectorAll('g.edgeLabel')]
      .filter((e) => e.textContent.trim())
      .map((e) => e.getBoundingClientRect())
      .filter((r) => r.width > 1 && r.height > 1);
    const tl = [...document.querySelectorAll('g.cluster-label')].map((r) => r.getBoundingClientRect());
    let k = 0;
    for (let i = 0; i < cl.length; i++) for (let j = i + 1; j < cl.length; j++) if (inter(cl[i], cl[j]) && !con(cl[i], cl[j]) && !con(cl[j], cl[i])) k++;
    for (let i = 0; i < nd.length; i++) for (let j = i + 1; j < nd.length; j++) if (inter(nd[i], nd[j])) k++;
    for (const l of lb) {
      for (const n of nd) if (inter(l, n)) k++;
      for (const t of tl) if (inter(l, t)) k++;
    }
    for (let i = 0; i < lb.length; i++) for (let j = i + 1; j < lb.length; j++) if (inter(lb[i], lb[j])) k++;
    return k;
  });
}

// 원고가 classDef/style 로 밝은 바탕(fill)을 박아 두고 글자색(color)을 주지 않으면, 다크 테마의 밝은 글자가
// 밝은 바탕 위에 놓여 읽기 어렵다. 다크로 그릴 때만 그런 줄 끝에 어두운 글자색을 더한다(원고는 그대로).
const DARK_TEXT_ON_LIGHT_FILL = '#1b1e24';
function luminance(hex) {
  let h = hex.replace('#', '');
  if (h.length === 3 || h.length === 4) h = [...h.slice(0, 3)].map((c) => c + c).join('');
  if (!/^[0-9a-f]{6}/i.test(h)) return null;
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function darkTextForLightFills(source) {
  return source.replace(/^(\s*(?:classDef|style)\s+\S+\s+)([^\n]*)$/gm, (line, head, decl) => {
    if (/(^|[,;])\s*color\s*:/i.test(decl)) return line;
    const fill = /(?:^|[,;])\s*fill\s*:\s*(#[0-9a-f]{3,8})\b/i.exec(decl);
    const lum = fill ? luminance(fill[1]) : null;
    if (lum === null || lum < 0.4) return line;
    return `${head}${decl.replace(/\s*;?\s*$/, '')},color:${DARK_TEXT_ON_LIGHT_FILL}`;
  });
}

async function renderOne(source, theme, layout) {
  const render = await getRenderer();
  const { url } = await fontStylesheet();
  const [res] = await render([theme === 'dark' ? darkTextForLightFills(source) : source], {
    prefix: prefixFor(source, theme), // id 접두어는 원고 원문으로 정한다(페이지·단독 SVG 이름과 맞게)
    // 실린 글꼴을 그리기 페이지에도 넣는다. mermaid-isomorphic 은 그리기 전에 document.fonts 를 모두 읽고(font.load),
    // 읽기에 실패하면 그리기가 실패한다.
    css: [url],
    mermaidConfig: {
      ...THEMES[theme],
      fontFamily: FONT_STACK,
      securityLevel: 'strict',
      // 시퀀스 그림의 글꼴은 따로 정해진다(기본 "Open Sans"·"trebuchet ms"). 자동 번호(sequenceNumber)는 font-family="sans-serif"
      // 속성이 박혀 있어 CSS 로 덮는다(themeCSS 는 그림 id 아래로 범위가 잡힌다). 라벨은 넘쳐도 자르지 않는다.
      sequence: { actorFontFamily: FONT_STACK, noteFontFamily: FONT_STACK, messageFontFamily: FONT_STACK },
      themeCSS: THEME_CSS,
      flowchart: { htmlLabels: true, ...layout.spacing },
      state: { ...layout.spacing },
    },
  });
  if (res.status !== 'fulfilled') throw new Error(String(res.reason?.message || res.reason));
  return { svg: res.value.svg, width: res.value.width, height: res.value.height, layout: layout.name };
}

/**
 * @param {string[]} sources Mermaid 원문 목록
 * @returns {Promise<Array<{light, dark} | {error: string}>>}
 */
export async function renderMermaid(sources) {
  active++;
  try {
    return await renderAll(sources);
  } finally {
    active--;
    if (active === 0 && browserPromise) {
      const p = browserPromise;
      browserPromise = undefined;
      p.then(({ browser }) => browser.close()).catch(() => {});
    }
  }
}

async function renderAll(sources) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const { hash } = await diagramFonts();
  const out = [];
  for (const src of sources) {
    const files = Object.fromEntries(Object.keys(THEMES).map((t) => [t, path.join(CACHE_DIR, `${keyFor(src, t, hash)}.json`)]));
    if (Object.values(files).every((f) => fs.existsSync(f))) {
      out.push(Object.fromEntries(Object.entries(files).map(([t, f]) => [t, JSON.parse(fs.readFileSync(f, 'utf8'))])));
      continue;
    }
    try {
      await assertCovered(src, 'Mermaid 원문');
      // 라이트 테마로 배치를 정하고(겹침이 없는 첫 설정), 다크 테마도 같은 배치로 그린다.
      // 겹침이 없는 첫 배치를 쓰고, 모두 겹치면 겹침이 가장 적은 배치를 쓴다.
      let best;
      for (const layout of LAYOUTS) {
        const cand = await renderOne(src, 'light', layout);
        const n = await overlaps(cand.svg, cand.width);
        if (!best || n < best.n) best = { cand, layout, n };
        if (n === 0) break;
      }
      const light = best.cand;
      const chosen = best.layout;
      const dark = await renderOne(src, 'dark', chosen);
      await verifyRendered(light.svg, light.width, '라이트 그림');
      await verifyRendered(dark.svg, dark.width, '다크 그림');
      fs.writeFileSync(files.light, JSON.stringify(light));
      fs.writeFileSync(files.dark, JSON.stringify(dark));
      out.push({ light, dark });
    } catch (e) {
      out.push({ error: String(e.message || e) });
    }
  }
  return out;
}

// 아주 넓은 왼→오(LR) 흐름도는 좁은 화면(360px)에서 80%로 줄여도 상자 폭의 몇 배라, 세로로 긴 띠 안에 빈 곳만 보이기 쉽다
// (M14 레슨 2의 전체 그림: 3157×884px → 302×707px 띠). 그런 그림만 같은 원문을 위→아래(TB)로 한 벌 더 그려
// 좁은 화면에서 대신 보인다(원고는 그대로, 넓은 화면은 원래 그림). 기준: 폭 2400px 이상이고 높이 600px 이상.
export const NARROW_MIN_WIDTH = 2400;
export const NARROW_MIN_HEIGHT = 600;
const LR_HEAD = /^(\s*(?:flowchart|graph))\s+(?:LR|RL)\b/m;
export function narrowSource(source, rendered) {
  if (!rendered || rendered.width < NARROW_MIN_WIDTH || rendered.height < NARROW_MIN_HEIGHT) return null;
  const first = source.split('\n').find((l) => l.trim() && !l.trim().startsWith('%%')) || '';
  if (!LR_HEAD.test(first)) return null;
  return source.replace(LR_HEAD, '$1 TB');
}
