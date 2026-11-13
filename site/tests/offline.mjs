// 오프라인 검사: 헤드리스 브라우저에서 루프백 밖으로 나가려는 시도를 모두 막고 기록한 채 시범 페이지를 연다. 기록이 0건이어야 한다.
// 어떤 통로를 기록하는지는 tests/lib/harness.mjs 의 offlineBrowser 주석, 각 통로가 실제로 잡히는지는 tests/offline-selftest.mjs.
// 검색(Pagefind)·퀴즈·시험 모드처럼 열 때 추가로 파일을 불러오는 동작도 실행한다. 저장소가 막힌 브라우저에서도 동작을 본다.
// 사용: node tests/offline.mjs --port <포트> [--all] [--out <폴더>]
import { listPages, offlineBrowser, PILOT_PAGES, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const base = `http://127.0.0.1:${port}`;
const pages = process.argv.includes('--all') ? listPages() : PILOT_PAGES;
const problems = [];
const server = await serve(port);
let opened = 0;

async function run(opts, label, fn) {
  const { browser, context, blocked, auditPage } = await offlineBrowser(opts);
  const errors = [];
  context.on('weberror', (e) => errors.push(String(e.error())));
  try {
    await fn(context, auditPage);
  } finally {
    await browser.close();
  }
  for (const b of blocked) problems.push(`[${label}] 루프백 밖 요청: ${b}`);
  for (const e of errors) problems.push(`[${label}] 페이지 스크립트 오류: ${e}`);
  console.log(`${label}: 막은 외부 요청 ${blocked.length}건, 스크립트 오류 ${errors.length}건`);
}

try {
  for (const colorScheme of ['light', 'dark']) {
    for (const width of [1280, 360]) {
      await run({ colorScheme, viewport: { width, height: 900 } }, `페이지 ${pages.length}개 ${colorScheme} ${width}px`, async (ctx, auditPage) => {
        const page = await ctx.newPage();
        for (const p of pages) {
          const res = await page.goto(base + p, { waitUntil: 'networkidle' });
          if (!res || res.status() !== 200) problems.push(`${p}: 응답 ${res?.status()}`);
          await auditPage(page);
          opened++;
        }
      });
    }
  }

  // 상호작용: 검색 색인 로딩, 퀴즈 채점, 시험 시작·제출
  const searchResults = {};
  await run({}, '상호작용(검색·퀴즈·시험)', async (ctx) => {
    const page = await ctx.newPage();
    await page.goto(`${base}/curriculum/m06-integration-messaging/02-sqs/`, { waitUntil: 'networkidle' });
    for (const q of ['가시성 타임아웃', '큐', '디커플링', '멱등', 'SQS FIFO', '배달 못 한 편지']) {
      const titles = await page.evaluate(async (query) => {
        const pf = await import('/pagefind/pagefind.js');
        await pf.options({ excerptLength: 10 });
        const r = await pf.search(query);
        const top = await Promise.all(r.results.slice(0, 3).map((x) => x.data()));
        return { count: r.results.length, top: top.map((d) => d.meta.title) };
      }, q);
      searchResults[q] = titles;
    }
    await page.goto(`${base}/curriculum/m06-integration-messaging/quiz/`, { waitUntil: 'networkidle' });
    await page.check('section.quiz-q[data-q="1"] input[value="B"]');
    await page.click('section.quiz-q[data-q="1"] .quiz-check');
    await page.goto(`${base}/curriculum/m14-capstone-exam/mock-exam/questions/`, { waitUntil: 'networkidle' });
    await page.click('[data-act=start]');
    await page.click('[data-act=submit]');
    await page.click('.guide-dialog .exam-primary');
    await page.waitForSelector('.exam-result:not([hidden])');
    await page.waitForLoadState('networkidle');
  });
  console.log('검색 결과(Pagefind, 상위 3개):');
  for (const [q, r] of Object.entries(searchResults)) console.log(`  "${q}" → ${r.count}건: ${r.top.join(' | ')}`);

  // 저장소가 막힌 브라우저: 퀴즈를 채점할 수 있고, 저장이 안 된다는 안내가 보여야 한다.
  await run({ blockStorage: true }, '저장소 차단', async (ctx) => {
    const page = await ctx.newPage();
    await page.goto(`${base}/curriculum/m06-integration-messaging/quiz/`, { waitUntil: 'networkidle' });
    await page.check('section.quiz-q[data-q="2"] input[value="D"]');
    await page.click('section.quiz-q[data-q="2"] .quiz-check');
    const verdict = await page.textContent('section.quiz-q[data-q="2"] .quiz-verdict');
    const note = await page.textContent('.quiz-summary .storage-note');
    if (!verdict?.startsWith('정답')) problems.push(`저장소 차단: 퀴즈 채점이 안 됨 (${verdict})`);
    if (!note) problems.push('저장소 차단: 저장 불가 안내가 없음');
    await page.goto(`${base}/curriculum/m14-capstone-exam/mock-exam/questions/`, { waitUntil: 'networkidle' });
    await page.click('[data-act=start]');
    if (await page.isHidden('section.exam-q[data-q="1"]')) problems.push('저장소 차단: 시험 모드가 시작되지 않음');
    console.log(`저장소 차단: 퀴즈 판정 "${verdict}", 안내 "${note}"`);
  });
} finally {
  server.close();
}

console.log(`열어 본 페이지 ${opened}회`);
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log(`FAIL offline: ${problems.length}건`);
  process.exit(1);
}
console.log('PASS offline: 루프백 밖 요청 0건, 스크립트 오류 0건');
