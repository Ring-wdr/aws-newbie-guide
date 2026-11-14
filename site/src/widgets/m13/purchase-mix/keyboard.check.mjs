// M13 구매 옵션 섞기 계산기를 키보드만으로 끝까지 조작하는 독립 검사(공용 site/tests/keyboard.mjs와 별도).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Home/End, Space, Enter)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 라이트/다크 × 1280/360px 위젯 스크린샷을 찍고 360px 가로 넘침을 확인한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m13/purchase-mix/keyboard.check.mjs --port 4334 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m13-cost-optimization/02-compute-cost/';
const ROOT = '.pmx';
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
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m13/purchase-mix"] astro-island:not([ssr])') !== null);
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
  const total = async () => (await page.textContent(`${ROOT} .pmx-total`)).trim();
  const expect = async (what, want, extra) => {
    const t = await total();
    const res = (await page.textContent(`${ROOT} .pmx-result`)).trim();
    if (t !== `월 ${want} USD`) problems.push(`${what}: "${t}" ≠ 월 ${want} USD`);
    else if (extra && !res.includes(extra)) problems.push(`${what}: 결과에 "${extra}" 없음 — "${res}"`);
    else console.log(`  ✓ ${what}: ${res.slice(0, 80)}`);
  };

  // 가로 스크롤 금지: 문서 폭이 화면 폭을 넘으면 실패(시작 상태와 미리 채우기마다)
  const noHScroll = async (label) => {
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    if (sw > cw) problems.push(`1280px ${label}: 가로 스크롤(scrollWidth ${sw} > clientWidth ${cw})`);
  };
  await page.evaluate(() => document.activeElement?.blur());
  await noHScroll('시작 상태');
  await expect('처음(워크시트 안 2)', '443.40', '가장 싼 약정 대수');
  await tabUntil(`${ROOT} button[data-preset="1"]`);
  await press('Enter');
  await noHScroll(`미리 채우기 1`);
  await expect('워크시트 안 1', '642.00', '같다');
  await tabUntil(`${ROOT} button[data-preset="3"]`);
  await press('Enter');
  await noHScroll(`미리 채우기 3`);
  await expect('워크시트 안 3', '642.00', '쓰지 않았지만');
  // 약정 슬라이더: Home → 0대, 화살표 6번 → 6대
  await tabUntil(`${ROOT} input[data-field=commit]`);
  await press('Home');
  await expect('약정 0대 + 배치 스팟', '574.80');
  for (let i = 0; i < 6; i++) await press('ArrowRight');
  await expect('약정 6대 + 배치 스팟', '443.40', '가장 싼 약정 대수');
  // 배치를 온디맨드로(화살표), 다시 스팟으로
  await tabUntil(`${ROOT} input[name=pmx-batch]`);
  await press('ArrowUp');
  await expect('약정 6대 + 배치 온디맨드', '510.60');
  await press('ArrowDown');
  await expect('다시 배치 스팟', '443.40');
  // "중단되면 안 된다" 켜기(Space) → 스팟 제외, 온디맨드로 계산
  await tabUntil(`${ROOT} input[data-field=mustNotStop]`);
  await press('Space');
  await expect('중단 불가 배치', '510.60', '스팟 대신 온디맨드');
  await tabUntil(`${ROOT} .pmx-table-box > summary`);
  await press('Enter');
  const cur = await page.textContent(`${ROOT} .pmx-table tr[aria-current] td:nth-child(2)`);
  if (cur.trim() !== '510.60') problems.push(`표의 지금 행: "${cur}"`);
  if (blocked.length) problems.push(`외부 요청: ${blocked.join(', ')}`);
  console.log(`키 입력 ${keys}번`);
  await browser.close();

  if (shots) {
    fs.mkdirSync(shots, { recursive: true });
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
        await o.page.locator(`${ROOT} button[data-preset="3"]`).click();
        await o.page.locator(`${ROOT} .pmx-table-box > summary`).click();
        const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (over > 0) problems.push(`${colorScheme} ${width}px: 가로 넘침 ${over}px`);
        const wide = await o.page.$$eval(`${ROOT} *`, (els, w) => els.filter((e) => e.getBoundingClientRect().right > w + 0.5 && !e.closest('.pmx-table-scroll')).map((e) => e.className || e.tagName).slice(0, 5), width);
        if (wide.length) problems.push(`${colorScheme} ${width}px: 화면 밖으로 나간 요소 ${wide.join(', ')}`);
        const file = path.join(shots, `m13-mix-${colorScheme}-${width}.png`);
        await o.page.locator(ROOT).screenshot({ path: file });
        console.log(`  스크린샷 ${path.basename(file)}`);
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
console.log('M13 구매 옵션 섞기: 키보드 조작 통과');
