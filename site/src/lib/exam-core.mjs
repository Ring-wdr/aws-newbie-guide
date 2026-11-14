// M14 모의고사 채점 규칙 — curriculum/m14-capstone-exam/mock-exam/grade.py 를 그대로 옮긴 것.
// 정답표·문항 형식·통과 기준·도메인 이름은 원고(answer-key.md, questions.md)와 grade.py 에서 읽는다(여기 박지 않는다).
// 브라우저(시험 모드)와 검사 도구(tools/sitecheck 가 node로 부른다)가 같은 코드를 쓴다. 의존성 없는 순수 함수만 둔다.

/** grade.py load_key 와 같은 정규식. */
const KEY_ROW = /^\|\s*(\d+)\s*\|\s*([A-F]+)\s*\|\s*(D[1-4])\s*\|\s*([1-4]\.\d)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$/;

/** @returns {Record<number, {number:number, answer:string[], domain:string, task:string, kind:string, topic:string}>} */
export function parseKey(text) {
  const key = {};
  for (const line of text.split(/\r?\n/)) {
    const m = KEY_ROW.exec(line);
    if (m) {
      const n = Number(m[1]);
      key[n] = { number: n, answer: [...new Set(m[2])].sort(), domain: m[3], task: m[4], kind: m[5], topic: m[6] };
    }
  }
  return key;
}

/** grade.py load_questions 와 같은 규칙: 문항 번호 → {options, choose, texts} */
export function parseQuestions(text) {
  const qs = {};
  let current = null;
  for (const line of text.split(/\r?\n/)) {
    const h = /^## 문항 (\d+)\s*$/.exec(line);
    if (h) {
      current = Number(h[1]);
      qs[current] = { options: [], choose: 1, texts: {} };
      continue;
    }
    if (current === null) continue;
    const o = /^- ([A-F])\. (.*)$/.exec(line);
    if (o) {
      qs[current].options.push(o[1]);
      qs[current].texts[o[1]] = o[2];
    }
    if (line.includes('(두 개를 고르시오.)')) qs[current].choose = 2;
    else if (line.includes('(세 개를 고르시오.)')) qs[current].choose = 3;
  }
  return qs;
}

/** grade.py 의 상수(PASS_PCT, DOMAINS, TOTAL)를 소스에서 읽는다. 못 읽으면 예외. */
export function parseGradeConstants(pySource) {
  const pass = /^PASS_PCT\s*=\s*([\d.]+)/m.exec(pySource);
  const total = /^TOTAL\s*=\s*(\d+)/m.exec(pySource);
  const dom = /^DOMAINS\s*=\s*\{([^}]*)\}/m.exec(pySource);
  if (!pass || !total || !dom) throw new Error('grade.py 에서 PASS_PCT·TOTAL·DOMAINS 를 읽지 못했다');
  const domains = {};
  for (const m of dom[1].matchAll(/"(D[1-4])"\s*:\s*"([^"]*)"/g)) domains[m[1]] = m[2];
  if (Object.keys(domains).length !== 4) throw new Error('grade.py DOMAINS 형식이 바뀌었다');
  return { passPct: Number(pass[1]), total: Number(total[1]), domains };
}

/** questions.md "응시 방법"의 타이머 분(예: "타이머를 **130분**"). */
export function parseTimerMinutes(questionsText) {
  const m = /타이머를\s*\*\*(\d+)분\*\*/.exec(questionsText);
  if (!m) throw new Error('questions.md 에서 "타이머를 **N분**" 을 찾지 못했다');
  return Number(m[1]);
}

/**
 * grade.py parse_answers 와 같은 규칙으로 답안 파일을 읽는다.
 * @returns {{answers: Record<number,string[]>, unsure: number[], warnings: string[], error?: string}}
 */
export function parseAnswerSheet(text, total = 65) {
  const answers = {};
  const unsure = new Set();
  const warnings = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.split('#', 1)[0].trim();
    if (!line) continue;
    const m = /^(\d+)\s*[.:)]?\s*(.*)$/s.exec(line);
    if (!m) return { answers, unsure: [...unsure], warnings, error: `답안 형식을 읽을 수 없습니다: ${JSON.stringify(raw)}` };
    const n = Number(m[1]);
    const rest = m[2].toUpperCase();
    if (rest.includes('?')) unsure.add(n);
    const letters = [...new Set(rest.match(/[A-F]/g) || [])].sort();
    if (!(n >= 1 && n <= total)) {
      warnings.push(`${n}번은 없는 문항이다(1~${total}) — 무시`);
      continue;
    }
    if (!letters.length && rest.replace(/[\s?]/g, '')) warnings.push(`${n}번 답에 A~F 글자가 없다 — 무응답으로 처리`);
    if (letters.length && n in answers) warnings.push(`${n}번이 두 번 나온다 — 뒤의 답(${letters.join('')})을 쓴다`);
    if (letters.length) answers[n] = letters;
  }
  return { answers, unsure: [...unsure].sort((a, b) => a - b), warnings };
}

const sameSet = (a, b) => a && b && a.length === b.length && a.every((x, i) => x === b[i]);

/**
 * grade.py grade() 와 같은 채점. 복수 응답은 고른 글자 집합이 정답과 정확히 같아야 정답(부분 점수 없음),
 * 무응답·없는 번호는 오답.
 */
export function gradeExam(key, answers, unsure, consts) {
  const per = {};
  for (const d of Object.keys(consts.domains)) per[d] = { ok: 0, total: 0 };
  const wrong = [];
  const lucky = [];
  const unsureSet = new Set(unsure || []);
  const nums = Object.keys(key).map(Number).sort((a, b) => a - b);
  for (const n of nums) {
    const item = key[n];
    per[item.domain].total += 1;
    const mine = answers[n] ? [...answers[n]].sort() : null;
    if (sameSet(mine, item.answer)) {
      per[item.domain].ok += 1;
      if (unsureSet.has(n)) lucky.push(n);
    } else wrong.push(n);
  }
  const totalOk = Object.values(per).reduce((s, v) => s + v.ok, 0);
  const totalQ = nums.length;
  const pct = (100 * totalOk) / totalQ;
  const answered = nums.filter((n) => answers[n] && answers[n].length).length;
  const domains = Object.entries(per).map(([d, v]) => ({
    domain: d,
    name: consts.domains[d],
    ok: v.ok,
    total: v.total,
    pct: v.total ? (100 * v.ok) / v.total : 0,
  }));
  return {
    domains,
    totalOk,
    totalQ,
    pct,
    pctText: pct.toFixed(1),
    pass: pct >= consts.passPct,
    more: Math.round((consts.passPct * totalQ) / 100 - totalOk),
    blank: totalQ - answered,
    weak: domains.filter((d) => d.pct < 65).map((d) => d.domain),
    wrong,
    lucky,
  };
}

/** answer-sheet.txt 형식으로 내보낸다(번호 답, 표시한 문항은 "?"). grade.py 가 그대로 읽는다. */
export function formatAnswerSheet(answers, flagged, total = 65) {
  const flags = new Set(flagged || []);
  const lines = ['# M14 모의고사 답안지 — 가이드 사이트 시험 모드에서 내보냄 (표시해 둔 문항은 답 뒤에 ?)'];
  for (let n = 1; n <= total; n++) {
    const a = (answers[n] || []).slice().sort().join('');
    lines.push(`${n} ${a}${flags.has(n) ? '?' : ''}`);
  }
  return `${lines.join('\n')}\n`;
}
