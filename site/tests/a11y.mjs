// 접근성 자동 검사(axe-core, site/ 의 고정 의존성): 시범 페이지 × 라이트/다크 × 1280/360px, 그리고 상호작용 뒤의 상태.
// WCAG 2.x A/AA 규칙 위반이 하나라도 있으면 실패. 모범 사례(best-practice) 규칙은 참고로만 출력한다.
// 사용: node tests/a11y.mjs --port <포트> [--pages pilot|all|/a/,/b/]
// 상호작용 뒤 상태(퀴즈 채점·시험)는 그 페이지가 대상에 있을 때만 본다.
import { createRequire } from 'node:module';
import { eachPage, EXAM_PAGE, isQuizPage, offlineBrowser, pagesFromArgs, portFromArgs, serve } from './lib/harness.mjs';

const require = createRequire(import.meta.url);
const AXE = require.resolve('axe-core/axe.min.js');
const port = portFromArgs(4321);
const base = `http://127.0.0.1:${port}`;
const pages = pagesFromArgs();
const quizPage = pages.find(isQuizPage);
const hasExam = pages.includes(EXAM_PAGE);
const WCAG = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'];
const failures = [];
const advisories = new Map();
let runs = 0;

async function audit(page, label) {
  await page.addScriptTag({ path: AXE });
  const res = await page.evaluate(async (tags) => {
    // eslint-disable-next-line no-undef
    const r = await axe.run(document, { resultTypes: ['violations'], runOnly: { type: 'tag', values: [...tags, 'best-practice'] } });
    return r.violations.map((v) => ({ id: v.id, impact: v.impact, tags: v.tags, help: v.help, nodes: v.nodes.slice(0, 3).map((n) => n.target.join(' ')) , count: v.nodes.length }));
  }, WCAG);
  runs++;
  for (const v of res) {
    const isWcag = v.tags.some((t) => WCAG.includes(t));
    if (isWcag) failures.push(`${label}: [${v.impact}] ${v.id} — ${v.help} (${v.count}곳: ${v.nodes.join(' / ')})`);
    else advisories.set(v.id, `${v.help} — 예: ${label} ${v.nodes[0]}`);
  }
}

const server = await serve(port);
try {
  for (const colorScheme of ['light', 'dark']) {
    for (const width of [1280, 360]) {
      const { browser, context } = await offlineBrowser({ colorScheme, viewport: { width, height: 900 } });
      await eachPage(context, pages, async (pg, p) => {
        await pg.goto(base + p, { waitUntil: 'networkidle' });
        await audit(pg, `${p} (${colorScheme} ${width})`);
      });
      const page = await context.newPage();
      // 상호작용 뒤 상태
      if (quizPage) {
        await page.goto(`${base}${quizPage}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => localStorage.clear());
        await page.reload({ waitUntil: 'networkidle' });
        // 1번은 맞히고 2번은 틀린다(정답·오답 표시를 모두 본다)
        const a1 = await page.getAttribute('section.quiz-q[data-q="1"]', 'data-answer');
        await page.check(`section.quiz-q[data-q="1"] input[value="${a1}"]`);
        await page.click('section.quiz-q[data-q="1"] .quiz-check');
        const a2 = await page.getAttribute('section.quiz-q[data-q="2"]', 'data-answer');
        await page.locator(`section.quiz-q[data-q="2"] input:not([value="${a2}"])`).first().check();
        await page.click('section.quiz-q[data-q="2"] .quiz-check');
        await audit(page, `퀴즈 채점 뒤 ${quizPage} (${colorScheme} ${width})`);
      }
      if (hasExam) {
        await page.goto(`${base}${EXAM_PAGE}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => localStorage.clear());
        await page.reload({ waitUntil: 'networkidle' });
        await page.click('[data-act=start]');
        await page.check('section.exam-q[data-q="1"] input[value="C"]');
        await page.click('[data-act=flag]');
        await audit(page, `시험 진행 중 (${colorScheme} ${width})`);
        await page.click('[data-act=submit]');
        await audit(page, `제출 확인 상자 (${colorScheme} ${width})`);
        await page.click('.guide-dialog .exam-primary');
        await page.waitForSelector('.exam-result:not([hidden])');
        await audit(page, `시험 결과·검토 (${colorScheme} ${width})`);
      }
      await browser.close();
    }
  }
} finally {
  server.close();
}

console.log(`axe-core 검사 ${runs}회 (규칙: ${WCAG.join(', ')})`);
if (advisories.size) {
  console.log('참고(모범 사례 규칙, 관문 아님):');
  for (const [id, msg] of advisories) console.log(`  · ${id}: ${msg}`);
}
if (failures.length) {
  for (const f of failures) console.log(`  - ${f}`);
  console.log(`FAIL a11y: WCAG 위반 ${failures.length}건`);
  process.exit(1);
}
console.log('PASS a11y: WCAG A/AA 위반 0건');
