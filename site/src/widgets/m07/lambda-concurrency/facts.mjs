// 위젯의 수치와 규칙 문장을 원고에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
//  - curriculum/m07-serverless-containers/01-lambda-execution-model.md (레슨 1)
//  - curriculum/m07-serverless-containers/cheatsheet.md (치트시트 "동시성 3종")
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 수치를 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

export const LESSON = 'curriculum/m07-serverless-containers/01-lambda-execution-model.md';
export const CHEATSHEET = 'curriculum/m07-serverless-containers/cheatsheet.md';

/** "1,000" → 1000 */
export function parseCount(s) {
  const t = String(s).replace(/,/g, '').trim();
  if (!/^\d+$/.test(t)) throw new Error(`수를 해석할 수 없다: "${s}"`);
  return Number(t);
}

function findLine(lines, re, after, what, file) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${file}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/**
 * @param {string} lesson 01-lambda-execution-model.md 내용
 * @param {string} cheat cheatsheet.md 내용
 */
export function readConcurrencyFacts(lesson, cheat) {
  const L = lesson.split('\n');
  const C = cheat.split('\n');
  const f = (re, what, after = 0) => findLine(L, re, after, what, LESSON);

  // 한계값 표: | 동시성 | 계정·리전당 기본 1,000 |
  const lim = f(/^\|\s*동시성\s*\|\s*계정·리전당 기본\s*([\d,]+)\s*\|/, '한계값 표의 동시성 행');
  // 핵심 개념: 예약 동시성은 … 상한, 프로비저닝된 동시성은 콜드 스타트를 없애려고 미리 띄워 두는 것
  const rules = f(/\*\*예약 동시성\(reserved\)\*\*.*\*\*상한\*\*.*\*\*프로비저닝된 동시성\*\*.*콜드 스타트를 없애려고/, '동시성 규칙 문장');
  // 핵심 개념: 한도를 넘으면 동기 호출은 429 TooManyRequestsException, 비동기·이벤트 소스는 Lambda가 재시도
  const thr = f(/한도를 넘으면 동기 호출은 \*\*(\d{3}) `(\w+)`.*비동기·이벤트 소스는 Lambda가 재시도/, '스로틀 문장');
  // 스스로 확인 3번
  const sc = f(/함수 A가 예약 동시성\s*([\d,]+),\s*계정 한도가\s*([\d,]+)이다\. 함수 A의 트래픽이 갑자기\s*([\d,]+)\s*동시 요청/, '스스로 확인 3번 문장');
  // lab01 10단계: 예약 동시성 5 → ConcurrentExecutions 1000, UnreservedConcurrentExecutions 995
  const labHead = f(/^== 10\. 예약 동시성\s*(\d+)/, 'lab01 10단계 머리');
  const labRes = f(/"ReservedConcurrentExecutions":\s*(\d+)/, 'lab01 ReservedConcurrentExecutions', labHead.line);
  const labAcc = f(/"ConcurrentExecutions":\s*(\d+)/, 'lab01 ConcurrentExecutions', labRes.line);
  const labUnr = f(/"UnreservedConcurrentExecutions":\s*(\d+)/, 'lab01 UnreservedConcurrentExecutions', labAcc.line);
  // 치트시트 "동시성 3종": 예약 동시성 … 0으로 두면 함수 정지
  const zero = findLine(C, /^\|\s*예약 동시성\s*\|.*0으로 두면 함수 정지/, 0, '예약 동시성 0 = 함수 정지', CHEATSHEET);

  return {
    lesson: LESSON,
    cheatsheet: CHEATSHEET,
    accountLimit: { value: parseCount(lim.m[1]), line: lim.line },
    rulesLine: rules.line,
    throttle: { status: Number(thr.m[1]), error: thr.m[2], line: thr.line },
    selfCheck: { reserved: parseCount(sc.m[1]), limit: parseCount(sc.m[2]), demand: parseCount(sc.m[3]), line: sc.line },
    lab01: {
      reserved: Number(labRes.m[1]),
      account: Number(labAcc.m[1]),
      unreserved: Number(labUnr.m[1]),
      line: labRes.line,
      unreservedLine: labUnr.line,
    },
    zeroStopsLine: zero.line,
  };
}
