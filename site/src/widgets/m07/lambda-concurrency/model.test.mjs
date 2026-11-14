// node --test src/widgets/m07/lambda-concurrency/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalize, allocate, explain, MODEL_MAX_DEMAND, throttleFate } from './model.mjs';
import { readConcurrencyFacts, parseCount, LESSON, CHEATSHEET } from './facts.mjs';

const L = 1000;
const run = (o) => {
  const input = normalize({ reservedOn: false, reserved: 0, provisioned: 0, demandA: 0, demandB: 0, invokeA: 'sync', ...o }, L);
  const r = allocate(input, L);
  return { input, r, ex: explain(input, r) };
};

test('스스로 확인 3번: 예약 100, 요청 500 → 100 실행, 400 스로틀(동기 429)', () => {
  const { r, ex } = run({ reservedOn: true, reserved: 100, demandA: 500 });
  assert.equal(r.a.run, 100);
  assert.equal(r.a.throttled, 400);
  assert.equal(r.unreserved, 900);
  assert.equal(ex.verdict, 'throttled-a');
  assert.ok(ex.lines.some((l) => l.includes('400건') && l.includes('429 TooManyRequestsException')), ex.lines.join('\n'));
});

test('lab01: 예약 5 → 미예약 몫 995', () => {
  const { r } = run({ reservedOn: true, reserved: 5 });
  assert.equal(r.unreserved, 995);
  assert.equal(r.reservedIdle, 5);
  assert.equal(r.free, 995);
});

test('예약 없음 + A 폭주 → 나머지 함수가 스로틀(퀴즈 3번 상황)', () => {
  const { r, ex } = run({ demandA: 1200, demandB: 50 });
  assert.equal(r.a.run, 1000);
  assert.equal(r.a.throttled, 200);
  assert.equal(r.b.run, 0);
  assert.equal(r.b.throttled, 50);
  assert.equal(ex.verdict, 'throttled-both');
});

test('A에 예약 800 → 나머지 함수는 200칸에서 보호된다', () => {
  const { r, ex } = run({ reservedOn: true, reserved: 800, demandA: 1200, demandB: 50 });
  assert.equal(r.a.run, 800);
  assert.equal(r.a.throttled, 400);
  assert.equal(r.b.run, 50);
  assert.equal(r.b.throttled, 0);
  assert.equal(r.free, 150);
  assert.equal(ex.verdict, 'throttled-a');
});

test('예약 동시성 0 = 함수 정지(치트시트)', () => {
  const { r, ex } = run({ reservedOn: true, reserved: 0, demandA: 10, demandB: 10 });
  assert.equal(r.a.run, 0);
  assert.equal(r.a.throttled, 10);
  assert.equal(r.a.stopped, true);
  assert.equal(r.b.run, 10);
  assert.equal(ex.verdict, 'stopped');
  assert.ok(ex.lines.some((l) => l.includes('정지')));
});

test('경계: 요청 = 상한이면 스로틀 0, 상한 + 1이면 1', () => {
  assert.equal(run({ reservedOn: true, reserved: 100, demandA: 100 }).r.a.throttled, 0);
  assert.equal(run({ reservedOn: true, reserved: 100, demandA: 101 }).r.a.throttled, 1);
  assert.equal(run({ demandA: 1000 }).r.a.throttled, 0);
  assert.equal(run({ demandA: 1001 }).r.a.throttled, 1);
  // 예약 없이 A와 B 합이 정확히 한도
  const { r, ex } = run({ demandA: 600, demandB: 400 });
  assert.equal(r.b.throttled, 0);
  assert.equal(r.free, 0);
  assert.equal(ex.verdict, 'ok');
  assert.equal(run({ demandA: 600, demandB: 401 }).r.b.throttled, 1);
});

test('프로비저닝: 그 수까지는 웜, 넘는 실행은 콜드', () => {
  const { r } = run({ provisioned: 50, demandA: 80 });
  assert.deepEqual([r.a.warm, r.a.cold, r.a.idleProv], [50, 30, 0]);
  const t = run({ provisioned: 50, demandA: 20, demandB: 1000 });
  assert.deepEqual([t.r.a.warm, t.r.a.cold, t.r.a.idleProv], [20, 0, 30]);
  // 놀고 있는 프로비저닝 환경도 칸을 차지한다(모형 가정 A4) → B는 950칸
  assert.equal(t.r.poolForB, 950);
  assert.equal(t.r.b.throttled, 50);
  assert.ok(t.ex.lines.some((l) => l.includes('30개는 요청 없이')));
});

test('프로비저닝은 예약 동시성을 넘지 않게 맞춘다', () => {
  const { input, r } = run({ reservedOn: true, reserved: 10, provisioned: 50, demandA: 30 });
  assert.equal(input.provisioned, 10);
  assert.deepEqual([r.a.run, r.a.warm, r.a.cold, r.a.throttled], [10, 10, 0, 20]);
  assert.equal(r.reservedIdle, 0);
});

test('비동기 호출의 스로틀은 Lambda가 재시도', () => {
  const { ex } = run({ reservedOn: true, reserved: 1, demandA: 3, invokeA: 'async' });
  assert.ok(ex.lines.some((l) => l.includes('Lambda가 재시도')));
  assert.ok(!ex.lines.some((l) => l.includes('429')));
  assert.equal(throttleFate('sync', 429, 'TooManyRequestsException'), '429 TooManyRequestsException');
});

test('칸의 합은 언제나 계정 동시성과 같고 음수가 없다', () => {
  for (const reservedOn of [false, true]) {
    for (const reserved of [0, 1, 5, 100, 999, 1000]) {
      for (const provisioned of [0, 1, 50, 1000]) {
        for (const demandA of [0, 1, 99, 100, 101, 1000, 5000]) {
          for (const demandB of [0, 1, 900, 5000]) {
            const { input, r } = run({ reservedOn, reserved, provisioned, demandA, demandB });
            const vals = [r.a.warm, r.a.cold, r.a.idleProv, r.reservedIdle, r.b.run, r.free, r.a.throttled, r.b.throttled];
            assert.ok(vals.every((v) => v >= 0 && Number.isInteger(v)), JSON.stringify({ input, r }));
            assert.equal(r.a.warm + r.a.cold + r.a.idleProv + r.reservedIdle + r.b.run + r.free, L);
            assert.equal(r.a.run + r.a.throttled, input.demandA);
            assert.equal(r.b.run + r.b.throttled, input.demandB);
          }
        }
      }
    }
  }
});

test('normalize: 범위 밖·빈칸·숫자 아님', () => {
  const n = normalize({ reservedOn: 1, reserved: 5000, provisioned: 9999, demandA: -3, demandB: 'abc', invokeA: 'x' }, L);
  assert.deepEqual(n, { reservedOn: true, reserved: 1000, provisioned: 1000, demandA: 0, demandB: 0, invokeA: 'sync' });
  assert.equal(normalize({ demandA: 99999 }, L).demandA, MODEL_MAX_DEMAND);
  assert.equal(normalize({ demandA: '' }, L).demandA, 0);
  assert.equal(normalize({ provisioned: 1500 }, L).provisioned, 1000);
});

test('parseCount', () => {
  assert.equal(parseCount('1,000'), 1000);
  assert.equal(parseCount('5'), 5);
  assert.throws(() => parseCount('많이'));
});

test('원고에서 수치를 읽는다(실제 레슨·치트시트)', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const root = path.resolve(here, '../../../../..');
  const lesson = fs.readFileSync(path.join(root, LESSON), 'utf8');
  const cheat = fs.readFileSync(path.join(root, CHEATSHEET), 'utf8');
  const f = readConcurrencyFacts(lesson, cheat);
  assert.equal(f.accountLimit.value, 1000);
  assert.deepEqual(f.throttle.status, 429);
  assert.equal(f.throttle.error, 'TooManyRequestsException');
  assert.deepEqual([f.selfCheck.reserved, f.selfCheck.limit, f.selfCheck.demand], [100, 1000, 500]);
  assert.deepEqual([f.lab01.reserved, f.lab01.account, f.lab01.unreserved], [5, 1000, 995]);
  // 스스로 확인의 한도가 표의 한도와 같고, 모형이 lab01의 관찰값을 그대로 낸다
  assert.equal(f.selfCheck.limit, f.accountLimit.value);
  const input = normalize({ reservedOn: true, reserved: f.lab01.reserved }, f.lab01.account);
  assert.equal(allocate(input, f.lab01.account).unreserved, f.lab01.unreserved);
  const lines = lesson.split('\n');
  assert.match(lines[f.accountLimit.line - 1], /\| 동시성 \| 계정·리전당 기본 1,000 \|/);
  assert.match(lines[f.lab01.unreservedLine - 1], /"UnreservedConcurrentExecutions": 995/);
  assert.match(cheat.split('\n')[f.zeroStopsLine - 1], /0으로 두면 함수 정지/);
});

test('원고 문장이 바뀌면 읽기가 실패한다', () => {
  assert.throws(() => readConcurrencyFacts('# 빈 원고\n', ''), /찾지 못했다/);
});
