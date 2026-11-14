// Lambda 동시성 칸 나누기 — 설명용 모형(실제 Lambda·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙(원고):
//  R1. 동시성 = 동시에 실행 중인 환경 수. 계정·리전당 기본 1,000(01-lambda-execution-model.md:33·47, cheatsheet.md:26).
//  R2. 예약 동시성은 함수 하나가 쓸 몫을 떼어 두는 동시에 상한이 된다(01:33, cheatsheet.md:32).
//      떼어 둔 만큼 나머지 함수들이 나눠 쓸 몫(UnreservedConcurrentExecutions)이 줄어든다(01:170~177 — 1000 중 5 예약 → 995).
//  R3. 예약 동시성을 0으로 두면 함수 정지(cheatsheet.md:32).
//  R4. 프로비저닝된 동시성은 콜드 스타트를 없애려고 미리 띄워 둔 환경(01:30·33).
//  R5. 한도를 넘으면 동기 호출은 429 TooManyRequestsException(스로틀), 비동기·이벤트 소스는 Lambda가 재시도(01:34).
//
// 모형의 가정(원고에 없는 단순화 — 화면에도 적는다):
//  A1. 한순간의 동시 요청 수만 본다(요청이 몇 초 걸리는지, 확장 속도, 재시도가 언제 성공하는지는 계산하지 않는다).
//  A2. 예약 동시성이 없을 때 함수 A와 나머지 함수들(B)은 미예약 몫을 함께 쓰고, 모형은 A의 요청이 먼저 자리를 잡는다고 둔다.
//  A3. 데워진 환경은 프로비저닝된 것뿐이라고 둔다(앞선 호출로 데워져 남아 있는 환경은 없다). 그 밖의 실행은 모두 콜드 스타트.
//  A4. 프로비저닝된 환경은 요청이 없어도 자리를 차지한다(예약이 없으면 미예약 몫에서, 있으면 예약 몫 안에서).
//      프로비저닝된 동시성은 예약 동시성을 넘을 수 없게 맞춘다.
//  A5. 나머지 함수들(B)은 동기 호출로 두고 콜드 스타트는 따지지 않는다.

/** 화면에서 받는 요청 수의 상한(모형 화면의 범위, AWS 한도가 아니다). */
export const MODEL_MAX_DEMAND = 5000;

/**
 * @typedef {{ reservedOn: boolean, reserved: number, provisioned: number, demandA: number, demandB: number, invokeA: 'sync' | 'async' }} Input
 */

const int = (v, lo, hi, dflt) => {
  if (v === '' || v === null || v === undefined) return dflt;
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, Math.round(n)));
};

/** 입력을 모형이 다룰 수 있는 정수 범위로 맞춘다. limit = 원고의 계정 동시성(1,000). */
export function normalize(input, limit) {
  const reservedOn = Boolean(input.reservedOn);
  const reserved = int(input.reserved, 0, limit, 0);
  const cap = reservedOn ? reserved : limit;
  return {
    reservedOn,
    reserved,
    provisioned: int(input.provisioned, 0, cap, 0),
    demandA: int(input.demandA, 0, MODEL_MAX_DEMAND, 0),
    demandB: int(input.demandB, 0, MODEL_MAX_DEMAND, 0),
    invokeA: input.invokeA === 'async' ? 'async' : 'sync',
  };
}

/**
 * 한순간의 동시성 칸 나누기.
 * @param {Input} input 이미 normalize 된 값
 * @param {number} limit 계정 동시성
 */
export function allocate(input, limit) {
  const { reservedOn, reserved, provisioned, demandA, demandB } = input;
  const capA = reservedOn ? reserved : limit; // A가 쓸 수 있는 최대
  const runA = Math.min(demandA, capA);
  const warmA = Math.min(runA, provisioned);
  const coldA = runA - warmA;
  const idleProvA = provisioned - warmA; // 요청이 없어 놀고 있는 프로비저닝된 환경
  const unreserved = reservedOn ? limit - reserved : limit; // UnreservedConcurrentExecutions
  // A가 미예약 몫에서 차지한 자리(예약이 있으면 0 — A는 자기 몫 안에서만 돈다)
  const aInPool = reservedOn ? 0 : runA + idleProvA;
  const poolForB = unreserved - aInPool;
  const runB = Math.min(demandB, poolForB);
  const throttledA = demandA - runA;
  const throttledB = demandB - runB;
  const reservedIdle = reservedOn ? reserved - runA - idleProvA : 0; // 예약 몫 중 비어 있는 칸
  const free = unreserved - aInPool - runB; // 미예약 몫 중 비어 있는 칸
  return {
    limit,
    capA,
    unreserved,
    poolForB,
    a: { demand: demandA, run: runA, warm: warmA, cold: coldA, idleProv: idleProvA, throttled: throttledA, stopped: reservedOn && reserved === 0 },
    b: { demand: demandB, run: runB, throttled: throttledB },
    reservedIdle,
    free,
  };
}

const n = (x) => x.toLocaleString('en-US');

/** 스로틀된 요청이 어떻게 되는지(R5). */
export function throttleFate(kind, status, error) {
  return kind === 'async' ? 'Lambda가 재시도' : `${status} ${error}`;
}

/**
 * 결과를 글로 풀어 쓴다(표·화면 낭독용). 원고 규칙 번호를 단다.
 * @returns {{ verdict: 'ok' | 'throttled-a' | 'throttled-b' | 'throttled-both' | 'stopped', lines: string[] }}
 */
export function explain(input, r, t = { status: 429, error: 'TooManyRequestsException' }) {
  const lines = [];
  const fateA = throttleFate(input.invokeA, t.status, t.error);
  const fateB = throttleFate('sync', t.status, t.error);
  if (input.reservedOn) {
    lines.push(`함수 A는 예약 동시성 ${n(input.reserved)}을(를) 떼어 두었다. 이 값이 A의 몫이자 상한이고, 나머지 함수들이 나눠 쓸 몫은 ${n(r.limit)} − ${n(input.reserved)} = ${n(r.unreserved)}이다.`);
  } else {
    lines.push(`예약 동시성이 없어 함수 A와 나머지 함수들이 계정 동시성 ${n(r.limit)}을(를) 함께 쓴다(모형은 A의 요청이 먼저 자리를 잡는다고 둔다).`);
  }
  if (r.a.stopped) {
    lines.push(`예약 동시성이 0이라 함수 A는 정지 상태다 — A의 요청 ${n(r.a.demand)}건이 모두 스로틀된다(${fateA}).`);
  } else if (r.a.demand === 0) {
    lines.push('함수 A에 들어온 요청이 없다.');
  } else {
    const parts = [];
    if (r.a.warm) parts.push(`${n(r.a.warm)}건은 프로비저닝된(미리 데운) 환경에서 콜드 스타트 없이`);
    if (r.a.cold) parts.push(`${n(r.a.cold)}건은 새 환경을 만들어 콜드 스타트와 함께`);
    lines.push(`함수 A 요청 ${n(r.a.demand)}건 중 ${n(r.a.run)}건이 실행된다${parts.length ? `: ${parts.join(', ')} 실행` : ''}.`);
    if (r.a.throttled) lines.push(`함수 A의 나머지 ${n(r.a.throttled)}건은 상한(${n(r.capA)})을 넘어 스로틀된다 — ${input.invokeA === 'async' ? '비동기 호출이라 Lambda가 재시도한다' : `동기 호출이라 ${t.status} ${t.error}를 받는다`}.`);
  }
  if (r.a.idleProv) lines.push(`프로비저닝된 환경 ${n(r.a.idleProv)}개는 요청 없이 데워진 채 자리를 차지하고 있다(켜 둔 시간만큼 과금).`);
  if (r.b.demand === 0) {
    lines.push('나머지 함수들에 들어온 요청이 없다.');
  } else if (r.b.throttled === 0) {
    lines.push(`나머지 함수들의 요청 ${n(r.b.demand)}건은 남은 몫 ${n(r.poolForB)} 안이라 모두 실행된다.`);
  } else {
    const why = !input.reservedOn && r.a.run + r.a.idleProv > 0 ? ` 함수 A가 ${n(r.a.run + r.a.idleProv)}칸을 차지해 남은 몫이 ${n(r.poolForB)}뿐이다.` : ` 남은 몫이 ${n(r.poolForB)}이다.`;
    lines.push(`나머지 함수들의 요청 ${n(r.b.demand)}건 중 ${n(r.b.throttled)}건이 스로틀된다(${fateB}).${why}`);
  }
  let verdict = 'ok';
  if (r.a.stopped) verdict = 'stopped';
  else if (r.a.throttled && r.b.throttled) verdict = 'throttled-both';
  else if (r.a.throttled) verdict = 'throttled-a';
  else if (r.b.throttled) verdict = 'throttled-b';
  return { verdict, lines };
}

export const VERDICT_LABEL = {
  ok: '모두 실행',
  'throttled-a': '함수 A 일부 스로틀',
  'throttled-b': '나머지 함수 스로틀',
  'throttled-both': '양쪽 모두 스로틀',
  stopped: '함수 A 정지',
};
