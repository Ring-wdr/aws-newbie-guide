// 위젯 상자에 aria-busy="true" 가 남지 않는지(GUIDE-SITE 원칙 6). 화면 낭독기는 busy 영역을 건너뛸 수 있어,
// 남아 있으면 위젯이 서버에서 그린 내용(진행 목록·처음 계산 결과)까지 가려진다.
// 위젯 상자(.guide-widget 안에 astro-island)가 있는 대상 페이지마다 두 가지로 이동한 뒤 busy 로 남은 상자가 0인지 본다:
//   ① 로드 직후 맨 끝으로 바로 스크롤(중간 위젯을 빠르게 지나친 경우)  ② 스크롤 없이 Tab 으로만 문서 끝까지 이동
// 먼저 결함을 심은 페이지(옛 동작 — 붙기 전 busy, 붙으면 뗌 — 과 풀리지 않는 busy)로 이 검사가 실제로 실패하는지 확인한다.
// 사용: node tests/widget-busy.mjs --port <포트> [--pages pilot|all|/a/,/b/]
import fs from 'node:fs';
import path from 'node:path';
import { DIST, eachPage, offlineBrowser, pagesFromArgs, portFromArgs, serve, baseUrl } from './lib/harness.mjs';

const port = portFromArgs(4321);
const SETTLE_MS = 1000;
const MAX_TABS = 800;

const hasWidget = (p) => {
  const f = path.join(DIST, p, 'index.html');
  if (!fs.existsSync(f)) return false;
  const html = fs.readFileSync(f, 'utf8');
  return html.includes('guide-widget') && html.includes('<astro-island');
};

const busyBoxes = (page) => page.$$eval('.guide-widget[aria-busy="true"]', (els) => els.map((e) => e.dataset.widget || '(이름 없음)'));

/** 페이지 하나: 두 이동 방식마다 busy 로 남은 위젯 이름 목록. */
async function checkPage(page, p) {
  const url = `${baseUrl(port)}${p}`;
  const out = {};
  await page.goto(url, { waitUntil: 'load' });
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await page.waitForTimeout(SETTLE_MS);
  out['끝까지 스크롤'] = await busyBoxes(page);
  await page.goto(url, { waitUntil: 'load' });
  let n = 0;
  for (; n < MAX_TABS; n++) {
    await page.keyboard.press('Tab');
    if (n > 3 && (await page.evaluate(() => document.activeElement === document.body || document.activeElement === null))) break;
  }
  await page.waitForTimeout(SETTLE_MS);
  out[`Tab 만(${n}번)`] = await busyBoxes(page);
  return out;
}

async function run(pages, initScript) {
  const problems = [];
  const { browser, context } = await offlineBrowser({ viewport: { width: 1280, height: 900 } });
  try {
    if (initScript) await context.addInitScript(initScript);
    await eachPage(context, pages, async (page, p) => {
      const r = await checkPage(page, p);
      for (const [how, names] of Object.entries(r)) if (names.length) problems.push(`${p} ${how}: aria-busy="true" 남음 — ${names.join(', ')}`);
    });
  } finally {
    await browser.close();
  }
  return problems;
}

// 심는 결함 ① 옛 동작(PR #52): 붙기 전에는 busy, 붙으면(ssr 속성이 사라지면) 뗀다 — 화면에 안 들어온 위젯은 남는다.
const PLANT_UNTIL_HYDRATED = () => {
  document.addEventListener('DOMContentLoaded', () => {
    const sync = (b) => (b.querySelector('astro-island[ssr]') ? b.setAttribute('aria-busy', 'true') : b.removeAttribute('aria-busy'));
    const boxes = [...document.querySelectorAll('.guide-widget')].filter((b) => b.querySelector('astro-island'));
    boxes.forEach(sync);
    const mo = new MutationObserver((rs) => rs.forEach((r) => r.target.closest?.('.guide-widget') && sync(r.target.closest('.guide-widget'))));
    boxes.forEach((b) => mo.observe(b, { subtree: true, attributes: true, attributeFilter: ['ssr'] }));
  });
};
// 심는 결함 ② 풀리지 않는 busy(누가 떼어도 다시 단다).
const PLANT_STUCK = () => {
  const put = () => document.querySelectorAll('.guide-widget').forEach((b) => b.setAttribute('aria-busy', 'true'));
  document.addEventListener('DOMContentLoaded', () => {
    put();
    setInterval(put, 50);
  });
};

const SELFTEST_PAGES = ['/curriculum/m07-serverless-containers/', '/curriculum/m07-serverless-containers/01-lambda-execution-model/'];

const server = await serve(port);
let failed = false;
try {
  // 자체 시험: 심은 결함마다 두 페이지 모두에서 잡혀야 한다(①은 맨 끝 스크롤에서, ②는 두 방식 모두에서).
  const st1 = await run(SELFTEST_PAGES, PLANT_UNTIL_HYDRATED);
  const st2 = await run(SELFTEST_PAGES, PLANT_STUCK);
  const caught1 = SELFTEST_PAGES.every((p) => st1.some((x) => x.startsWith(`${p} 끝까지 스크롤`)));
  const caught2 = SELFTEST_PAGES.every((p) => st2.some((x) => x.startsWith(`${p} 끝까지 스크롤`)) && st2.some((x) => x.startsWith(`${p} Tab`)));
  console.log(`widget-busy 자체 시험: 붙기 전 busy ${caught1 ? '잡음' : '놓침'}(${st1.length}건), 풀리지 않는 busy ${caught2 ? '잡음' : '놓침'}(${st2.length}건)`);
  if (!caught1 || !caught2) {
    failed = true;
    console.log('  심은 결함을 잡지 못했다:', JSON.stringify({ st1, st2 }));
  }
  const pages = pagesFromArgs({ withFiles: false }).filter(hasWidget);
  const problems = await run(pages, null);
  console.log(`widget-busy: 위젯 페이지 ${pages.length}쪽 × (끝까지 스크롤·Tab 만) — aria-busy 남은 위젯 ${problems.length}곳`);
  for (const x of problems) console.log(`  ✖ ${x}`);
  if (problems.length) failed = true;
} finally {
  server.close();
}
process.exit(failed ? 1 : 0);
