// SQS 가시성 타임아웃 타임라인 — 설명용 모형(실제 SQS·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 모형의 가정(화면에도 그대로 적는다 — ASSUMPTIONS):
//  1. 메시지가 보이면 놀고 있는 워커가 곧바로 받아 간다(폴링 대기 0초).
//  2. 받은 워커는 "처리 시간"만큼 일한 뒤, 성공이면 DeleteMessage, 실패면 아무것도 하지 않는다.
//  3. 처리가 끝나는 시각과 타임아웃이 끝나는 시각이 같으면 다시 보이는 쪽을 먼저 둔다
//     (원고 02-sqs.md:34 "처리 시간보다 **길게**" — 같으면 안전하지 않다).
//  4. 재드라이브 정책이 있으면, 이미 maxReceiveCount번 받아 간 메시지를 다음에 받으려는 순간 DLQ로 옮긴다
//     (원고 02-sqs.md:59 "maxReceiveCount번 넘게 받아 간 메시지를 DLQ로", 02-sqs.md:179 "두 번 실패한 뒤 세 번째로 받으려는 순간 … DLQ로").
//  5. 처리를 끝낸 워커의 DeleteMessage는 항상 통한다고 둔다(다른 워커가 같은 메시지를 다시 받아 간 뒤라도). 모형의 단순화다.
//     실제로는 가시성 타임아웃이 지난 뒤의 삭제가 보장되지 않는다(원고에 없는 내용이라 단정하지 않는다).
//  7. 수신을 MAX_RECEIVES_SHOWN번 펼친 뒤에도 끝나지 않으면 거기서 멈춘다(결과 'looping').
//  6. 메시지 보존 기간(기본 4일)은 다루지 않는다.

/** 재드라이브 정책이 없을 때 끝없이 반복되는 수신을 화면에 몇 번까지 펼칠지(모형 화면의 상한, AWS 한도가 아니다). */
export const MAX_RECEIVES_SHOWN = 10;

/** 화면의 maxReceiveCount 입력 범위. 원고에 범위가 없어서 모형 화면의 범위로 둔다(AWS 한도가 아니다). 원고의 예는 lab02의 2(02-sqs.md:150). */
export const MODEL_MAX_RECEIVE_RANGE = { min: 1, max: MAX_RECEIVES_SHOWN };

/**
 * @typedef {{ visibility: number, processing: number, maxReceiveCount: number, redrive: boolean, outcome: 'success' | 'fail' }} Input
 * @typedef {{ t: number, kind: 'receive' | 'hidden-end' | 'delete' | 'fail' | 'dlq' | 'stop', receive: number, worker: number | null }} Event
 * @typedef {{ worker: number, start: number, visibleAt: number, finish: number, end: number, endKind: 'delete' | 'fail' | 'cut' }} Lane
 */

/** 입력을 모형이 다룰 수 있는 정수 범위로 맞춘다. limits는 원고에서 읽은 가시성 타임아웃 범위(초). */
export function normalize(input, limits) {
  const int = (v, lo, hi, dflt) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return dflt;
    return Math.min(hi, Math.max(lo, Math.round(n)));
  };
  return {
    visibility: int(input.visibility, limits.minSec, limits.maxSec, limits.defaultSec),
    processing: int(input.processing, 0, limits.maxSec, 0),
    maxReceiveCount: int(input.maxReceiveCount, MODEL_MAX_RECEIVE_RANGE.min, MODEL_MAX_RECEIVE_RANGE.max, MODEL_MAX_RECEIVE_RANGE.min),
    redrive: Boolean(input.redrive),
    outcome: input.outcome === 'fail' ? 'fail' : 'success',
  };
}

/**
 * 메시지 하나의 일생을 사건 목록으로 계산한다.
 * @param {Input} input 이미 normalize 된 값
 * @returns {{ events: Event[], lanes: Lane[], result: 'deleted' | 'dlq' | 'looping', receives: number, duplicates: number, busyAtEnd: number, end: number }}
 */
export function simulate(input) {
  const { visibility: V, processing: T, maxReceiveCount: M, redrive, outcome } = input;
  /** @type {Event[]} */
  const events = [];
  /** @type {Lane[]} */
  const lanes = [];
  /** @type {Lane[]} */
  const busy = []; // 아직 처리 중인 워커(받은 순서 = 끝나는 순서)
  let t = 0;
  let receives = 0;
  let result = /** @type {'deleted' | 'dlq' | 'looping'} */ ('looping');

  for (;;) {
    // 메시지가 시각 t에 보인다. 워커가 받으려 한다.
    if (redrive && receives >= M) {
      events.push({ t, kind: 'dlq', receive: receives, worker: null });
      result = 'dlq';
      break;
    }
    if (receives >= MAX_RECEIVES_SHOWN) {
      events.push({ t, kind: 'stop', receive: receives, worker: null });
      result = 'looping';
      break;
    }
    receives++;
    const lane = { worker: receives, start: t, visibleAt: t + V, finish: t + T, end: t + T, endKind: /** @type {Lane['endKind']} */ ('cut') };
    lanes.push(lane);
    busy.push(lane);
    events.push({ t, kind: 'receive', receive: receives, worker: receives });

    const visibleAt = t + V;
    let deleted = false;
    // 다시 보이기 전에(엄격히 먼저) 끝나는 처리
    while (busy.length && busy[0].finish < visibleAt) {
      const w = /** @type {Lane} */ (busy.shift());
      if (outcome === 'success') {
        w.endKind = 'delete';
        events.push({ t: w.finish, kind: 'delete', receive: receives, worker: w.worker });
        deleted = true;
        break;
      }
      w.endKind = 'fail';
      events.push({ t: w.finish, kind: 'fail', receive: receives, worker: w.worker });
    }
    if (deleted) {
      result = 'deleted';
      break;
    }
    events.push({ t: visibleAt, kind: 'hidden-end', receive: receives, worker: null });
    t = visibleAt;
  }

  const end = events[events.length - 1].t;
  // 끝난 시각에 아직 처리 중인 워커는 그 시각에서 자른다(endKind 'cut').
  for (const l of lanes) l.end = l.endKind === 'cut' ? Math.min(l.finish, end) : l.finish;
  const busyAtEnd = busy.length;
  return { events, lanes, result, receives, duplicates: Math.max(0, receives - 1), busyAtEnd, end };
}

/** 초 → "1시간 2분 3초" 꼴. 0은 "0초". */
export function formatDuration(sec) {
  const s = Math.max(0, Math.round(sec));
  if (s === 0) return '0초';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  return [h && `${h}시간`, m && `${m}분`, r && `${r}초`].filter(Boolean).join(' ');
}

/** 사건 하나를 한 문장으로(표와 단계 안내에 같은 문장을 쓴다). */
export function describe(ev, input) {
  const at = formatDuration(ev.t);
  switch (ev.kind) {
    case 'receive':
      return `${at}: 워커 ${ev.worker}이(가) 받음(수신 ${ev.receive}번째, ReceiveCount=${ev.receive}). 가시성 타임아웃 ${formatDuration(input.visibility)} 동안 다른 소비자에게 안 보임`;
    case 'delete':
      return `${at}: 워커 ${ev.worker}이(가) 처리를 끝내고 DeleteMessage — 메시지가 사라짐`;
    case 'fail':
      return `${at}: 워커 ${ev.worker}의 처리 실패 — 지우지 않음(타임아웃이 끝날 때까지 계속 안 보임)`;
    case 'hidden-end':
      return `${at}: 가시성 타임아웃이 끝나 메시지가 다시 보임`;
    case 'dlq':
      return `${at}: 이미 ${ev.receive}번 받아 간 메시지를 ${ev.receive + 1}번째로 받으려는 순간 — 수신 횟수가 maxReceiveCount(${input.maxReceiveCount})를 넘으므로 원본 큐에서 DLQ로 옮겨짐`;
    case 'stop':
      return `${at}: 재드라이브 정책이 없어 같은 일이 계속 반복된다 — 모형은 수신 ${MAX_RECEIVES_SHOWN}번에서 멈춘다`;
    default:
      return at;
  }
}

/** 결과 요약 한 문장. */
export function summarize(sim, input) {
  const dup = sim.duplicates;
  if (sim.result === 'deleted') {
    return dup === 0
      ? `한 번 받아 ${formatDuration(sim.end)} 만에 삭제됐다. 처리 시간(${formatDuration(input.processing)})이 가시성 타임아웃(${formatDuration(input.visibility)})보다 짧아 다른 워커에게 다시 보이지 않았다.`
      : `삭제되기 전까지 ${sim.receives}번 받아 갔다 — 같은 작업이 ${dup}번 더 시작된 중복 처리다. 가시성 타임아웃(${formatDuration(input.visibility)})이 처리 시간(${formatDuration(input.processing)})보다 길어야 한다.`;
  }
  if (sim.result === 'dlq') {
    const busy = sim.busyAtEnd ? ` 이때 아직 처리 중이던 워커가 ${sim.busyAtEnd}개 있었다.` : '';
    return `${sim.receives}번 받아 가고도 삭제되지 않아 ${formatDuration(sim.end)}에 DLQ로 옮겨졌다.${busy}`;
  }
  if (input.outcome === 'success') {
    const why =
      input.visibility === 0
        ? '가시성 타임아웃이 0초라 받자마자 다시 보여, 시간이 흐르기 전에 다른 워커가 계속 다시 받아 간다'
        : '처리가 끝나기 전에 가시성 타임아웃이 계속 끝나 다른 워커가 계속 다시 받아 간다';
    return `${why}. ${MAX_RECEIVES_SHOWN}번 받아 갈 때까지 아무 워커도 처리를 끝내지 못해 메시지가 지워지지 않았다(모형은 ${MAX_RECEIVES_SHOWN}번에서 멈춘다) — 같은 작업이 겹겹이 중복 처리된다. 가시성 타임아웃을 처리 시간보다 길게 둔다.`;
  }
  return `재드라이브 정책이 없어 지워지지 않는 메시지가 타임아웃마다 다시 나타난다(독 메시지). ${MAX_RECEIVES_SHOWN}번 받아 간 뒤에도 끝나지 않는다(모형은 ${MAX_RECEIVES_SHOWN}번에서 멈춘다).`;
}
