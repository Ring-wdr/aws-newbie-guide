// CloudWatch 알람 상태 평가 — 설명용 모형(실제 CloudWatch·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(원고 curriculum/m10-monitoring-iac/01-cloudwatch-metrics-alarms.md):
//  - 01:34 알람은 INSUFFICIENT_DATA로 생긴다(lab02 출력 01:143 "State": "INSUFFICIENT_DATA"도 같다).
//  - 01:42 "최근 N개 구간 중 M개가 위반이면 ALARM" (M of N).
//  - 01:43 TreatMissingData: missing(판단 보류) · notBreaching(정상 취급) · breaching(위반 취급) · ignore(직전 상태 유지).
//  - 01:39 ALARM --> INSUFFICIENT_DATA: 데이터 없음 (TreatMissingData=missing).
//  - 01:44 액션은 상태가 바뀔 때 실행한다.
//  - 01:136 lab02는 --statistic Average 로 구간의 값을 평균 하나로 요약한다(01:159 이유의 900.0 = 800·900·1000의 평균).
//
// 모형의 가정(화면에도 그대로 적는다):
//  1. 구간(Period)마다 데이터 포인트는 하나(그 구간의 통계 값)이거나 없다(누락).
//  2. 평가는 구간이 끝날 때마다 한 번, 바로 그 구간까지의 최근 N개 구간만 본다. 실제 평가 지연(01:205 "분 단위 지연")은 없다.
//  3. 누락을 위반·정상으로 취급(breaching·notBreaching)하면 그 구간을 그 값으로 센다.
//     missing·ignore 이면 세지 않는다.
//  4. 판정: 위반 M개 이상 → ALARM. 아니면 셀 수 있는 데이터가 하나라도 있으면 OK.
//     하나도 없으면 missing → INSUFFICIENT_DATA, ignore → 직전 상태 유지.
//     창 안에 누락이 섞였을 때 실제 CloudWatch의 판정 규칙은 더 복잡하다(원고 범위 밖) — 모형은 창 안의 데이터만 센다.
//  5. 알람을 만든 뒤의 구간만 센다. N개가 차기 전에는 있는 구간만으로 판정한다.

export const STATES = ['OK', 'ALARM', 'INSUFFICIENT_DATA'];
export const TMD_KEYS = ['missing', 'notBreaching', 'breaching', 'ignore'];

/** 비교 연산자(실제 API 이름)와 화면 기호. 원고에는 GreaterThanThreshold만 나온다(01:137). */
export const OPS = {
  GreaterThanThreshold: { sym: '>', test: (v, t) => v > t },
  GreaterThanOrEqualToThreshold: { sym: '≥', test: (v, t) => v >= t },
  LessThanThreshold: { sym: '<', test: (v, t) => v < t },
  LessThanOrEqualToThreshold: { sym: '≤', test: (v, t) => v <= t },
};

/** 화면 범위(AWS 한도가 아니다): 평가 구간 수 N, 보여 줄 구간 수. */
export const MODEL_LIMITS = { maxN: 10, maxPoints: 12 };

/** 평균(Average 통계). lab02에서 게시한 값들을 구간 값 하나로 요약할 때 쓴다. */
export function average(values) {
  if (!values.length) throw new Error('빈 값 목록');
  return values.reduce((a, b) => a + b, 0) / values.length;
}

/**
 * "300, 900, -, 800" → [300, 900, null, 800]. 빈 칸·"-"·"누락"은 누락(null).
 * 숫자가 아닌 칸은 bad 에 모은다(화면이 알려 준다). 앞뒤 공백·끝의 쉼표 하나는 무시한다.
 */
export function parsePoints(s, max = MODEL_LIMITS.maxPoints) {
  const raw = String(s ?? '').trim();
  if (raw === '') return { points: [], bad: [], cut: false };
  const cells = raw.replace(/,\s*$/, '').split(',');
  const points = [];
  const bad = [];
  for (const c of cells) {
    const t = c.trim();
    if (t === '' || t === '-' || t === '누락') points.push(null);
    else if (/^-?\d+(\.\d+)?$/.test(t)) points.push(Number(t));
    else bad.push(t);
  }
  return { points: points.slice(0, max), bad, cut: points.length > max };
}

export function formatPoints(points) {
  return points.map((p) => (p === null ? '-' : String(p))).join(', ');
}

/** 입력을 모형이 다룰 수 있는 범위로 맞춘다. M은 1..N, N은 1..maxN. */
export function normalize(input) {
  const int = (v, lo, hi, dflt) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return dflt;
    return Math.min(hi, Math.max(lo, Math.round(n)));
  };
  const n = int(input.n, 1, MODEL_LIMITS.maxN, 1);
  const thr = Number(input.threshold);
  return {
    threshold: Number.isFinite(thr) ? thr : 0,
    op: OPS[input.op] ? input.op : 'GreaterThanThreshold',
    n,
    m: int(input.m, 1, n, 1),
    tmd: TMD_KEYS.includes(input.tmd) ? input.tmd : 'missing',
    periodSec: int(input.periodSec, 1, 86400, 60),
    initial: STATES.includes(input.initial) ? input.initial : 'INSUFFICIENT_DATA',
    points: (input.points ?? []).slice(0, MODEL_LIMITS.maxPoints).map((p) => (p === null || p === undefined || !Number.isFinite(Number(p)) ? null : Number(p))),
  };
}

/** 데이터 포인트 하나의 판정. 'breach' | 'ok' | 'missing'(셀 수 없음). treated: 누락을 TreatMissingData로 바꾼 것인가 */
export function classify(value, cfg) {
  if (value === null) {
    if (cfg.tmd === 'breaching') return { as: 'breach', treated: true };
    if (cfg.tmd === 'notBreaching') return { as: 'ok', treated: true };
    return { as: 'missing', treated: false };
  }
  return { as: OPS[cfg.op].test(value, cfg.threshold) ? 'breach' : 'ok', treated: false };
}

/**
 * 구간마다 알람을 평가한다.
 * @param cfg normalize 된 입력
 * @returns {{ steps: Array<{ i: number, t: number, value: number|null, as: string, treated: boolean, from: number, breaches: number, counted: number, state: string, prev: string, changed: boolean, why: string }>, final: string, changes: number }}
 */
export function evaluate(cfg) {
  const cls = cfg.points.map((v) => classify(v, cfg));
  const steps = [];
  let state = cfg.initial;
  for (let i = 0; i < cfg.points.length; i++) {
    const from = Math.max(0, i - cfg.n + 1);
    const win = cls.slice(from, i + 1);
    const breaches = win.filter((c) => c.as === 'breach').length;
    const counted = win.filter((c) => c.as !== 'missing').length;
    const prev = state;
    let why;
    if (breaches >= cfg.m) {
      state = 'ALARM';
      why = 'breach';
    } else if (counted > 0) {
      state = 'OK';
      why = 'ok';
    } else if (cfg.tmd === 'ignore') {
      why = 'ignore';
    } else {
      state = 'INSUFFICIENT_DATA';
      why = 'nodata';
    }
    steps.push({ i, t: (i + 1) * cfg.periodSec, value: cfg.points[i], as: cls[i].as, treated: cls[i].treated, from, breaches, counted, state, prev, changed: state !== prev, why });
  }
  return { steps, final: state, changes: steps.filter((s) => s.changed).length };
}

/** 위반·정상 예시 값(값 추가 단추용). 연산자 방향으로 임계값에서 delta만큼 떨어진 값. */
export function sampleValue(cfg, breach) {
  const delta = Math.max(1, Math.round(Math.abs(cfg.threshold) * 0.5));
  const up = cfg.op.startsWith('Greater');
  return breach === up ? cfg.threshold + delta : cfg.threshold - delta;
}

export function formatSec(sec) {
  if (sec % 3600 === 0) return `${sec / 3600}시간`;
  if (sec % 60 === 0) return `${sec / 60}분`;
  if (sec > 60) return `${Math.floor(sec / 60)}분 ${sec % 60}초`;
  return `${sec}초`;
}

const AS_LABEL = { breach: '위반', ok: '정상', missing: '누락(세지 않음)' };
export function pointLabel(step, cfg) {
  if (step.value === null) return step.treated ? `누락 → ${AS_LABEL[step.as]}로 취급(${cfg.tmd})` : `누락 → 세지 않음(${cfg.tmd})`;
  return `${step.value} ${OPS[cfg.op].sym} ${cfg.threshold}? ${step.as === 'breach' ? '예 → 위반' : '아니요 → 정상'}`;
}

/** 한 단계의 판정 이유(글). */
export function explain(step, cfg) {
  const span = step.from === step.i ? `구간 ${step.i + 1}` : `구간 ${step.from + 1}~${step.i + 1}`;
  const win = step.i - step.from + 1;
  const partial = win < cfg.n ? ` (아직 ${win}개뿐)` : '';
  const head = `최근 ${cfg.n}개 창 = ${span}${partial}: 위반 ${step.breaches}개, ALARM에 필요 ${cfg.m}개.`;
  let tail;
  if (step.why === 'breach') tail = ' 위반이 충분하다 → ALARM.';
  else if (step.why === 'ok') tail = ` 위반이 모자라고 셀 수 있는 데이터가 ${step.counted}개 있다 → OK.`;
  else if (step.why === 'ignore') tail = ` 셀 수 있는 데이터가 없다 → ignore: 직전 상태(${step.state}) 유지.`;
  else tail = ' 셀 수 있는 데이터가 없다 → INSUFFICIENT_DATA.';
  const change = step.changed ? ` 상태가 ${step.prev} → ${step.state}로 바뀐다(그 상태에 걸어 둔 액션이 실행된다).` : ' 상태가 그대로라 SNS 같은 액션은 다시 실행되지 않는다(Auto Scaling 액션만 예외로 1분마다 반복).';
  return head + tail + change;
}
