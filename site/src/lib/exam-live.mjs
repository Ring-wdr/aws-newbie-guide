// 모의고사 진행 상태가 "아직 진행 중"인지 — 시험 중 정답 링크 가리기(src/scripts/exam-guard.ts)가 쓴다. 순수 함수.
// 타이머는 시험 페이지가 열려 있는 동안만 줄어들므로, 시작만 하고 떠나면 phase 가 'running' 으로 남아 정답 링크가
// 끝없이 숨는다. 그래서 마지막으로 저장한 시각(lastActiveAt) + 남은 시간 = "종료 예정 시각"에서 STALE_AFTER_MS 가
// 더 지난 진행 상태는 버려진 것으로 보고 가리지 않는다. 시험 페이지를 다시 열면 그대로 이어서 풀 수 있다(상태는 지우지 않는다).
// 단위 시험: exam-live.test.mjs

/** 종료 예정 시각 뒤 이만큼 지나면 버려진 시험으로 본다. */
export const STALE_AFTER_MS = 24 * 60 * 60 * 1000;

/**
 * @param {unknown} s 저장값(guide:exam:m14-mock-exam)
 * @param {number} now Date.now()
 * @returns {'idle' | 'running' | 'stale' | 'submitted'}
 */
export function examLiveState(s, now) {
  if (!s || typeof s !== 'object') return 'idle';
  const phase = /** @type {any} */ (s).phase;
  if (phase !== 'running') return phase === 'submitted' ? 'submitted' : 'idle';
  const at = Number(/** @type {any} */ (s).lastActiveAt);
  // 저장 시각이 없는 옛 저장값은 판단할 수 없으므로 진행 중으로 둔다(시험 페이지를 한 번 열면 시각이 생긴다).
  if (!Number.isFinite(at) || at <= 0) return 'running';
  const left = Math.max(0, Number(/** @type {any} */ (s).remainingMs) || 0);
  return now > at + left + STALE_AFTER_MS ? 'stale' : 'running';
}
