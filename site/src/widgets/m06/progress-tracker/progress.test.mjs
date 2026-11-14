// node --test 'src/widgets/m06/**/*.test.mjs'
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModuleItems, countQuizQuestions, sanitize, toggle, computeProgress, quizGradedCount, QUIZ_STATE_KEY, STORAGE_KEY } from './progress.mjs';

const MOD = 'curriculum/m06-integration-messaging';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
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
