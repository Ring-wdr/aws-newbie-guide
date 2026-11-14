// 키보드만으로 M07 "동시성 칸 나누기" 위젯을 끝까지 조작하고 결과를 단언한다(GUIDE-SITE 5장, 위젯 전용 독립 스크립트).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 숫자·Backspace)이다. 상태를 "읽는" 것만 DOM에서 한다.
// 덧붙여 --shots <폴더>를 주면 위젯 상자를 라이트/다크 × 1280/360px로 찍고, 360px에서 가로 넘침이 없는지 확인한다.
// 사용(site/ 에서, 빌드 뒤): node src/widgets/m07/lambda-concurrency/keyboard.check.mjs --port 4333 [--shots <폴더>]
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m07-serverless-containers/01-lambda-execution-model/';
const ROOT = '.lc';
const port = portFromArgs(4333);
const base = `http://127.0.0.1:${port}`; // sitecheck-allow: 검사 스크립트가 여는 루프백 서버 주소(빌드 산출물에 들어가지 않는다)
const shotsIdx = process.argv.indexOf('--shots');
const shots = shotsIdx >= 0 ? path.resolve(process.argv[shotsIdx + 1]) : null;
const problems = [];
const server = await serve(port);
let browser;
try {
  const b = await offlineBrowser({ viewport: { width: 1280, height: 900 } });
  browser = b.browser;
  const page = await b.context.newPage();
  const focusIs = (sel) => document.activeElement?.matches?.(sel) ?? false;
  const press = (k) => page.keyboard.press(k);
  async function tabUntil(sel, { back = false, max = 400 } = {}) {
    for (let i = 0; i < max; i++) {
      if (await page.evaluate(focusIs, sel)) return;
      await press(back ? 'Shift+Tab' : 'Tab');
    }
    throw new Error(`초점을 옮기지 못했다: ${sel}`);
  }
  async function typeNumber(sel, value, back = false) {
    await tabUntil(sel, { back });
    for (let i = 0; i < 8; i++) await press('Backspace');
    for (const ch of String(value)) await press(ch);
  }
  const result = () => page.textContent(`${ROOT} .lc-result`);
  const expect = async (what, ...needles) => {
    const t = (await result()).replace(/\s+/g, ' ');
    for (const nd of needles) if (!t.includes(nd)) problems.push(`${what}: "${nd}" 없음 — ${t.slice(0, 160)}`);
    return t;
  };

  await page.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator(ROOT).evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m07/lambda-concurrency"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  // 1) 스스로 확인 3번(기본으로 골라져 있지만 다시 Enter): 100 실행, 400 스로틀 429
  await tabUntil(`${ROOT} button[data-preset=self-check]`);
  await press('Enter');
  await expect('스스로 확인 3번', '함수 A 일부 스로틀', '400건', '429 TooManyRequestsException');
  // 2) 퀴즈 3번: 쿠폰 폭주 → 양쪽 스로틀
  await tabUntil(`${ROOT} button[data-preset=coupon]`);
  await press('Enter');
  await expect('쿠폰 폭주', '양쪽 모두 스로틀', '나머지 함수들의 요청 50건 중 50건이 스로틀');
  // 3) 예약 동시성을 켜고(Space) 800을 입력 → 나머지 함수 보호
  await tabUntil(`${ROOT} input[data-field=reservedOn]`);
  await press('Space');
  await typeNumber(`${ROOT} input[data-field=reserved]`, 800);
  await expect('예약 800', '함수 A 일부 스로틀', '나머지 함수들의 요청 50건은 남은 몫 200 안이라 모두 실행');
  // 4) 호출 방식을 비동기로(화살표) → 재시도
  await tabUntil(`${ROOT} input[name=lc-invoke]`);
  await press('ArrowDown');
  await expect('비동기', '비동기 호출이라 Lambda가 재시도');
  // 5) 예약 동시성 0 → 함수 정지
  await typeNumber(`${ROOT} input[data-field=reserved]`, 0, true);
  await expect('예약 0', '함수 A 정지');
  // 6) 프로비저닝 예 → 웜 50, 콜드 30
  await tabUntil(`${ROOT} button[data-preset=provisioned]`, { back: true });
  await press('Enter');
  await expect('프로비저닝', '모두 실행', '50건은 프로비저닝된(미리 데운) 환경', '30건은 새 환경');
  const row = (await page.textContent(`${ROOT} tr[data-row=a]`)).replace(/\s+/g, ' ');
  if (!row.includes('80 (50 / 30)')) problems.push(`표의 함수 A 행이 기대와 다름: ${row}`);
  // 7) 표·가정 접기/펼치기도 키보드로
  await tabUntil(`${ROOT} .lc-assume > summary`);
  await press('Enter');
  if (!(await page.$eval(`${ROOT} .lc-assume`, (d) => d.open))) problems.push('가정 상자가 Enter로 펼쳐지지 않음');
  console.log(`동시성 위젯(키보드): ${(await result()).replace(/\s+/g, ' ').trim().slice(0, 80)}…`);

  if (shots) {
    const fs = await import('node:fs');
    fs.mkdirSync(shots, { recursive: true });
    for (const scheme of ['light', 'dark']) {
      for (const width of [1280, 360]) {
        const c = await offlineBrowser({ colorScheme: scheme, viewport: { width, height: 900 } });
        const p = await c.context.newPage();
        await p.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
        await p.locator(ROOT).scrollIntoViewIfNeeded();
        await p.waitForFunction(() => document.querySelector('.guide-widget astro-island:not([ssr])') !== null);
        await p.click(`${ROOT} button[data-preset=coupon-fixed]`);
        const over = await p.evaluate((sel) => {
          const doc = document.documentElement;
          const w = document.querySelector(sel);
          return { page: doc.scrollWidth - doc.clientWidth, widget: w.scrollWidth - w.clientWidth };
        }, ROOT);
        if (over.page > 0 || over.widget > 0) problems.push(`${scheme} ${width}px: 가로 넘침 ${JSON.stringify(over)}`);
        await p.locator(ROOT).screenshot({ path: path.join(shots, `m07-lambda-concurrency-${scheme}-${width}.png`) });
        await c.browser.close();
      }
    }
    console.log(`스크린샷: ${shots}`);
  }
} catch (e) {
  problems.push(String(e?.stack || e));
} finally {
  await browser?.close();
  server.close();
}
if (problems.length) {
  console.error(`실패 ${problems.length}건:\n- ${problems.join('\n- ')}`);
  process.exit(1);
}
console.log('통과: M07 lambda-concurrency 키보드 조작');
