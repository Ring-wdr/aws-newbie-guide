// M12 DR 전략 고르기를 키보드만으로 끝까지 조작하는 독립 검사(공용 site/tests/keyboard.mjs와 별도).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Enter)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 라이트/다크 × 1280/360px 위젯 스크린샷을 찍고 360px 가로 넘침을 확인한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m12/dr-strategy-picker/keyboard.check.mjs --port 4334 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { baseUrl, offlineBrowser, portFromArgs, serve, shootElement } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m12-resilience-dr-migration/02-rto-rpo-dr-strategies/';
const ROOT = '.drp';
const port = portFromArgs(4334);
const base = baseUrl(port);
const shotsIdx = process.argv.indexOf('--shots');
const shots = shotsIdx >= 0 ? path.resolve(process.argv[shotsIdx + 1]) : null;
const problems = [];
const server = await serve(port);

async function open(opts) {
  const b = await offlineBrowser(opts);
  const page = await b.context.newPage();
  await page.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator(ROOT).evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m12/dr-strategy-picker"] astro-island:not([ssr])') !== null);
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
  const pickName = async () => (await page.textContent(`${ROOT} .drp-tag`)).replace('★', '').trim();
  const expect = async (what, want, split) => {
    const got = await pickName();
    const hasSplit = (await page.$(`${ROOT} .drp-split`)) !== null;
    if (got !== want) problems.push(`${what}: 고른 전략 "${got}" ≠ "${want}"`);
    else if (split !== undefined && hasSplit !== split) problems.push(`${what}: 두 축 나눠 보기 표시 ${hasSplit} ≠ ${split}`);
    else console.log(`  ✓ ${what}: ${got}${hasSplit ? ' (두 축 나눠 보기)' : ''}`);
  };

  // 가로 스크롤 금지: 문서 폭이 화면 폭을 넘으면 실패(시작 상태와 미리 채우기마다)
  const noHScroll = async (label) => {
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    if (sw > cw) problems.push(`1280px ${label}: 가로 스크롤(scrollWidth ${sw} > clientWidth ${cw})`);
  };
  await page.evaluate(() => document.activeElement?.blur());
  await noHScroll('시작 상태');
  await expect('처음(워크시트 b)', '파일럿 라이트', false);
  for (const [id, want] of [['a', '백업·복원'], ['c', '웜 스탠바이'], ['d', '다중 사이트 액티브-액티브']]) {
    await tabUntil(`${ROOT} button[data-preset="${id}"]`);
    await press('Enter');
    await noHScroll(`미리 채우기 ${id}`);
    await expect(`워크시트 ${id}`, want, false);
  }
  await tabUntil(`${ROOT} button[data-preset="selfCheck"]`);
  await press('Enter');
  await noHScroll(`미리 채우기 selfCheck`);
  await expect('스스로 확인 1', '파일럿 라이트', true);
  // RPO 라디오(지금 "초~분") → ArrowUp = "시간"(목록이 넉넉한 단계부터) → 백업·복원
  await tabUntil(`${ROOT} input[name=drp-rpo]`);
  await press('ArrowUp');
  await expect('RPO 시간 + RTO 시간', '백업·복원', false);
  // RTO 라디오(지금 "시간") → ArrowDown 3번 = "거의 0" → 다중 사이트, 데이터는 백업·복원 수준이면 됨
  await tabUntil(`${ROOT} input[name=drp-rto]`);
  for (let i = 0; i < 3; i++) await press('ArrowDown');
  await expect('RPO 시간 + RTO 거의 0', '다중 사이트 액티브-액티브', false);
  await press('ArrowUp');
  await expect('RPO 시간 + RTO 분', '웜 스탠바이', false);
  const verdicts = await page.$$eval(`${ROOT} .drp-card`, (cs) => cs.map((c) => c.dataset.verdict).join(','));
  if (verdicts !== 'no,no,pick,over') problems.push(`카드 판정 "${verdicts}" ≠ "no,no,pick,over"`);
  // 표 펼침 상자를 키보드로 연다
  await tabUntil(`${ROOT} .drp-table-box > summary`);
  await press('Enter');
  if (!(await page.$eval(`${ROOT} .drp-table-box`, (d) => d.open))) problems.push('표 상자가 Enter로 열리지 않음');
  const row = await page.textContent(`${ROOT} .drp-table tbody tr:nth-child(3) td:last-child`);
  if (!row.includes('고름')) problems.push(`표의 웜 스탠바이 판정: "${row}"`);
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
        await o.page.locator(`${ROOT} button[data-preset=selfCheck]`).click();
        await o.page.locator(`${ROOT} .drp-table-box > summary`).click();
        const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (over > 0) problems.push(`${colorScheme} ${width}px: 가로 넘침 ${over}px`);
        const wide = await o.page.$$eval(`${ROOT} *`, (els, w) => els.filter((e) => e.getBoundingClientRect().right > w + 0.5 && !e.closest('.drp-table-scroll')).map((e) => e.className || e.tagName).slice(0, 5), width);
        if (wide.length) problems.push(`${colorScheme} ${width}px: 화면 밖으로 나간 요소 ${wide.join(', ')}`);
        const file = shots && path.join(shots, `m12-dr-${colorScheme}-${width}.png`);
        if (shots) {
          await shootElement(o.page, ROOT, file);
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
console.log('M12 DR 전략 고르기: 키보드 조작 통과');
