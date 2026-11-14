// node --test src/widgets/m13/purchase-mix/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cost, sweep, worksheetPlans, MODEL_LIMITS } from './model.mjs';
import { readMixFacts, LESSON } from './facts.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const text = fs.readFileSync(path.join(root, LESSON), 'utf8');
const f = readMixFacts(text);

test('원고 값을 읽는다', () => {
  assert.deepEqual([f.price, f.spDiscount, f.spotDiscount, f.hours], [0.1, 0.3, 0.7, 730]);
  assert.deepEqual([f.base.count, f.peak.count, f.peak.hours, f.batch.count, f.batch.hours], [6, 6, 180, 4, 240]);
  assert.deepEqual([f.officialMax.computeSP.pct, f.officialMax.spot.pct], [66, 90]);
});

test('워크시트 2의 세 안 = 모범 답안(642.00 / 443.40 / 642.00)', () => {
  for (const p of worksheetPlans(f)) assert.equal(cost(f, p.choice).total, f.answers[p.id].total, p.label);
});

test('(2)의 구성: SP 306.60 + 온디맨드 108.00 + 스팟 28.80, 낭비 0', () => {
  const r = cost(f, { commit: 6, batch: 'spot' });
  assert.deepEqual(r.parts, { sp: 306.6, od: 108, batch: 28.8 });
  assert.equal(r.unusedHours, 0);
  assert.equal(r.odHours, 6 * 180);
});

test('(3)은 피크용 6대분 약정 중 550시간씩을 쓰지 않는다(쓰지 않아도 낸다)', () => {
  const r = cost(f, { commit: 12, batch: 'spot' });
  assert.equal(r.unusedHours, 6 * (730 - 180));
  assert.equal(r.odHours, 0);
  assert.equal(r.unusedCost, 231);
});

test('약정 대수에 따른 합계: 바닥(6대)에서 가장 싸다', () => {
  const s = sweep(f, { batch: 'spot' });
  assert.equal(s.best, f.base.count);
  assert.equal(s.rows.length, MODEL_LIMITS.maxCommit + 1);
  // 6대까지는 1대마다 730×(0.10−0.07)=21.90씩 줄고, 그 뒤로는 730×0.07−180×0.10=33.10씩 는다
  assert.equal(Math.round((s.rows[5].total - s.rows[6].total) * 100) / 100, 21.9);
  assert.equal(Math.round((s.rows[7].total - s.rows[6].total) * 100) / 100, 33.1);
});

test('중단되면 안 되는 배치는 스팟을 고를 수 없다(온디맨드로 계산)', () => {
  const r = cost(f, { commit: 6, batch: 'spot', mustNotStop: true });
  assert.equal(r.batchMode, 'od');
  assert.equal(r.spotBlocked, true);
  assert.equal(r.parts.batch, 96);
  assert.equal(cost(f, { commit: 6, batch: 'od', mustNotStop: true }).spotBlocked, false);
});

test('경계: 약정 대수는 0~12로 맞춘다', () => {
  assert.equal(cost(f, { commit: -3, batch: 'od' }).k, 0);
  assert.equal(cost(f, { commit: 99, batch: 'od' }).k, MODEL_LIMITS.maxCommit);
  assert.equal(cost(f, { commit: 'x', batch: 'od' }).total, 642);
  assert.equal(cost(f, { commit: 6.4, batch: 'od' }).k, 6);
});

test('원고 숫자가 바뀌어 모범 답안과 어긋나면 실패', () => {
  const bad = text.replace('| **443.40** |', '| **443.41** |');
  assert.notEqual(bad, text);
  assert.throws(() => readMixFacts(bad), /≠ 원고/);
  assert.throws(() => readMixFacts('# 빈\n'), /찾지 못했다/);
});
