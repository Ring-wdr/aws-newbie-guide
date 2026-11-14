// 키보드만으로 M04 수명 주기 규칙 점검기를 끝까지 조작한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs 와 별개인 위젯 전용 검사.
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 글자)이다. 상태를 "읽는" 것만 DOM에서 한다.
// 사용(site/ 에서, 빌드 뒤): node src/widgets/m04/s3-lifecycle-planner/keyboard.check.mjs --port <포트>
import { baseUrl, offlineBrowser, portFromArgs, serve, widgetOverflow } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m04-storage/02-storage-classes-and-lifecycle/';
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
const focusIs = (sel) => document.activeElement?.matches?.(sel) ?? false;
async function tabUntil(sel, { back = false, max = 200 } = {}) {
  for (let i = 0; i < max; i++) {
    if (await page.evaluate(focusIs, sel)) return;
    await press(back ? 'Shift+Tab' : 'Tab');
  }
  throw new Error(`초점을 옮기지 못했다: ${sel}`);
}
const result = () => page.textContent('.lc-result');
const expect = async (what, re) => {
  const t = (await result()).replace(/\s+/g, ' ').trim();
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t}"`);
  else console.log(`ok  ${what}: ${t.slice(0, 70)}…`);
};

try {
  await page.goto(`${baseUrl(port)}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator('.lc').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m04/s3-lifecycle-planner"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());
  await expect('처음(lab02 영수증 규칙)', /^✓ 저장됨 .*2555일\(약 7년\)에 삭제/);

  // 1) 거부 예: Glacier IR 4일 → Deep Archive 20일
  await tabUntil('.lc button[data-preset=too-soon]');
  await press('Enter');
  await expect('너무 이른 연쇄 전환', /^✗ 거부됨 .*94일 이후여야/);

  // 2) Deep Archive 일수를 94로 고치면 저장(경계)
  await tabUntil('.lc input[data-field=days-1]');
  for (let i = 0; i < 6; i++) await press('Backspace');
  await page.keyboard.type('94');
  keys += 2;
  await expect('94일로 고침', /^✓ 저장됨 /);

  // 3) 스스로 확인 1번: 7일 IA, 20일 삭제 → 주의(17일치)
  await tabUntil('.lc button[data-preset=self-check]', { back: true });
  await press('Enter');
  await expect('스스로 확인 1번', /^△ 저장됨 — 주의 .*13일만 두고.*17일치 조기 삭제/);

  // 3b) 만료를 전환(7일)보다 빠른 5일로 → 거부, 다시 20일로 → 주의
  await tabUntil('.lc input[data-field=exp-days]');
  for (let i = 0; i < 6; i++) await press('Backspace');
  await page.keyboard.type('5');
  keys += 1;
  await expect('만료 5일(전환 7일보다 빠름)', /^✗ 거부됨 .*만료\(5일\)가 Standard-IA 전환\(7일\)보다 빠르거나 같아 거부된다.*8일 이후/);
  for (let i = 0; i < 6; i++) await press('Backspace');
  await page.keyboard.type('20');
  keys += 2;
  await expect('만료 20일로 되돌림', /^△ 저장됨 — 주의 .*17일치/);

  // 4) 전환 1의 클래스를 글자 입력으로 Deep Archive로 → 13일만 두고 167일치
  await tabUntil('.lc select[data-field=cls-0]', { back: true });
  await page.keyboard.type('Glacier D');
  keys += 9;
  await expect('Deep Archive로 바꿈', /Glacier Deep Archive에 13일만 두고.*167일치/);

  // 5) 만료 끄기(Space) → 계속 보관
  await tabUntil('.lc input[data-field=exp-on]');
  await press('Space');
  await expect('만료 끔', /^✓ 저장됨 객체는 Standard → Glacier Deep Archive 순서로 옮겨 가고 계속 보관/);

  // 6) 객체 크기 128 KB 미만(화살표) → Standard에 머문다
  await tabUntil('.lc input[name=lc-size]');
  await press('ArrowDown');
  await expect('128 KB 미만', /Standard에 머물고 계속 보관.*128 KB 미만 객체는/);

  // 7) 표·폭포 펼치기(Enter), 표는 키보드로 스크롤 상자에 초점이 간다
  await tabUntil('.lc .lc-water > summary');
  await press('Enter');
  if (!(await page.$eval('.lc .lc-water', (d) => d.open))) problems.push('폭포 설명이 Enter로 펼쳐지지 않음');
  const water = await page.textContent('.lc .lc-water ul');
  if (!water.includes('Glacier Instant Retrieval → Glacier Flexible Retrieval, Glacier Deep Archive')) problems.push(`폭포 목록이 기대와 다름: ${water.slice(0, 120)}`);
  await tabUntil('.lc .lc-table-scroll', { back: true });
  const rows = await page.$$eval('.lc .lc-table tbody tr', (r) => r.length);
  if (rows !== 1) problems.push(`128 KB 미만이면 표가 Standard 한 줄이어야 한다: ${rows}줄`);
  if (blocked.length) problems.push(`루프백 밖 요청: ${blocked.join(', ')}`);
  // 360px 가로 넘침(라이트·다크, 처음 상태와 미리 채우기마다) — --shots 없이도 늘 확인한다
  problems.push(...(await widgetOverflow({ port, path: PAGE, widget: 'm04/s3-lifecycle-planner' })));
} catch (e) {
  problems.push(String(e?.stack || e));
} finally {
  await browser.close();
  server.close();
}

console.log(`키 입력 ${keys}번`);
if (problems.length) {
  console.error(`키보드 검사 실패 ${problems.length}건:\n- ${problems.join('\n- ')}`);
  process.exit(1);
}
console.log('키보드 검사 통과: M04 수명 주기 규칙 점검기');
