// 키보드만으로 M02 NACL·SG 왕복 위젯을 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs와 같은 방식:
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 숫자·Backspace), DOM은 상태를 "읽기"만 한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m02/nacl-sg-round-trip/keyboard.check.mjs --port <포트>
import { baseUrl, offlineBrowser, portFromArgs, serve, widgetOverflow } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m02-vpc-networking/04-security-group-vs-nacl/';
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
async function typeNumber(text) {
  for (let i = 0; i < 8; i++) await press('Backspace');
  for (const ch of text) await press(ch);
}
const expect = async (what, re) => {
  const t = (await page.textContent('.nf-result')).replace(/\s+/g, ' ');
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t.slice(0, 140)}"`);
};
const decidedRows = () => page.$$eval('.nf-table tr[data-decided=true]', (rs) => rs.map((r) => r.cells[0].textContent + ' ' + r.cells[1].textContent));

try {
  await page.goto(`${baseUrl(port)}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator('.nf').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m02/nacl-sg-round-trip"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  await expect('처음(앱 a → DB:5432)', /연결됨/);
  // ALB → DB 직접: NACL 32767
  await tabUntil('.nf button[data-preset=alb-db]');
  await press('Enter');
  await expect('ALB → DB', /요청 거부\(NACL\)/);
  if (!(await decidedRows()).includes('인바운드 32767(*)')) problems.push(`ALB → DB 판정 규칙: ${await decidedRows()}`);
  // 출발지를 화살표로 앱 a까지(alb → app-a: ArrowDown이 처음으로 돈다)
  await tabUntil('.nf input[name=nf-source]');
  await press('ArrowDown');
  await expect('앱 a로 바꿈', /연결됨/);
  // 앱 b(ArrowDown) → 110번 규칙
  await press('ArrowDown');
  await expect('앱 b', /연결됨/);
  if (!(await decidedRows()).includes('인바운드 110')) problems.push(`앱 b 판정 규칙: ${await decidedRows()}`);
  // 목적지 포트 22 → NACL 거부
  await tabUntil('.nf input[data-field=port]');
  await typeNumber('22');
  await expect('포트 22', /요청 거부\(NACL\)/);
  await typeNumber('5432');
  // 임시 포트 경계 1024 → 여전히 연결
  await tabUntil('.nf input[data-field=ephemeral]');
  await typeNumber('1024');
  await expect('임시 포트 1024', /연결됨/);
  // 아웃바운드 임시 포트 규칙 빠뜨리기(Space) → 타임아웃
  await tabUntil('.nf input[data-field=dropEgress]');
  await press('Space');
  await expect('아웃바운드 규칙 빠뜨림', /응답 막힘 → 타임아웃/);
  // 규칙 표 스크롤 영역에 초점이 가고 →로 스크롤할 수 있다
  await tabUntil('.nf-table-scroll');
  await press('ArrowRight');
  // 예 "앱 a → DB:22"로(Shift+Tab으로 되돌아가 Enter)
  await tabUntil('.nf button[data-preset=app-ssh]', { back: true });
  await press('Enter');
  await expect('앱 a → DB:22', /요청 거부\(NACL\)/);
  if (blocked.length) problems.push(`외부 요청: ${blocked.join(', ')}`);
  // 360px 가로 넘침(라이트·다크, 처음 상태와 미리 채우기마다) — --shots 없이도 늘 확인한다
  problems.push(...(await widgetOverflow({ port, path: PAGE, widget: 'm02/nacl-sg-round-trip' })));
} catch (e) {
  problems.push(`중단: ${e.message}`);
} finally {
  await browser.close();
  server.close();
}

console.log(`누른 키 ${keys}번`);
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log(`FAIL keyboard(m02/nacl-sg-round-trip): ${problems.length}건`);
  process.exit(1);
}
console.log('PASS keyboard(m02/nacl-sg-round-trip): ALB → DB(32767) → 앱 a → 앱 b(110) → 포트 22 → 임시 포트 1024 → 아웃바운드 규칙 빠뜨림(타임아웃) → 표 스크롤 → 예 "DB:22"');
