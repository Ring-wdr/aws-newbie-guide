// 키보드만으로 M00 요청 여정 위젯을 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs와 같은 방식:
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Enter), DOM은 상태를 "읽기"만 한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m00/request-journey/keyboard.check.mjs --port <포트>
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m00-orientation/04-first-request-anatomy/';
const port = portFromArgs(4321);
const problems = [];
const server = await serve(port);
const { browser, context, blocked } = await offlineBrowser({ viewport: { width: 1280, height: 900 } });
const page = await context.newPage();
let keys = 0;
const press = async (k) => {
  keys++;
  await page.keyboard.press(k);
};
async function tabUntil(sel, { back = false, max = 200 } = {}) {
  for (let i = 0; i < max; i++) {
    if (await page.evaluate((s) => document.activeElement?.matches?.(s) ?? false, sel)) return;
    await press(back ? 'Shift+Tab' : 'Tab');
  }
  throw new Error(`초점을 옮기지 못했다: ${sel}`);
}
const expect = async (what, re, stage) => {
  const t = (await page.textContent('.rj-result')).replace(/\s+/g, ' ');
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t.slice(0, 140)}"`);
  if (stage) {
    const at = await page.getAttribute('.rj-stage[aria-current=step]', 'data-stage').catch(() => null);
    if (at !== stage) problems.push(`${what}: 멈춘 단계 ${at}, 기대 ${stage}`);
  }
};

try {
  await page.goto(`http://127.0.0.1:${port}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator('.rj').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m00/request-journey"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  await expect('처음', /종료 코드 0/);
  // 잘못된 것: 화살표로 차례로(syntax → connect → tamper → skew → denied)
  await tabUntil('.rj input[name=rj-fault]');
  const want = [
    [/종료 코드 252/, 'parse'],
    [/종료 코드 255/, 'send'],
    [/종료 코드 254.*SignatureDoesNotMatch/, 'verify'],
    [/종료 코드 254.*RequestTimeTooSkewed/, 'verify'],
    [/종료 코드 254/, 'service'],
  ];
  for (const [re, stage] of want) {
    await press('ArrowDown');
    await expect(`잘못된 것 ${stage}`, re, stage);
  }
  await press('ArrowDown'); // 처음(잘못된 것 없음)으로 돈다
  await expect('잘못된 것 없음', /종료 코드 0/);
  // 키 위치: 어디에도 없음(ArrowUp: file → none, 처음에서 위로 돌면 마지막)
  await tabUntil('.rj input[name=rj-creds]', { back: true });
  await press('ArrowUp');
  await expect('키 없음', /종료 코드 253/, 'creds');
  // 둘 다(ArrowUp) → 환경 변수가 우선
  await press('ArrowUp');
  await expect('둘 다', /종료 코드 0/);
  const creds = await page.textContent('.rj-stage[data-stage=creds] .rj-desc');
  if (!creds.includes('환경 변수가 파일보다 우선')) problems.push(`둘 다: 자격 증명 단계 설명 "${creds}"`);
  // 표 펼치기
  await tabUntil('.rj-table-box > summary');
  await press('Enter');
  const row = await page.$eval('.rj-table-box', (d) => (d.open ? d.querySelector('tr[aria-current=true]')?.textContent : null));
  if (!row?.startsWith('0')) problems.push(`표: 현재 행 "${row}"`);
  if (blocked.length) problems.push(`외부 요청: ${blocked.join(', ')}`);
} catch (e) {
  problems.push(`중단: ${e.message}`);
} finally {
  await browser.close();
  server.close();
}

console.log(`누른 키 ${keys}번`);
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log(`FAIL keyboard(m00/request-journey): ${problems.length}건`);
  process.exit(1);
}
console.log('PASS keyboard(m00/request-journey): 잘못된 것 다섯 가지(252·255·254×3) → 없음 → 키 없음(253) → 둘 다(환경 변수 우선) → 표');
