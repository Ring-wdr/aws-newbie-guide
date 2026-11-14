// 진행 추적(전 모듈 공용) — 화면과 분리한 순수 함수. 브라우저와 빌드가 함께 쓴다(node: 모듈을 쓰지 않는다).
// 단위 시험: progress.test.mjs. 항목 목록은 원고(모듈 README의 "## 레슨"·"## 실습" 표, quiz.md)에서 빌드 때 읽는다.
// 사이트 쪽에 사본을 두지 않는다. 원고를 읽는 쪽은 catalog.mjs.

/** 모듈 하나의 저장 키. storage.ts가 앞에 "guide:"를 붙인다 → localStorage "guide:progress:m06"(P1의 M06 값과 같다). */
export const storageKey = (mod) => `progress:${mod}`;
export const STORAGE_KEY = storageKey('m06'); // P1 호환(M06)
export const QUIZ_STATE_KEY = (quizRoute) => `quiz:${quizRoute.replace(/\/+$/, '')}`; // guide-client.ts의 퀴즈 저장 키와 같은 규칙

const cells = (line) =>
  line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((c) => c.trim());
const LINK = /\[([^\]]+)\]\(\.\/([^)\s#]+)(?:#[^)\s]*)?\)/;

/** "## 제목" 아래 첫 표의 데이터 행(머리·구분 행 제외). 표 앞의 안내 문단은 건너뛴다. */
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

const plain = (s) => s.replace(/\*\*|`/g, '').replace(/\\([\\`*_{}[\]()#+\-.!|~])/g, '$1');

/**
 * 모듈 README에서 레슨·실습·퀴즈(또는 모의고사·캡스톤) 항목을 읽는다.
 * - 레슨: "## 레슨" 표의 둘째 칸 링크.
 * - 실습: "## 실습" 표의 둘째 칸 첫 링크(lab·sdk 파일). 링크가 없는 행("(레슨 문서 안)" 워크시트)은
 *   셋째 칸의 첫 레슨 번호로 그 레슨 페이지를 가리킨다.
 * - 퀴즈: README의 quiz.md 링크. 퀴즈에 문항이 없으면(M14 — 모의고사로 대신한다) 대신 README가 링크한
 *   모의고사(mock-exam/questions.md)와 캡스톤 자기 점검표(capstone-self-check.md)를 "모의고사·캡스톤"으로 둔다.
 * @param {string} readme README.md 내용
 * @param {string} moduleDir "curriculum/m06-integration-messaging"
 * @param {{ quizQuestions?: number }} [opts] quiz.md 문항 수(모르면 1 이상으로 본다)
 * @returns {{ id: string, kind: 'lesson' | 'lab' | 'quiz' | 'exam', label: string, file: string, line: number }[]}
 */
export function readModuleItems(readme, moduleDir, opts = {}) {
  const lines = readme.split('\n');
  const items = [];
  const lessonFile = new Map();
  for (const r of tableUnder(lines, '레슨')) {
    const m = LINK.exec(r.cells[1] ?? '');
    if (!m) throw new Error(`README.md:${r.line}: 레슨 행에서 링크를 찾지 못했다`);
    lessonFile.set(String(Number(r.cells[0])), m[2]);
    items.push({ id: `lesson:${m[2].replace(/\.md$/, '')}`, kind: 'lesson', label: `레슨 ${r.cells[0]}. ${plain(m[1])}`, file: `${moduleDir}/${m[2]}`, line: r.line });
  }
  for (const r of tableUnder(lines, '실습')) {
    const m = LINK.exec(r.cells[1] ?? '');
    if (m) {
      items.push({ id: `lab:${m[2]}`, kind: 'lab', label: `${plain(m[1])} — ${plain(r.cells[0])}`, file: `${moduleDir}/${m[2]}`, line: r.line });
      continue;
    }
    // 링크 없는 행: 레슨 문서 안의 워크시트. 레슨 칸의 첫 번호가 가리키는 레슨으로 연다.
    const n = /\d+/.exec(r.cells[2] ?? '')?.[0];
    const f = n ? lessonFile.get(String(Number(n))) : undefined;
    if (!f) throw new Error(`README.md:${r.line}: 실습 행에 링크도, 레슨 표에 있는 레슨 번호도 없다`);
    const name = plain(r.cells[0]);
    items.push({ id: `lab:in-lesson:${name}`, kind: 'lab', label: `${name} — 레슨 ${Number(n)} 안`, file: `${moduleDir}/${f}`, line: r.line });
  }
  const q = lines.findIndex((l) => /\]\(\.\/quiz\.md\)/.test(l));
  if (q < 0) throw new Error('모듈 README에서 quiz.md 링크를 찾지 못했다');
  if (opts.quizQuestions === 0) {
    const want = [
      { target: 'mock-exam/questions.md', id: 'exam:mock-exam' },
      { target: 'capstone-self-check.md', id: 'exam:capstone-self-check' },
    ];
    for (const w of want) {
      const re = new RegExp(`\\[([^\\]]+)\\]\\(\\./${w.target.replace(/[.]/g, '\\.')}\\)`);
      const at = lines.findIndex((l) => re.test(l));
      if (at < 0) continue;
      items.push({ id: w.id, kind: 'exam', label: plain(re.exec(lines[at])[1]), file: `${moduleDir}/${w.target}`, line: at + 1 });
    }
    if (!items.some((i) => i.kind === 'exam')) throw new Error('퀴즈에 문항이 없는데 README에서 모의고사·캡스톤 링크도 찾지 못했다');
  } else {
    items.push({ id: 'quiz', kind: 'quiz', label: '모듈 퀴즈', file: `${moduleDir}/quiz.md`, line: q + 1 });
  }
  const ids = new Set(items.map((i) => i.id));
  if (ids.size !== items.length) throw new Error('진행 항목 id가 겹친다');
  return items;
}

/** quiz.md의 문항 수(**N.** 로 시작하는 줄). */
export function countQuizQuestions(quiz) {
  return quiz.split('\n').filter((l) => /^\*\*\d+\.\*\*\s/.test(l)).length;
}

/** 저장된 값을 믿지 않는다: 모르는 id·참이 아닌 값은 버린다. ids는 항목 배열이나 id 문자열 배열. */
export function sanitize(raw, items) {
  const done = {};
  const src = raw && typeof raw === 'object' && raw.done && typeof raw.done === 'object' ? raw.done : {};
  for (const it of items) {
    const id = typeof it === 'string' ? it : it.id;
    if (src[id] === true) done[id] = true;
  }
  return { v: 1, done };
}

/**
 * 항목 하나만 바꾼다(레슨 페이지의 "이 레슨 완료"). 저장된 다른 id는 모르는 것이라도 그대로 둔다 —
 * 그 페이지는 모듈의 전체 목록을 모르므로 지우면 안 된다(읽을 때 sanitize가 거른다).
 */
export function setOne(raw, id, on) {
  const src = raw && typeof raw === 'object' && raw.done && typeof raw.done === 'object' ? raw.done : {};
  const done = {};
  for (const [k, v] of Object.entries(src)) if (v === true) done[k] = true;
  if (on) done[id] = true;
  else delete done[id];
  return { v: 1, done };
}

export function toggle(state, id, on) {
  const done = { ...state.done };
  if (on) done[id] = true;
  else delete done[id];
  return { v: 1, done };
}

/** 화면에 내는 묶음 순서와 이름. */
export const GROUPS = [
  { kind: 'lesson', title: '레슨' },
  { kind: 'lab', title: '실습' },
  { kind: 'quiz', title: '퀴즈' },
  { kind: 'exam', title: '모의고사·캡스톤' },
];

/** 전체와 종류별 완료 수, 백분율(내림). by에는 항목이 있는 종류만 담는다. */
export function computeProgress(items, state) {
  const by = {};
  for (const it of items) {
    by[it.kind] ??= { done: 0, total: 0 };
    by[it.kind].total++;
    if (state.done[it.id]) by[it.kind].done++;
  }
  const total = items.length;
  const done = items.filter((it) => state.done[it.id]).length;
  return { done, total, pct: total ? Math.floor((done / total) * 100) : 0, by };
}

/** 퀴즈 페이지가 저장한 상태(guide-client.ts의 QuizState)에서 채점한 문항 수만 센다. 정답 여부는 보지 않는다. */
export function quizGradedCount(quizState) {
  if (!quizState || typeof quizState !== 'object' || !quizState.graded || typeof quizState.graded !== 'object') return 0;
  const picked = quizState.picked && typeof quizState.picked === 'object' ? quizState.picked : {};
  return Object.entries(quizState.graded).filter(([n, g]) => g === true && typeof picked[n] === 'string').length;
}
