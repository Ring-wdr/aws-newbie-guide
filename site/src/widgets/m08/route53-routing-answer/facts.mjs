// 위젯의 레코드·규칙을 원고 curriculum/m08-dns-edge/02-routing-policies-and-health-checks.md 에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
//  - "5) 워크시트"의 레코드 표(이름 · SetIdentifier · 정책 설정 · 값 · 상태 확인) → 위젯의 레코드 묶음
//  - 워크시트 문항 1~9와 정답의 굵은 글씨 → 사례 단추와 "원고의 답"
//  - lab02 4단계의 단순 레코드 값, 정책 표의 가중치 범위·다중값 최대 개수·지리 일치 순서, 정답 7번의 규칙 문장
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다. 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

export const LESSON = 'curriculum/m08-dns-edge/02-routing-policies-and-health-checks.md';

function findLine(lines, re, after, what) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}
const fail = (what, line) => {
  throw new Error(`${LESSON}:${line}의 ${what}을(를) 해석하지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
};
const cells = (row) => row.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((c) => c.trim());
const unq = (s) => s.replace(/`/g, '').trim();

/** "지연 시간, `ap-northeast-2`" 같은 정책 칸 → { policy, ... } */
export function parsePolicy(s, n, line) {
  let m;
  if ((m = /^지연 시간,\s*`([a-z0-9-]+)`$/.exec(s))) return Array(n).fill({ policy: 'latency', region: m[1] });
  if ((m = /^지리적 위치,\s*국가\s+([A-Z]{2})$/.exec(s))) return Array(n).fill({ policy: 'geo', geo: { kind: 'country', code: m[1] } });
  if ((m = /^지리적 위치,\s*대륙\s+([A-Z]{2})$/.exec(s))) return Array(n).fill({ policy: 'geo', geo: { kind: 'continent', code: m[1] } });
  if (/^지리적 위치,\s*`\*`$/.test(s)) return Array(n).fill({ policy: 'geo', geo: { kind: 'default', code: '*' } });
  if ((m = /^장애 조치\s+(PRIMARY|SECONDARY)$/.exec(s))) return Array(n).fill({ policy: 'failover', role: m[1] });
  if (/^다중값 응답$/.test(s)) return Array(n).fill({ policy: 'multivalue' });
  if ((m = /^가중치\s+(\d+(?:\s*\/\s*\d+)*)$/.exec(s))) {
    const w = m[1].split('/').map((x) => Number(x.trim()));
    if (w.length !== n) fail('가중치 개수', line);
    return w.map((weight) => ({ policy: 'weighted', weight }));
  }
  return fail(`정책 설정 "${s}"`, line);
}

/** "192.0.2.31 / .32 / .33" → 각 값. ".32"처럼 줄인 값은 첫 값의 앞부분을 이어 붙인다. */
export function expandValues(s, n, line) {
  const parts = s.split(' / ').map((x) => x.trim());
  if (parts.length === 1 && n > 1) fail('값 개수', line);
  if (parts.length !== n) fail('값 개수', line);
  const first = parts[0];
  return parts.map((p) => (p.startsWith('.') && /^\d+\.\d+\.\d+\.\d+$/.test(first) ? first.replace(/\.\d+$/, '') + p : p));
}

/**
 * @param {string} text 02-routing-policies-and-health-checks.md 내용
 */
export function readRoutingFacts(text) {
  const L = text.split('\n');
  const f = (re, what, after = 0) => findLine(L, re, after, what);

  // 정책 표의 규칙
  const weightRow = f(/^\|\s*가중치\(weighted\)\s*\|\s*`Weight`\s*(\d+)~(\d+)\s*\|/, '정책 표의 가중치 행');
  const multiRow = f(/^\|\s*다중값 응답\(multivalue\)\s*\|.*\*\*건강한\*\* 값을 최대\s*(\d+)개까지/, '정책 표의 다중값 행');
  const geoRow = f(/^\|\s*지리적 위치\(geolocation\)\s*\|.*가장 구체적인 일치\(주 > 국가 > 대륙 > 기본 `\*`\)/, '정책 표의 지리적 위치 순서');
  const simpleRow = f(/^\|\s*단순\(simple\)\s*\|.*\*\*상태 확인을 붙일 수 없다\*\*/, '정책 표의 단순 행');
  // lab02 4단계: simple   → NOERROR 192.0.2.10,192.0.2.11
  const simple = f(/^simple\s+→\s+NOERROR\s+([\d.,]+)\s*$/, 'lab02 단순 레코드 응답');
  // 정답 7번의 규칙
  const allHealthy = f(/\*\*If no record is healthy, all records are healthy\*\*/, '"If no record is healthy" 규칙');
  // 정답 2번: EvaluateTargetHealth=true 인 Alias 는 대상이 건강하지 않으면 후보에서 빠진다
  const eth = f(/`EvaluateTargetHealth=true`인 Alias는 대상이 건강하지 않으면 후보에서 빠지고/, 'EvaluateTargetHealth 문장');
  // 정답 8번: 상태 확인이 없는 다중값 레코드는 항상 건강
  const noHc = f(/상태 확인이 없는 다중값 레코드는 항상 건강한 것으로 친다/, '상태 확인 없는 레코드 문장');
  // 정답 9번: 가중치 0
  const zeroW = f(/가중치 0은 다른 레코드에 0이 아닌 가중치가 있는 한 응답되지 않는다/, '가중치 0 문장');
  // 본문: 모든 레코드가 0이면 똑같은 비율
  const allZero = f(/모든 레코드가 0이면 똑같은 비율로 나뉜다/, '가중치 모두 0 문장');

  // 워크시트 레코드 표
  const head = f(/^\|\s*이름\s*\|\s*SetIdentifier\s*\|\s*정책 설정\s*\|\s*값\s*\|\s*상태 확인\s*\|\s*$/, '워크시트 레코드 표 머리');
  const records = [];
  for (let i = head.line + 1; i < L.length && L[i].startsWith('|'); i++) {
    const line = i + 1;
    const c = cells(L[i]);
    if (c.length !== 5) fail('표 칸 수', line);
    const name = unq(c[0]);
    const ids = c[1].split(' / ').map((x) => x.trim());
    const pol = parsePolicy(c[2], ids.length, line);
    const vals = expandValues(c[3], ids.length, line);
    // "각각 HC-a / HC-b / HC-c" → 레코드마다 하나씩
    const hcs = c[4] === '없음' ? ids.map(() => null) : c[4].replace(/^각각\s+/, '').split(' / ').map((x) => x.trim());
    if (hcs.length !== ids.length) fail('상태 확인 개수', line);
    ids.forEach((id, k) => records.push({ name, id, ...pol[k], value: vals[k], hc: hcs[k], line }));
  }
  if (records.length < 5) fail('워크시트 레코드', head.line);

  // 워크시트 문항 1~10 과 정답(굵은 글씨)
  const qStart = f(/^1\.\s+도쿄의 사용자가 `api`를 묻는다/, '워크시트 1번', head.line);
  const questions = {};
  for (let i = qStart.line - 1; i < L.length; i++) {
    const m = /^(\d+)\.\s+(.+)$/.exec(L[i]);
    if (!m) break;
    questions[m[1]] = { text: m[2], line: i + 1 };
  }
  const aStart = f(/^<details><summary>정답과 해설<\/summary>/, '워크시트 정답', qStart.line);
  const answers = {};
  for (let i = aStart.line; i < L.length && !L[i].startsWith('</details>'); i++) {
    const m = /^(\d+)\.\s+\*\*(.+?)\*\*/.exec(L[i]);
    if (m) answers[m[1]] = { bold: m[2], line: i + 1 };
  }
  for (const k of ['1', '2', '3', '4', '5', '6', '7', '8', '9']) if (!questions[k] || !answers[k]) fail(`워크시트 ${k}번 문항·정답`, qStart.line);

  return {
    lesson: LESSON,
    weightRange: { min: Number(weightRow.m[1]), max: Number(weightRow.m[2]), line: weightRow.line },
    multiMax: { value: Number(multiRow.m[1]), line: multiRow.line },
    geoOrderLine: geoRow.line,
    simpleNoHcLine: simpleRow.line,
    simple: { values: simple.m[1].split(','), line: simple.line },
    rules: { allHealthy: allHealthy.line, evaluateTargetHealth: eth.line, noHcHealthy: noHc.line, zeroWeight: zeroW.line, allZero: allZero.line },
    records,
    worksheetLine: head.line,
    questions,
    answers,
  };
}
