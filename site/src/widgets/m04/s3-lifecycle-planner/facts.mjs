// 위젯의 수치·규칙을 원고(curriculum/m04-storage/02-storage-classes-and-lifecycle.md)에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 수치를 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs(원고 읽기 시험 포함)

export const LESSON = 'curriculum/m04-storage/02-storage-classes-and-lifecycle.md';

function fail(what) {
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

function findLine(lines, re, what, after = 0) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  return fail(what);
}

const cells = (line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());

/** "없음" → 0, "30일" → 30, 그 밖("(시험 범위 밖)")은 null */
export function parseMinDays(s) {
  if (s === '없음') return 0;
  const m = /^(\d+)일$/.exec(s);
  return m ? Number(m[1]) : null;
}

/**
 * @param {string} text 02-storage-classes-and-lifecycle.md 내용
 */
export function readLifecycleFacts(text) {
  const lines = text.split('\n');

  // 1) "스토리지 클래스 한눈에" 표: | 클래스 (API 이름) | 이럴 때 | 검색(첫 바이트) | 최소 보관 기간 | …
  const head = findLine(lines, /^\|\s*클래스 \(API 이름\)\s*\|/, '스토리지 클래스 표 머리');
  const cols = cells(lines[head.line - 1]);
  const iRet = cols.indexOf('검색(첫 바이트)');
  const iMin = cols.indexOf('최소 보관 기간');
  if (iRet < 0 || iMin < 0) fail('표의 "검색(첫 바이트)"·"최소 보관 기간" 열');
  /** @type {Record<string, {api: string, name: string, retrieval: string, minDays: number | null, line: number}>} */
  const classes = {};
  for (let i = head.line + 1; i < lines.length && lines[i].startsWith('|'); i++) {
    const c = cells(lines[i]);
    const m = /^(.+?)\s*\(`([A-Z_]+)`\)$/.exec(c[0]);
    if (!m) fail(`표 ${i + 1}줄의 클래스 이름`);
    classes[m[2]] = { api: m[2], name: m[1], retrieval: c[iRet], minDays: parseMinDays(c[iMin]), line: i + 1 };
  }
  if (!classes.STANDARD) fail('표의 Standard 행');

  // 2) 수명 주기 절의 Mermaid 폭포 그림: 노드 S[Standard] …, 간선 S --> IA …
  const sec = findLine(lines, /^### 수명 주기\(Lifecycle\) 규칙/, '"수명 주기(Lifecycle) 규칙" 절');
  const open = findLine(lines, /^```mermaid\s*$/, '수명 주기 절의 Mermaid 그림', sec.line);
  const ids = {};
  /** @type {Record<string, string[]>} */
  const next = {};
  let close = -1;
  for (let i = open.line; i < lines.length; i++) {
    if (/^```\s*$/.test(lines[i])) {
      close = i + 1;
      break;
    }
    for (const nm of lines[i].matchAll(/(\w+)\[([^\]]+)\]/g)) {
      const api = Object.values(classes).find((c) => c.name === nm[2])?.api;
      if (!api) fail(`그림 노드 "${nm[2]}"에 맞는 표의 클래스`);
      ids[nm[1]] = api;
    }
    const e = /^\s*(\w+)(?:\[[^\]]*\])?\s*-->\s*(\w+)(?:\[[^\]]*\])?\s*$/.exec(lines[i]);
    if (e) {
      if (!ids[e[1]] || !ids[e[2]]) fail(`${i + 1}줄 간선의 노드`);
      (next[ids[e[1]]] ||= []).push(ids[e[2]]);
    }
  }
  if (close < 0 || !next.STANDARD) fail('폭포 그림의 간선');
  for (const api of Object.values(ids)) next[api] ||= [];
  const waterfall = { next, lines: [open.line, close] };

  // 3) 거부 규칙 예(73~76줄 근처): "예: Glacier IR 4일 → Deep Archive 20일은 안 되고 94일 이후여야 한다."
  const ex = findLine(lines, /예: Glacier IR (\d+)일 → Deep Archive (\d+)일은 안 되고 (\d+)일 이후여야 한다/, '거부 규칙의 예');
  const rejectExample = { girDays: Number(ex.m[1]), daDays: Number(ex.m[2]), okFrom: Number(ex.m[3]), line: ex.line };

  // 3b) 만료는 모든 전환보다 늦어야 한다: "만료 일수는 그 규칙의 모든 전환 일수보다 커야 한다"
  const ea = findLine(lines, /만료 일수는 그 규칙의 모든 전환 일수보다 커야 한다/, '만료·전환 순서 규칙');
  const expireAfter = { line: ea.line };

  // 4) 2026-07 변경 전 규칙: "Standard-IA·One Zone-IA로의 전환은 생성 후 30일 이상"
  const old = findLine(lines, /Standard-IA·One Zone-IA로의 전환은 생성 후 (\d+)일 이상/, '2026-07 이전 IA 최소 전환 일수');
  const oldIaMin = { days: Number(old.m[1]), line: old.line };

  // 5) 작은 객체: "128 KB 미만 객체는 기본적으로 어떤 클래스로도 전환되지 않는다"
  const sm = findLine(lines, /(\d+) KB 미만 객체는 기본적으로 어떤 클래스로도 전환되지 않는다/, '작은 객체 전환 기본값');
  const smallObject = { kb: Number(sm.m[1]), line: sm.line };

  // 6) 복원이 필요한 클래스: "Glacier Flexible Retrieval·Deep Archive 객체는 바로 `GET`할 수 없다"
  const rs = findLine(lines, /^(.+?)·(.+?) 객체는 바로 `GET`할 수 없다/, 'Glacier 복원 문장');
  // 원고는 "Deep Archive"처럼 앞의 "Glacier"를 줄여 쓴다 → 표 이름이 같거나 " <이름>"으로 끝나는 클래스
  const byShort = (n) => Object.values(classes).find((c) => c.name === n || c.name.endsWith(` ${n}`))?.api;
  const restore = [rs.m[1], rs.m[2]].map((n) => byShort(n) ?? fail(`복원 문장의 "${n}"`));
  const restoreLine = rs.line;

  // 7) 0일 만료 거부: "존재하지 않는 클래스, 중복 규칙 ID, 0일 만료도 거부한다"
  const z = findLine(lines, /(\d+)일 만료도 거부한다/, '0일 만료 거부 문장');
  const expirationMin = { days: Number(z.m[1]) + 1, line: z.line };

  // 8) lab02 8단계 출력의 영수증 규칙(JSON 배열)
  const id = findLine(lines, /"ID": "receipts-tiering"/, 'lab02 영수증 규칙(receipts-tiering)');
  let a = id.line - 1;
  while (a >= 0 && lines[a] !== '[') a--;
  let b = id.line - 1;
  while (b < lines.length && lines[b] !== ']') b++;
  if (a < 0 || b >= lines.length) fail('영수증 규칙 JSON 배열');
  const rule = JSON.parse(lines.slice(a, b + 1).join('\n')).find((r) => r.ID === 'receipts-tiering');
  const receipts = {
    transitions: rule.Transitions.map(([days, cls]) => ({ cls, days })),
    expireDays: rule.ExpireDays,
    line: id.line,
  };

  // 9) lab02 11·12단계: 거부되는 두 규칙
  const r11 = findLine(lines, /\(Glacier IR (\d+)일 → Deep Archive (\d+)일\) → 거부/, 'lab02 11단계');
  const r12 = findLine(lines, /\(GLACIER (\d+)일 → STANDARD_IA (\d+)일\) → 거부/, 'lab02 12단계');
  const labRejects = {
    tooSoon: { transitions: [{ cls: 'GLACIER_IR', days: Number(r11.m[1]) }, { cls: 'DEEP_ARCHIVE', days: Number(r11.m[2]) }], line: r11.line },
    backwards: { transitions: [{ cls: 'GLACIER', days: Number(r12.m[1]) }, { cls: 'STANDARD_IA', days: Number(r12.m[2]) }], line: r12.line },
  };

  // 10) 스스로 확인 1번: "생성 7일 후 Standard-IA로, 20일 후 삭제" 와 답의 "13일만 두고 … 남은 17일치"
  const sc = findLine(lines, /생성 (\d+)일 후 Standard-IA로, (\d+)일 후 삭제/, '스스로 확인 1번');
  const ans = findLine(lines, /(\d+)일만 두고 지우므로, 객체마다 남은 (\d+)일치/, '스스로 확인 1번의 답', sc.line);
  const selfCheck = {
    transitions: [{ cls: 'STANDARD_IA', days: Number(sc.m[1]) }],
    expireDays: Number(sc.m[2]),
    line: sc.line,
    answer: { held: Number(ans.m[1]), remaining: Number(ans.m[2]), line: ans.line },
  };

  return { lesson: LESSON, classes, tableLine: head.line, waterfall, rejectExample, expireAfter, oldIaMin, smallObject, restore, restoreLine, expirationMin, receipts, labRejects, selfCheck };
}
