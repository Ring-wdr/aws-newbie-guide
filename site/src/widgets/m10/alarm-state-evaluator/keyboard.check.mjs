// M10 알람 상태 평가기를 키보드만으로 끝까지 조작하는 독립 검사(공용 site/tests/keyboard.mjs와 별도).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Home/End, Space, Enter, 글자)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 라이트/다크 × 1280/360px 위젯 스크린샷을 찍고 360px 가로 넘침을 확인한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m10/alarm-state-evaluator/keyboard.check.mjs --port 4334 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m10-monitoring-iac/01-cloudwatch-metrics-alarms/';
const ROOT = '.cwa';
const port = portFromArgs(4334);
const base = `http://127.0.0.1:${port}`; // sitecheck-allow: 루프백 검사 서버
const shotsIdx = process.argv.indexOf('--shots');
const shots = shotsIdx >= 0 ? path.resolve(process.argv[shotsIdx + 1]) : null;
const problems = [];
const server = await serve(port);

async function open(opts) {
  const b = await offlineBrowser(opts);
  const page = await b.context.newPage();
  await page.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator(ROOT).evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m10/alarm-state-evaluator"] astro-island:not([ssr])') !== null);
  return { ...b, page };
}
const focusIs = (sel) => document.activeElement?.matches?.(sel) ?? false;

try {
  const { browser, page, blocked } = await open({ viewport: { width: 1280, height: 900 } });
  let keys = 0;
  const press = async (k) => {
    keys++;
    await page.keyboard.press(k);
  };
  const tabUntil = async (sel, { back = false, max = 200 } = {}) => {
    for (let i = 0; i < max; i++) {
      if (await page.evaluate(focusIs, sel)) return;
      await press(back ? 'Shift+Tab' : 'Tab');
    }
    throw new Error(`초점을 옮기지 못했다: ${sel}`);
  };
  const result = () => page.textContent(`${ROOT} .cwa-result`);
  const expect = async (what, want) => {
    const t = (await result()).trim();
    if (!t.includes(want)) problems.push(`${what}: "${want}"가 아님 — "${t}"`);
    else console.log(`  ✓ ${what}: ${t.slice(0, 70)}`);
  };

  // 가로 스크롤 금지: 문서 폭이 화면 폭을 넘으면 실패(시작 상태와 미리 채우기마다)
  const noHScroll = async (label) => {
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    if (sw > cw) problems.push(`1280px ${label}: 가로 스크롤(scrollWidth ${sw} > clientWidth ${cw})`);
  };
  await page.evaluate(() => document.activeElement?.blur());
  await noHScroll('시작 상태');
  // 1) 처음(lab02 예): ALARM
  await expect('lab02 예(처음 값)', 'ALARM');
  // 2) 하트비트 예 → missing: INSUFFICIENT_DATA
  await tabUntil(`${ROOT} button[data-preset=heartbeat]`);
  await press('Enter');
  await noHScroll(`미리 채우기 heartbeat`);
  await expect('하트비트 + missing(범위 상한을 지나 INSUFFICIENT_DATA)', '? INSUFFICIENT_DATA');
  // 3) TreatMissingData를 화살표로: notBreaching → OK, breaching → ALARM, ignore → OK(직전 상태 유지)
  await tabUntil(`${ROOT} input[name=cwa-tmd]`);
  await press('ArrowDown');
  await expect('하트비트 + notBreaching', '● OK');
  await press('ArrowDown');
  await expect('하트비트 + breaching(원고의 답 — 범위 상한을 지나 ALARM)', '▲ ALARM');
  await press('ArrowDown');
  await expect('하트비트 + ignore(직전 상태 OK 유지)', '● OK');
  // 규칙·한계 문구는 접힌 영역이 아니라 판정 바로 옆에 보여야 한다
  const rulesShown = await page.$eval(`${ROOT} .cwa-verdict .cwa-rules`, (e) => !e.closest('details') && e.getBoundingClientRect().height > 0 && e.textContent.includes('판정하지 않음'));
  if (!rulesShown) problems.push('판정 규칙과 한계 문구가 판정 옆에 보이지 않음');
  // 4) M of N 예 → ALARM, 평가 시점 Home → 구간 1, End → 마지막
  await tabUntil(`${ROOT} button[data-preset=spike]`, { back: true });
  await press('Enter');
  await noHScroll(`미리 채우기 spike`);
  await expect('M of N 예', 'ALARM');
  await tabUntil(`${ROOT} input[data-field=at]`);
  await press('Home');
  let now = (await page.textContent(`${ROOT} .cwa-now`)).trim();
  if (!/^구간 1\/6/.test(now)) problems.push(`평가 시점 Home: "${now}"`);
  await press('ArrowRight');
  now = (await page.textContent(`${ROOT} .cwa-now`)).trim();
  if (!/^구간 2\/6.*위반 1개, ALARM에 필요 2개.*OK/.test(now)) problems.push(`평가 시점 2구간(튀는 값 하나): "${now}"`);
  else console.log(`  ✓ 평가 시점 2구간: ${now.slice(0, 70)}`);
  await press('End');
  now = (await page.textContent(`${ROOT} .cwa-now`)).trim();
  if (!/^구간 6\/6/.test(now)) problems.push(`평가 시점 End: "${now}"`);
  // 5) N을 글자로 1로 바꾸면(M은 1로 맞춰짐) 마지막 값 850 하나로 ALARM, 표의 필요 수도 1
  await tabUntil(`${ROOT} input[data-field=n]`, { back: true });
  for (let i = 0; i < 4; i++) await press('Backspace');
  await press('1');
  await expect('N=1', 'ALARM');
  const need = await page.textContent(`${ROOT} .cwa-table tbody tr:last-child td:nth-child(3)`);
  if (!/실제 6개 중 최근 N개 · 위반 1$/.test(need.trim())) problems.push(`N=1일 때 표의 판정 근거: "${need}"`);
  // 6) 값 덧붙이기: 정상 값 → OK, 누락 → (missing) INSUFFICIENT_DATA, 마지막 지우기 → OK
  await tabUntil(`${ROOT} button[data-add=ok]`);
  await press('Enter');
  await expect('정상 값 덧붙임', '● OK');
  await tabUntil(`${ROOT} button[data-add=missing]`);
  await press('Enter');
  await expect('누락 덧붙임(missing — 범위 안 실제 값으로 OK 유지)', '● OK');
  await tabUntil(`${ROOT} button[data-add=drop]`);
  await press('Enter');
  await expect('마지막 구간 지우기', '● OK');
  // 7) 표 펼침 상자를 키보드로 닫았다 연다
  await tabUntil(`${ROOT} .cwa-table-box > summary`);
  await press('Enter');
  if (await page.$eval(`${ROOT} .cwa-table-box`, (d) => d.open)) problems.push('표 상자가 Enter로 닫히지 않음');
  await press('Enter');
  if (blocked.length) problems.push(`외부 요청: ${blocked.join(', ')}`);
  console.log(`키 입력 ${keys}번`);
  await browser.close();

  // 가로 넘침 검사는 --shots 없이도 늘 돈다(스크린샷만 --shots 때)
  {
    if (shots) fs.mkdirSync(shots, { recursive: true });
    for (const colorScheme of ['light', 'dark']) {
      for (const width of [1280, 360]) {
        const o = await open({ colorScheme, viewport: { width, height: 900 }, reducedMotion: 'reduce' });
        const chk = async (label) => {
          const [sw, cw] = await o.page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
          if (sw > cw) problems.push(`${colorScheme} ${width}px ${label}: 가로 스크롤(scrollWidth ${sw} > clientWidth ${cw})`);
        };
        await chk('시작 상태');
        for (const id of await o.page.$$eval(`${ROOT} button[data-preset]`, (bs) => bs.map((b) => b.dataset.preset))) {
          await o.page.locator(`${ROOT} button[data-preset="${id}"]`).click();
          await chk(`미리 채우기 ${id}`);
        }
        await o.page.evaluate((s) => document.documentElement.setAttribute('data-theme', s), colorScheme);
        await o.page.locator(`${ROOT} button[data-preset=spike]`).click();
        await o.page.locator(`${ROOT} input[data-field=at]`).fill('3');
        const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (over > 0) problems.push(`${colorScheme} ${width}px: 가로 넘침 ${over}px`);
        const wide = await o.page.$$eval(`${ROOT} *`, (els, w) => els.filter((e) => e.getBoundingClientRect().right > w + 0.5 && !e.closest('.cwa-table-scroll')).map((e) => e.className || e.tagName).slice(0, 5), width);
        if (wide.length) problems.push(`${colorScheme} ${width}px: 화면 밖으로 나간 요소 ${wide.join(', ')}`);
        const file = shots && path.join(shots, `m10-alarm-${colorScheme}-${width}.png`);
        if (shots) {
          await o.page.locator(ROOT).screenshot({ path: file });
          console.log(`  스크린샷 ${path.basename(file)}`);
        }
        await o.browser.close();
      }
    }
  }
} catch (e) {
  problems.push(String(e?.stack || e));
} finally {
  server.close();
}

if (problems.length) {
  console.error(`실패 ${problems.length}건:\n- ${problems.join('\n- ')}`);
  process.exit(1);
}
console.log('M10 알람 상태 평가기: 키보드 조작 통과');
