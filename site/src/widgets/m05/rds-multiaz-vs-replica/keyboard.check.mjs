// 키보드만으로 M05 Multi-AZ vs 읽기 복제본 실험대를 끝까지 조작한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs 와 별개인 위젯 전용 검사.
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 글자)이다. 상태를 "읽는" 것만 DOM에서 한다.
// 사용(site/ 에서, 빌드 뒤): node src/widgets/m05/rds-multiaz-vs-replica/keyboard.check.mjs --port <포트>
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m05-databases/02-multi-az-vs-read-replica/';
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
const type = async (s) => {
  keys += s.length;
  await page.keyboard.type(s);
};
const focusIs = (sel) => document.activeElement?.matches?.(sel) ?? false;
async function tabUntil(sel, { back = false, max = 200 } = {}) {
  for (let i = 0; i < max; i++) {
    if (await page.evaluate(focusIs, sel)) return;
    await press(back ? 'Shift+Tab' : 'Tab');
  }
  throw new Error(`초점을 옮기지 못했다: ${sel}`);
}
const norm = (t) => t.replace(/\s+/g, ' ').trim();
const expect = async (what, re, sel = '.rr-result') => {
  const t = norm(await page.textContent(sel));
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t}"`);
  else console.log(`ok  ${what}: ${t.slice(0, 70)}…`);
};
const clearAndType = async (s) => {
  for (let i = 0; i < 4; i++) await press('Backspace');
  await type(s);
};

try {
  await page.goto(`http://127.0.0.1:${port}${PAGE}`, { waitUntil: 'networkidle' }); // sitecheck-allow: 검사용 로컬 서버(루프백)
  await page.locator('.rr').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m05/rds-multiaz-vs-replica"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());
  await expect('처음(단일 인스턴스, AZ 장애)', /^✗ 문제 .*주문 API가 멈춘다/);

  // 1) Multi-AZ 켜기(Space) → 자동 장애 조치
  await tabUntil('.rr input[data-field=multiAz]');
  await press('Space');
  await expect('Multi-AZ + AZ 장애', /^✓ 괜찮음 .*1~2분/);
  await expect('Multi-AZ 단계', /대기를 기본으로 승격.*같은 DNS 이름.*잃지 않는다/, '.rr-steps');

  // 2) 정산 쿼리(Enter) → Multi-AZ 대기는 트래픽을 받지 않는다
  await tabUntil('.rr button[data-event=report]');
  await press('Enter');
  await expect('Multi-AZ만 + 정산 쿼리', /^✗ 문제 /);
  await expect('스스로 확인 1번 근거', /대기 인스턴스는 트래픽을 받지 않는다/, '.rr-steps');

  // 3) 복제본 2개, 그러나 배치는 원본 → 여전히 문제
  await tabUntil('.rr input[data-field=replicas]', { back: true });
  await clearAndType('2');
  await expect('복제본 2 + 배치 원본', /^✗ 문제 /);
  await expect('배치 연결', /여전히 원본 엔드포인트/, '.rr-steps');

  // 4) 배치를 복제본 엔드포인트로(화살표) → 해결
  await tabUntil('.rr input[name=rr-batch]');
  await press('ArrowDown');
  await expect('배치 → 복제본', /^✓ 괜찮음 .*느려지지 않는다/);

  // 5) 자동 백업 0일 → 복제본을 만들 수 없다, 1일(경계) → 다시 괜찮음
  await tabUntil('.rr input[data-field=retention]', { back: true });
  await clearAndType('0');
  await expect('보존 0일', /^✗ 문제 .*만들 수 없다\(InvalidDBInstanceState\)/);
  await clearAndType('1');
  await expect('보존 1일', /^✓ 괜찮음 /);

  // 6) 복제본을 같은 AZ로(화살표), Multi-AZ 끄고 AZ 장애 → 복제본도 함께 멈춤
  await tabUntil('.rr input[name=rr-loc]');
  await press('ArrowUp');
  await tabUntil('.rr input[data-field=multiAz]', { back: true });
  await press('Space');
  await tabUntil('.rr button[data-event=az-failure]');
  await press('Enter');
  await expect('같은 AZ 복제본 + AZ 장애', /^✗ 문제 /);
  await expect('같은 AZ 복제본도 멈춤', /같은 AZ\(us-east-1a\)라 함께 멈춘다/, '.rr-steps');

  // 7) 다른 리전으로 옮기면 수동 승격(조건부)
  await tabUntil('.rr input[name=rr-loc]', { back: true });
  await press('ArrowDown');
  await press('ArrowDown');
  await expect('다른 리전 복제본 + AZ 장애', /^△ 조건부 .*새 엔드포인트.*참고: 교차 리전 복제본은 데이터 전송 요금/);

  // 8) 방금 쓴 주문 다시 읽기 → 조건부(비동기 지연), 쓰기 한계 → 문제
  await tabUntil('.rr button[data-event=read-after-write]');
  await press('Enter');
  await expect('읽기 직후', /^△ 조건부 .*비동기 복제의 지연/);
  await tabUntil('.rr button[data-event=write-bottleneck]');
  await press('Enter');
  await expect('쓰기 한계', /^✗ 문제 .*복제로는 쓰기가 늘지 않는다/);

  // 9) 엔진 Oracle(글자 입력) → 복제본 상한 5
  await tabUntil('.rr select[data-field=engine]', { back: true });
  await type('Oracle');
  await tabUntil('.rr input[data-field=replicas]');
  await clearAndType('9');
  await expect('Oracle 상한', /0~5\(Oracle.*지금 5개/, '#rr-rep-hint');
  await tabUntil('.rr details.rr-assume > summary');
  await press('Enter');
  if (!(await page.$eval('.rr details.rr-assume', (d) => d.open))) problems.push('가정 설명이 Enter로 펼쳐지지 않음');
  if (blocked.length) problems.push(`루프백 밖 요청: ${blocked.join(', ')}`);
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
console.log('키보드 검사 통과: M05 Multi-AZ vs 읽기 복제본 실험대');
