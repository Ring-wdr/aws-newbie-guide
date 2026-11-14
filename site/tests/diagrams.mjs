// 다이어그램 배치 검사: 빌드된 페이지의 Mermaid SVG(라이트·다크)에서
//  - 라벨 잘림: HTML 라벨(foreignObject) 안 내용이 상자보다 넓거나 높다
//  - 겹침: 서브그래프(cluster) 상자끼리 한쪽이 다른 쪽을 품지 않은 채 겹친다, 노드끼리 겹친다,
//          간선 라벨이 노드·서브그래프 제목·다른 간선 라벨에 가려진다
// 를 찾는다. 실제 화면 폭(1280px)에서 본다.
// 글꼴(빌드한 OS 와 보는 OS 의 시스템 글꼴이 달라도 라벨이 잘리지 않는가 — src/plugins/diagram-font.mjs):
//  - 정상 조건: 실린 다이어그램 글꼴("Guide Diagram")을 다 읽은 뒤 잰다. 읽기 실패·시스템 글꼴로 그려진 글자(그림 글자 제외,
//    DevTools 프로토콜 CSS.getPlatformFontsForNode)도 실패.
//  - 대체 글꼴 조건: 실린 글꼴 요청을 막아 시스템 글꼴로 그리게 한 경우(라이트·다크)와, 거기에 폭이 크게 다른 고정폭 글꼴을
//    강제한 경우(라이트). 이때는 라벨이 상자를 넘칠 수 있지만, 잘려서 사라지는 글자(자르는 조상 밖의 글자, 스크롤로 닿을 수
//    없는 왼쪽·위로 나간 글자)는 0 이어야 한다.
//  - 단독 SVG(원래 크기로 보기): 파일 안에 담은 글꼴을 읽고 라벨이 잘리지 않는다.
// 사용: node tests/diagrams.mjs --port <포트> [--pages all(기본)|pilot|/a/,/b/] [--fail]   (--fail: 하나라도 있으면 종료 코드 1)
import fs from 'node:fs';
import { offlineBrowser, pagesFromArgs, portFromArgs, serve, baseUrl, siteRoute } from './lib/harness.mjs';
import { DIAGRAM_FAMILY, EMOJI_SEQ } from '../src/plugins/diagram-font.mjs';

const FONT_ROUTE = '**/fonts/diagram-*.woff2';
// 대체 글꼴 조건 2: 실린 글꼴을 막고 폭이 크게 다른 고정폭 글꼴을 강제한다.
const FORCE_WIDE = '.diagram svg, .diagram svg * { font-family: "Courier New", monospace !important; }';

/** 페이지 안: 그림 글자에 필요한 다이어그램 글꼴 조각을 읽고 상태를 돌려준다. */
async function loadDiagramFonts(family) {
  const svgs = [...document.querySelectorAll('.diagram svg, .diagram-selftest svg')];
  if (!svgs.length) return { diagrams: 0 };
  const text = svgs.map((x) => x.textContent).join('');
  try {
    await document.fonts.load(`16px "${family}"`, text);
  } catch {}
  await document.fonts.ready;
  const faces = [...document.fonts].filter((f) => f.family.replace(/"/g, '') === family);
  return {
    diagrams: svgs.length,
    faces: faces.length,
    loaded: faces.filter((f) => f.status === 'loaded').length,
    error: faces.filter((f) => f.status === 'error').length,
    ready: document.fonts.check(`16px "${family}"`, text),
  };
}

/** 페이지 안: 보이는 그림의 글자 노드에 표시를 달고 개수를 돌려준다(시스템 글꼴 검사용). */
function markText(theme) {
  let n = 0;
  for (const svg of document.querySelectorAll(`.diagram-${theme} svg, .diagram-n-${theme} svg`)) {
    if (!svg.getClientRects().length) continue;
    const w = document.createTreeWalker(svg, NodeFilter.SHOW_TEXT);
    for (let t = w.nextNode(); t; t = w.nextNode()) {
      if (!t.nodeValue.trim() || t.parentElement.closest('style, title, desc')) continue;
      if (!t.parentElement.hasAttribute('data-fchk')) {
        t.parentElement.setAttribute('data-fchk', '');
        n++;
      }
    }
  }
  return n;
}

/** Chromium 이 실제로 쓴 글꼴: 실린 글꼴이 아닌 글꼴로 그려진 글자가 있는 노드(그림 글자 묶음 수만큼은 허용). */
async function systemFontText(page, theme) {
  if (!(await page.evaluate(markText, theme))) return [];
  const cdp = await page.context().newCDPSession(page);
  const out = [];
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
      const text = outerHTML.replace(/<[^>]+>/g, '').trim();
      const emoji = (text.match(new RegExp(EMOJI_SEQ.source, 'gu')) || []).length;
      if (sys.reduce((a, f) => a + f.glyphCount, 0) > emoji) out.push(`시스템 글꼴로 그려진 글자(${sys.map((f) => f.familyName).join(', ')}) "${text.slice(0, 30)}"`);
    }
  } finally {
    await page.evaluate(() => document.querySelectorAll('[data-fchk]').forEach((e) => e.removeAttribute('data-fchk')));
    await cdp.detach().catch(() => {});
  }
  return out;
}

/**
 * 페이지 안: 잘려서 사라지는 글자. 그림 안 글자 노드의 줄 상자마다, 그림 상자(.diagram-scroll)까지의 조상 중
 * 넘침을 자르는(overflow 가 visible 이 아닌) 요소 밖으로 나간 부분이 있거나, 스크롤 상자의 왼쪽·위로 나가 스크롤로도 닿을 수 없으면 센다.
 */
function clipLoss(theme) {
  const out = [];
  const svgs = [...document.querySelectorAll(`.diagram-${theme} svg, .diagram-n-${theme} svg`)];
  svgs.forEach((svg) => {
    if (!svg.getClientRects().length) return;
    const scroll = svg.closest('.diagram-scroll');
    const all = [...document.querySelectorAll(svg.parentElement.classList.contains(`diagram-n-${theme}`) ? `.diagram-n-${theme} svg` : `.diagram-${theme} svg`)];
    const index = (svg.parentElement.classList.contains(`diagram-n-${theme}`) ? 'n' : '') + (all.indexOf(svg) + 1);
    const w = document.createTreeWalker(svg, NodeFilter.SHOW_TEXT);
    const lost = new Set();
    for (let t = w.nextNode(); t; t = w.nextNode()) {
      if (!t.nodeValue.trim() || t.parentElement.closest('style, title, desc')) continue;
      const range = document.createRange();
      range.selectNodeContents(t);
      for (const r of range.getClientRects()) {
        if (r.width < 0.5 || r.height < 0.5) continue;
        let bad = false;
        for (let el = t.parentElement; el && el !== scroll; el = el.parentElement) {
          const cs = getComputedStyle(el);
          const b = el.getBoundingClientRect();
          if (cs.overflowX !== 'visible' && (r.left < b.left - 1 || r.right > b.right + 1)) bad = true;
          if (cs.overflowY !== 'visible' && (r.top < b.top - 1 || r.bottom > b.bottom + 1)) bad = true;
        }
        if (scroll) {
          const sb = scroll.getBoundingClientRect();
          if (r.left < sb.left - scroll.scrollLeft - 1 || r.top < sb.top - scroll.scrollTop - 1) bad = true;
        }
        if (bad) lost.add(t.nodeValue.trim().slice(0, 30));
      }
    }
    if (lost.size) out.push({ index, issues: [...lost].map((x) => `글자 잘림 "${x}"`) });
  });
  return out;
}

// 원고 구조 때문에 배치로는 고칠 수 없어 편집자에게 넘긴 겹침(이유와 함께). 여기 없는 것은 실패.
const KNOWN = JSON.parse(fs.readFileSync(new URL('./diagrams-known.json', import.meta.url), 'utf8')).known;
const isKnown = (page, index, issue) => KNOWN.some((k) => k.page === page && k.index === index && issue.includes(k.match));

// 넓은 그림의 첫 화면: 흐름의 시작(들어오는 간선이 없는 노드 중 가장 위·왼쪽)이 스크롤 상자 안에 다 보여야 한다.
// guide-client.ts 의 startNode 와 같은 규칙을 여기서 따로 계산한다(구현을 그대로 믿지 않게).
function startVisible(theme) {
  const out = [];
  [...document.querySelectorAll('.diagram-scroll')].forEach((box, i) => {
    if (box.scrollWidth <= box.clientWidth + 1) return;
    const svg = box.querySelector(`.diagram-${theme} svg, .diagram-n-${theme} svg`); // 좁은 화면용 TB 배치(diagram-n-*)도
    if (!svg) return;
    const nodes = [...svg.querySelectorAll('g.node')];
    const idOf = (n) => /flowchart-(.+)-\d+$/.exec(n.id)?.[1];
    const names = new Set(nodes.map(idOf));
    const into = new Set();
    for (const e of svg.querySelectorAll('path[data-edge="true"][data-id]')) {
      const parts = (/^L_(.+)_\d+$/.exec(e.dataset.id)?.[1] || '').split('_');
      for (let k = 1; k < parts.length; k++) {
        if (names.has(parts.slice(0, k).join('_')) && names.has(parts.slice(k).join('_'))) {
          into.add(parts.slice(k).join('_'));
          break;
        }
      }
    }
    const starts = nodes.filter((n) => !into.has(idOf(n))).map((n) => ({ n, r: n.getBoundingClientRect() })).filter((x) => x.r.width > 0);
    if (!starts.length) return;
    starts.sort((a, b) => (Math.abs(a.r.top - b.r.top) > 2 ? a.r.top - b.r.top : a.r.left - b.r.left));
    const r = starts[0].r;
    const b = box.getBoundingClientRect();
    if (r.left < b.left - 1 || r.right > b.right + 1) out.push({ index: i + 1, msg: `첫 화면에 흐름의 시작 "${starts[0].n.textContent.trim().slice(0, 20)}"이 잘림(노드 ${Math.round(r.left - b.left)}~${Math.round(r.right - b.left)}px / 상자 ${Math.round(b.width)}px)` });
  });
  return out;
}

/** 페이지 안에서 실행: 테마의 Mermaid SVG 마다 라벨 잘림·겹침·노드 글자 명암비를 잰다. */
function analyze(theme) {
  const out = [];
  const svgs = [...document.querySelectorAll(`.diagram-${theme} svg`)];
  svgs.forEach((svg, i) => {
    const issues = [];
    for (const fo of svg.querySelectorAll('foreignObject')) {
      const inner = fo.firstElementChild;
      if (!inner) continue;
      const fr = fo.getBoundingClientRect();
      const ir = inner.getBoundingClientRect();
      const sw = inner.scrollWidth - inner.clientWidth;
      const sh = inner.scrollHeight - inner.clientHeight;
      if (ir.width - fr.width > 1.5 || ir.height - fr.height > 1.5 || sw > 1 || sh > 1) {
        issues.push(`라벨 잘림 "${inner.textContent.trim().slice(0, 30)}" (+${Math.round(Math.max(ir.width - fr.width, sw))}×+${Math.round(Math.max(ir.height - fr.height, sh))}px)`);
      }
    }
    const box = (el) => el.getBoundingClientRect();
    const clusters = [...svg.querySelectorAll('g.cluster > rect')].map((r) => ({ r: box(r), name: r.parentElement.id }));
    const inter = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    const contains = (a, b) => a.left <= b.left + 1 && a.right >= b.right - 1 && a.top <= b.top + 1 && a.bottom >= b.bottom - 1;
    for (let x = 0; x < clusters.length; x++)
      for (let y = x + 1; y < clusters.length; y++) {
        const a = clusters[x].r;
        const b = clusters[y].r;
        if (inter(a, b) && !contains(a, b) && !contains(b, a)) issues.push(`서브그래프 겹침 ${clusters[x].name} / ${clusters[y].name}`);
      }
    const nodes = [...svg.querySelectorAll('g.node')].map((n) => ({ r: box(n), name: n.id }));
    for (let x = 0; x < nodes.length; x++)
      for (let y = x + 1; y < nodes.length; y++) if (inter(nodes[x].r, nodes[y].r)) issues.push(`노드 겹침 ${nodes[x].name} / ${nodes[y].name}`);
    // 간선 라벨: 노드·서브그래프 제목·다른 간선 라벨에 가려지면 안 된다
    const labels = [...svg.querySelectorAll('g.edgeLabel')]
      .map((e) => ({ r: box(e), text: e.textContent.trim() }))
      .filter((e) => e.text && e.r.width > 1 && e.r.height > 1);
    const titles = [...svg.querySelectorAll('g.cluster-label')].map((t) => ({ r: box(t), name: t.textContent.trim().slice(0, 20) }));
    for (const l of labels) {
      for (const n of nodes) if (inter(l.r, n.r)) issues.push(`간선 라벨 "${l.text.slice(0, 20)}"이 노드 ${n.name}에 가려짐`);
      for (const t of titles) if (inter(l.r, t.r)) issues.push(`간선 라벨 "${l.text.slice(0, 20)}"이 서브그래프 제목 "${t.name}"과 겹침`);
    }
    for (let x = 0; x < labels.length; x++)
      for (let y = x + 1; y < labels.length; y++)
        if (inter(labels[x].r, labels[y].r)) issues.push(`간선 라벨끼리 겹침 "${labels[x].text.slice(0, 15)}" / "${labels[y].text.slice(0, 15)}"`);
    // 노드 글자와 노드 바탕의 명암비(WCAG AA 4.5:1). classDef/style 로 밝은 fill 을 박고 글자색이 없으면 다크에서 낮아진다.
    const rgb = (c) => (/rgba?\(([^)]+)\)/.exec(c)?.[1].split(',').map((x) => parseFloat(x)) ?? null);
    const lum = ([r, g, b]) => [r, g, b].map((v) => v / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)).reduce((s, c, k) => s + c * [0.2126, 0.7152, 0.0722][k], 0);
    for (const n of svg.querySelectorAll('g.node')) {
      const shape = n.querySelector('rect, polygon, circle, ellipse, path');
      const label = n.querySelector('.nodeLabel p, .nodeLabel, text');
      if (!shape || !label || !label.textContent.trim()) continue;
      const f = rgb(getComputedStyle(shape).fill);
      const t = rgb(getComputedStyle(label).color);
      if (!f || !t || (f.length > 3 && f[3] === 0)) continue;
      const [a, b] = [lum(f), lum(t)].sort((x, y) => y - x);
      const ratio = (a + 0.05) / (b + 0.05);
      if (ratio < 4.5) issues.push(`노드 글자 명암비 ${ratio.toFixed(2)}:1 "${label.textContent.trim().slice(0, 20)}" (바탕 ${getComputedStyle(shape).fill}, 글자 ${getComputedStyle(label).color})`);
    }
    if (issues.length) out.push({ index: i + 1, issues });
  });
  return { count: svgs.length, out };
}
const port = portFromArgs(4321);
const pages = pagesFromArgs({ withFiles: false, def: 'all' });
const server = await serve(port);

/** 자체 시험: 결함을 심은 그림(밝은 바탕 + 밝은 글자 노드, 겹친 노드, 시작 노드가 오른쪽 끝에 있는 넓은 그림)을 잡는지. */
async function selftest(page) {
  await page.goto(`${baseUrl(port)}/curriculum/m06-integration-messaging/cheatsheet/`, { waitUntil: 'load' });
  await page.evaluate(() => {
    const host = document.querySelector('.sl-markdown-content');
    const node = (id, x, fill, color) =>
      `<g class="node" id="st-flowchart-${id}-0" transform="translate(${x},40)"><rect x="-50" y="-20" width="100" height="40" style="fill:${fill}"></rect>` +
      `<foreignObject x="-40" y="-10" width="80" height="20"><div><span class="nodeLabel" style="color:${color}"><p>${id}</p></span></div></foreignObject></g>`;
    host.insertAdjacentHTML(
      'afterbegin',
      `<div class="diagram" data-selftest="1"><div class="diagram-scroll" style="overflow-x:auto;width:300px"><div class="diagram-selftest">` +
        `<svg width="1600" height="80" style="max-width:none;width:1600px">` +
        node('LOW', 60, '#fde2e2', '#cccccc') + node('B1', 300, '#1f2020', '#cccccc') + node('B2', 330, '#1f2020', '#cccccc') + node('START', 1540, '#1f2020', '#cccccc') +
        `<path data-edge="true" data-id="L_START_LOW_0" d="M0 0"></path><path data-edge="true" data-id="L_START_B1_0" d="M0 0"></path><path data-edge="true" data-id="L_START_B2_0" d="M0 0"></path>` +
        // 잘려서 사라지는 글자(자르는 상자 안의 긴 글자)와 시스템 글꼴로 그려진 글자
        `<foreignObject x="600" y="10" width="60" height="24"><div style="overflow:hidden;width:40px;white-space:nowrap">CLIPPEDCLIPPEDCLIPPED</div></foreignObject>` +
        `<text x="800" y="30" style="font-family:monospace">SYSFONT</text>` +
        `</svg></div></div></div>`,
    );
  });
  const a = await page.evaluate(analyze, 'selftest');
  const sv = await page.evaluate(startVisible, 'selftest');
  const issues = a.out[0]?.issues ?? [];
  const contrast = issues.some((x) => x.startsWith('노드 글자 명암비'));
  const overlap = issues.some((x) => x.startsWith('노드 겹침'));
  const start = sv.some((x) => x.msg.includes('START'));
  const lost = (await page.evaluate(clipLoss, 'selftest')).some((x) => x.issues.some((i) => i.includes('CLIPPED')));
  const sysFont = (await systemFontText(page, 'selftest')).some((x) => x.includes('SYSFONT'));
  const ok = contrast && overlap && start && lost && sysFont;
  const said = (b) => (b ? '잡음' : '못 잡음');
  console.log(`자체 시험(심은 결함): 낮은 명암비 ${said(contrast)}, 노드 겹침 ${said(overlap)}, 첫 화면에서 잘린 시작 노드 ${said(start)}, 잘려서 사라지는 글자 ${said(lost)}, 시스템 글꼴로 그려진 글자 ${said(sysFont)} → ${ok ? 'PASS' : 'FAIL'}`);
  return ok;
}
const results = [];
const fontFail = [];
const lossFail = [];
const condFail = [];
let fontPages = 0;
const opens = new Set();
const svgFail = [];
const startFail = [];
let selfOk = false;
let svgChecked = 0;
let narrowChecked = 0;
try {
  for (const colorScheme of ['light', 'dark']) {
    const { browser, context } = await offlineBrowser({ colorScheme, viewport: { width: 1280, height: 900 } });
    const page = await context.newPage();
    if (colorScheme === 'light') selfOk = await selftest(page);
    for (const p of pages) {
      await page.goto(`${baseUrl(port)}${p}`, { waitUntil: 'load' });
      const fl = await page.evaluate(loadDiagramFonts, DIAGRAM_FAMILY);
      if (fl.diagrams) {
        fontPages++;
        if (!fl.faces || fl.error || !fl.ready) fontFail.push(`${p} (${colorScheme}): 다이어그램 글꼴을 읽지 못함(@font-face ${fl.faces ?? 0}개, 오류 ${fl.error ?? 0}개)`);
        if (colorScheme === 'light') for (const x of await systemFontText(page, 'light')) fontFail.push(`${p}: ${x}`);
      }
      const found = await page.evaluate(analyze, colorScheme);
      for (const f of found.out) results.push({ page: p, theme: colorScheme, ...f });
      // 좁은 화면용 TB 배치(아주 넓은 LR 그림만, 40rem 이하에서 보임): 잠깐 보이게 해서 같은 기준으로 잰다. 순번은 n1, n2…
      if (await page.$('.diagram-scroll-narrow')) {
        await page.addStyleTag({ content: '.diagram-scroll-narrow{display:block!important}' });
        const nf = await page.evaluate(analyze, `n-${colorScheme}`);
        for (const f of nf.out) results.push({ page: p, theme: colorScheme, ...f, index: `n${f.index}` });
        narrowChecked += nf.count;
      }
      for (const f of await page.evaluate(startVisible, colorScheme)) startFail.push(`${p} 그림 ${f.index} (${colorScheme} 1280px): ${f.msg}`);
      for (const href of await page.$$eval(`.diagram-open-${colorScheme}`, (as) => as.map((a) => a.getAttribute('href')))) opens.add(href);
    }
    // '원래 크기로 보기' 링크가 가리키는 단독 SVG 가 XML 로 읽히고 그림이 그려지는지
    for (const href of opens) {
      // 링크는 base 를 붙여 나온다(하위 경로 빌드). base 밖을 가리키면 siteRoute 가 null — 실패로 남긴다.
      const route = siteRoute(href);
      if (route === null) {
        svgFail.push(`${href}: 사이트 base 밖을 가리킴`);
        continue;
      }
      if (!route.startsWith('/diagrams/') || !href.endsWith(`-${colorScheme}.svg`)) continue;
      const res = await page.goto(`${baseUrl(port)}${route}`, { waitUntil: 'load' });
      const ok = await page.evaluate(() => document.documentElement.localName === 'svg' && !document.querySelector('parsererror') && (() => { const b = document.documentElement.getBBox(); return b.width > 50 && b.height > 20 && document.documentElement.textContent.trim().length > 0; })());
      if (!res || res.status() !== 200 || !ok) svgFail.push(`${href}: ${res ? res.status() : '응답 없음'}${ok ? '' : ', SVG 로 그려지지 않음'}`);
      // 단독 SVG 안에 담은 글꼴을 읽고, 그 글꼴로 라벨이 잘리지 않는지
      const st = await page.evaluate(async (family) => {
        await document.fonts.ready;
        const faces = [...document.fonts].filter((f) => f.family.replace(/"/g, '') === family);
        await Promise.all(faces.map((f) => f.load().catch(() => {})));
        const clipped = [];
        for (const fo of document.querySelectorAll('foreignObject')) {
          const inner = fo.firstElementChild;
          if (!inner) continue;
          const fr = fo.getBoundingClientRect();
          const ir = inner.getBoundingClientRect();
          if (ir.width - fr.width > 1.5 || ir.height - fr.height > 1.5) clipped.push(inner.textContent.trim().slice(0, 30));
        }
        return { faces: faces.length, bad: faces.filter((f) => f.status !== 'loaded').length, clipped, visible: [...document.querySelectorAll('foreignObject')].every((f) => getComputedStyle(f).overflow === 'visible') };
      }, DIAGRAM_FAMILY);
      if (!st.faces || st.bad) svgFail.push(`${href}: 담은 다이어그램 글꼴을 읽지 못함(${st.faces}개 중 ${st.bad}개)`);
      if (st.clipped.length) svgFail.push(`${href}: 라벨 잘림 ${st.clipped.slice(0, 3).map((x) => `"${x}"`).join(', ')}`);
      if (!st.visible) svgFail.push(`${href}: 라벨 넘침을 자른다(foreignObject overflow 가 visible 이 아님)`);
      svgChecked++;
    }
    await browser.close();
  }
  // 대체 글꼴 조건: 실린 글꼴을 막아 시스템 글꼴로(라이트·다크), 그리고 폭이 크게 다른 고정폭 글꼴로(라이트). 잘려서 사라지는 글자 0.
  for (const cond of [
    { name: '시스템 글꼴', colorScheme: 'light', force: false },
    { name: '시스템 글꼴', colorScheme: 'dark', force: false },
    { name: '고정폭 글꼴', colorScheme: 'light', force: true },
  ]) {
    const { browser, context } = await offlineBrowser({ colorScheme: cond.colorScheme, viewport: { width: 1280, height: 900 } });
    const page = await context.newPage();
    await page.route(FONT_ROUTE, (route) => route.abort('blockedbyclient'));
    for (const p of pages) {
      await page.goto(`${baseUrl(port)}${p}`, { waitUntil: 'load' });
      const fl = await page.evaluate(loadDiagramFonts, DIAGRAM_FAMILY);
      if (!fl.diagrams) continue;
      // 조건이 실제로 걸렸는지(실린 글꼴을 못 읽었는지) — 안 걸렸으면 이 판정은 의미가 없다
      if (!fl.error && fl.ready) condFail.push(`${p} (${cond.name}, ${cond.colorScheme}): 실린 글꼴을 막지 못함`);
      if (cond.force) await page.addStyleTag({ content: FORCE_WIDE });
      if (await page.$('.diagram-scroll-narrow')) await page.addStyleTag({ content: '.diagram-scroll-narrow{display:block!important}' });
      for (const f of await page.evaluate(clipLoss, cond.colorScheme)) lossFail.push(`${p} 그림 ${f.index} (${cond.name}, ${cond.colorScheme}): ${f.issues.slice(0, 3).join('; ')}`);
    }
    await browser.close();
  }
  // 360px(라이트): 넓은 그림의 첫 화면만 본다
  {
    const { browser, context } = await offlineBrowser({ colorScheme: 'light', viewport: { width: 360, height: 800 } });
    const page = await context.newPage();
    for (const p of pages) {
      await page.goto(`${baseUrl(port)}${p}`, { waitUntil: 'load' });
      for (const f of await page.evaluate(startVisible, 'light')) startFail.push(`${p} 그림 ${f.index} (light 360px): ${f.msg}`);
      // 좁은 화면용 배치가 있는 그림은 360px에서 원래 그림 대신 그것이 보여야 한다
      for (const bad of await page.$$eval('.diagram.has-narrow', (fs) =>
        fs.filter((f) => f.querySelector('.diagram-scroll-wide').getClientRects().length > 0 || f.querySelector('.diagram-scroll-narrow').getClientRects().length === 0).map((f, i) => i + 1),
      ))
        startFail.push(`${p} 좁은 화면용 배치 ${bad}: 360px에서 원래 그림이 보이거나 TB 배치가 숨어 있음`);
    }
    await browser.close();
  }
} finally {
  server.close();
}
const known = [];
const fresh = [];
for (const r of results) {
  const k = r.issues.filter((x) => isKnown(r.page, r.index, x));
  const f = r.issues.filter((x) => !isKnown(r.page, r.index, x));
  if (k.length) known.push({ ...r, issues: k });
  if (f.length) fresh.push({ ...r, issues: f });
}
// 낡은 예외: 대상 페이지에 있는데 이제 재현되지 않는 항목(원고가 고쳐졌으면 diagrams-known.json 에서 지운다)
const stale = KNOWN.filter((k) => pages.includes(k.page) && !known.some((r) => r.page === k.page && r.index === k.index && r.issues.some((x) => x.includes(k.match))));
for (const r of known) console.log(`알려진 원고 문제(편집자 몫) ${r.page} 그림 ${r.index} (${r.theme}): ${r.issues.join('; ')}`);
for (const k of stale) console.log(`낡은 예외(재현되지 않음 — diagrams-known.json 에서 지운다) ${k.page} 그림 ${k.index} "${k.match}"`);
for (const r of fresh.sort((a, b) => b.issues.length - a.issues.length)) console.log(`${r.issues.length}건 ${r.page} 그림 ${r.index} (${r.theme}): ${r.issues.slice(0, 4).join('; ')}`);
for (const f of svgFail) console.log(`단독 SVG 실패 ${f}`);
for (const f of startFail) console.log(`첫 화면 ${f}`);
for (const f of fontFail) console.log(`글꼴 ${f}`);
for (const f of condFail) console.log(`대체 글꼴 조건 미적용 ${f}`);
for (const f of lossFail) console.log(`대체 글꼴에서 ${f}`);
console.log(`단독 SVG(원래 크기 보기) ${svgChecked}개 확인, 실패 ${svgFail.length}개 · 좁은 화면용 TB 배치 ${narrowChecked}개(라이트·다크) 검사`);
console.log(`글꼴: 그림이 있는 페이지 ${fontPages / 2}개에서 실린 글꼴 확인, 실패 ${fontFail.length}건 · 대체 글꼴 조건(시스템 글꼴 라이트·다크, 고정폭 라이트)에서 잘려서 사라지는 글자 ${lossFail.length}건, 조건 미적용 ${condFail.length}건`);
const fontTotal = fontFail.length + lossFail.length + condFail.length;
const total = fresh.reduce((s, r) => s + r.issues.length, 0) + svgFail.length + stale.length + startFail.length + fontTotal + (selfOk ? 0 : 1);
console.log(`${total ? 'FOUND' : 'PASS'} diagrams: 페이지 ${pages.length}개, 새 문제 ${total - stale.length - startFail.length - fontTotal}건(그림 ${fresh.length}개), 첫 화면에서 시작이 잘린 그림 ${startFail.length}개, 글꼴·대체 글꼴 문제 ${fontTotal}건, 알려진 원고 문제 ${known.length}건, 낡은 예외 ${stale.length}건, 자체 시험 ${selfOk ? '통과' : '실패'}`);
if (total && process.argv.includes('--fail')) process.exit(1);
