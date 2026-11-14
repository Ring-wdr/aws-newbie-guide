// node --test src/widgets/m06/sqs-visibility-timeline/*.test.mjs   (site/ 에서. 위젯 시험 전부: pnpm test:widgets)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { simulate, normalize, formatDuration, describe, summarize, MAX_RECEIVES_SHOWN } from './model.mjs';
import { readVisibilityFacts, parseKoDuration, LESSON } from './facts.mjs';

const limits = { defaultSec: 30, minSec: 0, maxSec: 43200 };
const run = (o) => simulate(normalize({ visibility: 30, processing: 10, maxReceiveCount: 2, redrive: true, outcome: 'success', ...o }, limits));
const kinds = (sim) => sim.events.map((e) => `${e.kind}@${e.t}`);

test('처리 시간 < 타임아웃, 성공: 한 번 받고 삭제', () => {
  const s = run({});
  assert.equal(s.result, 'deleted');
  assert.deepEqual(kinds(s), ['receive@0', 'delete@10']);
  assert.equal(s.duplicates, 0);
  assert.equal(s.end, 10);
});

test('스스로 확인 1번: 처리 2분, 타임아웃 30초, 재드라이브 없음 → 중복 처리 후 삭제', () => {
  const s = run({ visibility: 30, processing: 120, redrive: false });
  assert.equal(s.result, 'deleted');
  // 0, 30, 60, 90초에 받고, 워커 1이 120초에 끝나 지운다(120초에 다시 보이는 것보다 먼저가 아니다 → 120초 수신 뒤 삭제)
  assert.deepEqual(kinds(s), ['receive@0', 'hidden-end@30', 'receive@30', 'hidden-end@60', 'receive@60', 'hidden-end@90', 'receive@90', 'hidden-end@120', 'receive@120', 'delete@120']);
  assert.equal(s.receives, 5);
  assert.equal(s.duplicates, 4);
  assert.equal(s.busyAtEnd, 4);
});

test('처리 시간 = 타임아웃이면 다시 보이는 쪽이 먼저(경계는 안전하지 않다)', () => {
  const s = run({ visibility: 30, processing: 30, redrive: false });
  assert.deepEqual(kinds(s).slice(0, 4), ['receive@0', 'hidden-end@30', 'receive@30', 'delete@30']);
  assert.equal(s.duplicates, 1);
});

test('lab02: 가시성 2초, maxReceiveCount=2, 항상 실패 → 두 번 받은 뒤 세 번째로 받으려는 순간 DLQ', () => {
  const s = run({ visibility: 2, processing: 1, maxReceiveCount: 2, outcome: 'fail' });
  assert.equal(s.result, 'dlq');
  assert.deepEqual(kinds(s), ['receive@0', 'fail@1', 'hidden-end@2', 'receive@2', 'fail@3', 'hidden-end@4', 'dlq@4']);
  assert.equal(s.receives, 2);
  assert.equal(s.busyAtEnd, 0);
});

test('재드라이브가 있어도 성공 전에 횟수를 넘기면 DLQ(처리 중인 워커가 남는다)', () => {
  const s = run({ visibility: 30, processing: 120, maxReceiveCount: 3 });
  assert.equal(s.result, 'dlq');
  assert.equal(s.end, 90);
  assert.equal(s.receives, 3);
  assert.equal(s.busyAtEnd, 3);
  assert.ok(s.lanes.every((l) => l.endKind === 'cut' && l.end === 90));
});

test('재드라이브 없음 + 항상 실패 → 상한까지 펼치고 반복 표시', () => {
  const s = run({ visibility: 5, processing: 1, redrive: false, outcome: 'fail' });
  assert.equal(s.result, 'looping');
  assert.equal(s.receives, MAX_RECEIVES_SHOWN);
  assert.equal(s.events.at(-1).kind, 'stop');
  assert.equal(s.events.filter((e) => e.kind === 'fail').length, MAX_RECEIVES_SHOWN);
});

test('타임아웃 0초: 받자마자 다시 보인다(끝이 있는지)', () => {
  const s = run({ visibility: 0, processing: 10, maxReceiveCount: 3 });
  assert.equal(s.result, 'dlq');
  assert.equal(s.end, 0);
  const t = run({ visibility: 0, processing: 0, redrive: false });
  assert.equal(t.result, 'looping');
});

test('사건 시각은 줄어들지 않는다', () => {
  for (const V of [0, 1, 2, 7, 30, 43200]) {
    for (const T of [0, 1, 5, 30, 31, 120, 50000]) {
      for (const outcome of ['success', 'fail']) {
        for (const redrive of [true, false]) {
          const s = run({ visibility: V, processing: T, outcome, redrive, maxReceiveCount: 4 });
          for (let i = 1; i < s.events.length; i++) assert.ok(s.events[i].t >= s.events[i - 1].t, `${V}/${T}/${outcome}/${redrive}`);
          assert.ok(s.receives <= MAX_RECEIVES_SHOWN);
          assert.ok(s.lanes.every((l) => l.end >= l.start && l.end <= s.end));
          assert.ok(summarize(s, { visibility: V, processing: T, maxReceiveCount: 4, outcome, redrive }).length > 10);
        }
      }
    }
  }
});

test('normalize: 범위 밖·숫자 아님은 맞춰진다', () => {
  const n = normalize({ visibility: 99999, processing: -3, maxReceiveCount: 0, redrive: 1, outcome: 'x' }, limits);
  assert.deepEqual(n, { visibility: 43200, processing: 0, maxReceiveCount: 1, redrive: true, outcome: 'success' });
  assert.equal(normalize({ visibility: 'abc' }, limits).visibility, 30);
  assert.equal(normalize({ visibility: '', maxReceiveCount: 50 }, limits).maxReceiveCount, MAX_RECEIVES_SHOWN);
});

test('formatDuration', () => {
  assert.equal(formatDuration(0), '0초');
  assert.equal(formatDuration(30), '30초');
  assert.equal(formatDuration(120), '2분');
  assert.equal(formatDuration(3725), '1시간 2분 5초');
  assert.equal(formatDuration(43200), '12시간');
});

test('describe: 사건마다 글로 설명한다', () => {
  const input = { visibility: 2, processing: 1, maxReceiveCount: 2, redrive: true, outcome: 'fail' };
  const s = simulate(input);
  const texts = s.events.map((e) => describe(e, input));
  assert.match(texts[0], /워커 1.*ReceiveCount=1/);
  assert.match(texts.at(-1), /3번째로 받으려는 순간.*maxReceiveCount\(2\)를 넘으므로.*DLQ/);
});

test('parseKoDuration', () => {
  assert.equal(parseKoDuration('30초'), 30);
  assert.equal(parseKoDuration('12시간'), 43200);
  assert.equal(parseKoDuration('2분'), 120);
  assert.throws(() => parseKoDuration('곧'));
});

test('원고에서 수치를 읽는다(실제 02-sqs.md)', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const text = fs.readFileSync(path.resolve(here, '../../../../..', LESSON), 'utf8');
  const f = readVisibilityFacts(text);
  assert.deepEqual({ d: f.timeout.defaultSec, lo: f.timeout.minSec, hi: f.timeout.maxSec }, { d: 30, lo: 0, hi: 43200 });
  assert.deepEqual({ p: f.selfCheck.processingSec, v: f.selfCheck.visibilitySec }, { p: 120, v: 30 });
  assert.deepEqual({ m: f.lab02.maxReceiveCount, v: f.lab02.visibilitySec }, { m: 2, v: 2 });
  // 줄 번호가 실제로 그 문장을 가리킨다
  const lines = text.split('\n');
  assert.match(lines[f.timeout.line - 1], /가시성 타임아웃 \| 30초/);
  assert.match(lines[f.lab02.visibilityLine - 1], /"VisibilityTimeout": "2"/);
});

test('원고 문장이 바뀌면 읽기가 실패한다(조용히 다른 수치를 쓰지 않는다)', () => {
  assert.throws(() => readVisibilityFacts('# 빈 원고\n'), /찾지 못했다/);
});

test('DLQ 문장: maxReceiveCount번 받은 뒤 다음 수신 시도에서 옮겨진다(경계, 원고 02-sqs.md:59·179)', () => {
  for (const M of [1, 2]) {
    const input = normalize({ visibility: 2, processing: 1, maxReceiveCount: M, redrive: true, outcome: 'fail' }, limits);
    const s = simulate(input);
    assert.equal(s.result, 'dlq');
    assert.equal(s.receives, M);
    const text = describe(s.events.at(-1), input);
    assert.ok(text.includes(`이미 ${M}번 받아 간 메시지를 ${M + 1}번째로 받으려는 순간`), text);
    assert.ok(text.includes(`maxReceiveCount(${M})를 넘으므로`), text);
    assert.doesNotMatch(text, new RegExp(`maxReceiveCount=${M} 초과`));
  }
});

test('타임아웃 0초 + 처리 성공(재드라이브 없음): 지워지지 않고 상한에서 멈추며, 문구가 동작과 같다', () => {
  const input = normalize({ visibility: 0, processing: 10, redrive: false, outcome: 'success' }, limits);
  const s = simulate(input);
  assert.equal(s.result, 'looping');
  assert.equal(s.receives, MAX_RECEIVES_SHOWN);
  assert.ok(!s.events.some((e) => e.kind === 'delete'));
  const text = summarize(s, input);
  assert.ok(text.includes(`${MAX_RECEIVES_SHOWN}번 받아 갈 때까지`), text);
  assert.ok(text.includes(`${MAX_RECEIVES_SHOWN}번에서 멈춘다`), text);
  assert.ok(text.includes('0초라 받자마자 다시 보여'), text);
  assert.doesNotMatch(text, /번 넘게/);
  // 타임아웃이 0초가 아니어도 처리 시간이 상한만큼 길면 같은 결과, 0초 설명은 붙지 않는다
  const input2 = normalize({ visibility: 1, processing: 120, redrive: false, outcome: 'success' }, limits);
  const t = summarize(simulate(input2), input2);
  assert.ok(t.includes('처리가 끝나기 전에') && !t.includes('0초라'), t);
  assert.match(describe(s.events.at(-1), input), new RegExp(`수신 ${MAX_RECEIVES_SHOWN}번에서 멈춘다`));
});
