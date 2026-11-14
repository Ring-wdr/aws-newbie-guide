// node --test src/widgets/m10/alarm-state-evaluator/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluate, evaluateRange, normalize, classify, parsePoints, formatPoints, sampleValue, average, explain, formatSec, MODEL_LIMITS } from './model.mjs';
import { readAlarmFacts, LESSON } from './facts.mjs';

const run = (o) => evaluate(normalize({ threshold: 500, op: 'GreaterThanThreshold', n: 3, m: 2, tmd: 'missing', periodSec: 60, ...o }));
const states = (r) => r.steps.map((s) => s.state);

// AWS 문서 "Configuring how CloudWatch alarms treat missing data" > "How alarm state is evaluated when data is missing"의
// 예시 표 두 개를 그대로 옮긴 것. 평가 범위 5, Evaluation Periods 3. 0 = 정상, X = 위반, - = 누락(오른쪽이 가장 최근).
// 열 순서: Missing, Ignore, Breaching, Not breaching. RETAIN = "Retain current state".
const RETAIN = 'retain';
const DOC_TABLES = [
  {
    m: 3,
    rows: [
      ['0 - X - X', ['OK', 'OK', 'OK', 'OK']],
      ['0 - - - -', ['OK', 'OK', 'OK', 'OK']],
      ['- - - - -', ['INSUFFICIENT_DATA', RETAIN, 'ALARM', 'OK']],
      ['0 X X - X', ['ALARM', 'ALARM', 'ALARM', 'ALARM']],
      ['- - X - -', ['ALARM', RETAIN, 'ALARM', 'OK']],
    ],
  },
  {
    m: 2,
    rows: [
      ['0 - X - X', ['ALARM', 'ALARM', 'ALARM', 'ALARM']],
      ['0 0 X 0 X', ['ALARM', 'ALARM', 'ALARM', 'ALARM']],
      ['0 - X - -', ['OK', 'OK', 'ALARM', 'OK']],
      ['- - - - 0', ['OK', 'OK', 'ALARM', 'OK']],
      ['- - - X -', ['ALARM', RETAIN, 'ALARM', 'OK']],
    ],
  },
];
const DOC_TMD = ['missing', 'ignore', 'breaching', 'notBreaching'];
const toRange = (s) => s.split(' ').map((c) => (c === 'X' ? 'breach' : c === '0' ? 'ok' : null));

for (const t of DOC_TABLES) {
  for (const [pts, want] of t.rows) {
    test(`AWS 문서 표(N=3, M=${t.m}, 범위 5): ${pts}`, () => {
      DOC_TMD.forEach((tmd, k) => assert.equal(evaluateRange(toRange(pts), 3, t.m, tmd).result, want[k], `${pts} / ${tmd}`));
    });
  }
}

test('문서의 이른 ALARM 설명: N=M=3에서 - - - - X, - - - X - 는 ALARM이 아니다(missing)', () => {
  assert.equal(evaluateRange(toRange('- - - - X'), 3, 3, 'missing').result, 'OK');
  assert.equal(evaluateRange(toRange('- - - X -'), 3, 3, 'missing').result, 'OK');
});

test('문서로 정해지지 않는 경우: 이른 ALARM 후보 위반이 최근 N개 밖이면 판정하지 않음', () => {
  assert.equal(evaluateRange(toRange('- X - - -'), 3, 3, 'missing').result, 'unknown');
  const r = run({ n: 3, m: 3, points: [900, null, null, null] });
  // 범위 4: "X - - -"의 X는 나이 4 > N → 판정 안 함
  assert.equal(r.steps[3].state, null);
  assert.equal(r.steps[3].unknown, true);
  assert.match(explain(r.steps[3], normalize({ n: 3, m: 3 })), /판정하지 않는다/);
});

test('검증 지적 재현: N=M=3, 900·900·900·- → missing·ignore 모두 ALARM 유지', () => {
  for (const tmd of ['missing', 'ignore']) {
    const r = run({ n: 3, m: 3, tmd, points: [900, 900, 900, null] });
    assert.deepEqual(states(r).slice(2), ['ALARM', 'ALARM'], tmd);
    assert.equal(r.steps[3].changed, false);
  }
});

test('M of N: 순간 튀는 값 하나로는 ALARM이 아니다, 3개 중 2개면 ALARM', () => {
  const r = run({ points: [300, 900, 300, 300, 800, 850] });
  assert.deepEqual(states(r), ['OK', 'OK', 'OK', 'OK', 'OK', 'ALARM']);
  assert.equal(r.changes, 2); // INSUFFICIENT_DATA→OK, OK→ALARM
  assert.equal(r.undecided, 0);
});

test('경계: 임계값과 같은 값은 GreaterThanThreshold에서 위반이 아니고 GreaterThanOrEqualToThreshold에서는 위반', () => {
  assert.equal(classify(500, normalize({ threshold: 500, op: 'GreaterThanThreshold' })), 'ok');
  assert.equal(classify(500, normalize({ threshold: 500, op: 'GreaterThanOrEqualToThreshold' })), 'breach');
  assert.equal(classify(1, normalize({ threshold: 1, op: 'LessThanThreshold' })), 'ok');
  assert.equal(classify(1, normalize({ threshold: 1, op: 'LessThanOrEqualToThreshold' })), 'breach');
  assert.equal(classify(null, normalize({})), null);
});

test('경계: 실제 포인트가 N개 이상이면 최근 실제 N개 — 위반이 정확히 M이면 ALARM, M-1이면 OK', () => {
  assert.equal(run({ n: 3, m: 2, points: [100, 900, 900] }).final, 'ALARM');
  assert.equal(run({ n: 3, m: 2, points: [900, 100, 100] }).final, 'OK');
  assert.equal(run({ n: 3, m: 3, points: [900, 900, 100] }).final, 'OK');
});

test('창 밖으로 밀려난 위반은 세지 않는다(ALARM → OK 회복)', () => {
  const r = run({ n: 2, m: 2, points: [900, 900, 100, 100] });
  assert.deepEqual(states(r), ['OK', 'ALARM', 'OK', 'OK']);
});

test('처음 상태는 INSUFFICIENT_DATA, 데이터가 계속 없으면(missing) 그대로', () => {
  const r = run({ points: [null, null] });
  assert.deepEqual(states(r), ['INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
  assert.equal(r.changes, 0);
  assert.equal(run({ points: [] }).final, 'INSUFFICIENT_DATA');
});

test('하트비트(N=M=1, LessThanThreshold 1)가 끊기면: 평가 범위에 따라 갈리는 동안은 판정하지 않는다', () => {
  const base = { threshold: 1, op: 'LessThanThreshold', n: 1, m: 1, points: [1, 1, 1, null, null, null] };
  // 첫 누락 구간: 범위(2 이상)에 실제 값 1이 남아 있어 모든 길이에서 OK
  for (const tmd of ['missing', 'ignore', 'breaching', 'notBreaching']) assert.equal(run({ ...base, tmd }).steps[3].state, 'OK', tmd);
  // 그다음: 범위 길이에 따라 실제 값이 들어가기도(OK) 빠지기도 한다
  const miss = run({ ...base, tmd: 'missing' }).steps[4];
  assert.equal(miss.state, null);
  assert.deepEqual(miss.possible.sort(), ['INSUFFICIENT_DATA', 'OK']);
  const br = run({ ...base, tmd: 'breaching' }).steps[4];
  assert.deepEqual(br.possible.sort(), ['ALARM', 'OK']);
  // notBreaching은 어느 길이에서도 OK
  assert.deepEqual(states(run({ ...base, tmd: 'notBreaching' })), ['OK', 'OK', 'OK', 'OK', 'OK', 'OK']);
  // ignore: 실제 값이 범위에 있으면 OK, 없으면 직전 상태(OK) 유지 → 모두 OK
  assert.deepEqual(states(run({ ...base, tmd: 'ignore' })), ['OK', 'OK', 'OK', 'OK', 'OK', 'OK']);
});

test('처음부터 누락만 있으면 breaching은 ALARM, notBreaching은 OK, ignore는 처음 상태 유지', () => {
  const pts = [null, null];
  assert.deepEqual(states(run({ n: 1, m: 1, tmd: 'breaching', points: pts })), ['ALARM', 'ALARM']);
  assert.deepEqual(states(run({ n: 1, m: 1, tmd: 'notBreaching', points: pts })), ['OK', 'OK']);
  assert.deepEqual(states(run({ n: 1, m: 1, tmd: 'ignore', points: pts })), ['INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
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
  assert.equal(classify(sampleValue(g, true), g), 'breach');
  assert.equal(classify(sampleValue(g, false), g), 'ok');
  const l = normalize({ threshold: 1, op: 'LessThanThreshold' });
  assert.equal(sampleValue(l, true), 0);
  assert.equal(classify(sampleValue(l, false), l), 'ok');
  const z = normalize({ threshold: 0, op: 'LessThanOrEqualToThreshold' });
  assert.equal(classify(sampleValue(z, true), z), 'breach');
  assert.equal(classify(sampleValue(z, false), z), 'ok');
});

test('explain·formatSec', () => {
  const cfg = normalize({ threshold: 500, n: 3, m: 2, points: [900, 900] });
  const r = evaluate(cfg);
  assert.match(explain(r.steps[0], cfg), /실제 데이터 포인트가 1개로.*채운다.*→ OK.*INSUFFICIENT_DATA → OK/);
  assert.match(explain(r.steps[1], cfg), /위반 2개.*→ ALARM/);
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
  assert.equal(r.steps[0].longest.breaches, f.lab02.reason.breaching);
  assert.equal(f.lab02.n, f.lab02.reason.of);
  assert.equal(f.heartbeat.tmd, 'breaching');
  assert.equal(f.heartbeat.periodSec, 60);
  assert.deepEqual(Object.keys(f.tmd.labels).sort(), ['breaching', 'ignore', 'missing', 'notBreaching']);
  assert.deepEqual(f.periods.highRes, [10, 30]);
});

test('원고 읽기: 문장이 바뀌면 실패한다', () => {
  assert.throws(() => readAlarmFacts('# 빈 원고\n'), /찾지 못했다/);
});
