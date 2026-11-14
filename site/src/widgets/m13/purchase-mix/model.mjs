// 구매 옵션 섞기 — 설명용 모형(실제 AWS 가격·청구가 아니다). 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 수치와 규칙의 출처(curriculum/m13-cost-optimization/02-compute-cost.md, 값은 facts.mjs가 빌드 때 읽는다):
//  - 워크시트 2: 예시 단가 0.10 USD/시간, Savings Plans 할인 30%, 스팟 할인 70%(모두 원고의 "예시 숫자"), 한 달 730시간.
//    API 바닥 6대 × 730시간, 피크 추가 6대 × 180시간, 정산 배치 4대 × 240시간(중단되면 다시 돌리면 됨).
//  - 모범 답안: (1) 642.00 (2) 443.40 (3) 642.00. 모형은 이 세 값을 그대로 다시 낸다(시험·빌드에서 확인).
//  - 스스로 확인 2: 약정 금액은 다 쓰지 않아도 낸다("최소 지불 금액").
//  - 시험 포인트: "중단되면 안 됨" 조건이면 스팟을 지운다.
//
// 모형의 가정(화면에도 적는다):
//  1. Savings Plans 약정을 "k대를 한 달 내내 쓰는 금액"으로 둔다(k × 730시간 × 할인 단가). 실제 SP는 $/시간 약정이다.
//  2. 피크 6대는 한 달 180시간 동안 바닥 6대와 함께 돈다. 그 시간에는 12대, 나머지 시간에는 6대가 돈다.
//     시간마다 약정이 덮는 대수 = min(돌고 있는 대수, k), 남는 대수는 온디맨드.
//  3. 배치는 약정과 따로 계산한다(온디맨드 또는 스팟). 스팟 중단으로 다시 돌리는 시간은 넣지 않는다.
//  4. 모든 인스턴스가 같은 단가(m7i.large 예시)다.

export const MODEL_LIMITS = { maxCommit: 12 };

const round2 = (x) => Math.round(x * 100) / 100;

/**
 * @param f 원고 값 { price, spDiscount, spotDiscount, hours, base: {count, hours}, peak: {count, hours}, batch: {count, hours} }
 * @param choice { commit: 약정 대수 k, batch: 'od' | 'spot', mustNotStop: boolean }
 */
export function cost(f, choice) {
  const k = Math.max(0, Math.min(MODEL_LIMITS.maxCommit, Math.round(Number(choice.commit) || 0)));
  const spPrice = f.price * (1 - f.spDiscount);
  const spotPrice = f.price * (1 - f.spotDiscount);
  const peakHours = f.peak.hours;
  const quietHours = f.hours - peakHours;
  const busy = f.base.count + f.peak.count; // 피크 시간에 도는 대수
  const quiet = f.base.count;
  const covered = Math.min(busy, k) * peakHours + Math.min(quiet, k) * quietHours; // 약정이 덮은 인스턴스·시간
  const unusedHours = k * f.hours - covered; // 약정했지만 쓰지 않은 인스턴스·시간
  const odHours = (busy - Math.min(busy, k)) * peakHours + (quiet - Math.min(quiet, k)) * quietHours;
  const batchMode = choice.batch === 'spot' && !choice.mustNotStop ? 'spot' : 'od';
  const batchHours = f.batch.count * f.batch.hours;
  const parts = {
    sp: k * f.hours * spPrice,
    od: odHours * f.price,
    batch: batchHours * (batchMode === 'spot' ? spotPrice : f.price),
  };
  return {
    k,
    batchMode,
    spotBlocked: choice.batch === 'spot' && Boolean(choice.mustNotStop),
    covered,
    unusedHours,
    unusedCost: round2(unusedHours * spPrice),
    odHours,
    batchHours,
    parts: { sp: round2(parts.sp), od: round2(parts.od), batch: round2(parts.batch) },
    total: round2(parts.sp + parts.od + parts.batch),
  };
}

/** 약정 대수 0..maxCommit 마다 합계. 가장 싼 k(같으면 작은 k). */
export function sweep(f, choice) {
  const rows = [];
  for (let k = 0; k <= MODEL_LIMITS.maxCommit; k++) rows.push({ k, total: cost(f, { ...choice, commit: k }).total });
  const best = rows.reduce((a, b) => (b.total < a.total ? b : a));
  return { rows, best: best.k };
}

/** 워크시트 2의 세 안. */
export function worksheetPlans(f) {
  return [
    { id: '1', label: '(1) 전부 온디맨드', choice: { commit: 0, batch: 'od' } },
    { id: '2', label: '(2) 바닥 SP + 피크 온디맨드 + 배치 스팟', choice: { commit: f.base.count, batch: 'spot' } },
    { id: '3', label: '(3) 피크까지 12대를 SP로 + 배치 스팟', choice: { commit: f.base.count + f.peak.count, batch: 'spot' } },
  ];
}

export const usd = (x) => x.toFixed(2);
