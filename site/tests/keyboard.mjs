// 키보드만으로 퀴즈, M06 위젯, 모의고사를 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장).
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter)이다. 마우스 클릭·page.check 같은 API 조작은 쓰지 않는다.
// 페이지 상태를 "읽는" 것(어디에 초점이 있나, 정답이 무엇인가)만 DOM에서 한다.
// 결과: --out 폴더에 keyboard-answers.txt(시험 모드가 내보낸 답안), keyboard-result.json(화면의 채점 결과).
// 사용: node tests/keyboard.mjs --port <포트> --out <폴더>
import fs from 'node:fs';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const base = `http://127.0.0.1:${port}`;
const outIdx = process.argv.indexOf('--out');
const out = outIdx >= 0 ? path.resolve(process.argv[outIdx + 1]) : null;
const problems = [];
const server = await serve(port);
const { browser, context } = await offlineBrowser({ viewport: { width: 1280, height: 900 } });
const page = await context.newPage();
let keys = 0;

async function press(k) {
  keys++;
  await page.keyboard.press(k);
}

/** 초점이 조건을 만족할 때까지 Tab(또는 Shift+Tab)을 누른다. */
async function tabUntil(pred, arg, { back = false, max = 300 } = {}) {
  for (let i = 0; i < max; i++) {
    if (await page.evaluate(pred, arg)) return;
    await press(back ? 'Shift+Tab' : 'Tab');
  }
  throw new Error(`초점을 옮기지 못했다: ${arg ?? pred.toString().slice(0, 120)}`);
}
const focusIs = (sel) => document.activeElement?.matches?.(sel) ?? false;

try {
  /* ---------------- 퀴즈 ---------------- */
  await page.goto(`${base}/curriculum/m06-integration-messaging/quiz/`, { waitUntil: 'networkidle' });
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'networkidle' });
  const quiz = await page.$$eval('section.quiz-q', (cs) => cs.map((c) => ({ n: c.dataset.q, answer: c.dataset.answer, letters: [...c.querySelectorAll('input')].map((i) => i.value) })));
  const wrongOn = new Set([quiz[3].n]); // 한 문항은 일부러 틀린다
  for (const q of quiz) {
    await tabUntil(focusIs, `section.quiz-q[data-q="${q.n}"] input`);
    const want = wrongOn.has(q.n) ? q.letters.find((l) => l !== q.answer) : q.answer;
    const idx = q.letters.indexOf(want);
    if (idx === 0) await press('Space');
    for (let k = 0; k < idx; k++) await press('ArrowDown');
    await tabUntil(focusIs, `section.quiz-q[data-q="${q.n}"] .quiz-check`);
    await press('Enter');
    const verdict = await page.textContent(`section.quiz-q[data-q="${q.n}"] .quiz-verdict`);
    const expected = wrongOn.has(q.n) ? '오답' : '정답';
    if (!verdict?.startsWith(expected)) problems.push(`퀴즈 ${q.n}번: 기대 ${expected}, 화면 "${verdict}"`);
    const open = await page.$eval(`section.quiz-q[data-q="${q.n}"] details.quiz-explain`, (d) => d.open && !d.hidden);
    if (!open) problems.push(`퀴즈 ${q.n}번: 채점 뒤 해설이 펼쳐지지 않음`);
  }
  const score = await page.textContent('.quiz-score');
  console.log(`퀴즈(키보드): ${score}`);
  if (!score.includes(`${quiz.length}문항 중 ${quiz.length - 1}문항 정답`) || !score.includes('통과')) problems.push(`퀴즈 점수 표시가 기대와 다름: ${score}`);

  /* ---------------- M06 위젯: SQS 가시성 타임아웃 타임라인 ---------------- */
  await page.goto(`${base}/curriculum/m06-integration-messaging/02-sqs/`, { waitUntil: 'networkidle' });
  await page.locator('.vt').evaluate((e) => e.scrollIntoView());
  await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="m06/sqs-visibility-timeline"] astro-island:not([ssr])') !== null);
  await page.evaluate(() => document.activeElement?.blur());
  await tabUntil(focusIs, '.vt button[data-preset=lab02]');
  await press('Enter');
  let vt = await page.textContent('.vt-result');
  if (!vt.includes('DLQ로 옮겨짐')) problems.push(`타임라인 lab02 예: DLQ 결과가 아님 "${vt}"`);
  // 재드라이브 끄기(Space) → 계속 반복
  await tabUntil(focusIs, '.vt input[data-field=redrive]');
  await press('Space');
  vt = await page.textContent('.vt-result');
  if (!vt.includes('계속 반복')) problems.push(`타임라인 재드라이브 끔: 반복 결과가 아님 "${vt}"`);
  // 처리 결과를 "성공"으로(화살표), 처리 시간 1초 < 타임아웃 2초 → 삭제
  await tabUntil(focusIs, '.vt input[name=vt-outcome]', { back: true });
  await press('ArrowUp');
  vt = await page.textContent('.vt-result');
  if (!vt.includes('삭제됨')) problems.push(`타임라인 성공: 삭제 결과가 아님 "${vt}"`);
  // 처리 시간을 숫자 키로 5초로 바꾼다 → 타임아웃(2초)보다 길어 중복 처리
  await tabUntil(focusIs, '.vt input[data-field=processing]', { back: true });
  for (let i = 0; i < 6; i++) await press('Backspace');
  await press('5');
  vt = await page.textContent('.vt-result');
  if (!vt.includes('중복 처리')) problems.push(`타임라인 처리 5초: 중복 처리 결과가 아님 "${vt}"`);
  // 단계별 보기: 처음 → 다음
  await tabUntil(focusIs, '.vt button[data-step=first]');
  await press('Enter');
  // "처음"이 비활성화되면 초점은 "다음 단계"로 옮겨져야 한다(body로 빠지지 않게)
  if (!(await page.waitForFunction(focusIs, '.vt button[data-step=next]', { timeout: 2000 }).then(() => true, () => false))) problems.push('타임라인: "처음" 뒤 초점이 "다음 단계"에 있지 않음');
  await tabUntil(focusIs, '.vt button[data-step=next]');
  await press('Enter');
  const nowText = await page.textContent('.vt-now');
  if (!/^단계 2\//.test(nowText.trim())) problems.push(`타임라인 단계 이동: "${nowText}"`);
  await tabUntil(focusIs, '.vt button[data-step=last]');
  await press('Enter');
  if (!(await page.waitForFunction(focusIs, '.vt button[data-step=prev]', { timeout: 2000 }).then(() => true, () => false))) problems.push('타임라인: "끝까지" 뒤 초점이 "이전 단계"에 있지 않음');
  console.log(`타임라인(키보드): ${vt.trim().slice(0, 60)}… / ${nowText.trim().slice(0, 30)}…`);

  /* ---------------- M06 위젯: 진행 추적 ---------------- */
  await page.goto(`${base}/curriculum/m06-integration-messaging/`, { waitUntil: 'networkidle' });
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'networkidle' });
  await page.locator('.pt').evaluate((e) => e.scrollIntoView());
  await page.waitForSelector('.pt input[data-item]:not([disabled])');
  await page.evaluate(() => document.activeElement?.blur());
  for (const id of ['lesson:02-sqs', 'lab:labs/lab02-sqs-dlq-redrive.sh', 'quiz']) {
    await tabUntil(focusIs, `.pt input[data-item="${id}"]`);
    await press('Space');
  }
  let pt = await page.textContent('.pt [data-progress-text]');
  if (!pt.includes('3항목 완료')) problems.push(`진행 추적: 3항목 완료가 아님 "${pt}"`);
  await page.reload({ waitUntil: 'networkidle' });
  await page.locator('.pt').evaluate((e) => e.scrollIntoView());
  await page.waitForSelector('.pt input[data-item]:not([disabled])');
  pt = await page.textContent('.pt [data-progress-text]');
  if (!pt.includes('3항목 완료')) problems.push(`진행 추적: 새로 고친 뒤 저장이 유지되지 않음 "${pt}"`);
  await tabUntil(focusIs, '.pt input[data-item="quiz"]');
  await press('Space');
  await tabUntil(focusIs, '.pt-reset');
  await press('Enter');
  pt = await page.textContent('.pt [data-progress-text]');
  if (!pt.includes('0항목 완료')) problems.push(`진행 추적: 모두 지우기 뒤 "${pt}"`);
  console.log('진행 추적(키보드): 체크 3개 → 새로 고침 뒤 유지 → 하나 해제 → 모두 지우기');

  /* ---------------- 모의고사 ---------------- */
  await page.goto(`${base}/curriculum/m14-capstone-exam/mock-exam/questions/`, { waitUntil: 'networkidle' });
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'networkidle' });
  const key = await page.evaluate(() => JSON.parse(document.getElementById('exam-data').textContent).key);
  await tabUntil(focusIs, '[data-act=start]');
  await press('Enter');
  const plan = {};
  const flagged = [];
  for (let n = 1; n <= 65; n++) {
    const answer = key[n].answer;
    const letters = await page.$$eval(`section.exam-q[data-q="${n}"] input`, (is) => is.map((i) => i.value));
    let want = answer;
    if (n % 13 === 0) want = []; // 무응답
    else if (n % 5 === 0) want = answer.length > 1 ? [answer[0]] : [letters.find((l) => l !== answer[0])]; // 오답(복수 응답은 일부만)
    plan[n] = want;
    if (await page.isHidden(`section.exam-q[data-q="${n}"]`)) throw new Error(`${n}번 문항이 보이지 않는다`);
    if (want.length) {
      await tabUntil(focusIs, `section.exam-q[data-q="${n}"] input`);
      if (answer.length === 1) {
        const idx = letters.indexOf(want[0]);
        if (idx === 0) await press('Space');
        for (let k = 0; k < idx; k++) await press('ArrowDown');
      } else {
        // 체크박스: 하나씩 Tab으로 지나가며 고를 것만 Space
        for (;;) {
          const v = await page.evaluate((q) => (document.activeElement?.matches(`section.exam-q[data-q="${q}"] input`) ? document.activeElement.value : null), n);
          if (!v) break;
          if (want.includes(v)) await press('Space');
          await press('Tab');
        }
      }
    }
    if (n % 7 === 0) {
      await tabUntil(focusIs, '[data-act=flag]');
      await press('Enter');
      flagged.push(n);
    }
    if (n < 65) {
      await tabUntil(focusIs, '[data-act=next]');
      await press('Enter');
    }
  }
  const st = await page.evaluate(() => window.__guideExamState());
  for (let n = 1; n <= 65; n++) {
    const got = (st.answers[n] || []).join('');
    if (got !== plan[n].slice().sort().join('')) problems.push(`시험 ${n}번: 계획 ${plan[n].join('')} / 저장 ${got}`);
  }
  if (st.flags.join(',') !== flagged.join(',')) problems.push(`표시한 문항이 다름: ${st.flags} / ${flagged}`);
  // 제출: 위쪽 막대의 "제출하고 채점"으로 돌아가 Enter, 확인 상자에서 Enter
  await tabUntil(focusIs, '[data-act=submit]', { back: true });
  await press('Enter');
  await page.waitForSelector('.guide-dialog[open]');
  if (!(await page.evaluate(() => document.activeElement?.closest('.guide-dialog') !== null))) problems.push('확인 상자에 초점이 가지 않음');
  await press('Enter');
  await page.waitForSelector('.exam-result:not([hidden])');
  const totalText = await page.textContent('.exam-total');
  const verdictText = await page.textContent('.exam-verdict');
  console.log(`모의고사(키보드): ${totalText} / ${verdictText} / 표시 ${flagged.length}개`);
  // 검토: 첫 번째 틀린 문항을 키보드로 열어 해설이 보이는지
  await tabUntil(focusIs, '[data-filter=wrong]');
  await press('Enter');
  await tabUntil(focusIs, '.exam-review-list button');
  await press('Enter');
  const explain = await page.$eval('.exam-explain-slot', (e) => (!e.hidden ? e.textContent.trim().length : 0));
  if (explain < 50) problems.push('검토 화면에 해설이 보이지 않음');
  // 결과로 돌아가 답안 내보내기(answer-sheet.txt 형식)
  await tabUntil(focusIs, '[data-act=back-to-result]');
  await press('Enter');
  await tabUntil(focusIs, '[data-act=export-sheet]');
  const [download] = await Promise.all([page.waitForEvent('download'), press('Enter')]);
  const m = /전체 (\d+)\/(\d+) = ([\d.]+)%/.exec(totalText);
  const result = { totalOk: Number(m[1]), totalQ: Number(m[2]), pct: m[3], pass: verdictText.includes('통과') };
  if (out) {
    fs.mkdirSync(out, { recursive: true });
    await download.saveAs(path.join(out, 'keyboard-answers.txt'));
    fs.writeFileSync(path.join(out, 'keyboard-result.json'), JSON.stringify(result));
  }
} catch (e) {
  problems.push(`중단: ${e.message}`);
} finally {
  await browser.close();
  server.close();
}

console.log(`누른 키 ${keys}번`);
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log(`FAIL keyboard: ${problems.length}건`);
  process.exit(1);
}
console.log('PASS keyboard: 퀴즈 12문항, M06 위젯 2개(가시성 타임아웃 타임라인·진행 추적), 모의고사 65문항(복수 응답·표시·무응답 포함)을 키 입력만으로 조작하고 제출·검토·내보내기까지 했다');
