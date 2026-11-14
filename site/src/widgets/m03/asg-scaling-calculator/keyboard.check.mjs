// 키보드만으로 M03 조정 정책 계산기를 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs와 같은 방식:
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter, 숫자·Backspace), DOM은 상태를 "읽기"만 한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m03/asg-scaling-calculator/keyboard.check.mjs --port <포트>
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m03-compute-scaling/06-auto-scaling/';
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
  const t = (await page.textContent('.as-result')).replace(/\s+/g, ' ');
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t.slice(0, 140)}"`);
};

try {
  await page.goto(`http://127.0.0.1:${port}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator('.as').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m03/asg-scaling-calculator"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  await expect('처음(워크시트 1번)', /새 희망 용량 6대/);
  // 워크시트 2번 → max에서 잘려 10대
  await tabUntil('.as button[data-preset="2"]');
  await press('Enter');
  await expect('워크시트 2번', /새 희망 용량 10대.*11대 > max 10/);
  // 정책을 단계 조정으로(ArrowDown 두 번: cpu → alb → step)
  await tabUntil('.as input[name=as-policy]');
  await press('ArrowDown');
  await press('ArrowDown');
  // 현재 대수 4, CPU 80 → 경계값: +3 → 7대
  await tabUntil('.as input[data-field=current]');
  await typeNumber('4');
  await tabUntil('.as input[data-field=metric]');
  await typeNumber('80');
  await expect('단계 조정 CPU 80', /새 희망 용량 7대.*\[20, ∞\) 구간 → \+3/);
  // CPU 59 → 경보 없음
  await typeNumber('59');
  await expect('단계 조정 CPU 59', /변화 없음.*경보가 울리지 않는다/);
  // 워크시트 8번(단순 조정, 120초 뒤 경보는 무시) → 6대
  await tabUntil('.as button[data-preset="8"]', { back: true });
  await press('Enter');
  await expect('워크시트 8번', /새 희망 용량 6대.*무시/);
  // 두 번째 경보를 300초 뒤로 → 쿨다운이 끝나 8대
  await tabUntil('.as input[data-field=secondAfter]');
  await typeNumber('300');
  await expect('단순 조정 300초 뒤', /새 희망 용량 8대/);
  // 두 번째 경보 끄기(Space) → 6대
  await tabUntil('.as input[data-field=secondAlarm]', { back: true });
  await press('Space');
  await expect('두 번째 경보 없음', /새 희망 용량 6대/);
  // 표 펼치기
  await tabUntil('.as-table-box > summary');
  await press('Enter');
  const table = await page.$eval('.as-table-box', (d) => (d.open ? d.querySelector('table').textContent : ''));
  if (!table.includes('새 희망 용량6대')) problems.push(`표 보기: "${table.slice(0, 120)}"`);
  // 워크시트 10번(예약 작업) → min 4, 6대
  await tabUntil('.as button[data-preset="10"]', { back: true });
  await press('Enter');
  await expect('워크시트 10번', /새 희망 용량 6대.*min 2 → 4/);
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
  console.log(`FAIL keyboard(m03/asg-scaling-calculator): ${problems.length}건`);
  process.exit(1);
}
console.log('PASS keyboard(m03/asg-scaling-calculator): 2번(max) → 단계 조정 80/59 → 8번(쿨다운) → 300초 → 경보 끄기 → 표 → 10번(예약 작업)');
