// 표 배치 검사: 빌드된 페이지의 본문 표를 실제 화면 폭에서 잰다.
//  - 칸 넘침(실패): 어떤 칸의 내용(글자·인라인 코드·가운뎃점 묶음)이 그 칸의 경계를 넘어 옆 칸과 겹친다. 1280·360px 모두.
//  - 표 넘침(보고): 1280px에서 표가 자기 상자(.table-scroll)보다 넓어 가로 스크롤이 생긴다.
//    tests/tables-known.json 에 없는 넘침이 새로 생기거나, 목록의 항목이 더는 넘치지 않으면(낡은 예외) 알린다.
//  - 넘치는 표의 상자: 키보드로 스크롤할 수 있고(tabindex=0, role=region, 접근 가능한 이름),
//    스크롤 표시(.is-scrollable — 가장자리 그림자와 글자 안내)가 붙어야 한다(실패).
//  - 넘치지 않는 표에는 표시가 없어야 한다: 보이는 안내 글, .is-scrollable(그림자·점선), aria-describedby, tabindex(실패).
//    처음 연 폭뿐 아니라 창 폭을 바꾼 뒤(360→1280, 다시 1280→360)의 상태도 본다.
//  - 한글 낱말 중간 줄바꿈: 칸 안 한글 낱말(가~힣 2자 이상 연속)이 두 줄에 걸치면 센다. 인라인 코드 안은 실패,
//    일반 글(칸보다 긴 공백 없는 덩어리를 break-word 가 끊은 것)은 알려진 성질로 보고만 한다.
// 먼저 결함을 심은 표(칸을 넘는 코드, 상자보다 넓은 표, 넘치지 않는데 남은 표시, 코드 안에서 끊긴 한글 낱말)를 재서
// 실제로 잡는지 확인한다(자체 시험).
// 사용: node tests/tables.mjs --port <포트> [--pages pilot|all|/a/,/b/] [--fail] [--json <파일>]
//   --fail: 칸 넘침·스크롤 표시 문제·알려진 목록과의 차이가 있으면 종료 코드 1
import fs from 'node:fs';
import { offlineBrowser, pagesFromArgs, portFromArgs, serve } from './lib/harness.mjs';

const KNOWN_FILE = new URL('./tables-known.json', import.meta.url);
const KNOWN = JSON.parse(fs.readFileSync(KNOWN_FILE, 'utf8')).known;
const port = portFromArgs(4321);
const base = `http://127.0.0.1:${port}`;
const pages = pagesFromArgs({ withFiles: false });
const jsonIdx = process.argv.indexOf('--json');
const WIDTHS = [1280, 360];

/** 페이지 안에서 실행: 본문 표마다 칸 넘침과 표 넘침을 잰다. */
function measure() {
  const hiddenCache = new Map();
  const hidden = (el, stop) => {
    for (let e = el; e && e !== stop; e = e.parentElement) {
      if (!hiddenCache.has(e)) {
        const cs = getComputedStyle(e);
        const b = e.getBoundingClientRect();
        hiddenCache.set(e, cs.display === 'none' || cs.visibility === 'hidden' || (cs.position === 'absolute' && (cs.clip !== 'auto' || cs.clipPath !== 'none' || (b.width <= 1 && b.height <= 1))));
      }
      if (hiddenCache.get(e)) return true;
    }
    return false;
  };
  const out = [];
  const boxes = [...document.querySelectorAll('.sl-markdown-content .table-scroll, .table-scroll[data-selftest]')];
  boxes.forEach((box, i) => {
    const table = box.querySelector('table');
    if (!table) return;
    const overflowPx = Math.round(table.getBoundingClientRect().width - box.clientWidth);
    const cells = [];
    const korean = [];
    const range = document.createRange();
    for (const cell of table.querySelectorAll('th, td')) {
      const r = cell.getBoundingClientRect();
      let worst = 0;
      // 글자(텍스트 노드)마다 화면에 그려진 줄 상자를 본다. 화면에서 숨긴 글(스크린 리더 전용 라벨 등)은 뺀다.
      const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
      for (let t = walker.nextNode(); t; t = walker.nextNode()) {
        if (!t.nodeValue.trim() || hidden(t.parentElement, cell)) continue;
        range.selectNodeContents(t);
        for (const q of range.getClientRects()) {
          if (q.width < 0.5) continue;
          worst = Math.max(worst, q.right - r.right, r.left - q.left);
        }
      }
      // 한글 낱말이 두 줄에 걸쳤는가(낱말 안에서 줄이 바뀌었는가)
      const walker2 = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
      for (let t = walker2.nextNode(); t; t = walker2.nextNode()) {
        if (!/[가-힣]{2}/.test(t.nodeValue) || hidden(t.parentElement, cell)) continue;
        for (const m of t.nodeValue.matchAll(/[가-힣]{2,}/g)) {
          range.setStart(t, m.index);
          range.setEnd(t, m.index + m[0].length);
          const tops = new Set([...range.getClientRects()].filter((q) => q.width > 0.5).map((q) => Math.round(q.top)));
          if (tops.size > 1) korean.push({ word: m[0], inCode: Boolean(t.parentElement.closest('code')) });
        }
      }
      if (worst > 1) {
        const row = cell.parentElement;
        cells.push({ row: [...row.parentElement.children].indexOf(row) + (row.parentElement.tagName === 'TBODY' ? 1 : 0), col: [...row.children].indexOf(cell) + 1, px: Math.round(worst), text: cell.textContent.trim().slice(0, 40) });
      }
    }
    const name = box.getAttribute('aria-label') || box.getAttribute('aria-labelledby') || '';
    const prev = box.previousElementSibling;
    // hidden 속성이 아니라 실제로 그려졌는지를 본다(CSS 가 hidden 을 덮어쓸 수 있다)
    const hintVisible = Boolean(prev?.classList.contains('table-scroll-hint') && getComputedStyle(prev).display !== 'none' && prev.getBoundingClientRect().height > 0);
    out.push({
      index: i + 1,
      boxW: box.clientWidth,
      tableW: Math.round(table.getBoundingClientRect().width),
      overflowPx,
      cells,
      scrollable: box.scrollWidth > box.clientWidth + 1,
      keyboard: box.tabIndex === 0 && box.getAttribute('role') === 'region' && name.trim().length > 0,
      hint: box.classList.contains('is-scrollable'),
      // 넘치지 않는데 남은 표시(있으면 문제)
      leftovers: [
        hintVisible && '안내 글',
        box.classList.contains('is-scrollable') && '그림자·점선(.is-scrollable)',
        box.hasAttribute('aria-describedby') && 'aria-describedby',
        box.hasAttribute('tabindex') && 'tabindex',
      ].filter(Boolean),
      korean,
      selftest: box.dataset.selftest || '',
      firstHeader: (table.querySelector('th')?.textContent || '').trim().slice(0, 20),
    });
  });
  return out;
}

/** 자체 시험: 결함을 심은 표를 붙이고 measure 가 잡는지 본다. */
async function selftest(page) {
  await page.goto(`${base}/curriculum/m06-integration-messaging/cheatsheet/`, { waitUntil: 'load' });
  await page.evaluate(() => {
    const host = document.querySelector('.sl-markdown-content');
    const mk = (key, html, setup) => {
      const d = document.createElement('div');
      d.className = 'table-scroll';
      d.dataset.selftest = key;
      d.innerHTML = html;
      host.prepend(d);
      setup?.(d);
    };
    // 1) 고정 폭 칸을 넘는, 줄바꿈되지 않는 코드(칸 겹침)
    mk('overlap', '<table style="table-layout:fixed;width:300px"><tbody><tr><td style="width:100px"><code style="white-space:nowrap;overflow-wrap:normal">AWS::ElasticLoadBalancingV2::LoadBalancer</code></td><td>옆 칸</td></tr></tbody></table>');
    // 2) 상자보다 넓은 표(표 넘침) — 스크롤 표시를 붙이는 스크립트가 돌기 전이라 is-scrollable 이 없다
    mk('wide', '<table style="width:3000px;max-width:none"><tbody><tr><td>넓은 표</td></tr></tbody></table>');
    // 3) 넘치지 않는데 표시가 남은 표(창을 넓힌 뒤 안내를 못 지운 상태를 흉내)
    mk('leftover', '<table style="width:200px"><tbody><tr><td>좁은 표</td></tr></tbody></table>', (d) => {
      const p = document.createElement('p');
      p.className = 'table-scroll-hint';
      p.id = 'selftest-hint';
      p.textContent = '안내';
      d.before(p);
      d.classList.add('is-scrollable');
      d.setAttribute('aria-describedby', 'selftest-hint');
      d.tabIndex = 0;
    });
    // 4) 인라인 코드 안의 한글 낱말이 중간에서 끊김
    mk('korean', '<table style="table-layout:fixed;width:300px"><tbody><tr><td style="width:70px"><code style="word-break:break-all">연결하지못했습니다</code></td><td>옆</td></tr></tbody></table>');
  });
  const m = await page.evaluate(measure);
  const by = (k) => m.find((t) => t.selftest === k);
  const checks = {
    '칸 넘침': by('overlap')?.cells.length > 0,
    '넓은 표 넘침': by('wide')?.overflowPx > 1000 && by('wide').scrollable,
    '표시 없는 넘침': by('wide') && !by('wide').hint,
    '넘치지 않는데 남은 표시': by('leftover') && !by('leftover').scrollable && by('leftover').leftovers.length === 4,
    '코드 안 한글 낱말 끊김': by('korean')?.korean.some((k) => k.inCode),
  };
  const ok = Object.values(checks).every(Boolean);
  console.log(`자체 시험(심은 결함): ${Object.entries(checks).map(([k, v]) => `${k} ${v ? '잡음' : '못 잡음'}`).join(', ')} → ${ok ? 'PASS' : 'FAIL'}`);
  return ok;
}

const server = await serve(port);
const overlap = [];
const scrollProblems = [];
const wide1280 = [];
const koreanCode = [];
const koreanText = [];
let tables = 0;
let selfOk = false;

/** 한 번 잰 결과를 문제 목록에 더한다. label 은 "1280px", "360→1280px" 처럼 상태를 나타낸다. */
function collect(p, res, label, { first = false } = {}) {
  for (const t of res) {
    for (const c of t.cells) overlap.push(`${p} 표 ${t.index} ${label}: ${c.row}행 ${c.col}열 +${c.px}px "${c.text}"`);
    if (t.scrollable && !t.keyboard) scrollProblems.push(`${p} 표 ${t.index} ${label}: 넘치는데 키보드로 스크롤할 수 없다(tabindex·role·이름)`);
    if (t.scrollable && !t.hint) scrollProblems.push(`${p} 표 ${t.index} ${label}: 넘치는데 스크롤 표시(.is-scrollable)가 없다`);
    if (!t.scrollable && t.leftovers.length) scrollProblems.push(`${p} 표 ${t.index} ${label}: 넘치지 않는데 표시가 남음(${t.leftovers.join('·')})`);
    if (first) {
      for (const k of t.korean) (k.inCode ? koreanCode : koreanText).push(`${p} 표 ${t.index} ${label}: "${k.word}"`);
    }
  }
}

const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
try {
  // 색 테마는 배치에 영향이 없다(같은 CSS 길이) — 라이트만 잰다
  for (const width of WIDTHS) {
    const { browser, context } = await offlineBrowser({ colorScheme: 'light', viewport: { width, height: 900 } });
    const page = await context.newPage();
    if (width === 1280) selfOk = await selftest(page);
    for (const p of pages) {
      await page.goto(base + p, { waitUntil: 'load' });
      const res = await page.evaluate(measure);
      if (width === 1280) tables += res.length;
      collect(p, res, `${width}px`, { first: true });
      for (const t of res) if (width === 1280 && t.overflowPx > 1) wide1280.push({ page: p, index: t.index, overflowPx: t.overflowPx, boxW: t.boxW, tableW: t.tableW, firstHeader: t.firstHeader });
    }
    await browser.close();
  }
  // 창 폭 바꾸기: 360px 로 연 뒤 1280px 로 넓히고, 다시 360px 로 좁힌다
  {
    const { browser, context } = await offlineBrowser({ colorScheme: 'light', viewport: { width: 360, height: 900 } });
    const page = await context.newPage();
    for (const p of pages) {
      await page.goto(base + p, { waitUntil: 'load' });
      await page.setViewportSize({ width: 1280, height: 900 });
      await settle(page);
      collect(p, await page.evaluate(measure), '360→1280px');
      await page.setViewportSize({ width: 360, height: 900 });
      await settle(page);
      collect(p, await page.evaluate(measure), '360→1280→360px');
      await page.setViewportSize({ width: 360, height: 900 });
    }
    await browser.close();
  }
} finally {
  server.close();
}

const isKnown = (w) => KNOWN.some((k) => k.page === w.page && k.index === w.index);
const fresh = wide1280.filter((w) => !isKnown(w));
const checkedPages = new Set(pages);
const stale = KNOWN.filter((k) => checkedPages.has(k.page) && !wide1280.some((w) => w.page === k.page && w.index === k.index));
for (const o of overlap.slice(0, 40)) console.log(`칸 넘침 ${o}`);
if (overlap.length > 40) console.log(`… 칸 넘침 외 ${overlap.length - 40}건`);
for (const s of scrollProblems.slice(0, 20)) console.log(`스크롤 표시 ${s}`);
for (const k of koreanCode) console.log(`코드 안 한글 낱말 끊김 ${k}`);
for (const k of koreanText) console.log(`(알려진 성질) 일반 글의 한글 낱말 끊김 — 칸보다 긴 공백 없는 덩어리 ${k}`);
for (const w of wide1280) console.log(`${isKnown(w) ? '알려진' : '새'} 1280px 표 넘침 ${w.page} 표 ${w.index}: 표 ${w.tableW}px / 상자 ${w.boxW}px (+${w.overflowPx}) "${w.firstHeader}"`);
for (const k of stale) console.log(`낡은 예외(이제 넘치지 않음 — tables-known.json 에서 지운다) ${k.page} 표 ${k.index}`);
if (jsonIdx >= 0) fs.writeFileSync(process.argv[jsonIdx + 1], JSON.stringify({ pages: pages.length, tables, overlap, wide1280, scrollProblems, koreanCode, koreanText }, null, 1));
const bad = overlap.length + scrollProblems.length + koreanCode.length + fresh.length + stale.length + (selfOk ? 0 : 1);
console.log(`페이지 ${pages.length}개, 표 ${tables}개 × ${WIDTHS.join('·')}px + 창 폭 바꾸기(360→1280→360px)`);
console.log(`${bad ? 'FOUND' : 'PASS'} tables: 칸 넘침 ${overlap.length}칸, 1280px 표 넘침 ${wide1280.length}개(알려진 ${wide1280.length - fresh.length}, 새 ${fresh.length}), 낡은 예외 ${stale.length}개, 스크롤 표시 문제 ${scrollProblems.length}건, 한글 낱말 중간 줄바꿈 코드 안 ${koreanCode.length}곳·일반 글 ${koreanText.length}곳(보고만), 자체 시험 ${selfOk ? '통과' : '실패'}`);
if (bad && process.argv.includes('--fail')) process.exit(1);
