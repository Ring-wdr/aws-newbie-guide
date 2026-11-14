// 위젯의 수치를 원고(curriculum/m06-integration-messaging/02-sqs.md)에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 수치를 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs(원고 읽기 시험 포함)

export const LESSON = 'curriculum/m06-integration-messaging/02-sqs.md';

const UNIT = { 초: 1, 분: 60, 시간: 3600, 일: 86400 };

/** "30초", "12시간", "2분" → 초 */
export function parseKoDuration(s) {
  const m = /^\s*(\d+)\s*(초|분|시간|일)\s*$/.exec(s);
  if (!m) throw new Error(`기간을 해석할 수 없다: "${s}"`);
  return Number(m[1]) * UNIT[m[2]];
}

function findLine(lines, re, after = 0, what) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/**
 * @param {string} text 02-sqs.md 내용
 * @returns 각 수치와 원고 줄 번호
 */
export function readVisibilityFacts(text) {
  const lines = text.split('\n');

  // 핵심 개념 표: | 가시성 타임아웃 | 30초 | 0초 ~ 12시간 | …
  const row = findLine(lines, /^\|\s*가시성 타임아웃\s*\|\s*([^|]+?)\s*\|\s*([^|~]+?)\s*~\s*([^|]+?)\s*\|/, 0, '가시성 타임아웃 표 행');
  const timeout = {
    defaultSec: parseKoDuration(row.m[1]),
    minSec: parseKoDuration(row.m[2]),
    maxSec: parseKoDuration(row.m[3]),
    line: row.line,
  };

  // 스스로 확인 1번: "이미지 변환 작업이 보통 2분 걸리는데 큐의 가시성 타임아웃이 30초다"
  const sc = findLine(lines, /작업이 보통\s*(\d+\s*(?:초|분|시간))\s*걸리는데 큐의 가시성 타임아웃이\s*(\d+\s*(?:초|분|시간))다/, 0, '스스로 확인 1번 문장');
  const selfCheck = { processingSec: parseKoDuration(sc.m[1]), visibilitySec: parseKoDuration(sc.m[2]), line: sc.line };

  // lab02 출력: "== 1. … RedrivePolicy(maxReceiveCount=2)…" 와 그 아래 "VisibilityTimeout": "2"
  const rp = findLine(lines, /RedrivePolicy\(maxReceiveCount=(\d+)\)/, 0, 'lab02의 maxReceiveCount');
  const vt = findLine(lines, /"VisibilityTimeout":\s*"(\d+)"/, rp.line, 'lab02의 VisibilityTimeout');
  const lab02 = { maxReceiveCount: Number(rp.m[1]), maxReceiveLine: rp.line, visibilitySec: Number(vt.m[1]), visibilityLine: vt.line };

  return { lesson: LESSON, timeout, selfCheck, lab02 };
}
