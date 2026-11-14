// 시범 화면 스크린샷: 라이트/다크 × 1280px/360px. 검증자가 직접 열어 깨진 곳을 본다(GUIDE-SITE 5장).
// 사용: node tests/screenshots.mjs --port <포트> --out <폴더> [--full] [--only 이름,이름]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve, shootElement, baseUrl } from './lib/harness.mjs';
import { widgetPages } from './lib/widget-checks.mjs';
import { WIDGETS_DIR } from '../src/lib/repo.mjs';

const port = portFromArgs(4321);
const outIdx = process.argv.indexOf('--out');
if (outIdx < 0) throw new Error('--out <폴더> 가 필요하다');
const out = path.resolve(process.argv[outIdx + 1]);
fs.mkdirSync(out, { recursive: true });
const full = process.argv.includes('--full');
const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1].split(',') : null;

const SHOTS = [
  { name: 'lesson-sqs', path: '/curriculum/m06-integration-messaging/02-sqs/' },
  { name: 'quiz-mid', path: '/curriculum/m06-integration-messaging/quiz/', prepare: quizMid },
  { name: 'mock-exam', path: '/curriculum/m14-capstone-exam/mock-exam/questions/', prepare: examMid },
  { name: 'cheatsheet', path: '/curriculum/m06-integration-messaging/cheatsheet/' },
  { name: 'm00-lesson3', path: '/curriculum/m00-orientation/03-environment-setup/' },
  { name: 'm03-auto-scaling', path: '/curriculum/m03-compute-scaling/06-auto-scaling/' },
  { name: 'home', path: '/' },
  { name: 'module-m06', path: '/curriculum/m06-integration-messaging/' },
  { name: 'exam-result', path: '/curriculum/m14-capstone-exam/mock-exam/questions/', prepare: examResult },
  { name: 'source-view', path: '/files/curriculum/m06-integration-messaging/labs/lab01-sqs-basics.sh/' },
  { name: 'source-helper', path: '/files/scripts/lab-wait.sh/' },
  { name: 'diagram-m14-02', path: '/curriculum/m14-capstone-exam/02-capstone-requirements-and-design/', prepare: (p) => p.locator('.diagram').first().evaluate((e) => e.scrollIntoView({ block: 'start' })) },
  // M06 맞춤 위젯(element: 위젯 상자만 찍는다)
  { name: 'widget-sqs-timeline', widget: 'm06/sqs-visibility-timeline', path: '/curriculum/m06-integration-messaging/02-sqs/', element: '.vt', prepare: timelineMid },
  { name: 'widget-progress', path: '/curriculum/m06-integration-messaging/', element: '.pt-wrap', prepare: progressSome },
  // 진행 추적(전 모듈 공용)·홈 요약·레슨 완료·모의고사 기록
  { name: 'home-progress', path: '/', element: '.po-wrap', prepare: homeProgress },
  { name: 'widget-progress-m14', path: '/curriculum/m14-capstone-exam/', element: '.pt-wrap', prepare: m14Progress },
  { name: 'widget-progress-m12', path: '/curriculum/m12-resilience-dr-migration/', element: '.pt-wrap', prepare: async (p) => { await p.locator('.pt-wrap').scrollIntoViewIfNeeded(); await p.waitForSelector('.pt input[data-item]:not([disabled])'); } },
  { name: 'progress-reset-confirm', path: '/curriculum/m06-integration-messaging/', prepare: resetConfirm },
  { name: 'lesson-done', path: '/curriculum/m06-integration-messaging/02-sqs/', element: '.ld', prepare: lessonDone },
  { name: 'exam-history-start', path: '/curriculum/m14-capstone-exam/mock-exam/questions/', element: '.exam-start', prepare: examHistory },
  { name: 'exam-running-nav', path: '/curriculum/m14-capstone-exam/mock-exam/questions/', prepare: examRunningNav },
  { name: 'diagram-m02', path: '/curriculum/m02-vpc-networking/02-vpc-subnet-route-igw/', prepare: (p) => p.locator('.diagram').first().evaluate((e) => e.scrollIntoView({ block: 'start' })) },
];

// 맞춤 위젯은 폴더(src/widgets/mNN/<이름>/index.astro)와 원고의 표시 줄에서 자동으로 찾는다 — 새 위젯을 여기에 적지 않아도 찍힌다.
// 위에 손으로 적은 항목(widget: 'mNN/<이름>')이 있으면 그것을 쓴다. 이름: widget-mNN-<이름>, 상자: .guide-widget[data-widget="mNN/<이름>"].
for (const [key, pages] of Object.entries(widgetPages()).sort()) {
  if (!fs.existsSync(path.join(WIDGETS_DIR, key, 'index.astro')) || SHOTS.some((x) => x.widget === key)) continue;
  const element = `.guide-widget[data-widget="${key}"]`;
  SHOTS.push({ name: `widget-${key.replace('/', '-')}`, widget: key, path: pages[0], element, prepare: (p) => hydrated(p, element) });
}

async function hydrated(page, element) {
  await page.locator(element).scrollIntoViewIfNeeded();
  await page.waitForFunction((sel) => document.querySelector(`${sel} astro-island:not([ssr])`) !== null, element);
}

async function timelineMid(page) {
  // lab02 예(독 메시지 → DLQ)를 고르고 3단계까지 넘긴 상태
  await page.locator('.vt').scrollIntoViewIfNeeded();
  await page.waitForSelector('.vt button[data-preset=lab02]:not([disabled])');
  await page.waitForFunction(() => document.querySelector('.guide-widget astro-island:not([ssr])') !== null);
  await page.click('.vt button[data-preset=lab02]');
  await page.click('.vt button[data-step=first]');
  await page.click('.vt button[data-step=next]');
  await page.click('.vt button[data-step=next]');
}

async function progressSome(page) {
  await page.locator('.pt-wrap').scrollIntoViewIfNeeded();
  await page.waitForSelector('.pt input[data-item]:not([disabled])');
  for (const id of ['lesson:01-why-decoupling', 'lesson:02-sqs', 'lab:labs/lab01-sqs-basics.sh']) await page.check(`.pt input[data-item="${id}"]`);
}

const seedHistory = (page) =>
  page.evaluate(() => {
    const rec = (at, ok, pass, ms, auto = false) => ({ at, ok, total: 65, pct: ((100 * ok) / 65).toFixed(1), pass, blank: 0, domains: [{ domain: 'D1', ok: Math.round(ok * 0.31), total: 20 }, { domain: 'D2', ok: Math.round(ok * 0.26), total: 17 }, { domain: 'D3', ok: Math.round(ok * 0.23), total: 15 }, { domain: 'D4', ok: ok - Math.round(ok * 0.31) - Math.round(ok * 0.26) - Math.round(ok * 0.23), total: 13 }], elapsedMs: ms, auto });
    localStorage.setItem('aws-newbie-guide:exam:m14-mock-exam:history', JSON.stringify({ v: 1, records: [rec('2026-11-13T05:10:00Z', 51, true, 6_480_000), rec('2026-11-06T01:02:00Z', 44, false, 7_800_000, true)] }));
  });

async function homeProgress(page) {
  await page.evaluate(() => {
    localStorage.setItem('aws-newbie-guide:progress:m00', JSON.stringify({ v: 1, done: { 'lesson:01-cloud-and-global-infrastructure': true, 'lesson:02-what-is-aws-emulator': true, quiz: true } }));
    localStorage.setItem('aws-newbie-guide:progress:m06', JSON.stringify({ v: 1, done: { 'lesson:02-sqs': true } }));
  });
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForFunction(() => /3항목|4항목/.test(document.querySelector('[data-overview-text]')?.textContent || ''));
}

async function m14Progress(page) {
  await seedHistory(page);
  await page.evaluate(() => localStorage.setItem('aws-newbie-guide:progress:m14', JSON.stringify({ v: 1, done: { 'lesson:01-well-architected-review': true, 'exam:mock-exam': true } })));
  await page.reload({ waitUntil: 'networkidle' });
  await page.locator('.pt-wrap').scrollIntoViewIfNeeded();
  await page.waitForSelector('.pt [data-exam-last]');
}

async function resetConfirm(page) {
  await progressSome(page);
  await page.click('.pt-reset');
  await page.waitForSelector('.guide-dialog[open]');
}

async function lessonDone(page) {
  await page.locator('.ld').scrollIntoViewIfNeeded();
  await page.waitForSelector('.ld input:not([disabled])');
  await page.check('.ld input');
}

async function examHistory(page) {
  await seedHistory(page);
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('.exam-start [data-exam-history] tbody tr');
}

async function examRunningNav(page) {
  await page.click('[data-act=start]');
  await page.evaluate(() => document.querySelector('.pagination-links')?.scrollIntoView({ block: 'end' }));
}

async function examResult(page) {
  await page.click('[data-act=start]');
  for (const [n, v] of [[1, 'C'], [2, 'B'], [3, 'B']]) {
    await page.check(`section.exam-q[data-q="${n}"] input[value="${v}"]`);
    await page.click('[data-act=next]');
  }
  await page.click('[data-act=submit]');
  await page.click('.guide-dialog .exam-primary');
  await page.waitForSelector('.exam-result:not([hidden])');
  await page.locator('.exam-result').scrollIntoViewIfNeeded();
}

async function quizMid(page) {
  // 1번은 맞히고 2번은 틀린 채 채점, 3번은 고르기만 한 상태
  await page.check('section.quiz-q[data-q="1"] input[value="B"]');
  await page.click('section.quiz-q[data-q="1"] .quiz-check');
  await page.check('section.quiz-q[data-q="2"] input[value="A"]');
  await page.click('section.quiz-q[data-q="2"] .quiz-check');
  await page.check('section.quiz-q[data-q="3"] input[value="A"]');
  await page.locator('section.quiz-q[data-q="2"]').scrollIntoViewIfNeeded();
}

async function examMid(page) {
  await page.click('[data-act=start]');
  await page.check('section.exam-q[data-q="1"] input[value="C"]');
  await page.click('[data-act=next]');
  await page.click('[data-act=next]');
  await page.click('[data-act=next]');
  await page.click('[data-act=next]');
  await page.click('[data-act=next]'); // 6번: 복수 응답
  await page.check('section.exam-q[data-q="6"] input[value="B"]');
  await page.click('[data-act=flag]');
  await page.locator('.exam-app').evaluate((e) => e.scrollIntoView({ block: 'start' }));
}

const server = await serve(port);
const written = [];
try {
  for (const theme of ['light', 'dark']) {
    for (const width of [1280, 360]) {
      const { browser, context, blocked } = await offlineBrowser({ colorScheme: theme, viewport: { width, height: width === 360 ? 780 : 900 } });
      for (const s of SHOTS.filter((x) => !only || only.includes(x.name))) {
        const page = await context.newPage();
        await page.goto(`${baseUrl(port)}${s.path}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => localStorage.clear());
        await page.reload({ waitUntil: 'networkidle' });
        if (s.prepare) await s.prepare(page);
        await page.waitForTimeout(300); // 스크롤 직후 붙박이(sticky) 요소가 다 그려지기를 기다린다
        const file = path.join(out, `${s.name}-${theme}-${width}.png`);
        if (s.element) await shootElement(page, s.element, file); // 붙박이 머리글을 숨기고 위젯 상자만 찍는다
        else await page.screenshot({ path: file, fullPage: full });
        written.push(file);
        // 페이지 가로 넘침(360px에서 본문이 밀리는지)
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (overflow > 0) console.log(`가로 넘침 ${overflow}px: ${s.path} (${theme} ${width})`);
        await page.close();
      }
      if (blocked.length) console.log(`외부 요청 차단 기록: ${blocked.join(', ')}`);
      await browser.close();
    }
  }
} finally {
  server.close();
}
console.log(written.join('\n'));
