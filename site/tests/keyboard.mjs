// 키보드만으로 퀴즈, M06 위젯, 모의고사를 끝까지 조작할 수 있는지 확인한다(GUIDE-SITE 5장).
// 대상(--pages)에 들어 있는 것만 조작한다: 퀴즈 페이지마다 한 번씩(문항이 있는 퀴즈), 위젯은 그 위젯이 놓인 페이지가
// 대상일 때, 모의고사는 시험 페이지가 대상일 때.
// 조작은 전부 키 입력(Tab, Shift+Tab, 화살표, Space, Enter)이다. 마우스 클릭·page.check 같은 API 조작은 쓰지 않는다.
// 페이지 상태를 "읽는" 것(어디에 초점이 있나, 정답이 무엇인가)만 DOM에서 한다.
// 위젯 폴더의 keyboard.check.mjs(UI 저자)는 자동으로 찾아, 그 위젯이 놓인 페이지가 대상일 때 이 스크립트의 서버를 닫은 뒤
// 같은 포트로 하나씩 돌린다(tests/lib/widget-checks.mjs). 발견 방식은 tests/widget-checks-selftest.mjs가 먼저 시험한다.
// 결과: --out 폴더에 keyboard-answers.txt(시험 모드가 내보낸 답안), keyboard-result.json(화면의 채점 결과).
// 사용: node tests/keyboard.mjs --port <포트> --out <폴더> [--pages pilot|all|/a/,/b/]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { EXAM_PAGE, SITE_DIR, isQuizPage, offlineBrowser, pagesFromArgs, portFromArgs, serve, baseUrl, withBase } from './lib/harness.mjs';
import { discoverWidgetChecks, runWidgetChecks } from './lib/widget-checks.mjs';

const port = portFromArgs(4321);
const base = baseUrl(port); // 하위 경로(base)로 빌드한 산출물이면 그 경로까지
const outIdx = process.argv.indexOf('--out');
const out = outIdx >= 0 ? path.resolve(process.argv[outIdx + 1]) : null;
const problems = [];
const pages = pagesFromArgs();
const SQS_PAGE = '/curriculum/m06-integration-messaging/02-sqs/';
const M06_PAGE = '/curriculum/m06-integration-messaging/';
const done = [];
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
  /* ---------------- 퀴즈(대상의 퀴즈 페이지마다) ---------------- */
  for (const qp of pages.filter(isQuizPage)) {
    await page.goto(`${base}${qp}`, { waitUntil: 'networkidle' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'networkidle' });
    const quiz = await page.$$eval('section.quiz-q', (cs) => cs.map((c) => ({ n: c.dataset.q, answer: c.dataset.answer, letters: [...c.querySelectorAll('input')].map((i) => i.value) })));
    if (!quiz.length) continue; // 문항 없는 퀴즈(M14 — 모의고사로 대신한다)
    await page.evaluate(() => document.activeElement?.blur());
    const wrongOn = new Set([quiz[Math.min(3, quiz.length - 1)].n]); // 한 문항은 일부러 틀린다
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
      if (!verdict?.startsWith(expected)) problems.push(`${qp} ${q.n}번: 기대 ${expected}, 화면 "${verdict}"`);
      const open = await page.$eval(`section.quiz-q[data-q="${q.n}"] details.quiz-explain`, (d) => d.open && !d.hidden);
      if (!open) problems.push(`${qp} ${q.n}번: 채점 뒤 해설이 펼쳐지지 않음`);
    }
    const score = await page.textContent('.quiz-score');
    console.log(`퀴즈(키보드) ${qp}: ${score}`);
    const need = Number(await page.getAttribute('.quiz-summary', 'data-need'));
    const verdictWord = quiz.length - 1 >= need ? '통과' : '미달';
    if (!score.includes(`${quiz.length}문항 중 ${quiz.length - 1}문항 정답`) || (verdictWord === '통과' && !score.includes('통과'))) problems.push(`${qp} 퀴즈 점수 표시가 기대와 다름: ${score}`);
    done.push(`퀴즈 ${qp.split('/')[2].slice(0, 3).toUpperCase()} ${quiz.length}문항`);
  }

  if (pages.includes(SQS_PAGE)) {
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
    done.push('M06 위젯: 가시성 타임아웃 타임라인');
  }

  /* ---------------- 진행 추적(전 모듈 공용): 대상의 모듈 첫 페이지마다 표시·새로 고침 뒤 유지·해제 ---------------- */
  const modulePages = pages.filter((p) => /^\/curriculum\/m\d\d-[^/]+\/$/.test(p));
  const leftDone = {}; // 모듈별로 남겨 둔 완료 수(홈 요약 대조용)
  const openTracker = async (mp) => {
    await page.goto(`${base}${mp}`, { waitUntil: 'networkidle' });
    await page.locator('.pt').evaluate((e) => e.scrollIntoView());
    await page.waitForSelector('.pt input[data-item]:not([disabled])');
  };
  const ptText = () => page.textContent('.pt [data-progress-text]');
  if (modulePages.length) {
    await page.goto(`${base}${modulePages[0]}`, { waitUntil: 'networkidle' });
    await page.evaluate(() => localStorage.clear());
  }
  for (const mp of modulePages) {
    await openTracker(mp);
    const ids = await page.$$eval('.pt input[data-item]', (is) => is.map((i) => i.dataset.item));
    const want = [ids.find((i) => i.startsWith('lesson:')), ids.find((i) => i.startsWith('lab:')), ids.at(-1)];
    await page.evaluate(() => document.activeElement?.blur());
    for (const id of want) {
      await tabUntil(focusIs, `.pt input[data-item="${id}"]`);
      await press('Space');
    }
    let pt = await ptText();
    if (!pt.includes(`${ids.length}항목 중 3항목 완료`)) problems.push(`${mp} 진행 추적: 3항목 완료가 아님 "${pt}"`);
    await openTracker(mp);
    pt = await ptText();
    if (!pt.includes('3항목 완료')) problems.push(`${mp} 진행 추적: 새로 고친 뒤 저장이 유지되지 않음 "${pt}"`);
    // 하나 해제(Space) → 2항목
    await page.evaluate(() => document.activeElement?.blur());
    await tabUntil(focusIs, `.pt input[data-item="${want[1]}"]`);
    await press('Space');
    pt = await ptText();
    if (!pt.includes('2항목 완료')) problems.push(`${mp} 진행 추적: 해제 뒤 "${pt}"`);
    leftDone[mp] = 2;
    if (mp === M06_PAGE) {
      // "모두 지우기"는 확인을 거친다: 처음 상자의 초점은 "취소" — Enter면 그대로, Tab → "모두 지우기" → Enter면 지운다.
      await tabUntil(focusIs, '.pt-reset');
      await press('Enter');
      await page.waitForSelector('.guide-dialog[open]');
      await press('Enter');
      await page.waitForSelector('.guide-dialog', { state: 'detached' });
      pt = await ptText();
      if (!pt.includes('2항목 완료')) problems.push(`M06 진행 추적: 확인 상자에서 취소했는데 "${pt}"`);
      if (!(await page.evaluate(focusIs, '.pt-reset'))) problems.push('M06 진행 추적: 취소 뒤 초점이 "모두 지우기"로 돌아오지 않음');
      // 백업 내보내기(키보드) → 모두 지우기(확인) → 가져오기: 새로 고치지 않아도 바로 반영
      await tabUntil(focusIs, '.pt-storage summary');
      await press('Enter');
      await tabUntil(focusIs, '.pt-storage button');
      const [dl] = await Promise.all([page.waitForEvent('download'), press('Enter')]);
      const backup = path.join(out || fs.mkdtempSync(path.join(os.tmpdir(), 'guide-kb-')), 'keyboard-progress-backup.json');
      await dl.saveAs(backup);
      await tabUntil(focusIs, '.pt-reset', { back: true });
      await press('Enter');
      await page.waitForSelector('.guide-dialog[open]');
      await press('Tab');
      await press('Enter');
      pt = await ptText();
      if (!pt.includes('0항목 완료')) problems.push(`M06 진행 추적: 모두 지우기 뒤 "${pt}"`);
      await tabUntil(focusIs, '.pt-storage button:nth-of-type(2)');
      const [chooser] = await Promise.all([page.waitForEvent('filechooser'), press('Enter')]);
      await chooser.setFiles(backup);
      const restored = await page.waitForFunction(() => /2항목 완료/.test(document.querySelector('.pt [data-progress-text]')?.textContent || ''), null, { timeout: 3000 }).then(() => true, () => false);
      if (!restored) problems.push(`M06 진행 추적: 백업을 가져온 뒤 같은 창에서 바로 반영되지 않음 "${await ptText()}"`);
    }
    done.push(`진행 추적 ${mp.split('/')[2].slice(0, 3).toUpperCase()}(${ids.length}항목)`);
  }
  if (modulePages.length) console.log(`진행 추적(키보드): 모듈 ${modulePages.length}개 — 표시 3개 → 새로 고침 뒤 유지 → 하나 해제${modulePages.includes(M06_PAGE) ? ', M06: 모두 지우기 확인(취소·확인)·백업 내보내기/가져오기 즉시 반영' : ''}`);

  if (pages.includes(SQS_PAGE)) {
    /* ---------------- 레슨 끝의 "이 레슨 완료" ---------------- */
    await page.goto(`${base}${SQS_PAGE}`, { waitUntil: 'networkidle' });
    await page.locator('.ld').evaluate((e) => e.scrollIntoView());
    await page.waitForSelector('.ld input:not([disabled])');
    const before = await page.isChecked('.ld input');
    await page.evaluate(() => document.activeElement?.blur());
    await tabUntil(focusIs, '.ld input');
    await press('Space');
    if ((await page.isChecked('.ld input')) === before) problems.push('이 레슨 완료: Space로 바뀌지 않음');
    const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('guide:progress:m06') || '{}'));
    if (Boolean(stored.done?.['lesson:02-sqs']) === before) problems.push(`이 레슨 완료: 저장값이 진행 추적과 같은 키에 없음 ${JSON.stringify(stored)}`);
    if (!before && leftDone[M06_PAGE] !== undefined) leftDone[M06_PAGE] += 1;
    done.push('이 레슨 완료(M06 레슨 2)');
  }

  if (pages.includes('/') && modulePages.length) {
    /* ---------------- 홈의 전체 진행 요약 ---------------- */
    await page.goto(`${base}/`, { waitUntil: 'networkidle' });
    await page.locator('.po').evaluate((e) => e.scrollIntoView());
    await page.waitForFunction(() => document.querySelector('.guide-widget[data-widget="progress-overview"] astro-island:not([ssr])') !== null);
    for (const [mp, n] of Object.entries(leftDone)) {
      const mod = mp.split('/')[2].slice(0, 3);
      const got = await page.textContent(`.po li[data-module="${mod}"] .po-count`);
      if (!got.trim().startsWith(`${n}/`)) problems.push(`홈 요약 ${mod}: 기대 ${n}개 완료, 화면 "${got}"`);
    }
    // 요약의 모듈 링크도 키보드로 닿는다
    await page.evaluate(() => document.activeElement?.blur());
    await tabUntil(focusIs, '.po a.po-name');
    done.push('홈 전체 진행 요약');
  }

  if (pages.includes(EXAM_PAGE)) {
    /* ---------------- 모의고사 ---------------- */
    await page.goto(`${base}/curriculum/m14-capstone-exam/mock-exam/questions/`, { waitUntil: 'networkidle' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'networkidle' });
    const key = await page.evaluate(() => JSON.parse(document.getElementById('exam-data').textContent).key);
    await tabUntil(focusIs, '[data-act=start]');
    await press('Enter');
    // 시험 중: 사이드바·이전/다음의 정답·해설 링크는 숨고, 본문의 링크는 확인을 거친다.
    const KEY_HREF = withBase('/curriculum/m14-capstone-exam/mock-exam/answer-key/'); // 본문 링크의 href 는 base 를 붙여 나온다
    const guard = await page.evaluate((href) => {
      const vis = (a) => a.getClientRects().length > 0 && getComputedStyle(a).visibility !== 'hidden';
      const links = [...document.querySelectorAll(`a[href="${href}"]`)];
      return {
        sidebar: links.filter((a) => a.closest('nav.sidebar')).map(vis),
        pager: links.filter((a) => a.closest('.pagination-links')).map(vis),
        body: links.filter((a) => a.closest('.sl-markdown-content')).length,
      };
    }, KEY_HREF);
    if (!guard.sidebar.length || guard.sidebar.some(Boolean)) problems.push(`시험 중 사이드바의 정답·해설 링크가 보임 ${JSON.stringify(guard)}`);
    if (!guard.pager.length || guard.pager.some(Boolean)) problems.push(`시험 중 다음 페이지(정답·해설) 링크가 보임 ${JSON.stringify(guard)}`);
    if (guard.body) {
      await tabUntil(focusIs, `.sl-markdown-content a[href="${KEY_HREF}"]`, { back: true });
      await press('Enter');
      const asked = await page.waitForSelector('.guide-dialog[open]', { timeout: 2000 }).then(() => true, () => false);
      if (!asked) problems.push('시험 중 본문의 정답·해설 링크: 확인 상자가 뜨지 않음');
      else {
        await press('Enter'); // 초점은 "열지 않기"
        await page.waitForSelector('.guide-dialog', { state: 'detached' });
      }
      if (!page.url().endsWith('/mock-exam/questions/')) problems.push(`시험 중 정답·해설로 이동해 버림: ${page.url()}`);
    }
    await page.evaluate(() => document.activeElement?.blur());
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
    // 제출이 끝나면 숨겼던 링크가 돌아온다
    if (!(await page.evaluate(() => [...document.querySelectorAll('nav.sidebar a[href$="/mock-exam/answer-key/"], .pagination-links a[href$="/mock-exam/answer-key/"]')].every((a) => a.getClientRects().length > 0 || a.closest('details:not([open])')))))
      problems.push('제출 뒤에도 정답·해설 링크가 숨어 있음');
    // 지난 응시 기록: 이번 제출이 화면 결과와 같은 점수로 한 줄 쌓였다
    const histRows = await page.$$eval('.exam-result [data-exam-history] tbody tr', (rs) => rs.map((r) => r.textContent));
    const tm = /전체 (\d+)\/(\d+) = ([\d.]+)%/.exec(totalText);
    if (histRows.length !== 1 || !histRows[0].includes(`${tm[1]}/${tm[2]} = ${tm[3]}%`)) problems.push(`응시 기록이 결과와 다름: ${JSON.stringify(histRows)} / ${totalText}`);
    const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('guide:exam:m14-mock-exam:history') || 'null'));
    if (stored?.records?.length !== 1 || stored.records[0].domains.length !== 4) problems.push(`응시 기록 저장값: ${JSON.stringify(stored)?.slice(0, 200)}`);
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
    // 응시 기록 지우기(확인 상자: 초점은 "취소" → Tab → "응시 기록 지우기" → Enter)
    await tabUntil(focusIs, '.exam-result [data-act=clear-history]', { back: true });
    await press('Enter');
    await page.waitForSelector('.guide-dialog[open]');
    await press('Tab');
    await press('Enter');
    await page.waitForSelector('.guide-dialog', { state: 'detached' });
    const left = await page.$$eval('.exam-result [data-exam-history] tbody tr', (rs) => rs.length);
    if (left !== 0) problems.push(`응시 기록 지우기 뒤 ${left}줄 남음`);
    const m = /전체 (\d+)\/(\d+) = ([\d.]+)%/.exec(totalText);
    const result = { totalOk: Number(m[1]), totalQ: Number(m[2]), pct: m[3], pass: verdictText.includes('통과') };
    if (out) {
      fs.mkdirSync(out, { recursive: true });
      await download.saveAs(path.join(out, 'keyboard-answers.txt'));
      fs.writeFileSync(path.join(out, 'keyboard-result.json'), JSON.stringify(result));
    }
    done.push('모의고사 65문항(복수 응답·표시·무응답 포함) 제출·검토·내보내기, 시험 중 정답 링크 가림·확인, 응시 기록 쌓기·지우기');
  }
} catch (e) {
  problems.push(`중단: ${e.message}`);
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
}

/* ---------------- 위젯 폴더의 keyboard.check.mjs(자동 발견) ---------------- */
{
  const st = spawnSync(process.execPath, ['tests/widget-checks-selftest.mjs'], { cwd: SITE_DIR, encoding: 'utf8' });
  console.log((st.stdout || st.stderr || '').trim().split('\n').at(-1));
  if (st.status !== 0) problems.push(`widget-checks-selftest 실패:\n${st.stdout}${st.stderr}`);
  const checks = discoverWidgetChecks();
  const { ran, problems: wp } = runWidgetChecks(checks, { port, pages, cwd: SITE_DIR });
  problems.push(...wp);
  console.log(`위젯 키보드 검사: 발견 ${checks.length}개, 대상 페이지에 있어 실행 ${ran.length}개, 실패 ${ran.filter((r) => !r.ok).length}개`);
  for (const r of ran.filter((x) => x.ok)) done.push(`위젯 ${r.widget}(keyboard.check.mjs)`);
}

console.log(`누른 키 ${keys}번`);
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log(`FAIL keyboard: ${problems.length}건`);
  process.exit(1);
}
console.log(`PASS keyboard: 키 입력만으로 조작 — ${done.length ? done.join(', ') : '대상에 조작할 퀴즈·위젯·시험이 없음'}`);
