// node --test src/widgets/m03/asg-scaling-calculator/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compute, normalize, combine, pickStep, presetInput, PRESETS, MODEL_LIMITS, fmt } from './model.mjs';
import { readScalingFacts, LESSON, POLICY_DIR, POLICY_FILES } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../../../..');
const lesson = fs.readFileSync(path.join(repo, LESSON), 'utf8');
const policies = Object.fromEntries(Object.entries(POLICY_FILES).map(([k, f]) => [k, fs.readFileSync(path.join(repo, POLICY_DIR, f), 'utf8')]));
const f = readScalingFacts(lesson, policies);
const run = (o) => compute(normalize({ min: 2, max: 10, ...o }, f.asg), f);

test('원고와 정책 파일에서 수치를 읽는다', () => {
  assert.deepEqual([f.asg.min, f.asg.max], [2, 10]);
  assert.equal(f.cpu.target, 50);
  assert.equal(f.alb.target, 1000);
  assert.equal(f.step.threshold, 60);
  assert.deepEqual(f.step.adjustments, [{ lower: 0, upper: 20, adjust: 1 }, { lower: 20, upper: null, adjust: 3 }]);
  assert.deepEqual([f.simple.adjust, f.simple.cooldown], [2, 300]);
  assert.deepEqual([f.scheduled.min, f.scheduled.desired], [4, 6]);
  assert.equal(f.cooldownDefault.sec, 300);
  const lines = lesson.split('\n');
  assert.match(lines[f.asg.line - 1], /min 2 \/ max 10/);
  assert.match(lines[f.step.thresholdLine - 1], /임계값 CPU 60%/);
  assert.match(lines[f.largestLine - 1], /가장 큰 용량/);
});

test('원고 워크시트 정답과 같다(1~8, 10번), 문항 글에 그 수치가 있다', () => {
  for (const p of PRESETS) {
    const r = compute(presetInput(p, f.asg), f);
    assert.equal(r.desired, f.answers[p.no].n, `${p.no}번: ${r.lines.join(' / ')}`);
    for (const m of p.mention) assert.ok(f.questions[p.no].text.includes(m), `${p.no}번 문항에 "${m}"이 없다: ${f.questions[p.no].text}`);
  }
});

test('워크시트 11번: 여러 정책이면 더 큰 용량', () => {
  assert.equal(combine([6, 8]), f.answers[11].n);
});

test('대상 추적: max로 자른다(2번), 축소 표시(3번), 정확히 나누어떨어지면 올리지 않는다', () => {
  const r2 = run({ policy: 'cpu', current: 6, metric: 90 });
  assert.deepEqual([r2.raw, r2.desired, r2.clampedBy], [11, 10, 'max']);
  const r3 = run({ policy: 'cpu', current: 6, metric: 30 });
  assert.equal(r3.scaleIn, true);
  assert.equal(run({ policy: 'cpu', current: 4, metric: 50 }).desired, 4); // 목표와 같으면 그대로
  assert.equal(run({ policy: 'cpu', current: 4, metric: 75 }).raw, 6); // ⌈6⌉ = 6(7이 아니다)
  assert.equal(run({ policy: 'alb', current: 4, metric: 7500 }).raw, 8); // ⌈7.5⌉
  assert.equal(run({ policy: 'alb', current: 4, metric: 8000 }).raw, 8); // ⌈8⌉ — 부동소수 오차로 9가 되지 않는다
});

test('대상 추적: min으로 자른다, 현재 0대', () => {
  const r = run({ policy: 'cpu', current: 4, metric: 1 });
  assert.deepEqual([r.raw, r.desired, r.clampedBy], [1, 2, 'min']);
  const z = compute(normalize({ policy: 'cpu', min: 0, max: 10, current: 0, metric: 80 }, f.asg), f);
  assert.equal(z.desired, 0);
});

test('단계 조정 경계: 임계값과 같으면 +1, 80은 +3(하한 포함, 상한 미포함), 미만은 경보 없음', () => {
  assert.equal(run({ policy: 'step', current: 4, metric: 60 }).desired, 5);
  assert.equal(run({ policy: 'step', current: 4, metric: 79.9 }).desired, 5);
  assert.equal(run({ policy: 'step', current: 4, metric: 80 }).desired, 7);
  const below = run({ policy: 'step', current: 4, metric: 59.9 });
  assert.deepEqual([below.desired, below.alarm], [4, false]);
  assert.equal(run({ policy: 'step', current: 9, metric: 95 }).desired, 10); // 12 → max
  assert.equal(pickStep(-1, f.step.adjustments), null);
  assert.equal(pickStep(20, f.step.adjustments).adjust, 3);
});

test('단순 조정: 쿨다운 안의 경보는 무시, 쿨다운과 같거나 지나면 다시 조정', () => {
  assert.equal(run({ policy: 'simple', current: 4 }).desired, 6);
  assert.equal(run({ policy: 'simple', current: 4, secondAlarm: true, secondAfter: 299 }).desired, 6);
  assert.equal(run({ policy: 'simple', current: 4, secondAlarm: true, secondAfter: 300 }).desired, 8);
  // 첫 조정이 max에서 잘리면 두 번째도 거기서 시작한다
  assert.equal(run({ policy: 'simple', current: 9, secondAlarm: true, secondAfter: 400 }).desired, 10);
});

test('예약 작업: min/desired를 바꾼다, max를 넘지 않는다', () => {
  const r = run({ policy: 'scheduled', current: 3 });
  assert.deepEqual([r.desired, r.min], [6, 4]);
  const small = run({ policy: 'scheduled', current: 2, max: 3 });
  assert.deepEqual([small.desired, small.min], [3, 3]);
});

test('normalize: min ≤ 현재 ≤ max, 범위 밖·숫자 아님은 맞춘다', () => {
  assert.deepEqual(normalize({ policy: 'x', min: 5, max: 3, current: 99, metric: 300 }, f.asg), { policy: 'cpu', min: 5, max: 5, current: 5, metric: 100, secondAlarm: false, secondAfter: 0 });
  assert.equal(normalize({ max: 999 }, f.asg).max, MODEL_LIMITS.maxSize);
  assert.equal(normalize({ min: 'abc' }, f.asg).min, 2);
  assert.equal(normalize({ policy: 'alb', metric: 1e9 }, f.asg).metric, MODEL_LIMITS.requests);
});

test('모든 정책·대수: 결과는 항상 min~max 안이고 설명 줄이 있다', () => {
  for (const policy of ['cpu', 'alb', 'step', 'simple', 'scheduled'])
    for (const [min, max] of [[0, 0], [0, 1], [2, 10], [5, 5], [1, 20]])
      for (let current = min; current <= max; current++)
        for (const metric of [0, 1, 49.5, 60, 80, 100, 7500]) {
          const r = compute(normalize({ policy, min, max, current, metric, secondAlarm: true, secondAfter: 300 }, f.asg), f);
          assert.ok(r.desired >= r.min && r.desired <= r.max, `${policy} ${min}/${max} ${current} ${metric}`);
          assert.ok(r.lines.length > 0);
        }
});

test('fmt', () => {
  assert.equal(fmt(7500), '7,500');
  assert.equal(fmt(1875), '1,875');
  assert.equal(fmt(10.8), '10.8');
  // -0 정리: 화면에 "-0"이 나오지 않는다
  assert.equal(fmt(-0), '0');
  assert.equal(fmt(-0.001), '0');
  assert.ok(Object.is(normalize({ min: '-0', max: 10, current: -0.2, metric: '-0' }, f.asg).current, 0));
  assert.ok(Object.is(normalize({ metric: '-0' }, f.asg).metric, 0));
  for (const policy of ['cpu', 'alb', 'step', 'simple', 'scheduled']) {
    const r = compute(normalize({ policy, min: 0, max: 5, current: 0, metric: '-0' }, f.asg), f);
    assert.ok(!r.lines.join(' ').includes('-0'), r.lines.join(' / '));
  }
});

test('원고·정책 파일이 바뀌어 읽지 못하면 실패한다', () => {
  assert.throws(() => readScalingFacts('# 빈 원고\n', policies), /찾지 못했다/);
  assert.throws(() => readScalingFacts(lesson, { ...policies, step: '{"AdjustmentType":"ExactCapacity"}' }), /읽지 못했다/);
});
