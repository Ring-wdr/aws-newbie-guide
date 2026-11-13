// 저장소 경로와 페이지 경로(라우트)의 대응. 빌드 설정·변환기·검사 스크립트가 모두 이 파일을 쓴다.
// 원고는 저장소의 제자리(curriculum/, docs/, README.md)에서 읽고 복사하지 않는다.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 빌드된 사전 렌더링 청크(dist/.prerender) 안에서는 import.meta.url 이 원래 위치가 아니므로,
// astro.config.mjs 가 설정 시점에 GUIDE_SITE_DIR 을 정해 둔다.
export const SITE_DIR = path.resolve(process.env.GUIDE_SITE_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), '../..'));

/** 원고를 읽을 저장소 루트. 시험용 고정 원고(fixture)로 빌드할 때만 GUIDE_REPO_ROOT로 바꾼다. */
export const REPO_ROOT = path.resolve(process.env.GUIDE_REPO_ROOT || path.join(SITE_DIR, '..'));

/** 맞춤 위젯을 찾는 디렉터리. 기본은 site/src/widgets. 시험용 빌드만 GUIDE_WIDGETS_DIR로 바꾼다. */
export const WIDGETS_DIR = path.resolve(process.env.GUIDE_WIDGETS_DIR || path.join(SITE_DIR, 'src/widgets'));

/** 페이지로 만드는 원고. 저장소 루트 기준 glob. */
export const CONTENT_PATTERNS = ['README.md', 'docs/*.md', 'curriculum/**/*.md'];

/**
 * 시범(P1)에서 사람이 직접 확인하는 페이지. 빌드는 기본으로 전체를 만들고,
 * GUIDE_SCOPE=pilot 이면 이 목록(+ 홈)만 만든다(개발 중 빠른 빌드용).
 */
export const PILOT_FILES = [
  'README.md',
  'curriculum/m06-integration-messaging/README.md',
  'curriculum/m06-integration-messaging/01-why-decoupling.md',
  'curriculum/m06-integration-messaging/02-sqs.md',
  'curriculum/m06-integration-messaging/03-sns-fanout.md',
  'curriculum/m06-integration-messaging/04-eventbridge.md',
  'curriculum/m06-integration-messaging/05-step-functions.md',
  'curriculum/m06-integration-messaging/06-streaming.md',
  'curriculum/m06-integration-messaging/cheatsheet.md',
  'curriculum/m06-integration-messaging/quiz.md',
  'curriculum/m00-orientation/03-environment-setup.md',
  'curriculum/m03-compute-scaling/06-auto-scaling.md',
  'curriculum/m14-capstone-exam/mock-exam/questions.md',
  'curriculum/m14-capstone-exam/mock-exam/answer-key.md',
];

export const SCOPE = process.env.GUIDE_SCOPE === 'pilot' ? 'pilot' : 'all';

const toPosix = (p) => p.split(path.sep).join('/');

/** 저장소 루트 기준 상대 경로(posix). */
export function repoRel(abs) {
  return toPosix(path.relative(REPO_ROOT, abs));
}

function walk(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || ent.name === 'node_modules') continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

let contentCache;
/** 페이지가 되는 모든 원고(저장소 상대 경로, 정렬됨). SCOPE와 무관한 전체 목록. */
export function allContentFiles() {
  if (contentCache) return contentCache;
  const files = [];
  if (fs.existsSync(path.join(REPO_ROOT, 'README.md'))) files.push('README.md');
  const docs = path.join(REPO_ROOT, 'docs');
  if (fs.existsSync(docs)) {
    for (const f of fs.readdirSync(docs).sort()) if (f.endsWith('.md')) files.push(`docs/${f}`);
  }
  const cur = path.join(REPO_ROOT, 'curriculum');
  if (fs.existsSync(cur)) {
    for (const f of walk(cur).sort()) if (f.endsWith('.md')) files.push(repoRel(f));
  }
  contentCache = files;
  return files;
}

/** 이번 빌드가 페이지로 만드는 원고. */
export function builtContentFiles() {
  const all = allContentFiles();
  if (SCOPE === 'pilot') return all.filter((f) => PILOT_FILES.includes(f));
  return all;
}

/** 원고 경로 → 콘텐츠 컬렉션 id. README.md는 디렉터리의 대표 페이지, 루트 README는 홈(index). */
export function idForRepoPath(rel) {
  let p = rel.replace(/\.md$/i, '');
  if (p === 'README') return 'index';
  p = p.replace(/\/README$/, '');
  return p.toLowerCase();
}

/** 원고 경로 → 사이트 경로("/.../"). */
export function routeForRepoPath(rel) {
  const id = idForRepoPath(rel);
  return id === 'index' ? '/' : `/${id}/`;
}

/** Markdown이 아닌 파일(lab·sdk 등) → 소스 보기 페이지 경로. */
export function fileViewRoute(rel) {
  return `/files/${rel}/`;
}

export function isInsideRepo(abs) {
  const rel = path.relative(REPO_ROOT, abs);
  return rel && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/** 모듈 디렉터리 이름(mNN-slug) — 경로가 커리큘럼 모듈 안이면. */
export function moduleOf(rel) {
  const m = /^curriculum\/(m\d\d-[^/]+)\//.exec(rel);
  return m ? m[1] : null;
}

/** 파일 종류. 변환기가 어떤 규칙을 적용할지 정한다. */
export function kindOf(rel) {
  if (rel === 'README.md') return 'home';
  if (rel.startsWith('docs/')) return 'doc';
  if (/\/mock-exam\/questions\.md$/.test(rel)) return 'exam-questions';
  if (/\/mock-exam\/answer-key\.md$/.test(rel)) return 'exam-key';
  if (/\/capstone-self-check\.md$/.test(rel)) return 'self-checklist';
  const base = rel.split('/').pop();
  if (base === 'README.md') return 'module';
  if (base === 'quiz.md') return 'quiz';
  if (base === 'cheatsheet.md') return 'cheatsheet';
  if (/^\d\d-.*\.md$/.test(base)) return 'lesson';
  return 'other';
}

/** 원고 첫 줄의 H1 제목(없으면 파일 이름). */
export function readTitle(rel) {
  const text = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
  const m = /^#\s+(.+?)\s*#*\s*$/m.exec(text.split('\n').find((l) => l.trim() !== '') || '');
  return m ? stripInlineMarkdown(m[1]) : rel.split('/').pop();
}

/** 제목은 글자로만 쓰이므로(탭 제목·사이드바) 인라인 Markdown 표시(`코드`, **굵게**, [링크](주소))를 걷어 낸다. */
export function stripInlineMarkdown(s) {
  return s
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__)(.+?)\1/g, '$2')
    .replace(/`([^`]*)`/g, '$1')
    .trim();
}

/** 사이드바에 쓸 짧은 이름: "M06-02. SQS — ..." → "02. SQS — ...". */
export function shortLabel(rel) {
  const title = readTitle(rel);
  const kind = kindOf(rel);
  if (kind === 'module') return '개요';
  if (kind === 'lesson') {
    const m = /^M\d\d-(\d\d)\.\s*(.*)$/.exec(title);
    return m ? `${m[1]}. ${m[2]}` : title;
  }
  if (kind === 'quiz') return '퀴즈';
  if (kind === 'cheatsheet') return title.includes('통합') ? '통합 치트시트' : '치트시트';
  if (kind === 'exam-questions') return '모의고사 (시험 모드)';
  if (kind === 'exam-key') return '모의고사 정답과 해설';
  if (kind === 'self-checklist') return '캡스톤 자기 점검표';
  return title;
}
