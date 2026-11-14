// Route 53 "이 질의에 어느 레코드가 답하나" — 설명용 모형(실제 Route 53·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙(원고 02-routing-policies-and-health-checks.md — 줄 번호는 facts.mjs가 빌드 때 찾는다):
//  R1 단순: 모든 값을 준다. 상태 확인을 붙일 수 없다(정책 표 단순 행).
//  R2 가중치: 가중치 비율대로 무작위. 가중치 0은 다른 레코드에 0이 아닌 가중치가 있는 한 응답되지 않고,
//     모든 레코드가 0이면 똑같은 비율로 나뉜다(정답 9번, lab02 5단계 해설).
//  R3 지연 시간: 질의자와 리전 사이의 측정 지연이 가장 짧은 레코드. EvaluateTargetHealth=true Alias는 대상이 건강하지 않으면 후보에서 빠진다(정답 2번).
//  R4 장애 조치: PRIMARY가 건강하면 PRIMARY, 아니면 SECONDARY(정책 표). PRIMARY가 없으면 SECONDARY(lab03 6단계).
//  R5 지리적 위치: 가장 구체적인 일치(주 > 국가 > 대륙 > 기본 *). 일치가 없고 기본도 없으면 빈 응답(NOERROR, 값 없음)(정답 3~5번).
//  R6 다중값: 건강한 값을 최대 8개까지. 상태 확인이 없는 레코드는 항상 건강(정답 8번).
//  R7 같은 이름·유형 묶음에 건강한 레코드가 하나도 없으면 모두 건강하다고 보고 정책대로 고른다(정답 7번, AWS 문서 인용).
//
// 모형의 가정(화면에도 적는다):
//  A1 질의자의 위치(국가·대륙)와 리전까지의 지연(ms)은 모형 값이다(LOCATIONS). 실제 지연 시간 정책은 AWS가 측정한 값을 쓴다.
//  A2 가중치는 기댓값(비율)만 보여 준다. 실제 응답은 무작위라 실행마다 조금씩 다르다.
//  A3 리졸버 캐시(TTL), 상태 확인 반영 시간(간격 × 임계값)은 다루지 않는다. 상태는 "지금 건강/비정상"만 고른다.
//  A4 지리적 위치 레코드에는 워크시트처럼 상태 확인이 없다고 둔다(상태 확인이 붙은 지리적 위치의 대체 규칙은 다루지 않는다).
//  A5 이름에 레코드가 하나도 없게 지우면 답을 계산하지 않는다(그때의 응답 코드는 다루지 않는다).
//  A6 주(state) 단위 지리 레코드와 지리 근접·IP 기반 정책은 다루지 않는다(워크시트에 없다).

/** 질의자 위치(모형 값). 대륙 코드는 Route 53 지리적 위치의 대륙 코드(AS·NA·SA·EU). 지연(ms)은 모형 값이다. */
export const LOCATIONS = [
  { id: 'KR', label: '한국', country: 'KR', continent: 'AS', latency: { 'ap-northeast-2': 10, 'us-east-1': 190 } },
  { id: 'JP', label: '일본 도쿄', country: 'JP', continent: 'AS', latency: { 'ap-northeast-2': 35, 'us-east-1': 160 } },
  { id: 'US', label: '미국 동부', country: 'US', continent: 'NA', latency: { 'ap-northeast-2': 190, 'us-east-1': 10 } },
  { id: 'BR', label: '브라질', country: 'BR', continent: 'SA', latency: { 'ap-northeast-2': 310, 'us-east-1': 120 } },
  { id: 'DE', label: '독일', country: 'DE', continent: 'EU', latency: { 'ap-northeast-2': 250, 'us-east-1': 90 } },
];
export const locationById = (id) => LOCATIONS.find((l) => l.id === id) || LOCATIONS[0];

export const POLICY_LABEL = { simple: '단순', weighted: '가중치', latency: '지연 시간', failover: '장애 조치', geo: '지리적 위치', multivalue: '다중값 응답' };

/** 단순 레코드 묶음을 원고 lab02 4단계의 값으로 만든다(이름 `simple`). */
export function simpleRecords(values, line) {
  return [{ name: 'simple', id: '(없음)', policy: 'simple', value: values.join(', '), values, hc: null, line }];
}

/** 레코드 묶음 → 이름별로 */
export function groupByName(records) {
  const out = new Map();
  for (const r of records) {
    if (!out.has(r.name)) out.set(r.name, []);
    out.get(r.name).push(r);
  }
  return out;
}

/** 화면 상태의 초깃값: 모두 있음, 상태 확인은 모두 건강, 가중치는 원고 값. */
export function initialState(records) {
  const present = {};
  const healthy = {};
  const weight = {};
  for (const r of records) {
    const k = keyOf(r);
    present[k] = true;
    healthy[k] = true;
    if (r.policy === 'weighted') weight[k] = r.weight;
  }
  return { present, healthy, weight };
}
export const keyOf = (r) => `${r.name}/${r.id}`;

const geoText = (g) => (g.kind === 'country' ? `국가 ${g.code}` : g.kind === 'continent' ? `대륙 ${g.code}` : '기본 *');
export function policyText(r) {
  switch (r.policy) {
    case 'latency':
      return `지연 시간, ${r.region}`;
    case 'geo':
      return `지리적 위치, ${geoText(r.geo)}`;
    case 'failover':
      return `장애 조치 ${r.role}`;
    case 'weighted':
      return '가중치';
    case 'multivalue':
      return '다중값 응답';
    default:
      return '단순';
  }
}

/**
 * 한 이름에 대한 질의의 답을 계산한다.
 * @param {Array} recs 같은 이름의 레코드(원고 순서)
 * @param {{present: Record<string, boolean>, healthy: Record<string, boolean>, weight: Record<string, number>}} state
 * @param {{country: string, continent: string, latency: Record<string, number>}} loc
 * @param {{multiMax?: number}} opt
 * @returns {{ kind: 'answer' | 'nodata' | 'weighted' | 'none', answers: {key: string, id: string, value: string, p?: number}[], steps: string[], status: Record<string, {mark: string, text: string}>, usedAllHealthy: boolean }}
 */
export function resolve(recs, state, loc, opt = {}) {
  const multiMax = opt.multiMax ?? 8;
  const steps = [];
  const status = {};
  const set = (r, mark, text) => (status[keyOf(r)] = { mark, text });
  const present = recs.filter((r) => state.present[keyOf(r)] !== false);
  for (const r of recs) if (!present.includes(r)) set(r, '—', '지워져 없음');
  if (!present.length) {
    steps.push('이 이름에 남은 레코드가 없다. 모형은 이때의 응답을 계산하지 않는다.');
    return { kind: 'none', answers: [], steps, status, usedAllHealthy: false };
  }
  const policy = present[0].policy;
  const isHealthy = (r) => (r.hc ? state.healthy[keyOf(r)] !== false : true);
  const ans = (r, extra = {}) => ({ key: keyOf(r), id: r.id, value: r.value, ...extra });

  // R7: 건강한 레코드가 하나도 없으면 모두 건강하다고 본다.
  let usedAllHealthy = false;
  const healthyOrAll = () => {
    const h = present.filter(isHealthy);
    for (const r of present) if (!isHealthy(r)) set(r, '✕', `상태 확인 실패(${r.hc})`);
    const bad = present.filter((r) => !isHealthy(r));
    if (h.length) {
      if (bad.length) steps.push(`${bad.map((r) => r.id).join(', ')}: 상태 확인이 실패해 후보에서 빠진다.`);
      return h;
    }
    usedAllHealthy = true;
    steps.push('건강한 레코드가 하나도 없다 → "If no record is healthy, all records are healthy": 모두 건강하다고 보고 정책대로 고른다.');
    return present;
  };

  if (policy === 'simple') {
    const r = present[0];
    steps.push('단순 정책: 레코드의 값을 모두 준다. 상태 확인을 붙일 수 없으므로 서버가 죽어도 그 값을 계속 준다.');
    set(r, '✓', '답함(값 전부)');
    return { kind: 'answer', answers: (r.values || [r.value]).map((v) => ({ key: keyOf(r), id: r.id, value: v })), steps, status, usedAllHealthy };
  }

  if (policy === 'weighted') {
    const cand = healthyOrAll();
    const w = (r) => Math.max(0, Number(state.weight[keyOf(r)] ?? r.weight) || 0);
    const sum = cand.reduce((s, r) => s + w(r), 0);
    let answers;
    if (sum === 0) {
      steps.push(`후보의 가중치가 모두 0이다 → ${cand.length}개가 똑같은 비율로 나뉜다.`);
      answers = cand.map((r) => ans(r, { p: 1 / cand.length }));
    } else {
      steps.push(`가중치 합 ${sum}에 대한 비율로 무작위로 고른다. 가중치 0인 레코드는 다른 레코드에 0이 아닌 가중치가 있는 한 응답되지 않는다.`);
      answers = cand.map((r) => ans(r, { p: w(r) / sum }));
    }
    for (const a of answers) {
      const r = present.find((x) => keyOf(x) === a.key);
      set(r, a.p > 0 ? '✓' : '·', a.p > 0 ? `${fmtPct(a.p)} 확률로 답함` : '가중치 0 — 응답되지 않음');
    }
    return { kind: 'weighted', answers, steps, status, usedAllHealthy };
  }

  if (policy === 'latency') {
    const cand = healthyOrAll();
    const ms = (r) => loc.latency[r.region] ?? Infinity;
    const best = cand.reduce((a, b) => (ms(b) < ms(a) ? b : a));
    steps.push(`지연 시간 정책: 후보 ${cand.map((r) => `${r.id}(${r.region}, 모형 ${ms(r)}ms)`).join(', ')} 중 지연이 가장 짧은 ${best.id}.`);
    for (const r of cand) if (r !== best) set(r, '·', `후보였지만 더 느림(모형 ${ms(r)}ms)`);
    set(best, '✓', `답함(모형 ${ms(best)}ms)`);
    return { kind: 'answer', answers: [ans(best)], steps, status, usedAllHealthy };
  }

  if (policy === 'failover') {
    const primary = present.find((r) => r.role === 'PRIMARY');
    const secondary = present.find((r) => r.role === 'SECONDARY');
    const cand = healthyOrAll();
    let pick;
    if (primary && cand.includes(primary)) {
      pick = primary;
      steps.push(usedAllHealthy ? 'PRIMARY를 고른다(모두 건강하다고 볼 때 장애 조치 정책은 PRIMARY).' : 'PRIMARY가 건강하다 → PRIMARY.');
    } else {
      pick = secondary;
      steps.push(primary ? 'PRIMARY가 건강하지 않다 → SECONDARY.' : 'PRIMARY 레코드가 없다 → SECONDARY(lab03 6단계).');
    }
    if (primary && primary !== pick && isHealthy(primary)) set(primary, '·', '대기');
    if (secondary && secondary !== pick) set(secondary, '·', '대기(PRIMARY가 건강할 때는 답하지 않음)');
    set(pick, '✓', '답함');
    return { kind: 'answer', answers: [ans(pick)], steps, status, usedAllHealthy };
  }

  if (policy === 'geo') {
    // A4: 지리적 위치 레코드의 상태 확인은 다루지 않는다(워크시트에 없다).
    const country = present.find((r) => r.geo.kind === 'country' && r.geo.code === loc.country);
    const continent = present.find((r) => r.geo.kind === 'continent' && r.geo.code === loc.continent);
    const dflt = present.find((r) => r.geo.kind === 'default');
    const pick = country || continent || dflt;
    const tried = [`국가 ${loc.country}: ${country ? country.id : '레코드 없음'}`, `대륙 ${loc.continent}: ${continent ? continent.id : '레코드 없음'}`, `기본 *: ${dflt ? dflt.id : '레코드 없음'}`];
    steps.push(`지리적 위치: 가장 구체적인 일치부터 본다 — ${tried.join(' → ')}.`);
    for (const r of present) if (r !== pick) set(r, '·', '일치하지 않거나 덜 구체적');
    if (!pick) {
      steps.push('일치하는 위치도 기본(*) 레코드도 없다 → 빈 응답(NOERROR, 값 없음). 이 사용자는 접속하지 못한다.');
      return { kind: 'nodata', answers: [], steps, status, usedAllHealthy };
    }
    set(pick, '✓', pick === country ? '답함(국가 일치)' : pick === continent ? '답함(대륙 일치)' : '답함(기본 *)');
    return { kind: 'answer', answers: [ans(pick)], steps, status, usedAllHealthy };
  }

  if (policy === 'multivalue') {
    const cand = healthyOrAll();
    // 건강한 레코드가 multiMax(8)개를 넘으면 실제 Route 53은 "앞의 8개"가 아니라 그중 대략 무작위로 최대 8개를 골라
    // 리졸버마다 다른 답을 준다(Amazon Route 53 개발자 안내서 "Multivalue answer routing": "To route traffic roughly at
    // random … Route 53 responds to DNS queries with up to eight healthy records and gives different answers to different
    // DNS resolvers."). 모형은 설명이 매번 같게 보이도록 앞에서부터 고른다 — 8개를 넘을 때 어느 8개가 나가는지는 모형 값이다.
    const picked = cand.slice(0, multiMax);
    steps.push(`다중값 응답: 건강한 레코드의 값을 최대 ${multiMax}개까지 함께 준다(상태 확인이 없는 레코드는 항상 건강).`);
    for (const r of picked) set(r, '✓', '답함(함께)');
    return { kind: 'answer', answers: picked.map((r) => ans(r)), steps, status, usedAllHealthy };
  }
  throw new Error(`모르는 정책: ${policy}`);
}

export function fmtPct(p) {
  const v = Math.round(p * 1000) / 10;
  return `${Number.isInteger(v) ? v : v.toFixed(1)}%`;
}

/** 결과를 한 줄로(상태 줄·표에 쓴다). */
export function summarize(res) {
  if (res.kind === 'none') return '레코드 없음(모형은 계산하지 않음)';
  if (res.kind === 'nodata') return '빈 응답(NOERROR, 값 없음)';
  if (res.kind === 'weighted') return res.answers.map((a) => `${a.id} ${a.value} ${fmtPct(a.p)}`).join(' · ');
  return res.answers.map((a) => (a.id === '(없음)' ? a.value : `${a.id}: ${a.value}`)).join(' · ');
}

/**
 * 워크시트 문항 1~9를 화면 상태로 옮긴다(원고 문항의 조건 그대로). 이름·위치·상태·지운 레코드.
 * 문항에 위치가 없으면 위치를 바꾸지 않는다(loc: null).
 */
export const WORKSHEET_CASES = {
  1: { name: 'api', loc: 'JP', unhealthy: [], deleted: [] },
  2: { name: 'api', loc: 'JP', unhealthy: ['api/seoul'], deleted: [] },
  3: { name: 'shop', loc: 'JP', unhealthy: [], deleted: [] },
  4: { name: 'shop', loc: 'KR', unhealthy: [], deleted: [] },
  5: { name: 'shop', loc: 'BR', unhealthy: [], deleted: ['shop/default'] },
  6: { name: 'pay', loc: null, unhealthy: ['pay/primary'], deleted: [] },
  7: { name: 'pay', loc: null, unhealthy: ['pay/primary'], deleted: ['pay/secondary'] },
  8: { name: 'img', loc: null, unhealthy: ['img/b'], deleted: [] },
  9: { name: 'new', loc: null, unhealthy: [], deleted: [] },
};

/** 문항 하나를 적용한 상태(나머지 레코드는 초깃값). */
export function caseState(records, c) {
  const s = initialState(records);
  for (const k of c.unhealthy) s.healthy[k] = false;
  for (const k of c.deleted) s.present[k] = false;
  return s;
}
