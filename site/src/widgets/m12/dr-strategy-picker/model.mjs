// DR 전략 고르기 — 설명용 모형. 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(curriculum/m12-resilience-dr-migration/02-rto-rpo-dr-strategies.md):
//  - 02:30~35 전략 표: 전략마다 RPO·RTO 단계와 비용. 표의 순서가 비용 순서다(02:27 "비용 ↑ · RTO/RPO ↓").
//  - 02:20 "둘 다 짧을수록 비싸다."
//  - 02:75 워크시트 b 답: "웜 스탠바이도 요구는 만족하지만 '평소 비용 최소'에 어긋난다" → 요구를 만족하는 것 중 가장 싼 것.
//  - 스스로 확인 1의 답(facts.selfCheck.answerLine): 요구를 두 축(데이터=RPO, 컴퓨트=RTO)으로 나눠 본다.
//
// 모형의 가정(화면에도 적는다):
//  1. RPO·RTO는 원고 표의 단계(시간 / 수십 분 / 분 / 초~분 / 거의 0)로만 비교한다. 단계 사이의 경계(몇 분부터 "수십 분"인가)는
//     원고에 없어서 숫자로 바꾸지 않는다 — 요구도 단계로 고른다.
//  2. 전략은 "요구 단계보다 같거나 짧은" RPO·RTO를 내면 그 축을 만족한다.
//  3. 비용은 표의 순서(가장 낮음 → 가장 높음)로만 비교한다. 실제 금액은 규모·서비스에 따라 다르다.

/** 단계: rank가 작을수록 짧다(엄격하다). 원고 표에 나오는 글자 그대로. */
export const RPO_TIERS = [
  { id: 'zero', label: '거의 0', rank: 0 },
  { id: 'sec-min', label: '초~분', rank: 1 },
  { id: 'hours', label: '시간', rank: 2 },
];
export const RTO_TIERS = [
  { id: 'zero', label: '거의 0', rank: 0 },
  { id: 'min', label: '분', rank: 1 },
  { id: 'tens-min', label: '수십 분', rank: 2 },
  { id: 'hours', label: '시간', rank: 3 },
];

export function tierOf(label, tiers) {
  return tiers.find((t) => t.label === label) ?? null;
}
const rank = (id, tiers) => {
  const t = tiers.find((x) => x.id === id);
  if (!t) throw new Error(`알 수 없는 단계 ${id}`);
  return t.rank;
};

/** 전략 하나가 요구를 만족하나. */
export function check(strategy, req) {
  const rpoOk = rank(strategy.rpo, RPO_TIERS) <= rank(req.rpo, RPO_TIERS);
  const rtoOk = rank(strategy.rto, RTO_TIERS) <= rank(req.rto, RTO_TIERS);
  return { rpoOk, rtoOk, ok: rpoOk && rtoOk };
}

/** 비용 순으로 정렬해, 조건을 만족하는 첫 전략. 없으면 null. */
function cheapest(strategies, pred) {
  return [...strategies].sort((a, b) => a.costRank - b.costRank).find(pred) ?? null;
}

/**
 * @param strategies facts.strategies (id, rpo, rto, costRank …)
 * @param req { rpo: RPO 단계 id, rto: RTO 단계 id }
 * @returns { rows: [{ id, rpoOk, rtoOk, ok, pick, over }], pick, dataLevel, computeLevel, split }
 *   pick: 두 축을 다 만족하는 가장 싼 전략 id
 *   dataLevel: RPO만 보면 충분한 가장 싼 전략, computeLevel: RTO만 보면 충분한 가장 싼 전략
 *   split: 데이터(RPO) 쪽이 컴퓨트(RTO) 쪽보다 비싼 전략을 요구하는가 — 스스로 확인 1처럼 "데이터는 복제, 컴퓨트는 나중에"로 나눠 볼 만한 경우
 */
export function pick(strategies, req) {
  const p = cheapest(strategies, (s) => check(s, req).ok);
  const data = cheapest(strategies, (s) => check(s, req).rpoOk);
  const compute = cheapest(strategies, (s) => check(s, req).rtoOk);
  const rows = strategies.map((s) => {
    const c = check(s, req);
    return { id: s.id, ...c, pick: p?.id === s.id, over: c.ok && p && s.costRank > p.costRank };
  });
  return { rows, pick: p?.id ?? null, dataLevel: data?.id ?? null, computeLevel: compute?.id ?? null, split: Boolean(data && compute && data.costRank > compute.costRank) };
}

/** 원고 문장의 시간 표현을 단계로 읽는 모형 해석(워크시트·스스로 확인 미리 채우기용). 원고에 경계가 없어서 단계를 직접 고른다. */
export const MODEL_PRESET_REQ = {
  // a: "하루 멈춰도 되고, 어제 밤 백업까지만 있으면 된다"
  a: { rpo: 'hours', rto: 'hours' },
  // b: "30분 안에 복구, 잃어도 되는 주문은 1분 이하"
  b: { rpo: 'sec-min', rto: 'tens-min' },
  // c: "몇 분 안에 … 바로 응답" — RPO 요구는 원고에 없다(가장 넉넉한 단계로 둔다)
  c: { rpo: 'hours', rto: 'min' },
  // d: "사용자가 눈치채면 안 되고, 데이터 손실은 0에 가까워야"
  d: { rpo: 'zero', rto: 'zero' },
  // 스스로 확인 1: "RPO 5분, RTO 4시간"
  selfCheck: { rpo: 'sec-min', rto: 'hours' },
};
