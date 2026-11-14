// 진행 추적 목록(빌드 때). 모듈 README에 표시 줄 <!-- widget: progress-tracker --> 이 있는 모듈만 추적한다.
// 표시가 있는데 README·quiz.md를 읽지 못하면 빌드를 실패시킨다(조용히 넘어가지 않는다).
import fs from 'node:fs';
import path from 'node:path';
import { REPO_ROOT, routeForRepoPath, fileViewRoute, readTitle } from '../lib/repo.mjs';
import { readModuleItems, countQuizQuestions, storageKey } from './progress.mjs';
import { withBase } from '../lib/base.mjs';

export const TRACKER_MARK = /^<!--\s*widget:\s*progress-tracker\s*-->\s*$/m;

const read = (rel) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
// 링크 주소(href)에는 base 접두어를 붙이고, 저장 키에 쓰는 quizRoute 는 base 와 무관한 사이트 경로로 둔다.
const hrefFor = (file) => withBase(file.endsWith('.md') ? routeForRepoPath(file) : fileViewRoute(file));

/** 모듈 하나("m06-integration-messaging")의 추적 정보. */
export function moduleProgress(modDir) {
  const dir = `curriculum/${modDir}`;
  const quizRel = `${dir}/quiz.md`;
  const quizQuestions = fs.existsSync(path.join(REPO_ROOT, quizRel)) ? countQuizQuestions(read(quizRel)) : undefined;
  let items;
  try {
    items = readModuleItems(read(`${dir}/README.md`), dir, { quizQuestions });
  } catch (e) {
    throw new Error(`${dir}/README.md: 진행 추적 목록을 읽지 못했다 — ${e.message}`);
  }
  const mod = modDir.slice(0, 3);
  return {
    mod,
    modDir,
    code: mod.toUpperCase(),
    title: readTitle(`${dir}/README.md`).replace(/^M\d\d\.\s*/, ''),
    href: withBase(routeForRepoPath(`${dir}/README.md`)),
    key: storageKey(mod),
    quizRoute: routeForRepoPath(quizRel),
    quizTotal: quizQuestions ?? 0,
    items: items.map((it) => ({ ...it, href: hrefFor(it.file) })),
  };
}

let cache;
/** 표시 줄이 있는 모든 모듈(이름 순). */
export function progressCatalog() {
  if (cache) return cache;
  const cur = path.join(REPO_ROOT, 'curriculum');
  const mods = fs.existsSync(cur)
    ? fs
        .readdirSync(cur)
        .filter((d) => /^m\d\d-/.test(d) && fs.existsSync(path.join(cur, d, 'README.md')))
        .sort()
    : [];
  cache = mods.filter((d) => TRACKER_MARK.test(read(`curriculum/${d}/README.md`))).map(moduleProgress);
  return cache;
}

/** 원고 경로가 추적되는 레슨이면 { module, item } — 레슨 페이지 끝의 "이 레슨 완료"에 쓴다. */
export function lessonOf(rel) {
  for (const m of progressCatalog()) {
    const item = m.items.find((it) => it.kind === 'lesson' && it.file === rel);
    if (item) return { module: m, item };
  }
  return null;
}
