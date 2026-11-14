// 키보드만으로 M08 "어느 레코드가 답하나" 위젯을 끝까지 조작하고 결과를 단언한다(GUIDE-SITE 5장, 위젯 전용 독립 스크립트).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 숫자·Backspace)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 위젯 상자를 라이트/다크 × 1280/360px로 찍고, 가로 넘침이 없는지 확인한다.
// 사용(site/ 에서, 빌드 뒤): node src/widgets/m08/route53-routing-answer/keyboard.check.mjs --port 4333 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { baseUrl, offlineBrowser, portFromArgs, serve, shootElement, widgetOverflow } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m08-dns-edge/02-routing-policies-and-health-checks/';
const ROOT = '.rr';
const port = portFromArgs(4333);
const base = baseUrl(port);
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
  const result = async () => (await page.textContent(`${ROOT} .rr-result`)).replace(/\s+/g, ' ');
  const expect = async (what, ...needles) => {
    const t = await result();
    for (const nd of needles) if (!t.includes(nd)) problems.push(`${what}: "${nd}" 없음 — ${t.slice(0, 200)}`);
  };
  const caseBtn = (k) => `${ROOT} button[data-case="${k}"]`;

  await page.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator(ROOT).evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m08/route53-routing-answer"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  // 워크시트 1~9번을 차례로 Enter → 원고의 답과 같은 결과
  const want = {
    1: ['seoul:'],
    2: ['virginia:'],
    3: ['asia: 203.0.113.3'],
    4: ['kr: 203.0.113.1'],
    5: ['빈 응답(NOERROR, 값 없음)'],
    6: ['secondary:'],
    7: ['primary: 192.0.2.100', 'If no record is healthy'],
    8: ['a: 192.0.2.31 · c: 192.0.2.33'],
    9: ['green 192.0.2.2 0%', '약 0번'],
  };
  for (const k of Object.keys(want)) {
    await tabUntil(caseBtn(k));
    await press('Enter');
    await expect(`워크시트 ${k}번`, ...want[k]);
  }
  // 9번에 이어 green 가중치를 숫자 키로 10, blue를 90으로 → green 10%
  await tabUntil(`${ROOT} li[data-rec="new/blue"] input[data-field=weight]`);
  for (let i = 0; i < 4; i++) await press('Backspace');
  await press('9');
  await press('0');
  await tabUntil(`${ROOT} li[data-rec="new/green"] input[data-field=weight]`);
  for (let i = 0; i < 4; i++) await press('Backspace');
  await press('1');
  await press('0');
  await expect('가중치 90:10', 'green 192.0.2.2 10%', '약 100번');
  // 이름을 shop으로(Enter), 위치를 화살표로 바꾸며 지리적 위치 확인: 한국 → kr
  await tabUntil(`${ROOT} button[data-name=shop]`, { back: true });
  await press('Enter');
  await tabUntil(`${ROOT} input[name=rr-loc]:checked`);
  // 지금 위치는 5번에서 고른 브라질(6~9번은 위치를 바꾸지 않는다). 위로 세 칸 → 한국
  if ((await page.$eval(`${ROOT} input[name=rr-loc]:checked`, (e) => e.value)) !== 'BR') problems.push('9번 뒤 위치가 브라질이 아님');
  for (let i = 0; i < 3; i++) await press('ArrowUp');
  await expect('shop 한국', 'kr: 203.0.113.1');
  // 아래로 세 칸 → 브라질(기본 레코드)
  await press('ArrowDown');
  await press('ArrowDown');
  await press('ArrowDown');
  await expect('shop 브라질', 'default: 203.0.113.9');
  // default 레코드를 Space로 지우면 빈 응답
  await tabUntil(`${ROOT} li[data-rec="shop/default"] input[data-field=present]`);
  await press('Space');
  await expect('shop 기본 지움', '빈 응답');
  // img로 바꾸고 HC-a를 Space로 끔 → b, c만
  await tabUntil(`${ROOT} button[data-name=img]`, { back: true });
  await press('Enter');
  await tabUntil(`${ROOT} li[data-rec="img/a"] input[data-field=healthy]`);
  await press('Space');
  await expect('img a 비정상', 'b: 192.0.2.32 · c: 192.0.2.33');
  const row = await page.textContent(`${ROOT} li[data-rec="img/a"] .rr-status`);
  if (!row.includes('상태 확인 실패')) problems.push(`img/a 상태 글이 기대와 다름: ${row}`);
  // 표 펼치기(Enter)
  await tabUntil(`${ROOT} .rr-table-box > summary`);
  await press('Enter');
  if (!(await page.$eval(`${ROOT} .rr-table-box`, (d) => d.open))) problems.push('표 상자가 Enter로 펼쳐지지 않음');
  console.log(`라우팅 위젯(키보드): ${(await result()).trim().slice(0, 80)}…`);

  if (shots) {
    fs.mkdirSync(shots, { recursive: true });
    for (const scheme of ['light', 'dark']) {
      for (const width of [1280, 360]) {
        const c = await offlineBrowser({ colorScheme: scheme, viewport: { width, height: 900 } });
        const p = await c.context.newPage();
        await p.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
        await p.locator(ROOT).scrollIntoViewIfNeeded();
        await p.waitForFunction(() => document.querySelector('.guide-widget astro-island:not([ssr])') !== null);
        await p.click(caseBtn('2'));
        const over = await p.evaluate((sel) => {
          const doc = document.documentElement;
          const w = document.querySelector(sel);
          return { page: doc.scrollWidth - doc.clientWidth, widget: w.scrollWidth - w.clientWidth };
        }, ROOT);
        if (over.page > 0 || over.widget > 0) problems.push(`${scheme} ${width}px: 가로 넘침 ${JSON.stringify(over)}`);
        await shootElement(p, ROOT, path.join(shots, `m08-route53-routing-answer-${scheme}-${width}.png`));
        await c.browser.close();
      }
    }
    console.log(`스크린샷: ${shots}`);
  }
  // 360px 가로 넘침(라이트·다크, 처음 상태와 미리 채우기마다) — --shots 없이도 늘 확인한다
  problems.push(...(await widgetOverflow({ port, path: PAGE, widget: 'm08/route53-routing-answer' })));
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
console.log('통과: M08 route53-routing-answer 키보드 조작');
