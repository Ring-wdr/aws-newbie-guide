// node --test 'src/lib/*.test.mjs'  (site/ 에서. 위젯 시험 전부: pnpm test:widgets)
import test from 'node:test';
import assert from 'node:assert/strict';
import { gradeExam } from './exam-core.mjs';
import { addRecord, sanitizeHistory, makeRecord, formatDuration, latestExam, HISTORY_MAX } from './exam-history.mjs';

const key = {
  1: { answer: ['A'], domain: 'D1' },
  2: { answer: ['B', 'C'], domain: 'D2' },
  3: { answer: ['D'], domain: 'D2' },
};
const consts = { domains: { D1: '보안', D2: '복원력' }, passPct: 72, total: 3 };

test('기록은 gradeExam 결과(= grade.py 규칙)를 그대로 담는다', () => {
  const r = gradeExam(key, { 1: ['A'], 2: ['B'] }, [], consts);
  const rec = makeRecord(r, { at: '2026-11-14T04:00:00.000Z', elapsedMs: 61_400 });
  assert.equal(rec.ok, 1);
  assert.equal(rec.total, 3);
  assert.equal(rec.pct, '33.3');
  assert.equal(rec.pass, false);
  assert.equal(rec.blank, 1);
  assert.deepEqual(rec.domains, [
    { domain: 'D1', ok: 1, total: 1 },
    { domain: 'D2', ok: 0, total: 2 },
  ]);
  assert.equal(rec.elapsedMs, 61_400);
});

test('최근 20회만, 최신이 앞', () => {
  let h = null;
  for (let i = 0; i < 25; i++) {
    h = addRecord(h, { at: new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString(), ok: i % 4, total: 3, pct: '0.0', pass: false, domains: [], elapsedMs: i });
  }
  assert.equal(h.records.length, HISTORY_MAX);
  assert.equal(h.records[0].elapsedMs, 24);
  assert.equal(h.records.at(-1).elapsedMs, 5);
});

test('깨진 저장값은 버린다', () => {
  assert.deepEqual(sanitizeHistory(null), { v: 1, records: [] });
  assert.deepEqual(sanitizeHistory({ records: 'x' }), { v: 1, records: [] });
  const h = sanitizeHistory({
    records: [
      { at: 'nope', ok: 1, total: 3, pct: '33.3' },
      { at: '2026-01-01T00:00:00Z', ok: 5, total: 3, pct: '1.0' },
      { at: '2026-01-01T00:00:00Z', ok: 1, total: 3, pct: '<b>' },
      { at: '2026-01-01T00:00:00Z', ok: 2, total: 3, pct: '66.7', pass: 'yes', domains: [{ domain: 'D1', ok: 9, total: 1 }, { domain: 'D2', ok: 1, total: 2 }] },
    ],
  });
  assert.equal(h.records.length, 1);
  assert.equal(h.records[0].pass, false);
  assert.deepEqual(h.records[0].domains, [{ domain: 'D2', ok: 1, total: 2 }]);
});

test('표시용 형식', () => {
  assert.equal(formatDuration(0), '0분 0초');
  assert.equal(formatDuration(3_723_000), '1시간 2분 3초');
  assert.equal(latestExam(null), null);
  const l = latestExam({ records: [{ at: '2026-01-01T00:00:00Z', ok: 50, total: 65, pct: '76.9', pass: true, domains: [], elapsedMs: 1 }] });
  assert.equal(l.count, 1);
  assert.equal(l.pass, true);
});
