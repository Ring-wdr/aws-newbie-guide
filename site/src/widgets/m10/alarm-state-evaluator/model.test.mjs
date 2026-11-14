// node --test src/widgets/m10/alarm-state-evaluator/*.test.mjs   (site/ 에서. 위젯 시험 전부: pnpm test:widgets)
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

test('문서의 이른 ALARM 설명: N=M=3에서 - - - - X, - - - X - 는 곧바로 ALARM이 되지 않는다(missing)', () => {
  // 문서는 "ALARM이 아니다"라고만 말한다 — 그 밖의 상태는 단언하지 않는다
  assert.notEqual(evaluateRange(toRange('- - - - X'), 3, 3, 'missing').result, 'ALARM');
  assert.notEqual(evaluateRange(toRange('- - - X -'), 3, 3, 'missing').result, 'ALARM');
});

test('이른 ALARM의 "가장 오래된 위반"은 평가 범위 전체에서 찾는다(모형 가정 4 — 문서의 두 문장 중 "evaluation range")', () => {
  assert.equal(evaluateRange(toRange('- X - - -'), 3, 3, 'missing').result, 'ALARM');
  assert.equal(evaluateRange(toRange('- X - - -'), 3, 3, 'ignore').result, 'retain');
  const r = run({ n: 3, m: 3, points: [900, null, null, null] });
  // 900 하나뿐 — 첫 구간은 실제 1개 <M, 나이 1 <M 이라 ALARM 아님. 나이가 M(3)에 이르는 3구간에서 이른 ALARM
  assert.equal(r.steps[2].state, 'ALARM');
  assert.equal(r.steps[3].unknown, false);
});

test('검증 지적 재현: N=M=3, 900·900·900 뒤 데이터가 끊기면 ignore는 이전 상태(ALARM)를 계속 유지한다', () => {
  const r = run({ n: 3, m: 3, tmd: 'ignore', points: [900, 900, 900, null, null, null, null, null] });
  assert.deepEqual(states(r).slice(2), Array(6).fill('ALARM'));
  for (const s of r.steps.slice(3)) {
    assert.equal(s.state, 'ALARM');
    assert.equal(s.changed, false);
    assert.ok(s.outcomes.every((o) => o.result === 'retain' || o.result === 'ALARM'), JSON.stringify(s.outcomes.map((o) => o.result)));
  }
  // 범위 밖으로 다 빠지면(모두 누락) ignore → 직전 상태 유지, missing → INSUFFICIENT_DATA
  const last = r.steps.at(-1);
  assert.ok(last.outcomes.some((o) => o.result === 'retain'));
  const m = run({ n: 3, m: 3, tmd: 'missing', points: [900, 900, 900, null, null, null, null, null] });
  assert.equal(m.steps.at(-1).state, 'INSUFFICIENT_DATA');
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

test('하트비트(N=M=1, LessThanThreshold 1)가 끊기면: 범위 상한(N+2)을 지나 TreatMissingData대로 정착한다', () => {
  const base = { threshold: 1, op: 'LessThanThreshold', n: 1, m: 1, points: [1, 1, 1, null, null, null, null] };
  // 첫 누락 구간: 범위(2·3)에 실제 값 1이 남아 있어 OK
  for (const tmd of ['missing', 'ignore', 'breaching', 'notBreaching']) assert.equal(run({ ...base, tmd }).steps[3].state, 'OK', tmd);
  // 둘째 누락 구간: 범위 2에는 실제 값이 없고 범위 3에는 있다 → missing·breaching은 갈려서 판정하지 않음
  assert.equal(run({ ...base, tmd: 'missing' }).steps[4].state, null);
  assert.deepEqual(run({ ...base, tmd: 'missing' }).steps[4].possible.sort(), ['INSUFFICIENT_DATA', 'OK']);
  assert.deepEqual(run({ ...base, tmd: 'breaching' }).steps[4].possible.sort(), ['ALARM', 'OK']);
  // 셋째 누락 구간부터: 범위 상한(3)을 지나 실제 값이 빠진다 → 정착
  assert.deepEqual(states(run({ ...base, tmd: 'breaching' })).slice(5), ['ALARM', 'ALARM']);
  assert.deepEqual(states(run({ ...base, tmd: 'missing' })).slice(5), ['INSUFFICIENT_DATA', 'INSUFFICIENT_DATA']);
  assert.deepEqual(states(run({ ...base, tmd: 'notBreaching' })), ['OK', 'OK', 'OK', 'OK', 'OK', 'OK', 'OK']);
  // ignore: 직전 상태(OK)를 유지한다
  assert.deepEqual(states(run({ ...base, tmd: 'ignore' })), ['OK', 'OK', 'OK', 'OK', 'OK', 'OK', 'OK']);
});

test('1·1·1 뒤 누락 9구간: 상한을 지난 뒤로는 모두 판정한다(영영 미판정이 아니다)', () => {
  const pts = [1, 1, 1, ...new Array(9).fill(null)];
  for (const [tmd, want] of [['breaching', 'ALARM'], ['missing', 'INSUFFICIENT_DATA'], ['notBreaching', 'OK'], ['ignore', 'OK']]) {
    const r = run({ threshold: 1, op: 'LessThanThreshold', n: 1, m: 1, tmd, points: pts });
    assert.ok(r.steps.slice(5).every((s) => s.state === want), tmd);
    assert.ok(r.undecided <= 1, `${tmd}: 미판정 ${r.undecided}`);
  }
  // N=3, M=3이어도 상한(5)을 지나면 정착
  const r3 = run({ n: 3, m: 3, tmd: 'missing', points: [900, 900, 900, ...new Array(6).fill(null)] });
  assert.equal(r3.final, 'INSUFFICIENT_DATA');
});

test('ignore: 미판정 구간 뒤에도 직전 상태가 하나로 모이면 판정한다', () => {
  const r = run({ n: 1, m: 1, tmd: 'ignore', points: [900, null, null, null] });
  assert.deepEqual(states(r), ['ALARM', 'ALARM', 'ALARM', 'ALARM']);
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
