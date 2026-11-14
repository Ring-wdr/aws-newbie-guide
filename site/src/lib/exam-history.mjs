// 모의고사 지난 응시 기록 — 순수 함수(브라우저·시험 공용). 단위 시험: exam-history.test.mjs
// 저장은 exam.ts가 storage.ts로 "exam:m14-mock-exam:history"(→ localStorage "aws-newbie-guide:exam:m14-mock-exam:history")에 한다.
// 점수는 제출 때 exam-core.gradeExam(= grade.py 규칙)이 낸 값을 그대로 담는다. 여기서는 다시 채점하지 않는다.

export const HISTORY_MAX = 20;

/**
 * gradeExam 결과 → 기록 한 줄.
 * @param {ReturnType<import('./exam-core.mjs').gradeExam>} r
 * @param {{ at: string, elapsedMs: number, auto?: boolean }} meta
 */
export function makeRecord(r, meta) {
  return {
    at: meta.at,
    ok: r.totalOk,
    total: r.totalQ,
    pct: r.pctText,
    pass: r.pass,
    blank: r.blank,
    domains: r.domains.map((d) => ({ domain: d.domain, ok: d.ok, total: d.total })),
    elapsedMs: Math.max(0, Math.round(meta.elapsedMs)),
    auto: Boolean(meta.auto),
  };
}

const isInt = (n) => Number.isInteger(n) && n >= 0;

/** 저장값을 믿지 않는다: 형식이 맞는 기록만, 최신순 최대 HISTORY_MAX개. */
export function sanitizeHistory(raw) {
  const list = raw && typeof raw === 'object' && Array.isArray(raw.records) ? raw.records : [];
  const out = [];
  for (const x of list) {
    if (!x || typeof x !== 'object') continue;
    if (typeof x.at !== 'string' || Number.isNaN(Date.parse(x.at))) continue;
    if (!isInt(x.ok) || !isInt(x.total) || x.total === 0 || x.ok > x.total) continue;
    if (typeof x.pct !== 'string' || !/^\d{1,3}\.\d$/.test(x.pct)) continue;
    const domains = Array.isArray(x.domains)
      ? x.domains.filter((d) => d && typeof d.domain === 'string' && isInt(d.ok) && isInt(d.total) && d.ok <= d.total).map((d) => ({ domain: d.domain, ok: d.ok, total: d.total }))
      : [];
    out.push({ at: x.at, ok: x.ok, total: x.total, pct: x.pct, pass: x.pass === true, blank: isInt(x.blank) ? x.blank : 0, domains, elapsedMs: isInt(x.elapsedMs) ? x.elapsedMs : 0, auto: x.auto === true });
  }
  out.sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
  return { v: 1, records: out.slice(0, HISTORY_MAX) };
}

/** 기록을 맨 앞에 더하고 최근 HISTORY_MAX개만 남긴다(원래 값은 바꾸지 않는다). */
export function addRecord(raw, record) {
  const h = sanitizeHistory(raw);
  return sanitizeHistory({ records: [record, ...h.records] });
}

/** 소요 시간 "1시간 5분 3초" / "12분 0초". */
export function formatDuration(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h ? `${h}시간 ${m}분 ${sec}초` : `${m}분 ${sec}초`;
}

/** 날짜 "2026-11-14 13:05"(브라우저의 지역 시간). */
export function formatWhen(iso) {
  const d = new Date(iso);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 진행 추적에 보일 최근 응시 요약(없으면 null). */
export function latestExam(raw) {
  const h = sanitizeHistory(raw);
  const r = h.records[0];
  return r ? { when: formatWhen(r.at), ok: r.ok, total: r.total, pct: r.pct, pass: r.pass, count: h.records.length } : null;
}
