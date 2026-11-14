// 다이어그램 배치 검사: 빌드된 페이지의 Mermaid SVG(라이트·다크)에서
//  - 라벨 잘림: HTML 라벨(foreignObject) 안 내용이 상자보다 넓거나 높다
//  - 겹침: 서브그래프(cluster) 상자끼리 한쪽이 다른 쪽을 품지 않은 채 겹친다, 노드끼리 겹친다,
//          간선 라벨이 노드·서브그래프 제목·다른 간선 라벨에 가려진다
// 를 찾는다. 실제 화면 폭(1280px)에서 본다.
// 사용: node tests/diagrams.mjs --port <포트> [--pages all(기본)|pilot|/a/,/b/] [--fail]   (--fail: 하나라도 있으면 종료 코드 1)
import fs from 'node:fs';
import { offlineBrowser, pagesFromArgs, portFromArgs, serve, baseUrl, siteRoute } from './lib/harness.mjs';

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
        `</svg></div></div></div>`,
    );
  });
  const a = await page.evaluate(analyze, 'selftest');
  const sv = await page.evaluate(startVisible, 'selftest');
  const issues = a.out[0]?.issues ?? [];
  const contrast = issues.some((x) => x.startsWith('노드 글자 명암비'));
  const overlap = issues.some((x) => x.startsWith('노드 겹침'));
  const start = sv.some((x) => x.msg.includes('START'));
  const ok = contrast && overlap && start;
  console.log(`자체 시험(심은 결함): 낮은 명암비 ${contrast ? '잡음' : '못 잡음'}, 노드 겹침 ${overlap ? '잡음' : '못 잡음'}, 첫 화면에서 잘린 시작 노드 ${start ? '잡음' : '못 잡음'} → ${ok ? 'PASS' : 'FAIL'}`);
  return ok;
}
const results = [];
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
      svgChecked++;
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
console.log(`단독 SVG(원래 크기 보기) ${svgChecked}개 확인, 실패 ${svgFail.length}개 · 좁은 화면용 TB 배치 ${narrowChecked}개(라이트·다크) 검사`);
const total = fresh.reduce((s, r) => s + r.issues.length, 0) + svgFail.length + stale.length + startFail.length + (selfOk ? 0 : 1);
console.log(`${total ? 'FOUND' : 'PASS'} diagrams: 페이지 ${pages.length}개, 새 문제 ${total - stale.length - startFail.length}건(그림 ${fresh.length}개), 첫 화면에서 시작이 잘린 그림 ${startFail.length}개, 알려진 원고 문제 ${known.length}건, 낡은 예외 ${stale.length}건, 자체 시험 ${selfOk ? '통과' : '실패'}`);
if (total && process.argv.includes('--fail')) process.exit(1);
