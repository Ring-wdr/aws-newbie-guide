// 위젯이 붙기 전(astro-island[ssr])에 Tab 으로 들어가 누른 첫 키가 버려지지 않는지(guide-client.ts 의 initEarlyInput).
// 위젯 스크립트(아일랜드의 component-url·renderer-url)만 일부러 늦게(DELAY_MS) 보내 "붙기 전"을 길게 만든 뒤,
// 위젯 안 첫 조작 요소 바로 앞에서 Tab 으로 들어가 키 하나를 누르고, 붙은 뒤의 위젯 상태(글자 + 입력 요소의 값)를
// "먼저 붙인 뒤 같은 키를 누른" 상태와 비교한다. 같아야 한다.
//   키: 숫자 칸 ArrowUp, 범위 ArrowRight, 글자 칸 a, 체크 상자 Space, 라디오 ArrowDown, select ArrowDown, 단추 Enter.
//   그 키가 붙은 위젯에서도 아무것도 바꾸지 않으면(처음 상태와 같음) 판정하지 않고 "효과 없음"으로 센다.
//   서버가 그린 상태에서 조작 요소가 모두 꺼져 있는 위젯(진행 추적·이 레슨 완료 — 저장소를 읽기 전에는 disabled)은 대상이 아니다.
// 먼저 자체 시험: 받아 두기를 막은 페이지(창 단계에서 이벤트 전파를 끊는 결함)에서 M06 위젯의 첫 키가 사라지는 것을 잡아야 한다.
// 사용: node tests/widget-early-input.mjs --port <포트> [--pages pilot|all|/a/,/b/]
import fs from 'node:fs';
import path from 'node:path';
import { DIST, baseUrl, eachPage, offlineBrowser, pagesFromArgs, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const DELAY_MS = 1500;
const MAX_TRIES = 4;
const MAX_BUTTON_TRIES = 8;
const SELFTEST_PAGE = '/curriculum/m06-integration-messaging/02-sqs/';

const hasIsland = (p) => {
  const f = path.join(DIST, p, 'index.html');
  return fs.existsSync(f) && /class="guide-widget[^"]*"[\s\S]*?<astro-island/.test(fs.readFileSync(f, 'utf8'));
};

/**
 * 페이지 안 위젯마다 조작 요소 후보(꺼져 있지 않고 보이는 입력·select·단추). 값을 바꾸는 입력을 먼저, 단추는 뒤에
 * (이미 눌린 미리 채우기 단추 aria-pressed=true 는 빼고). 브라우저 안에서 돈다.
 */
function controlsInPage() {
  const SEL = 'input:not([type=hidden]), select, textarea, button';
  const RANK = { number: 0, range: 0, text: 0, search: 0, textarea: 0, checkbox: 1, radio: 2, select: 3, button: 4 };
  return [...document.querySelectorAll('.guide-widget')].flatMap((box, i) => {
    const island = box.querySelector('astro-island');
    if (!island) return [];
    const all = [...island.querySelectorAll(SEL)];
    const cands = all
      .map((c, idx) => ({ c, idx, kind: c.tagName === 'INPUT' ? c.type : c.tagName.toLowerCase() }))
      .filter(({ c, kind }) => !c.disabled && c.getClientRects().length > 0 && kind in RANK && c.getAttribute('aria-pressed') !== 'true')
      .sort((a, b) => RANK[a.kind] - RANK[b.kind] || a.idx - b.idx);
    // 라디오는 묶음마다 하나만
    const seen = new Set();
    const out = [];
    for (const x of cands) {
      if (x.kind === 'radio') {
        if (seen.has(x.c.name)) continue;
        seen.add(x.c.name);
      }
      out.push({ box: i, idx: x.idx, widget: box.dataset.widget || "?", kind: x.kind, label: (x.c.textContent || "").trim().slice(0, 20) });
    }
    return out.length ? [out] : [];
  });
}

const KEY = { number: 'ArrowUp', range: 'ArrowRight', text: 'a', search: 'a', checkbox: 'Space', radio: 'ArrowDown', select: 'ArrowDown', button: 'Enter', textarea: 'a' };

/** 위젯 상태: 글자 + 입력 요소 값. */
const snapshot = (page, box) =>
  page.evaluate((i) => {
    const b = document.querySelectorAll('.guide-widget')[i];
    const vals = [...b.querySelectorAll('input, select, textarea')].map((e) => (e.type === 'checkbox' || e.type === 'radio' ? (e.checked ? '1' : '0') : e.value));
    return `${b.innerText}\n--\n${vals.join('|')}`;
  }, box);

/**
 * 위젯 하나: 첫 조작 요소 바로 앞의 초점 가능한 요소에 초점을 두고 Tab, 키 하나. mode:
 *   'none'    — 누르지 않는다(처음 상태)   'after' — 붙은 뒤에 누른다(기준)   'early' — 스크립트를 늦춰 붙기 전에 누른다
 * @returns {{ state: string, pending: boolean|null }} pending: 키를 누른 순간 아직 붙기 전이었는가('early'만)
 */
async function runOne(page, p, ctl, mode, presses = 1) {
  await page.unroute('**/*').catch(() => {});
  if (mode === 'early') {
    const html = fs.readFileSync(path.join(DIST, p, 'index.html'), 'utf8');
    const slow = new Set([...html.matchAll(/(?:component|renderer)-url="([^"]+)"/g)].map((m) => new URL(m[1], baseUrl(port) + '/').pathname));
    await page.route('**/*', async (route) => {
      if (slow.has(new URL(route.request().url()).pathname)) await new Promise((r) => setTimeout(r, DELAY_MS));
      await route.fallback();
    });
  }
  await page.goto(`${baseUrl(port)}${p}`, { waitUntil: mode === 'early' ? 'domcontentloaded' : 'networkidle' });
  await page.waitForSelector('html.guide-js');
  const island = `.guide-widget >> nth=${ctl.box}`;
  // 대상 요소에 초점을 둔 뒤 Shift+Tab 으로 한 칸 앞으로 갔다가, Tab 으로 들어간다(탭 순서 그대로).
  const ok = await page.evaluate(([i, idx]) => {
    const SEL = 'input:not([type=hidden]), select, textarea, button';
    const c = document.querySelectorAll('.guide-widget')[i].querySelector('astro-island').querySelectorAll(SEL)[idx];
    window.__earlyTarget = c;
    if (!c) return false;
    c.focus();
    return document.activeElement === c;
  }, [ctl.box, ctl.idx]);
  if (!ok) return { state: null, pending: null };
  // client:visible 위젯은 초점으로 화면에 들어와야 붙는다. 처음 상태·기준은 붙을 때까지 기다린 뒤에 잰다.
  const hydrated = () => page.waitForSelector(`${island} >> astro-island:not([ssr])`, { state: 'attached', timeout: DELAY_MS + 10000 });
  if (mode !== 'early') await hydrated();
  await page.keyboard.press('Shift+Tab');
  if (mode === 'none') return { state: await snapshot(page, ctl.box), pending: null };
  for (let n = 0; n < 5; n++) {
    await page.keyboard.press('Tab');
    if (await page.evaluate(() => document.activeElement === window.__earlyTarget || (window.__earlyTarget.type === 'radio' && document.activeElement?.name === window.__earlyTarget.name)))
      break;
  }
  const focused = await page.evaluate(() => document.activeElement === window.__earlyTarget || (window.__earlyTarget.type === 'radio' && document.activeElement?.name === window.__earlyTarget.name));
  if (!focused) return { state: null, pending: null, why: 'Tab 으로 첫 조작 요소에 닿지 못함' };
  const pending = await page.evaluate((i) => !!document.querySelectorAll('.guide-widget')[i].querySelector('astro-island[ssr]'), ctl.box);
  // 붙은 뒤 이 요소에 실제로 전달된 click 수(단추 다시 누르기가 꼭 한 번인지 본다)
  await page.evaluate(() => {
    window.__clicksAfter = 0;
    const t = window.__earlyTarget;
    t.addEventListener('click', () => { if (!t.closest('astro-island[ssr]')) window.__clicksAfter++; });
  });
  if (mode === 'after' && pending) return { state: null, pending, why: '기준 측정: 붙은 뒤에 눌러야 하는데 아직 붙기 전이었다' };
  await page.keyboard.press(KEY[ctl.kind] || 'Enter');
  // 두 번째부터는 같은 요소를 다시 누른다(초점이 옮겨 가도 같은 단추 — "다시 누르기가 두 번 적용된" 결함과 같은 꼴)
  for (let k = 1; k < presses; k++) await page.evaluate(() => window.__earlyTarget.click());
  await hydrated();
  await page.waitForTimeout(300);
  return { state: await snapshot(page, ctl.box), pending, clicks: await page.evaluate(() => window.__clicksAfter) };
}

async function run(pages, initScript) {
  const { browser, context } = await offlineBrowser({ viewport: { width: 1280, height: 900 } });
  const results = [];
  try {
    if (initScript) await context.addInitScript(initScript);
    await eachPage(context, pages, async (page, p) => {
      await page.goto(`${baseUrl(port)}${p}`, { waitUntil: 'networkidle' });
      const widgets = await page.evaluate(controlsInPage);
      for (const cands of widgets) {
        // 위젯마다 후보를 차례로(최대 MAX_TRIES) 시험해, 붙은 위젯에서 눈에 띄는 효과가 있는 첫 조작으로 판정한다.
        let r = null;
        for (const ctl of cands.filter((c) => c.kind !== 'button').concat(cands.filter((c) => c.kind === 'button')).slice(0, MAX_TRIES)) {
          const name = `${p} [${ctl.widget}] ${ctl.kind} ${KEY[ctl.kind] || 'Enter'}`;
          const none = await runOne(page, p, ctl, 'none');
          const after = await runOne(page, p, ctl, 'after');
          if (after.why) { r = { name, verdict: 'fail', why: after.why }; break; }
          if (after.state === none.state) { r = { name, verdict: 'no-effect' }; continue; }
          const early = await runOne(page, p, ctl, 'early');
          if (early.why) r = { name, verdict: 'fail', why: early.why };
          else if (!early.pending) r = { name, verdict: 'fail', why: '키를 누를 때 이미 붙어 있었다(늦추기가 듣지 않음 — 검사가 성립하지 않는다)' };
          else if (early.state === after.state) r = { name, verdict: 'pass' };
          else r = { name, verdict: 'fail', why: `붙기 전에 누른 키가 반영되지 않음\n      기준: ${JSON.stringify(after.state.slice(-160))}\n      실제: ${JSON.stringify(early.state.slice(-160))}` };
          break;
        }
        results.push(r);
        // 단추 다시 누르기가 "한 번만" 적용되는지: 효과가 있는 단추를 붙기 전에 한 번 눌러, 붙은 뒤 그 단추에 전달된 click 이
        // 정확히 1번이고 결과가 "붙은 뒤 한 번 누른" 기준과 같은지 본다(두 번 눌러도 같은 결과인 단추에서도 두 번 눌림을 잡는다).
        let b = null;
        for (const ctl of cands.filter((c) => c.kind === 'button').slice(0, MAX_BUTTON_TRIES)) {
          const name = `${p} [${ctl.widget}] 단추 한 번만 Enter(${ctl.label})`;
          const none = await runOne(page, p, ctl, 'none');
          const once = await runOne(page, p, ctl, 'after');
          if (once.why || once.state === none.state) continue;
          const early = await runOne(page, p, ctl, 'early');
          if (early.why) b = { name, verdict: 'fail', why: early.why, button: true };
          else if (!early.pending) b = { name, verdict: 'fail', why: '키를 누를 때 이미 붙어 있었다(늦추기가 듣지 않음)', button: true };
          else if (early.clicks !== 1) b = { name, verdict: 'fail', why: `붙기 전에 누른 단추가 붙은 뒤 ${early.clicks}번 눌림(한 번이어야 한다)`, button: true };
          else if (early.state === once.state) b = { name, verdict: 'pass', button: true };
          else b = { name, verdict: 'fail', why: '붙기 전에 누른 단추의 결과가 기준과 다름', button: true };
          break;
        }
        if (b) results.push(b);
      }
    }, 3);
  } finally {
    await browser.close();
  }
  return results;
}

// 심는 결함: 받아 두기(initEarlyInput)가 이벤트를 보지 못하게 창(window) 단계에서 전파를 끊는다(브라우저 기본 동작은 그대로).
const PLANT_NO_RECORD = () => {
  for (const t of ['click', 'input', 'change'])
    window.addEventListener(t, (e) => e.target instanceof Element && e.target.closest('.guide-widget astro-island[ssr]') && e.stopImmediatePropagation(), true);
};

// 심는 결함 ②: 붙기 전에 누른 단추를 붙은 뒤 한 번 더 누른다(받아 두기의 다시 누르기와 합쳐 두 번 적용).
const PLANT_DOUBLE_CLICK = () => {
  const pressed = new Map();
  document.addEventListener('click', (e) => {
    const island = e.target instanceof Element && e.target.closest('.guide-widget astro-island[ssr]');
    const btn = island && e.target.closest('button');
    if (btn) pressed.set(island, [...(pressed.get(island) ?? []), btn]);
  }, true);
  document.addEventListener('astro:hydrate', (e) => {
    for (const btn of pressed.get(e.target) ?? []) setTimeout(() => btn.click(), 0);
  }, true);
};

const server = await serve(port);
let failed = false;
try {
  const st = await run([SELFTEST_PAGE], PLANT_NO_RECORD);
  const caught = st.some((r) => r.verdict === 'fail' && r.why.startsWith('붙기 전에 누른 키'));
  console.log(`widget-early-input 자체 시험(받아 두기를 막은 페이지): ${caught ? "첫 키가 사라진 것을 잡음" : "놓침"} — ${st.map((r) => `${r.name}: ${r.verdict}`).join(", ")}`);
  if (!caught) failed = true;
  const st2 = await run([SELFTEST_PAGE], PLANT_DOUBLE_CLICK);
  const caught2 = st2.some((r) => r.button && r.verdict === 'fail' && /[02-9]번 눌림/.test(r.why));
  console.log(`widget-early-input 자체 시험(단추를 두 번 적용하는 페이지): ${caught2 ? '두 번 눌림을 잡음' : '놓침'} — ${st2.filter((r) => r.button).map((r) => `${r.name}: ${r.verdict}`).join(', ') || '단추 판정 없음'}`);
  if (!caught2) failed = true;
  const pages = pagesFromArgs({ withFiles: false }).filter(hasIsland);
  const res = await run(pages, null);
  const count = (v) => res.filter((r) => r.verdict === v).length;
  console.log(`widget-early-input: 위젯 페이지 ${pages.length}쪽, 조작 요소가 켜진 위젯 ${res.filter((r) => !r.button).length}개 — 반영 ${res.filter((r) => !r.button && r.verdict === 'pass').length}, 효과 없음(판정 안 함) ${count('no-effect')}, 실패 ${count('fail')} (위젯 스크립트 ${DELAY_MS}ms 늦춤)`);
  for (const r of res) if (r.verdict !== 'pass') console.log(`  ${r.verdict === 'fail' ? '✖' : '·'} ${r.name}${r.why ? ` — ${r.why}` : ' — 효과 없음'}`);
  if (count('fail')) failed = true;
  console.log(`widget-early-input(단추 한 번만): 판정한 위젯 ${res.filter((r) => r.button).length}개 — 반영 ${res.filter((r) => r.button && r.verdict === 'pass').length}`);
  if (pages.includes(SELFTEST_PAGE) && !res.some((r) => r.name.startsWith(SELFTEST_PAGE) && r.button && r.verdict === 'pass')) {
    console.log(`  ✖ ${SELFTEST_PAGE}: M06 위젯의 단추 한 번만 적용이 판정되지 않았다(대표 사례)`);
    failed = true;
  }
  if (pages.includes(SELFTEST_PAGE) && !res.some((r) => r.name.startsWith(SELFTEST_PAGE) && !r.button && r.verdict === 'pass')) {
    console.log(`  ✖ ${SELFTEST_PAGE}: M06 위젯이 판정되지 않았다(대표 사례)`);
    failed = true;
  }
} finally {
  server.close();
}
process.exit(failed ? 1 : 0);
