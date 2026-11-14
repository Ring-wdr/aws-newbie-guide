// 키보드만으로 M01 정책 평가 위젯을 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장). 공용 tests/keyboard.mjs와 같은 방식:
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter), DOM은 상태를 "읽기"만 한다.
// 사용(site/에서, 빌드 뒤): node src/widgets/m01/policy-evaluation/keyboard.check.mjs --port <포트>
import { offlineBrowser, portFromArgs, serve } from '../../../../tests/lib/harness.mjs';

const PAGE = '/curriculum/m01-iam-identity/03-policy-evaluation/';
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
const result = () => page.textContent('.pe-result');
const expect = async (what, re) => {
  const t = (await result()).replace(/\s+/g, ' ');
  if (!re.test(t)) problems.push(`${what}: 기대 ${re}, 화면 "${t.slice(0, 120)}"`);
  return t;
};
const stoppedAt = () => page.getAttribute('.pe-step[aria-current=step]', 'data-step');

try {
  await page.goto(`http://127.0.0.1:${port}${PAGE}`, { waitUntil: 'networkidle' });
  await page.locator('.pe').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m01/policy-evaluation"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());

  // 1) 처음 상태(정책 없는 인턴) → 암묵적 거부, 자격 증명 단계에서 끝
  await expect('처음(정책 없는 인턴)', /암묵적 거부.*no identity-based policy allows/);
  // 2) 원고의 예: Allow + 명시적 Deny → 명시적 거부
  await tabUntil('.pe button[data-preset=deny]');
  await press('Enter');
  await expect('예 "Allow + 명시적 Deny"', /명시적 거부.*with an explicit deny in an identity-based policy/);
  if ((await stoppedAt()) !== 'deny') problems.push(`명시적 거부의 끝난 단계: ${await stoppedAt()}`);
  // 3) Deny 라디오를 화살표로 "없음"까지 되돌린다(그룹 안 첫 항목으로: ArrowUp) → 허용
  await tabUntil('.pe input[name=pe-deny]');
  await press('ArrowUp');
  await expect('Deny 없음', /허용 \(allowed\)/);
  // 4) 권한 경계: "있지만 경계 밖"(ArrowDown 두 번) → 암묵적 거부(권한 경계)
  await tabUntil('.pe input[name=pe-boundary]');
  await press('ArrowDown');
  await press('ArrowDown');
  await expect('권한 경계 밖', /암묵적 거부.*no permissions boundary allows/);
  if ((await stoppedAt()) !== 'boundary') problems.push(`경계 밖의 끝난 단계: ${await stoppedAt()}`);
  // 5) 리소스 기반 정책 허용(Space) → 같은 계정이라 허용 *, 경계 단서 표시
  await tabUntil('.pe input[data-field=resource]', { back: true });
  await press('Space');
  await expect('리소스 정책 허용', /허용 \(allowed\) \*/);
  if (!(await page.isVisible('.pe-caveat'))) problems.push('경계 밖 + 리소스 허용인데 각주 단서가 보이지 않음');
  // 6) 교차 계정(ArrowDown) → 양쪽 모두 필요: 경계 밖이므로 거부
  await tabUntil('.pe input[name=pe-account]', { back: true });
  await press('ArrowDown');
  await expect('교차 계정 + 경계 밖', /암묵적 거부/);
  // 7) SCP 끄기(Space) → SCP에서 끝
  await tabUntil('.pe input[data-field=scp]');
  await press('Space');
  await expect('SCP 끔', /암묵적 거부.*SCP가 이 작업을 허용하지 않는다/);
  if ((await stoppedAt()) !== 'org') problems.push(`SCP 끔의 끝난 단계: ${await stoppedAt()}`);
  // 8) 표 펼치기(summary에서 Enter) → 표에 "여기서 끝"과 같은 행이 표시
  await tabUntil('.pe-table-box > summary');
  await press('Enter');
  const open = await page.$eval('.pe-table-box', (d) => d.open);
  const row = await page.textContent('.pe-table tr[aria-current=step]');
  if (!open || !row?.includes('SCP')) problems.push(`표 보기: open=${open}, 현재 행 "${row}"`);
  // 9) 원고의 예 "세션 정책 밖" — 같은 계정으로 돌아오고 세션 정책에서 끝
  await tabUntil('.pe button[data-preset=session]', { back: true });
  await press('Enter');
  await expect('예 "세션 정책 밖"', /암묵적 거부.*no session policy allows/);
  if ((await stoppedAt()) !== 'session') problems.push(`세션 정책 예의 끝난 단계: ${await stoppedAt()}`);
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
  console.log(`FAIL keyboard(m01/policy-evaluation): ${problems.length}건`);
  process.exit(1);
}
console.log('PASS keyboard(m01/policy-evaluation): 예 고르기 → Deny 해제 → 경계 밖 → 리소스 허용 → 교차 계정 → SCP 끔 → 표 펼치기 → 세션 정책 예');
