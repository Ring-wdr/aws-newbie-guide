// 시범 화면 스크린샷: 라이트/다크 × 1280px/360px. 검증자가 직접 열어 깨진 곳을 본다(GUIDE-SITE 5장).
// 사용: node tests/screenshots.mjs --port <포트> --out <폴더> [--full]
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const outIdx = process.argv.indexOf('--out');
if (outIdx < 0) throw new Error('--out <폴더> 가 필요하다');
const out = path.resolve(process.argv[outIdx + 1]);
fs.mkdirSync(out, { recursive: true });
const full = process.argv.includes('--full');

const SHOTS = [
  { name: 'lesson-sqs', path: '/curriculum/m06-integration-messaging/02-sqs/' },
  { name: 'quiz-mid', path: '/curriculum/m06-integration-messaging/quiz/', prepare: quizMid },
  { name: 'mock-exam', path: '/curriculum/m14-capstone-exam/mock-exam/questions/', prepare: examMid },
  { name: 'cheatsheet', path: '/curriculum/m06-integration-messaging/cheatsheet/' },
  { name: 'm00-lesson3', path: '/curriculum/m00-orientation/03-environment-setup/' },
  { name: 'm03-auto-scaling', path: '/curriculum/m03-compute-scaling/06-auto-scaling/' },
];

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
  await page.locator('.exam-bar').scrollIntoViewIfNeeded();
}

const server = await serve(port);
const written = [];
try {
  for (const theme of ['light', 'dark']) {
    for (const width of [1280, 360]) {
      const { browser, context, blocked } = await offlineBrowser({ colorScheme: theme, viewport: { width, height: width === 360 ? 780 : 900 } });
      for (const s of SHOTS) {
        const page = await context.newPage();
        await page.goto(`http://127.0.0.1:${port}${s.path}`, { waitUntil: 'networkidle' });
        await page.evaluate(() => localStorage.clear());
        await page.reload({ waitUntil: 'networkidle' });
        if (s.prepare) await s.prepare(page);
        const file = path.join(out, `${s.name}-${theme}-${width}.png`);
        await page.screenshot({ path: file, fullPage: full });
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
