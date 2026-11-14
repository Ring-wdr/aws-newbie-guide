// M06 진행 추적 — 화면과 분리한 순수 함수. 단위 시험: progress.test.mjs
// 항목 목록은 원고(모듈 README의 "## 레슨"·"## 실습" 표, quiz.md)에서 빌드 때 읽는다. 사이트 쪽에 사본을 두지 않는다.

export const STORAGE_KEY = 'progress:m06'; // storage.ts가 앞에 "guide:"를 붙인다 → localStorage "guide:progress:m06"
export const QUIZ_STATE_KEY = (quizRoute) => `quiz:${quizRoute.replace(/\/+$/, '')}`; // guide-client.ts의 퀴즈 저장 키와 같은 규칙

const cells = (line) =>
  line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((c) => c.trim());
const LINK = /\[([^\]]+)\]\(\.\/([^)\s]+)\)/;

/** "## 제목" 아래 첫 표의 데이터 행(머리·구분 행 제외). */
function tableUnder(lines, heading) {
  const start = lines.findIndex((l) => l.trim() === `## ${heading}`);
  if (start < 0) throw new Error(`모듈 README에서 "## ${heading}" 절을 찾지 못했다`);
  const rows = [];
  let inTable = false;
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (/^##\s/.test(l)) break;
    if (l.trim().startsWith('|')) {
      inTable = true;
      rows.push({ cells: cells(l), line: i + 1 });
    } else if (inTable) break;
  }
  if (rows.length < 3) throw new Error(`"## ${heading}" 절에서 표를 찾지 못했다`);
  return rows.slice(2);
}

const plain = (s) => s.replace(/\*\*|`/g, '');

/**
 * 모듈 README에서 레슨·실습·퀴즈 항목을 읽는다.
 * @param {string} readme README.md 내용
 * @param {string} moduleDir "curriculum/m06-integration-messaging"
 * @returns {{ id: string, kind: 'lesson' | 'lab' | 'quiz', label: string, file: string, line: number }[]}
 */
export function readModuleItems(readme, moduleDir) {
  const lines = readme.split('\n');
  const items = [];
  for (const r of tableUnder(lines, '레슨')) {
    const m = LINK.exec(r.cells[1] ?? '');
    if (!m) throw new Error(`README.md:${r.line}: 레슨 행에서 링크를 찾지 못했다`);
    items.push({ id: `lesson:${m[2].replace(/\.md$/, '')}`, kind: 'lesson', label: `레슨 ${r.cells[0]}. ${plain(m[1])}`, file: `${moduleDir}/${m[2]}`, line: r.line });
  }
  for (const r of tableUnder(lines, '실습')) {
    const m = LINK.exec(r.cells[1] ?? '');
    if (!m) throw new Error(`README.md:${r.line}: 실습 행에서 링크를 찾지 못했다`);
    items.push({ id: `lab:${m[2]}`, kind: 'lab', label: `${plain(m[1])} — ${plain(r.cells[0])}`, file: `${moduleDir}/${m[2]}`, line: r.line });
  }
  const q = lines.findIndex((l) => /\[quiz\.md\]\(\.\/quiz\.md\)/.test(l));
  if (q < 0) throw new Error('모듈 README에서 quiz.md 링크를 찾지 못했다');
  items.push({ id: 'quiz', kind: 'quiz', label: '모듈 퀴즈', file: `${moduleDir}/quiz.md`, line: q + 1 });
  const ids = new Set(items.map((i) => i.id));
  if (ids.size !== items.length) throw new Error('진행 항목 id가 겹친다');
  return items;
}

/** quiz.md의 문항 수(**N.** 로 시작하는 줄). */
export function countQuizQuestions(quiz) {
  return quiz.split('\n').filter((l) => /^\*\*\d+\.\*\*\s/.test(l)).length;
}

/** 저장된 값을 믿지 않는다: 모르는 id·참이 아닌 값은 버린다. */
export function sanitize(raw, items) {
  const done = {};
  const src = raw && typeof raw === 'object' && raw.done && typeof raw.done === 'object' ? raw.done : {};
  for (const it of items) if (src[it.id] === true) done[it.id] = true;
  return { v: 1, done };
}

export function toggle(state, id, on) {
  const done = { ...state.done };
  if (on) done[id] = true;
  else delete done[id];
  return { v: 1, done };
}

const KINDS = /** @type {const} */ (['lesson', 'lab', 'quiz']);

/** 전체와 종류별 완료 수, 백분율(내림). */
export function computeProgress(items, state) {
  const by = Object.fromEntries(KINDS.map((k) => [k, { done: 0, total: 0 }]));
  for (const it of items) {
    by[it.kind].total++;
    if (state.done[it.id]) by[it.kind].done++;
  }
  const total = items.length;
  const done = KINDS.reduce((s, k) => s + by[k].done, 0);
  return { done, total, pct: total ? Math.floor((done / total) * 100) : 0, by };
}

/** 퀴즈 페이지가 저장한 상태(guide-client.ts의 QuizState)에서 채점한 문항 수만 센다. 정답 여부는 보지 않는다. */
export function quizGradedCount(quizState) {
  if (!quizState || typeof quizState !== 'object' || !quizState.graded || typeof quizState.graded !== 'object') return 0;
  const picked = quizState.picked && typeof quizState.picked === 'object' ? quizState.picked : {};
  return Object.entries(quizState.graded).filter(([n, g]) => g === true && typeof picked[n] === 'string').length;
}
