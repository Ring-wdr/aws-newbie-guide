// CloudWatch 알람 상태 평가 — 설명용 모형(실제 CloudWatch·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(원고 줄 번호는 facts.mjs가 빌드 때 찾아 화면에 보인다 — 여기에는 적지 않는다):
//  - 원고 01-cloudwatch-metrics-alarms.md: 알람은 INSUFFICIENT_DATA로 생긴다(lab02 출력), M of N 정의,
//    TreatMissingData 네 값의 뜻, 액션은 상태가 바뀔 때 실행, lab02의 Average 통계.
//  - 누락이 섞였을 때의 판정은 원고에 없어서 AWS 문서를 따른다:
//    Amazon CloudWatch 사용 설명서 "Configuring how CloudWatch alarms treat missing data" 의
//    "How alarm state is evaluated when data is missing" 절과 "Avoiding premature transitions to alarm state" 절.
//    (1) CloudWatch는 N(Evaluation Periods)보다 많은 데이터 포인트를 가져온다 — 그 시간 폭이 "평가 범위(evaluation range)".
//        정확한 길이는 기간 길이와 해상도에 따라 다르고 문서는 예(N=3 → 5)만 든다.
//    (2) 평가 범위 안 실제 데이터 포인트가 N개 이상이면 가장 최근 실제 N개로 판정한다(TreatMissingData 안 씀).
//    (3) N개보다 적으면 모자란 만큼만 TreatMissingData 값으로 채우고, 범위 안 실제 포인트는 모두 넣어 판정한다.
//    (4) 이른 ALARM 규칙: 가장 오래된 위반 포인트가 M번째 이상 오래되었고 그보다 최근은 위반이거나 누락이면 ALARM.
//        문서의 두 문장이 "가장 오래된 위반"을 찾는 폭을 다르게 적는다 — 첫 문단은 "during the Evaluation Periods number of
//        data points"(최근 N개), M of N 문단은 "during the evaluation range"(평가 범위 전체). 모형은 뒤의 것(평가 범위)을 따른다.
//        두 해석은 최근 N개에 위반이 없고 그보다 오래된 범위 안에만 위반이 있을 때 갈린다(예: N=M=3, "X - - -").
//        문서의 표(model.test.mjs의 40칸)는 두 해석 모두에서 같다.
//    시험(model.test.mjs)이 문서의 예시 표 두 개의 모든 행 × TreatMissingData 네 값을 그대로 확인한다.
//
// 모형의 가정·한계(화면의 판정 옆에도 적는다):
//  1. 구간(Period)마다 데이터 포인트는 하나(그 구간의 통계 값)이거나 없다(누락). 첫 구간 앞에는 데이터가 없다.
//  2. 구간이 끝날 때마다 곧바로 평가한다(실제 평가 지연 없음). 슬라이딩 평가 창(기본값)만 다룬다.
//  3. 평가 범위 길이는 문서가 밝히지 않는다(예: Evaluation Periods 3 → 평가 범위 5). 범위는 유한하다(문서 표 1의
//     2행 설명: 다음 평가에도 누락이면 "that non-breaching data point will no longer be in the evaluation range").
//     모형은 문서의 예를 근거로 상한을 N+2(모형 값)로 두고 길이 N+1과 N+2로 판정해, 둘이 갈리면
//     "모형이 판정하지 않는다"고 하고 가능한 결과만 보여 준다.
//  4. 이른 ALARM 규칙의 "가장 오래된 위반"은 평가 범위 전체에서 찾는다(위 (4)의 해석). 그래서 N=M=3에서 900·900·900 뒤
//     데이터가 끊겨도 위반이 범위 안에 남아 있는 동안 missing은 ALARM, ignore는 직전 상태(ALARM)를 유지한다
//     (ignore는 이른 ALARM 대신 상태를 유지한다 — 문서 표의 "Retain current state").

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

/** 평가 범위 길이 후보(모형 값): N+1 ~ N+2. 근거는 AWS 문서의 예(Evaluation Periods 3 → 평가 범위 5). 실제 길이는 문서가 밝히지 않는다. */
export const MODEL_RANGE_EXTRA = { min: 1, max: 2 };

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

/** 데이터 포인트 하나: 'breach' | 'ok' | null(누락). */
export function classify(value, cfg) {
  if (value === null || value === undefined) return null;
  return OPS[cfg.op].test(value, cfg.threshold) ? 'breach' : 'ok';
}

/**
 * 평가 범위 하나로 한 번 판정한다(문서 규칙 (2)~(4)).
 * @param range 평가 범위의 포인트들, 오래된 것부터: 'breach' | 'ok' | null
 * @returns {{ result: 'OK'|'ALARM'|'INSUFFICIENT_DATA'|'retain'|'unknown', why: string, real: number, fill: number, breaches: number }}
 */
export function evaluateRange(range, n, m, tmd) {
  const real = range.filter((p) => p !== null);
  if (real.length >= n) {
    const breaches = real.slice(-n).filter((p) => p === 'breach').length;
    return { result: breaches >= m ? 'ALARM' : 'OK', why: 'real', real: real.length, fill: 0, breaches };
  }
  const fill = n - real.length;
  const realBreaches = real.filter((p) => p === 'breach').length;
  if (tmd === 'breaching' || tmd === 'notBreaching') {
    const breaches = realBreaches + (tmd === 'breaching' ? fill : 0);
    return { result: breaches >= m ? 'ALARM' : 'OK', why: 'fill', real: real.length, fill, breaches };
  }
  // missing · ignore: 채운 누락은 위반으로도 정상으로도 세지 않는다
  if (real.length === 0) return { result: tmd === 'ignore' ? 'retain' : 'INSUFFICIENT_DATA', why: 'none', real: 0, fill, breaches: 0 };
  if (realBreaches >= m) return { result: 'ALARM', why: 'fill', real: real.length, fill, breaches: realBreaches };
  // 이른 ALARM 규칙: 범위 안 실제 포인트가 모두 위반이고, 가장 오래된 위반의 나이(가장 최근 = 1)가 M 이상
  if (real.every((p) => p === 'breach')) {
    const oldest = range.findIndex((p) => p === 'breach');
    const age = range.length - oldest;
    if (age >= m) {
      // 가장 오래된 위반은 평가 범위 전체에서 찾는다(머리 주석 (4)·가정 4 — 문서의 "during the evaluation range").
      return { result: tmd === 'ignore' ? 'retain' : 'ALARM', why: 'premature', real: real.length, fill, breaches: realBreaches };
    }
  }
  return { result: 'OK', why: 'fill', real: real.length, fill, breaches: realBreaches };
}

/**
 * 구간마다 알람을 평가한다. 평가 범위 길이 R을 N+1과 N+2(모형 값)로 판정해 결과가 하나로 모이면 판정,
 * 갈리면 판정하지 않는다. 첫 구간 앞은 누락으로 채운다.
 * @param cfg normalize 된 입력
 */
export function evaluate(cfg) {
  const cls = cfg.points.map((v) => classify(v, cfg));
  const steps = [];
  let prevSet = new Set([cfg.initial]); // 직전 상태로 가능한 값들
  let prevDecided = true;
  for (let i = 0; i < cfg.points.length; i++) {
    const history = cls.slice(0, i + 1);
    const outcomes = [];
    for (let R = cfg.n + MODEL_RANGE_EXTRA.min; R <= cfg.n + MODEL_RANGE_EXTRA.max; R++) {
      const range = R > history.length ? [...new Array(R - history.length).fill(null), ...history] : history.slice(-R);
      outcomes.push({ R, ...evaluateRange(range, cfg.n, cfg.m, cfg.tmd) });
    }
    const set = new Set();
    let unknown = false;
    for (const o of outcomes) {
      if (o.result === 'unknown') unknown = true;
      else if (o.result === 'retain') for (const p of prevSet) set.add(p);
      else set.add(o.result);
    }
    const decided = !unknown && set.size === 1;
    const state = decided ? [...set][0] : null;
    const prev = prevSet.size === 1 && prevDecided ? [...prevSet][0] : null;
    const usesPrev = outcomes.some((o) => o.result === 'retain');
    // retain 이 직전의 미정 상태를 물려받으면 미정
    const decided2 = decided && !(usesPrev && prev === null);
    steps.push({
      i,
      t: (i + 1) * cfg.periodSec,
      value: cfg.points[i],
      as: cls[i],
      state: decided2 ? state : null,
      possible: unknown ? null : [...set],
      unknown,
      prev,
      changed: decided2 && prev !== null ? state !== prev : null,
      outcomes,
      longest: outcomes[outcomes.length - 1],
      dependsOnRange: new Set(outcomes.map((o) => o.result)).size > 1,
    });
    prevSet = unknown ? new Set(STATES) : set;
    prevDecided = decided2;
  }
  const last = steps.at(-1);
  return {
    steps,
    final: steps.length ? last.state : cfg.initial,
    finalPossible: steps.length ? last.possible : [cfg.initial],
    changes: steps.filter((s) => s.changed === true).length,
    undecided: steps.filter((s) => s.state === null).length,
  };
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

export function pointLabel(step, cfg) {
  if (step.value === null) return '누락';
  return `${step.value} ${OPS[cfg.op].sym} ${cfg.threshold}? ${step.as === 'breach' ? '예 → 위반' : '아니요 → 정상'}`;
}

const WHY = {
  real: (o, cfg) => `평가 범위에 실제 데이터 포인트가 ${o.real}개(N=${cfg.n}개 이상)라 가장 최근 실제 ${cfg.n}개로 판정한다 — 위반 ${o.breaches}개, ALARM에 필요 ${cfg.m}개. TreatMissingData는 쓰지 않는다.`,
  fill: (o, cfg) =>
    `실제 데이터 포인트가 ${o.real}개로 N=${cfg.n}개보다 적어 모자란 ${o.fill}개를 ${cfg.tmd}로 채운다${cfg.tmd === 'breaching' ? '(위반으로 셈)' : cfg.tmd === 'notBreaching' ? '(정상으로 셈)' : '(세지 않음)'} — 위반 ${o.breaches}개, ALARM에 필요 ${cfg.m}개.`,
  none: (o, cfg) => (cfg.tmd === 'ignore' ? '평가 범위에 실제 데이터가 없다 → ignore: 직전 상태를 유지한다.' : '평가 범위에 실제 데이터가 없다 → missing: INSUFFICIENT_DATA.'),
  premature: (o, cfg) =>
    `실제 포인트가 모두 위반이고 가장 오래된 위반이 ${cfg.m}번째 이상 오래되었으며 그 뒤는 누락뿐이다 → 문서의 "이른 ALARM" 규칙${cfg.tmd === 'ignore' ? '이지만 ignore는 상태를 유지한다(문서 표).' : '으로 ALARM.'}`,
  'premature-far': () => '가장 오래된 위반이 최근 N개 밖에 있어 문서의 표·규칙으로 정해지지 않는다.',
};

/** 한 단계의 판정 이유(글). 단정할 수 없는 경우는 단정하지 않는다. */
export function explain(step, cfg) {
  if (step.unknown) return `모형이 판정하지 않는다: ${WHY['premature-far']()}`;
  if (step.state === null) {
    const poss = step.possible.join(' 또는 ');
    return step.dependsOnRange
      ? `모형이 판정하지 않는다: 평가 범위 길이(모형 값 N+1 또는 N+2 — 실제 길이는 문서가 밝히지 않는다)에 따라 ${poss}가 될 수 있다. 오래된 실제 값이 범위 안에 남아 있느냐에 따라 달라진다.`
      : `모형이 판정하지 않는다: 직전 상태를 정하지 못해 이번 결과도 ${poss} 중 하나다.`;
  }
  const o = step.longest;
  const why = WHY[o.why](o, cfg);
  const range = step.dependsOnRange ? '' : ' 평가 범위 길이(모형 값 N+1·N+2) 어느 쪽이든 같은 결과다.';
  let change;
  if (step.changed === null) change = ' 직전 상태를 정하지 못해 바뀌었는지는 알 수 없다.';
  else if (step.changed) change = ` 상태가 ${step.prev} → ${step.state}로 바뀐다(그 상태에 걸어 둔 액션이 실행된다).`;
  else change = ' 상태가 그대로라 SNS 같은 액션은 다시 실행되지 않는다(Auto Scaling 액션만 예외로 1분마다 반복).';
  return `${why}${range} → ${step.state}.${change}`;
}
