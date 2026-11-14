// Auto Scaling "이 지표 값이면 몇 대?" — 설명용 모형(실제 Auto Scaling·에뮬레이터 실행이 아니다. 에뮬레이터는 조정 정책이 501).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
// 계산은 원고의 채점기 curriculum/m03-compute-scaling/sdk/scaling_worksheet.py와 같은 규칙이다:
//  - 대상 추적: 필요 대수 = ⌈현재 대수 × 현재 지표 ÷ 목표값⌉, min/max로 자른다(06-auto-scaling.md:291 근사식 — AWS는 정확한 식을 공개하지 않는다)
//  - 단계 조정: 경보 임계값을 넘은 "폭"으로 단계를 고른다. 하한 포함·상한 미포함(06-auto-scaling.md:216 "60 이상 80 미만이면 +1, 80 이상이면 +3")
//  - 단순 조정: 한 번 조정하면 쿨다운이 끝날 때까지 다음 경보를 무시한다(06-auto-scaling.md:44·48)
//  - 예약 작업: 그 시각에 min/desired를 정해진 값으로 바꾼다(06-auto-scaling.md:45, 워크시트 10번)
//  - 조정 정책은 희망 용량을 바꾸지만 min/max를 넘지 않는다(06-auto-scaling.md:33)

/** 화면 입력 범위(AWS 한도가 아니라 모형 화면의 범위). */
export const MODEL_LIMITS = Object.freeze({ maxSize: 20, cpu: 100, requests: 100000, seconds: 3600 });

export const POLICIES = ['cpu', 'alb', 'step', 'simple', 'scheduled'];

/** 0 이상 정수로 맞춘다. 숫자가 아니면 dflt. */
const int = (v, lo, hi, dflt) => {
  if (v === '' || v === null || v === undefined) return dflt;
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, Math.round(n))) + 0; // + 0: -0을 0으로(화면에 "-0"이 나오지 않게)
};
const num = (v, lo, hi, dflt) => {
  if (v === '' || v === null || v === undefined) return dflt;
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, n)) + 0;
};

/**
 * 입력을 모형이 다루는 범위로 맞춘다. min ≤ max, min ≤ 현재 ≤ max가 되게 한다(ASG는 실제 대수를 그 범위에 둔다).
 * @param {object} raw
 * @param {{ min: number, max: number }} dflt 원고 워크시트 ASG의 min/max
 */
export function normalize(raw, dflt) {
  const policy = POLICIES.includes(raw?.policy) ? raw.policy : 'cpu';
  const min = int(raw?.min, 0, MODEL_LIMITS.maxSize, dflt.min);
  const max = Math.max(min, int(raw?.max, 0, MODEL_LIMITS.maxSize, Math.max(min, dflt.max)));
  const current = Math.min(max, Math.max(min, int(raw?.current, 0, MODEL_LIMITS.maxSize, min)));
  const metric = policy === 'alb' ? num(raw?.metric, 0, MODEL_LIMITS.requests, 0) : num(raw?.metric, 0, MODEL_LIMITS.cpu, 0);
  const secondAlarm = Boolean(raw?.secondAlarm);
  const secondAfter = int(raw?.secondAfter, 0, MODEL_LIMITS.seconds, 0);
  return { policy, min, max, current, metric, secondAlarm, secondAfter };
}

export const clamp = (n, min, max) => Math.max(min, Math.min(max, n));

/** 단계 조정에서 초과 폭이 들어가는 단계(하한 포함, 상한 미포함). null 하한·상한은 -∞·+∞. */
export function pickStep(breach, adjustments) {
  return adjustments.find((s) => (s.lower === null ? -Infinity : s.lower) <= breach && breach < (s.upper === null ? Infinity : s.upper)) ?? null;
}

/**
 * 새 희망 용량을 계산한다.
 * @param {ReturnType<typeof normalize>} x
 * @param {object} p 정책 값(facts.mjs가 정책 JSON에서 읽은 것): { cpu: {target}, alb: {target}, step: {threshold, adjustments}, simple: {adjust, cooldown}, scheduled: {min, desired} }
 * @returns {{ desired: number, raw: number, min: number, max: number, clampedBy: 'min' | 'max' | null, alarm: boolean, lines: string[], scaleIn: boolean }}
 */
export function compute(x, p) {
  const lines = [];
  let raw = x.current;
  let min = x.min;
  let alarm = true;
  switch (x.policy) {
    case 'cpu':
    case 'alb': {
      const target = x.policy === 'cpu' ? p.cpu.target : p.alb.target;
      const metric = x.policy === 'cpu' ? x.metric : x.current > 0 ? x.metric / x.current : 0;
      if (x.policy === 'alb') lines.push(`대상당 요청 = 전체 ${fmt(x.metric)} ÷ ${x.current}대 = ${fmt(metric)}`);
      // 부동소수 오차(예: 4 × 1875 ÷ 1000 = 7.500000001)로 한 대 더 올리지 않게 아주 작은 값을 뺀다(sdk/scaling_worksheet.py와 같다)
      raw = x.current === 0 ? 0 : Math.ceil((x.current * metric) / target - 1e-9);
      lines.push(`⌈${x.current}대 × ${fmt(metric)} ÷ ${fmt(target)}⌉ = ⌈${fmt((x.current * metric) / target)}⌉ = ${raw}대`);
      if (x.current === 0) lines.push('현재 0대라 지표가 없다(모형은 0대로 둔다).');
      break;
    }
    case 'step': {
      const breach = x.metric - p.step.threshold;
      if (breach < 0) {
        alarm = false;
        lines.push(`CPU ${fmt(x.metric)}% < 경보 임계값 ${p.step.threshold}% → 경보가 울리지 않는다`);
        break;
      }
      const s = pickStep(breach, p.step.adjustments);
      lines.push(`초과 폭 = ${fmt(x.metric)} − ${p.step.threshold} = ${fmt(breach)} → ${s ? `[${s.lower ?? '−∞'}, ${s.upper ?? '∞'}) 구간 → ${sign(s.adjust)}` : '맞는 단계 없음'}`);
      raw = x.current + (s ? s.adjust : 0);
      lines.push(`${x.current}대 ${sign(s ? s.adjust : 0)} = ${raw}대`);
      break;
    }
    case 'simple': {
      const first = x.current + p.simple.adjust;
      lines.push(`첫 경보: ${x.current}대 ${sign(p.simple.adjust)} = ${first}대(그 뒤 쿨다운 ${p.simple.cooldown}초)`);
      raw = first;
      if (x.secondAlarm) {
        // 두 번째 경보는 첫 조정을 min/max로 자른 대수에서 시작한다
        const afterFirst = clamp(first, x.min, x.max);
        if (x.secondAfter < p.simple.cooldown) {
          lines.push(`${x.secondAfter}초 뒤 두 번째 경보: ${x.secondAfter}초 < 쿨다운 ${p.simple.cooldown}초 → 무시`);
          raw = first;
        } else {
          raw = afterFirst + p.simple.adjust;
          lines.push(`${x.secondAfter}초 뒤 두 번째 경보: 쿨다운(${p.simple.cooldown}초)이 끝났다 → ${afterFirst}대 ${sign(p.simple.adjust)} = ${raw}대`);
        }
      }
      break;
    }
    case 'scheduled': {
      min = clamp(p.scheduled.min, 0, x.max);
      raw = Math.max(p.scheduled.desired, min);
      lines.push(`예약 작업 시각: min ${x.min} → ${min}, desired → ${p.scheduled.desired}`);
      if (p.scheduled.min > x.max) lines.push(`예약 작업의 min ${p.scheduled.min}이 max ${x.max}보다 커서 모형은 max로 자른다.`);
      break;
    }
    default:
      break;
  }
  const desired = clamp(raw, min, x.max);
  const clampedBy = raw > x.max ? 'max' : raw < min ? 'min' : null;
  if (clampedBy === 'max') lines.push(`${raw}대 > max ${x.max} → ${desired}대`);
  if (clampedBy === 'min') lines.push(`${raw}대 < min ${min} → ${desired}대`);
  const scaleIn = (x.policy === 'cpu' || x.policy === 'alb') && desired < x.current;
  return { desired, raw, min, max: x.max, clampedBy, alarm, lines, scaleIn };
}

/** 여러 정책이면 가장 큰 용량을 주는 정책을 따른다(06-auto-scaling.md:50, 워크시트 11번). */
export function combine(desiredList) {
  return Math.max(...desiredList);
}

export function fmt(n) {
  // 반올림이 -0을 만들면(예: -0.001) "-0"이 아니라 "0"으로 쓴다
  const v = (Number.isInteger(n) ? n : Math.round(n * 100) / 100) + 0;
  return v.toLocaleString('en-US');
}
const sign = (n) => (n >= 0 ? `+${n}` : `−${-n}`);

/**
 * 원고 워크시트(06-auto-scaling.md 293~306줄)의 문항. no: 문항 번호(정답 표에서 답을 읽어 시험이 맞춰 본다).
 * v의 수치는 문항 글에서 온 것이고(시험이 문항 글에 그 수치가 있는지 확인한다), min/max는 워크시트 ASG(facts.asg).
 * 9번(PercentChangeInCapacity)은 lab 정책 파일이 없어 넣지 않았다. 11번은 combine()으로 시험한다.
 */
export const PRESETS = [
  { no: 1, policy: 'cpu', v: { current: 4, metric: 75 }, mention: ['현재 4대', '75%'] },
  { no: 2, policy: 'cpu', v: { current: 6, metric: 90 }, mention: ['현재 6대', '90%'] },
  { no: 3, policy: 'cpu', v: { current: 6, metric: 30 }, mention: ['현재 6대', '30%'] },
  { no: 4, policy: 'alb', v: { current: 4, metric: 7500 }, mention: ['현재 4대', '7,500'] },
  { no: 5, policy: 'step', v: { current: 4, metric: 65 }, mention: ['현재 4대', '65%'] },
  { no: 6, policy: 'step', v: { current: 4, metric: 85 }, mention: ['85%'] },
  { no: 7, policy: 'step', v: { current: 4, metric: 55 }, mention: ['55%'] },
  { no: 8, policy: 'simple', v: { current: 4, secondAlarm: true, secondAfter: 120 }, mention: ['4대에서 경보', '120초 뒤'] },
  { no: 10, policy: 'scheduled', v: { current: 3 }, mention: ['현재 3대'] },
];

export function presetInput(preset, asg) {
  return normalize({ policy: preset.policy, min: asg.min, max: asg.max, metric: 0, secondAlarm: false, secondAfter: 0, ...preset.v }, asg);
}
