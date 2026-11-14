// Mermaid 다이어그램을 빌드할 때 SVG로 그린다(라이트·다크 두 벌). 브라우저에는 Mermaid 스크립트를 보내지 않는다.
// 그리기는 mermaid-isomorphic이 Playwright 헤드리스 Chromium 안에서 한다(로컬 파일만 읽는다).
// 같은 원문은 디스크 캐시(node_modules/.cache/guide-mermaid)에서 재사용한다.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { SITE_DIR } from '../lib/repo.mjs';

const require = createRequire(import.meta.url);
const CACHE_DIR = path.join(SITE_DIR, 'node_modules/.cache/guide-mermaid');

// 페이지와 같은 시스템 글꼴 스택. 빌드 때 글자 폭을 이 글꼴로 재므로 화면과 어긋남이 작다.
export const FONT_STACK =
  '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", "Segoe UI", sans-serif';

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
    versionTag = `mi${v('mermaid-isomorphic')}-pw${v('playwright')}-v5`;
  }
  return versionTag;
}

let renderer;
async function getRenderer() {
  if (!renderer) {
    const { createMermaidRenderer } = await import('mermaid-isomorphic');
    renderer = createMermaidRenderer();
  }
  return renderer;
}

function keyFor(source, theme) {
  return crypto.createHash('sha256').update(`${cacheVersion()}\0${JSON.stringify(THEMES[theme])}\0${source}`).digest('hex').slice(0, 24);
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
async function overlaps(svg, width) {
  const { browser } = await measurePageFor();
  const measurePage = await browser.newPage({ viewport: { width: 1600, height: 1200 } });
  try {
    return await measure(measurePage, svg, width);
  } finally {
    await measurePage.close().catch(() => {});
  }
}
async function measure(measurePage, svg, width) {
  await measurePage.setContent(`<div style="width:${Math.ceil(width)}px">${svg}</div>`);
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

async function renderOne(source, theme, layout) {
  const render = await getRenderer();
  const [res] = await render([source], {
    prefix: prefixFor(source, theme),
    mermaidConfig: {
      ...THEMES[theme],
      fontFamily: FONT_STACK,
      securityLevel: 'strict',
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
  const out = [];
  for (const src of sources) {
    const files = Object.fromEntries(Object.keys(THEMES).map((t) => [t, path.join(CACHE_DIR, `${keyFor(src, t)}.json`)]));
    if (Object.values(files).every((f) => fs.existsSync(f))) {
      out.push(Object.fromEntries(Object.entries(files).map(([t, f]) => [t, JSON.parse(fs.readFileSync(f, 'utf8'))])));
      continue;
    }
    try {
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
      fs.writeFileSync(files.light, JSON.stringify(light));
      fs.writeFileSync(files.dark, JSON.stringify(dark));
      out.push({ light, dark });
    } catch (e) {
      out.push({ error: String(e.message || e) });
    }
  }
  return out;
}
