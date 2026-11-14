// 표 배치 검사: 빌드된 페이지의 본문 표를 실제 화면 폭에서 잰다.
//  - 칸 넘침(실패): 어떤 칸의 내용(글자·인라인 코드·가운뎃점 묶음)이 그 칸의 경계를 넘어 옆 칸과 겹친다. 1280·360px 모두.
//  - 표 넘침(보고): 1280px에서 표가 자기 상자(.table-scroll)보다 넓어 가로 스크롤이 생긴다.
//    tests/tables-known.json 에 없는 넘침이 새로 생기거나, 목록의 항목이 더는 넘치지 않으면(낡은 예외) 알린다.
//  - 넘치는 표의 상자: 키보드로 스크롤할 수 있고(tabindex=0, role=region, 접근 가능한 이름),
//    스크롤 표시(.is-scrollable — 가장자리 그림자와 글자 안내)가 붙어야 한다(실패).
// 먼저 결함을 심은 표(칸을 넘는 코드, 상자보다 넓은 표)를 재서 실제로 잡는지 확인한다(자체 시험).
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
      if (worst > 1) {
        const row = cell.parentElement;
        cells.push({ row: [...row.parentElement.children].indexOf(row) + (row.parentElement.tagName === 'TBODY' ? 1 : 0), col: [...row.children].indexOf(cell) + 1, px: Math.round(worst), text: cell.textContent.trim().slice(0, 40) });
      }
    }
    const name = box.getAttribute('aria-label') || box.getAttribute('aria-labelledby') || '';
    out.push({
      index: i + 1,
      boxW: box.clientWidth,
      tableW: Math.round(table.getBoundingClientRect().width),
      overflowPx,
      cells,
      scrollable: box.scrollWidth > box.clientWidth + 1,
      keyboard: box.tabIndex === 0 && box.getAttribute('role') === 'region' && name.trim().length > 0,
      hint: box.classList.contains('is-scrollable'),
      firstHeader: (table.querySelector('th')?.textContent || '').trim().slice(0, 20),
    });
  });
  return out;
}

/** 자체 시험: 결함을 심은 표 두 개를 붙이고 measure 가 잡는지 본다. */
async function selftest(page) {
  await page.goto(`${base}/curriculum/m06-integration-messaging/cheatsheet/`, { waitUntil: 'load' });
  await page.evaluate(() => {
    const host = document.querySelector('.sl-markdown-content');
    const mk = (html) => {
      const d = document.createElement('div');
      d.className = 'table-scroll';
      d.dataset.selftest = '1';
      d.innerHTML = html;
      host.prepend(d);
    };
    // 1) 고정 폭 칸을 넘는, 줄바꿈되지 않는 코드(칸 겹침)
    mk('<table style="table-layout:fixed;width:300px"><tbody><tr><td style="width:100px"><code style="white-space:nowrap;overflow-wrap:normal">AWS::ElasticLoadBalancingV2::LoadBalancer</code></td><td>옆 칸</td></tr></tbody></table>');
    // 2) 상자보다 넓은 표(표 넘침) — 스크롤 표시를 붙이는 스크립트가 돌기 전이라 is-scrollable 이 없다
    mk('<table style="width:3000px;max-width:none"><tbody><tr><td>넓은 표</td></tr></tbody></table>');
  });
  const m = (await page.evaluate(measure)).filter((t) => t.index <= 2);
  const wide = m.find((t) => t.tableW >= 3000);
  const narrow = m.find((t) => t.tableW < 3000);
  const ok = narrow?.cells.length > 0 && wide?.overflowPx > 1000 && wide.scrollable && !wide.hint;
  console.log(`자체 시험(심은 결함): 칸 넘침 ${narrow?.cells.length ?? 0}칸 잡음, 넓은 표 넘침 ${wide?.overflowPx ?? 0}px 잡음, 표시 없는 넘침 ${wide && !wide.hint ? '잡음' : '못 잡음'} → ${ok ? 'PASS' : 'FAIL'}`);
  return ok;
}

const server = await serve(port);
const overlap = [];
const scrollProblems = [];
const wide1280 = [];
let tables = 0;
let selfOk = false;
try {
  for (const width of WIDTHS) {
    for (const colorScheme of ['light']) {
      // 색 테마는 배치에 영향이 없다(같은 CSS 길이) — 라이트만 잰다
      const { browser, context } = await offlineBrowser({ colorScheme, viewport: { width, height: 900 } });
      const page = await context.newPage();
      if (width === 1280) selfOk = await selftest(page);
      for (const p of pages) {
        await page.goto(base + p, { waitUntil: 'load' });
        const res = await page.evaluate(measure);
        if (width === 1280) tables += res.length;
        for (const t of res) {
          for (const c of t.cells) overlap.push(`${p} 표 ${t.index} ${width}px: ${c.row}행 ${c.col}열 +${c.px}px "${c.text}"`);
          if (t.scrollable && !t.keyboard) scrollProblems.push(`${p} 표 ${t.index} ${width}px: 넘치는데 키보드로 스크롤할 수 없다(tabindex·role·이름)`);
          if (t.scrollable && !t.hint) scrollProblems.push(`${p} 표 ${t.index} ${width}px: 넘치는데 스크롤 표시(.is-scrollable)가 없다`);
          if (width === 1280 && t.overflowPx > 1) wide1280.push({ page: p, index: t.index, overflowPx: t.overflowPx, boxW: t.boxW, tableW: t.tableW, firstHeader: t.firstHeader });
        }
      }
      await browser.close();
    }
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
for (const w of wide1280) console.log(`${isKnown(w) ? '알려진' : '새'} 1280px 표 넘침 ${w.page} 표 ${w.index}: 표 ${w.tableW}px / 상자 ${w.boxW}px (+${w.overflowPx}) "${w.firstHeader}"`);
for (const k of stale) console.log(`낡은 예외(이제 넘치지 않음 — tables-known.json 에서 지운다) ${k.page} 표 ${k.index}`);
if (jsonIdx >= 0) fs.writeFileSync(process.argv[jsonIdx + 1], JSON.stringify({ pages: pages.length, tables, overlap, wide1280, scrollProblems }, null, 1));
const bad = overlap.length + scrollProblems.length + fresh.length + stale.length + (selfOk ? 0 : 1);
console.log(`페이지 ${pages.length}개, 표 ${tables}개 × ${WIDTHS.join('·')}px`);
console.log(`${bad ? 'FOUND' : 'PASS'} tables: 칸 넘침 ${overlap.length}칸, 1280px 표 넘침 ${wide1280.length}개(알려진 ${wide1280.length - fresh.length}, 새 ${fresh.length}), 낡은 예외 ${stale.length}개, 스크롤 표시 문제 ${scrollProblems.length}건, 자체 시험 ${selfOk ? '통과' : '실패'}`);
if (bad && process.argv.includes('--fail')) process.exit(1);
