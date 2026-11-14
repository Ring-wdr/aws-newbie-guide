// M11 Athena 스캔량 어림을 키보드만으로 끝까지 조작하는 독립 검사(공용 site/tests/keyboard.mjs와 별도).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 글자)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 라이트/다크 × 1280/360px 위젯 스크린샷을 찍고 360px 가로 넘침을 확인한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m11/athena-scan-estimator/keyboard.check.mjs --port 4334 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m11-analytics/04-query-services/';
const ROOT = '.asc';
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
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m11/athena-scan-estimator"] astro-island:not([ssr])') !== null);
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
  const expect = async (what, bytes, extra) => {
    const b = (await page.textContent(`${ROOT} .asc-bytes`)).trim();
    const res = (await page.textContent(`${ROOT} .asc-result`)).trim();
    if (b !== `스캔 ${bytes}`) problems.push(`${what}: "${b}" ≠ "스캔 ${bytes}"`);
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
  await expect("처음(lab05 WHERE dt)", '665바이트', '실행된다');
  await tabUntil(`${ROOT} button[data-preset="lab05-all"]`);
  await press('Enter');
  await noHScroll(`미리 채우기 lab05-all`);
  await expect('lab05 필터 없음 = ScannedBytes 1595', '1.56 KB', '100%');
  await tabUntil(`${ROOT} button[data-preset="self-check"]`);
  await press('Enter');
  await noHScroll(`미리 채우기 self-check`);
  await expect('스스로 확인 1 출발점', '10.0 TB', '차단');
  // ① 파티션 필터 켜기(Space) → 최근 7일
  await tabUntil(`${ROOT} input[data-field=filter]`);
  await press('Space');
  await expect('+ 최근 7일 파티션', '196 GB', '1.9%');
  // ② Parquet(화살표)
  await tabUntil(`${ROOT} input[name=asc-format]`);
  await press('ArrowDown');
  await expect('+ Parquet, 2/7열', '56.1 GB');
  // 쓰는 열을 글자로 1로
  await tabUntil(`${ROOT} input[data-field=read]`);
  await press('Backspace');
  await press('1');
  await expect('+ 1열만', '28.1 GB');
  // ③ 압축 4배(라디오에서 화살표 두 번)
  await tabUntil(`${ROOT} input[name=asc-compression]`);
  await press('ArrowDown');
  await press('ArrowDown');
  await expect('+ 압축 4배', '7.01 GB', '차단');
  // ④ 상한 끄기(Space) → 차단 없음
  await tabUntil(`${ROOT} input[data-field=cutoff]`);
  await press('Space');
  await expect('상한 끔', '7.01 GB', '상한이 없어');
  const steps = await page.$$eval(`${ROOT} .asc-steps li`, (ls) => ls.length);
  if (steps !== 4) problems.push(`단계 목록 ${steps}개`);
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
        await o.page.locator(`${ROOT} button[data-preset="self-check"]`).click();
        await o.page.locator(`${ROOT} input[data-field=filter]`).check();
        await o.page.locator(`${ROOT} input[name=asc-format][value=parquet]`).check();
        const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (over > 0) problems.push(`${colorScheme} ${width}px: 가로 넘침 ${over}px`);
        const wide = await o.page.$$eval(`${ROOT} *`, (els, w) => els.filter((e) => e.getBoundingClientRect().right > w + 0.5).map((e) => e.className || e.tagName).slice(0, 5), width);
        if (wide.length) problems.push(`${colorScheme} ${width}px: 화면 밖으로 나간 요소 ${wide.join(', ')}`);
        const file = shots && path.join(shots, `m11-athena-${colorScheme}-${width}.png`);
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
console.log('M11 Athena 스캔량 어림: 키보드 조작 통과');
