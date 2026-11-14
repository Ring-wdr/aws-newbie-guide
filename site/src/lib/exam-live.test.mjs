// node --test 'src/lib/*.test.mjs'  (site/ 에서. 위젯 시험 전부: pnpm test:widgets)
import test from 'node:test';
import assert from 'node:assert/strict';
import { examLiveState, STALE_AFTER_MS } from './exam-live.mjs';

const H = 60 * 60 * 1000;

test('없음·시작 전·제출 뒤', () => {
  assert.equal(examLiveState(null, 0), 'idle');
  assert.equal(examLiveState('x', 0), 'idle');
  assert.equal(examLiveState({ phase: 'idle' }, 0), 'idle');
  assert.equal(examLiveState({ phase: 'submitted' }, 0), 'submitted');
});

test('진행 중: 종료 예정 시각 + 24시간까지는 진행 중', () => {
  const s = { phase: 'running', lastActiveAt: 1_000_000, remainingMs: 2 * H };
  assert.equal(STALE_AFTER_MS, 24 * H);
  assert.equal(examLiveState(s, 1_000_000), 'running');
  assert.equal(examLiveState(s, 1_000_000 + 2 * H + 24 * H), 'running');
  assert.equal(examLiveState(s, 1_000_000 + 2 * H + 24 * H + 1), 'stale');
});

test('일시 정지한 시험도 같은 기준(남은 시간 + 24시간)', () => {
  const s = { phase: 'running', paused: true, lastActiveAt: 5, remainingMs: 130 * 60 * 1000 };
  assert.equal(examLiveState(s, 5 + 130 * 60 * 1000 + 24 * H - 1), 'running');
  assert.equal(examLiveState(s, 5 + 130 * 60 * 1000 + 24 * H + 1), 'stale');
});

test('저장 시각이 없는 옛 저장값·이상한 값은 진행 중으로 둔다', () => {
  assert.equal(examLiveState({ phase: 'running', remainingMs: 0 }, 1e15), 'running');
  assert.equal(examLiveState({ phase: 'running', lastActiveAt: 'x' }, 1e15), 'running');
  assert.equal(examLiveState({ phase: 'running', lastActiveAt: 10, remainingMs: -5 }, 10 + 24 * H + 1), 'stale');
});
