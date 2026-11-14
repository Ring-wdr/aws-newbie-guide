// node --test src/progress/ src/lib/  (전 모듈 진행 추적의 순수 함수와 원고 읽기)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModuleItems, countQuizQuestions, sanitize, toggle, setOne, computeProgress, quizGradedCount, QUIZ_STATE_KEY, STORAGE_KEY, storageKey } from './progress.mjs';

const MOD = 'curriculum/m06-integration-messaging';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const readme = fs.readFileSync(path.join(root, MOD, 'README.md'), 'utf8');
const items = readModuleItems(readme, MOD);

test('실제 M06 README에서 레슨 6 · 실습 8 · 퀴즈 1을 읽는다', () => {
  const count = (k) => items.filter((i) => i.kind === k).length;
  assert.equal(count('lesson'), 6);
  assert.equal(count('lab'), 8);
  assert.equal(count('quiz'), 1);
  assert.equal(items[1].id, 'lesson:02-sqs');
  assert.match(items[1].label, /^레슨 2\. SQS/);
  assert.equal(items[1].file, `${MOD}/02-sqs.md`);
  const lab = items.find((i) => i.id === 'lab:labs/lab02-sqs-dlq-redrive.sh');
  assert.ok(lab && /DLQ와 재처리/.test(lab.label));
  assert.ok(items.some((i) => i.id === 'lab:sdk/order_worker.py'));
  // 가리키는 파일이 실제로 있다
  for (const it of items) assert.ok(fs.existsSync(path.join(root, it.file)), it.file);
});

test('퀴즈 문항 수는 원고와 같다(quiz.md 머리말: 12문항)', () => {
  const quiz = fs.readFileSync(path.join(root, MOD, 'quiz.md'), 'utf8');
  assert.equal(countQuizQuestions(quiz), 12);
  assert.match(quiz, /12문항 중/);
});

test('README 형식이 바뀌면 조용히 넘어가지 않는다', () => {
  assert.throws(() => readModuleItems('# 빈 README\n', MOD), /"## 레슨"/);
  assert.throws(() => readModuleItems('## 레슨\n\n| # | 레슨 |\n|---|---|\n| 1 | 링크 없음 |\n\n## 실습\n', MOD), /링크를 찾지 못했다/);
});

test('sanitize: 모르는 id·참이 아닌 값·깨진 값은 버린다', () => {
  assert.deepEqual(sanitize(null, items), { v: 1, done: {} });
  assert.deepEqual(sanitize('x', items), { v: 1, done: {} });
  assert.deepEqual(sanitize({ done: { quiz: true, 'lesson:02-sqs': 'yes', 'lesson:99': true } }, items), { v: 1, done: { quiz: true } });
});

test('toggle과 computeProgress', () => {
  let s = sanitize(undefined, items);
  assert.deepEqual(computeProgress(items, s), { done: 0, total: 15, pct: 0, by: { lesson: { done: 0, total: 6 }, lab: { done: 0, total: 8 }, quiz: { done: 0, total: 1 } } });
  // 퀴즈 없는 모듈(M14)은 by에 quiz가 없다
  s = toggle(s, 'lesson:02-sqs', true);
  s = toggle(s, 'quiz', true);
  s = toggle(s, 'lab:labs/lab01-sqs-basics.sh', true);
  const p = computeProgress(items, s);
  assert.equal(p.done, 3);
  assert.equal(p.pct, 20);
  assert.deepEqual(p.by.lesson, { done: 1, total: 6 });
  s = toggle(s, 'quiz', false);
  assert.equal(computeProgress(items, s).by.quiz.done, 0);
  for (const it of items) s = toggle(s, it.id, true);
  assert.equal(computeProgress(items, s).pct, 100);
});

test('toggle은 원래 상태를 바꾸지 않는다', () => {
  const s = sanitize({ done: { quiz: true } }, items);
  toggle(s, 'quiz', false);
  assert.equal(s.done.quiz, true);
});

test('퀴즈 페이지 기록: 채점한 문항 수', () => {
  assert.equal(quizGradedCount(undefined), 0);
  assert.equal(quizGradedCount({ picked: { 1: 'B', 2: 'A' }, graded: { 1: true, 2: true, 3: true } }), 2);
  assert.equal(quizGradedCount({ picked: {}, graded: 'x' }), 0);
});

test('저장 키', () => {
  assert.equal(STORAGE_KEY, 'progress:m06');
  assert.equal(QUIZ_STATE_KEY('/curriculum/m06-integration-messaging/quiz/'), 'quiz:/curriculum/m06-integration-messaging/quiz');
});

test('setOne: 레슨 페이지는 다른 항목(모르는 id 포함)을 지우지 않는다', () => {
  const raw = { v: 1, done: { quiz: true, 'lab:x': true, junk: 'no' } };
  assert.deepEqual(setOne(raw, 'lesson:02-sqs', true), { v: 1, done: { quiz: true, 'lab:x': true, 'lesson:02-sqs': true } });
  assert.deepEqual(setOne(raw, 'quiz', false), { v: 1, done: { 'lab:x': true } });
  assert.deepEqual(setOne(null, 'quiz', true), { v: 1, done: { quiz: true } });
  assert.equal(raw.done.junk, 'no');
});

test('sanitize는 id 문자열 배열도 받는다(홈 요약)', () => {
  assert.deepEqual(sanitize({ done: { quiz: true, x: true } }, ['quiz', 'lesson:01']), { v: 1, done: { quiz: true } });
  assert.equal(storageKey('m14'), 'progress:m14');
});

// 15개 모듈 전부: 원고 README의 표 행 수를 이 시험이 따로 세어(다른 방법) 읽은 목록과 맞춘다.
const mods = fs.readdirSync(path.join(root, 'curriculum')).filter((d) => /^m\d\d-/.test(d)).sort();
function rowsUnder(text, heading) {
  const lines = text.split('\n');
  const i = lines.indexOf(`## ${heading}`);
  const out = [];
  for (const l of lines.slice(i + 1)) {
    if (l.startsWith('## ')) break;
    if (l.startsWith('|')) out.push(l);
    else if (out.length) break;
  }
  return out.slice(2);
}
test('15개 모듈 모두에서 레슨·실습 수가 README 표의 행 수와 같고, 가리키는 파일이 있다', () => {
  assert.equal(mods.length, 15);
  for (const d of mods) {
    const dir = `curriculum/${d}`;
    const text = fs.readFileSync(path.join(root, dir, 'README.md'), 'utf8');
    const quizQuestions = countQuizQuestions(fs.readFileSync(path.join(root, dir, 'quiz.md'), 'utf8'));
    const its = readModuleItems(text, dir, { quizQuestions });
    assert.equal(its.filter((i) => i.kind === 'lesson').length, rowsUnder(text, '레슨').length, `${d} 레슨`);
    assert.equal(its.filter((i) => i.kind === 'lab').length, rowsUnder(text, '실습').length, `${d} 실습`);
    for (const it of its) assert.ok(fs.existsSync(path.join(root, it.file)), `${d}: ${it.file}`);
    if (quizQuestions > 0) assert.equal(its.filter((i) => i.kind === 'quiz').length, 1, `${d} 퀴즈`);
    // 진행 추적 표시 줄이 README에 하나 있다(빈 줄로 둘러싼 독립 줄)
    const marks = text.split('\n').map((l, k, a) => (l === '<!-- widget: progress-tracker -->' ? [a[k - 1], a[k + 1]] : null)).filter(Boolean);
    assert.equal(marks.length, 1, `${d} 표시 줄`);
    assert.deepEqual(marks[0], ['', ''], `${d} 표시 줄 앞뒤 빈 줄`);
  }
});

test('링크 없는 워크시트 행(M12·M13)은 그 레슨 페이지를 가리킨다', () => {
  const d = 'curriculum/m12-resilience-dr-migration';
  const its = readModuleItems(fs.readFileSync(path.join(root, d, 'README.md'), 'utf8'), d, { quizQuestions: 13 });
  const ws = its.filter((i) => i.id.startsWith('lab:in-lesson:'));
  assert.equal(ws.length, 2);
  assert.equal(ws[0].file, `${d}/01-availability-and-spof.md`);
  assert.match(ws[1].label, /DR 전략.*레슨 2 안$/);
  assert.throws(() => readModuleItems('## 레슨\n\n| # | 레슨 |\n|---|---|\n| 1 | [a](./01-a.md) |\n\n## 실습\n\n| 실습 | 스크립트 | 레슨 |\n|---|---|---|\n| w | (안) | 9 |\n\n[quiz.md](./quiz.md)\n', d), /레슨 번호/);
});

test('M14: 퀴즈 대신 모의고사·캡스톤 자기 점검표', () => {
  const d = 'curriculum/m14-capstone-exam';
  const its = readModuleItems(fs.readFileSync(path.join(root, d, 'README.md'), 'utf8'), d, { quizQuestions: 0 });
  assert.deepEqual(
    its.filter((i) => i.kind === 'exam').map((i) => [i.id, i.file]),
    [
      ['exam:mock-exam', `${d}/mock-exam/questions.md`],
      ['exam:capstone-self-check', `${d}/capstone-self-check.md`],
    ],
  );
  assert.equal(its.filter((i) => i.kind === 'quiz').length, 0);
  const p = computeProgress(its, toggle(sanitize(null, its), 'exam:mock-exam', true));
  assert.deepEqual(p.by.exam, { done: 1, total: 2 });
  assert.equal(p.by.quiz, undefined);
});
