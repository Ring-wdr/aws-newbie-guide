// 시범 화면 스크린샷: 라이트/다크 × 1280px/360px. 검증자가 직접 열어 깨진 곳을 본다(GUIDE-SITE 5장).
// 사용: node tests/screenshots.mjs --port <포트> --out <폴더> [--full] [--only 이름,이름]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

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
  { name: 'widget-sqs-timeline', path: '/curriculum/m06-integration-messaging/02-sqs/', element: '.vt', prepare: timelineMid },
  { name: 'widget-progress', path: '/curriculum/m06-integration-messaging/', element: '.pt-wrap', prepare: progressSome },
  // 진행 추적(전 모듈 공용)·홈 요약·레슨 완료
  { name: 'home-progress', path: '/', element: '.po-wrap', prepare: homeProgress },
  { name: 'widget-progress-m14', path: '/curriculum/m14-capstone-exam/', element: '.pt-wrap', prepare: m14Progress },
  { name: 'widget-progress-m12', path: '/curriculum/m12-resilience-dr-migration/', element: '.pt-wrap', prepare: async (p) => { await p.locator('.pt-wrap').scrollIntoViewIfNeeded(); await p.waitForSelector('.pt input[data-item]:not([disabled])'); } },
  { name: 'progress-reset-confirm', path: '/curriculum/m06-integration-messaging/', prepare: resetConfirm },
  { name: 'lesson-done', path: '/curriculum/m06-integration-messaging/02-sqs/', element: '.ld', prepare: lessonDone },
  { name: 'diagram-m02', path: '/curriculum/m02-vpc-networking/02-vpc-subnet-route-igw/', prepare: (p) => p.locator('.diagram').first().evaluate((e) => e.scrollIntoView({ block: 'start' })) },
];

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

async function homeProgress(page) {
  await page.evaluate(() => {
    localStorage.setItem('guide:progress:m00', JSON.stringify({ v: 1, done: { 'lesson:01-cloud-and-global-infrastructure': true, 'lesson:02-what-is-aws-emulator': true, quiz: true } }));
    localStorage.setItem('guide:progress:m06', JSON.stringify({ v: 1, done: { 'lesson:02-sqs': true } }));
  });
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForFunction(() => /3항목|4항목/.test(document.querySelector('[data-overview-text]')?.textContent || ''));
}

async function m14Progress(page) {
  await page.evaluate(() => localStorage.setItem('guide:progress:m14', JSON.stringify({ v: 1, done: { 'lesson:01-well-architected-review': true, 'exam:mock-exam': true } })));
  await page.reload({ waitUntil: 'networkidle' });
  await page.locator('.pt-wrap').scrollIntoViewIfNeeded();
  await page.waitForSelector('.pt input[data-item]:not([disabled])');
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
        await page.goto(`http://127.0.0.1:${port}${s.path}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => localStorage.clear());
        await page.reload({ waitUntil: 'networkidle' });
        if (s.prepare) await s.prepare(page);
        await page.waitForTimeout(300); // 스크롤 직후 붙박이(sticky) 요소가 다 그려지기를 기다린다
        const file = path.join(out, `${s.name}-${theme}-${width}.png`);
        if (s.element) {
          // 붙박이 머리글이 위젯을 가리지 않게, 전체 페이지에서 위젯 상자만 잘라 찍는다.
          await page.evaluate((sel) => {
            const target = document.querySelector(sel);
            for (const el of document.querySelectorAll('body *')) {
              const pos = getComputedStyle(el).position;
              if ((pos === 'fixed' || pos === 'sticky') && !el.contains(target) && !target.contains(el)) el.style.visibility = 'hidden';
            }
          }, s.element);
          const box = await page.locator(s.element).evaluate((e) => {
            const r = e.getBoundingClientRect();
            return { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height };
          });
          const pad = 8;
          await page.screenshot({ path: file, fullPage: true, clip: { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad), width: box.width + 2 * pad, height: box.height + 2 * pad } });
        }
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
