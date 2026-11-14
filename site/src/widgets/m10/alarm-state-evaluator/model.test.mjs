// node --test src/widgets/m10/alarm-state-evaluator/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluate, normalize, classify, parsePoints, formatPoints, sampleValue, average, explain, formatSec, MODEL_LIMITS } from './model.mjs';
import { readAlarmFacts, LESSON } from './facts.mjs';

const run = (o) => evaluate(normalize({ threshold: 500, op: 'GreaterThanThreshold', n: 3, m: 2, tmd: 'missing', periodSec: 60, ...o }));
const states = (r) => r.steps.map((s) => s.state);

test('M of N: 순간 튀는 값 하나로는 ALARM이 아니다, 3개 중 2개면 ALARM', () => {
  const r = run({ points: [300, 900, 300, 300, 800, 850] });
  assert.deepEqual(states(r), ['OK', 'OK', 'OK', 'OK', 'OK', 'ALARM']);
  assert.equal(r.steps[5].breaches, 2);
  assert.equal(r.changes, 2); // INSUFFICIENT_DATA→OK, OK→ALARM
});

test('경계: 임계값과 같은 값은 GreaterThanThreshold에서 위반이 아니고 GreaterThanOrEqualToThreshold에서는 위반', () => {
  assert.equal(classify(500, normalize({ threshold: 500, op: 'GreaterThanThreshold' })).as, 'ok');
  assert.equal(classify(500, normalize({ threshold: 500, op: 'GreaterThanOrEqualToThreshold' })).as, 'breach');
  assert.equal(classify(1, normalize({ threshold: 1, op: 'LessThanThreshold' })).as, 'ok');
  assert.equal(classify(1, normalize({ threshold: 1, op: 'LessThanOrEqualToThreshold' })).as, 'breach');
});

test('경계: 위반 수가 정확히 M이면 ALARM, M-1이면 OK', () => {
  assert.equal(run({ n: 3, m: 2, points: [900, 900] }).final, 'ALARM');
  assert.equal(run({ n: 3, m: 2, points: [900, 100, 100] }).final, 'OK');
  assert.equal(run({ n: 3, m: 3, points: [900, 900, 100] }).final, 'OK');
});

test('창 밖으로 밀려난 위반은 세지 않는다(ALARM → OK 회복)', () => {
  const r = run({ n: 2, m: 2, points: [900, 900, 100, 100] });
  assert.deepEqual(states(r), ['OK', 'ALARM', 'OK', 'OK']);
  assert.equal(r.steps[2].from, 1);
});

test('처음 상태는 INSUFFICIENT_DATA, 데이터가 없으면 그대로', () => {
  const r = run({ points: [null, null] });
  assert.deepEqual(states(r), ['INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
  assert.equal(r.changes, 0);
  assert.equal(run({ points: [] }).final, 'INSUFFICIENT_DATA');
});

test('TreatMissingData 네 가지: 데이터가 끊긴 하트비트(LessThanThreshold 1, N=M=1)', () => {
  const pts = [1, 1, null, null];
  const base = { threshold: 1, op: 'LessThanThreshold', n: 1, m: 1, points: pts };
  assert.deepEqual(states(run({ ...base, tmd: 'missing' })), ['OK', 'OK', 'INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
  assert.deepEqual(states(run({ ...base, tmd: 'breaching' })), ['OK', 'OK', 'ALARM', 'ALARM']);
  assert.deepEqual(states(run({ ...base, tmd: 'notBreaching' })), ['OK', 'OK', 'OK', 'OK']);
  assert.deepEqual(states(run({ ...base, tmd: 'ignore' })), ['OK', 'OK', 'OK', 'OK']);
});

test('ignore: ALARM 중에 데이터가 끊기면 ALARM 유지, missing이면 INSUFFICIENT_DATA로(01:39)', () => {
  const pts = [900, null, null];
  assert.deepEqual(states(run({ n: 1, m: 1, tmd: 'ignore', points: pts })), ['ALARM', 'ALARM', 'ALARM']);
  assert.deepEqual(states(run({ n: 1, m: 1, tmd: 'missing', points: pts })), ['ALARM', 'INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
  const r = run({ n: 1, m: 1, tmd: 'ignore', points: [null] });
  assert.equal(r.final, 'INSUFFICIENT_DATA'); // 직전 상태 = 처음 상태
  assert.equal(r.steps[0].why, 'ignore');
});

test('누락이 섞인 창: missing은 남은 데이터로 판정, breaching은 누락을 위반으로 센다', () => {
  assert.equal(run({ n: 3, m: 2, tmd: 'missing', points: [900, null, null] }).final, 'OK');
  assert.equal(run({ n: 3, m: 2, tmd: 'breaching', points: [900, null, 100] }).final, 'ALARM');
  assert.equal(run({ n: 3, m: 2, tmd: 'notBreaching', points: [900, null, null] }).final, 'OK');
});

test('normalize: M은 N을 넘지 않고, N은 화면 범위 안', () => {
  const c = normalize({ n: 2, m: 5 });
  assert.equal(c.m, 2);
  assert.equal(normalize({ n: 99 }).n, MODEL_LIMITS.maxN);
  assert.equal(normalize({ n: 0, m: 0 }).n, 1);
  assert.equal(normalize({ n: 'x' }).n, 1);
  assert.equal(normalize({ op: 'Nope', tmd: 'nope' }).op, 'GreaterThanThreshold');
  assert.equal(normalize({ tmd: 'nope' }).tmd, 'missing');
  assert.equal(normalize({ points: new Array(20).fill(1) }).points.length, MODEL_LIMITS.maxPoints);
});

test('parsePoints: 빈 칸·"-"·"누락"은 누락, 숫자가 아니면 bad', () => {
  assert.deepEqual(parsePoints('300, 900, -, , 누락, 800,').points, [300, 900, null, null, null, 800]);
  assert.deepEqual(parsePoints('  ').points, []);
  assert.deepEqual(parsePoints('1, abc, 2').bad, ['abc']);
  assert.deepEqual(parsePoints('-5, 2.5').points, [-5, 2.5]);
  assert.equal(parsePoints(new Array(13).fill('1').join(',')).cut, true);
  assert.equal(formatPoints([1, null, 3]), '1, -, 3');
});

test('sampleValue: 연산자 방향에 맞는 위반·정상 값', () => {
  const g = normalize({ threshold: 500, op: 'GreaterThanThreshold' });
  assert.equal(classify(sampleValue(g, true), g).as, 'breach');
  assert.equal(classify(sampleValue(g, false), g).as, 'ok');
  const l = normalize({ threshold: 1, op: 'LessThanThreshold' });
  assert.equal(sampleValue(l, true), 0);
  assert.equal(classify(sampleValue(l, false), l).as, 'ok');
  const z = normalize({ threshold: 0, op: 'LessThanOrEqualToThreshold' });
  assert.equal(classify(sampleValue(z, true), z).as, 'breach');
  assert.equal(classify(sampleValue(z, false), z).as, 'ok');
});

test('explain·formatSec', () => {
  const cfg = normalize({ threshold: 500, n: 3, m: 2, points: [900, 900] });
  const r = evaluate(cfg);
  assert.match(explain(r.steps[0], cfg), /아직 1개뿐.*OK.*INSUFFICIENT_DATA → OK/);
  assert.match(explain(r.steps[1], cfg), /위반 2개.*ALARM/);
  assert.equal(formatSec(10), '10초');
  assert.equal(formatSec(300), '5분');
  assert.equal(formatSec(90), '1분 30초');
});

test('원고 읽기: lab02 값과 이유가 모형과 맞는다', () => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
  const f = readAlarmFacts(fs.readFileSync(path.join(root, LESSON), 'utf8'));
  assert.equal(f.lab02.initialState, 'INSUFFICIENT_DATA');
  assert.equal(f.lab02.statistic, 'Average');
  assert.deepEqual([f.lab02.n, f.lab02.m, f.lab02.threshold, f.lab02.op, f.lab02.tmd], [1, 1, 500, 'GreaterThanThreshold', 'missing']);
  // lab02의 이유 "1 out of the last 1 datapoints [900.0" = 게시한 값의 평균
  assert.equal(average(f.lab02.values), f.lab02.reason.datapoint);
  const r = evaluate(normalize({ ...f.lab02, initial: f.lab02.initialState, points: [average(f.lab02.values)] }));
  assert.equal(r.final, 'ALARM');
  assert.equal(r.steps[0].breaches, f.lab02.reason.breaching);
  assert.equal(r.steps[0].i - r.steps[0].from + 1, f.lab02.reason.of);
  assert.equal(f.heartbeat.tmd, 'breaching');
  assert.equal(f.heartbeat.periodSec, 60);
  assert.deepEqual(Object.keys(f.tmd.labels).sort(), ['breaching', 'ignore', 'missing', 'notBreaching']);
  assert.deepEqual(f.periods.highRes, [10, 30]);
});

test('원고 읽기: 문장이 바뀌면 실패한다', () => {
  assert.throws(() => readAlarmFacts('# 빈 원고\n'), /찾지 못했다/);
});
