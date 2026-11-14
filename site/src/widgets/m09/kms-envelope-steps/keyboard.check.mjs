// 키보드만으로 M09 "봉투 암호화 한 단계씩" 위젯을 끝까지 조작하고 결과를 단언한다(GUIDE-SITE 5장, 위젯 전용 독립 스크립트).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 숫자·Backspace)이다. 상태를 "읽는" 것만 DOM에서 한다.
// --shots <폴더>를 주면 위젯 상자를 라이트/다크 × 1280/360px로 찍고, 가로 넘침이 없는지 확인한다.
// 사용(site/ 에서, 빌드 뒤): node src/widgets/m09/kms-envelope-steps/keyboard.check.mjs --port 4333 [--shots <폴더>]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m09-security-encryption/01-kms/';
const ROOT = '.ev';
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
  const text = async (sel) => (await page.textContent(`${ROOT} ${sel}`)).replace(/\s+/g, ' ');
  const expect = async (what, sel, ...needles) => {
    const t = await text(sel);
    for (const nd of needles) if (!t.includes(nd)) problems.push(`${what}: "${nd}" 없음 — ${t.slice(0, 200)}`);
  };
  const focusMovedTo = (sel) => page.waitForFunction(focusIs, sel, { timeout: 2000 }).then(() => true, () => false);

  await page.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator(ROOT).evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m09/kms-envelope-steps"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  // 1) lab03 예: 성공, 9단계
  await tabUntil(`${ROOT} button[data-preset=lab03]`);
  await press('Enter');
  await expect('lab03', '.ev-result', '복호화 성공', '9단계', '데이터 키(32바이트)만');
  // 2) 처음에는 1단계("처음"·"이전"은 비활성). "끝까지" → 초점이 "이전 단계"로
  await expect('1단계', '.ev-now', '단계 1/9');
  await tabUntil(`${ROOT} button[data-step=last]`);
  await press('Enter');
  if (!(await focusMovedTo(`${ROOT} button[data-step=prev]`))) problems.push('"끝까지" 뒤 초점이 "이전 단계"에 있지 않음');
  await expect('끝', '.ev-now', '단계 9/9');
  // 3) "처음" → 초점이 "다음 단계"로, 다음 → 다음(GenerateDataKey, 로컬 암호화)
  await tabUntil(`${ROOT} button[data-step=first]`, { back: true });
  await press('Enter');
  if (!(await focusMovedTo(`${ROOT} button[data-step=next]`))) problems.push('"처음" 뒤 초점이 "다음 단계"에 있지 않음');
  await press('Enter');
  await expect('2단계', '.ev-now', '단계 2/9', 'GenerateDataKey');
  const app2 = await page.$$eval(`${ROOT} .ev-box-app li`, (ls) => ls.map((l) => l.dataset.item));
  if (!app2.includes('pdk') || !app2.includes('edk')) problems.push(`2단계 주문 서비스 메모리에 데이터 키 두 개가 없음: ${app2}`);
  await press('Enter');
  await expect('3단계', '.ev-now', '단계 3/9', '64,921바이트');
  await tabUntil(`${ROOT} button[data-step=last]`);
  await press('Enter');
  // 4) 키 상태를 화살표로 비활성 → DisabledException, 마지막 단계는 Decrypt
  await tabUntil(`${ROOT} input[name=ev-key]`, { back: true });
  await press('ArrowDown');
  await expect('비활성', '.ev-result', 'DisabledException로 실패', '7단계');
  await expect('비활성 단계', '.ev-now', 'DisabledException');
  // 한 칸 더 → 삭제 대기
  await press('ArrowDown');
  await expect('삭제 대기', '.ev-result', 'KMSInvalidStateException');
  // 다시 활성으로(위로 두 칸)
  await press('ArrowUp');
  await press('ArrowUp');
  await expect('활성', '.ev-result', '복호화 성공');
  // 5) 다른 컨텍스트(Space) → InvalidCiphertextException, 끄고 변조(Space) → InvalidTag
  await tabUntil(`${ROOT} input[data-field=otherContext]`);
  await press('Space');
  await expect('다른 컨텍스트', '.ev-result', 'InvalidCiphertextException');
  await press('Space');
  await tabUntil(`${ROOT} input[data-field=tampered]`);
  await press('Space');
  await expect('변조', '.ev-result', 'InvalidTag로 실패', '8단계');
  await press('Space');
  // 6) 크기를 숫자 키로 4096 → 한도 이하 안내, 4097 → 봉투
  await tabUntil(`${ROOT} input[data-field=size]`, { back: true });
  for (let i = 0; i < 10; i++) await press('Backspace');
  for (const ch of '4096') await press(ch);
  await expect('4096', '#ev-size-hint', '이하라 KMS Encrypt로 바로');
  await press('Backspace');
  await press('7');
  await expect('4097', '#ev-size-hint', 'ValidationException로 거부');
  await expect('4097 결과', '.ev-result', '복호화 성공', '평문 4,097바이트');
  // 7) 표 펼치기
  await tabUntil(`${ROOT} .ev-table-box > summary`);
  await press('Enter');
  if (!(await page.$eval(`${ROOT} .ev-table-box`, (d) => d.open))) problems.push('표 상자가 Enter로 펼쳐지지 않음');
  const rows = await page.$$eval(`${ROOT} .ev-table tbody tr`, (t) => t.length);
  if (rows !== 9) problems.push(`표의 단계 수 ${rows} ≠ 9`);
  console.log(`봉투 암호화 위젯(키보드): ${(await text('.ev-result')).trim().slice(0, 80)}…`);

  if (shots) {
    fs.mkdirSync(shots, { recursive: true });
    for (const scheme of ['light', 'dark']) {
      for (const width of [1280, 360]) {
        const c = await offlineBrowser({ colorScheme: scheme, viewport: { width, height: 900 } });
        const p = await c.context.newPage();
        await p.goto(`${base}${PAGE}`, { waitUntil: 'networkidle' });
        await p.locator(ROOT).scrollIntoViewIfNeeded();
        await p.waitForFunction(() => document.querySelector('.guide-widget astro-island:not([ssr])') !== null);
        await p.click(`${ROOT} button[data-preset=disabled]`);
        await p.click(`${ROOT} button[data-step=last]`);
        const over = await p.evaluate((sel) => {
          const doc = document.documentElement;
          const w = document.querySelector(sel);
          return { page: doc.scrollWidth - doc.clientWidth, widget: w.scrollWidth - w.clientWidth };
        }, ROOT);
        if (over.page > 0 || over.widget > 0) problems.push(`${scheme} ${width}px: 가로 넘침 ${JSON.stringify(over)}`);
        await p.locator(ROOT).screenshot({ path: path.join(shots, `m09-kms-envelope-steps-${scheme}-${width}.png`) });
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
console.log('통과: M09 kms-envelope-steps 키보드 조작');
