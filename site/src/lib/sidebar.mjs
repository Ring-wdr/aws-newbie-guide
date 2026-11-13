// 사이드바(모듈 → 레슨) 구성. 원고 디렉터리를 읽어 만든다(등록 파일을 따로 두지 않는다).
import { builtContentFiles, kindOf, readTitle, routeForRepoPath, shortLabel } from './repo.mjs';
import { ko } from '../i18n/ko.mjs';

const ORDER = { module: 0, lesson: 1, cheatsheet: 2, quiz: 3, 'self-checklist': 4, 'exam-questions': 5, 'exam-key': 6, other: 7 };

function sortKey(rel) {
  const base = rel.split('/').pop();
  return `${ORDER[kindOf(rel)] ?? 9}-${base}`;
}

export function buildSidebar() {
  const files = builtContentFiles();
  const groups = new Map();
  for (const rel of files) {
    const m = /^curriculum\/(m\d\d-[^/]+)\//.exec(rel);
    if (!m) continue;
    if (!groups.has(m[1])) groups.set(m[1], []);
    groups.get(m[1]).push(rel);
  }
  const sidebar = [];
  if (files.includes('README.md')) sidebar.push({ label: ko.site.homeLabel, link: '/' });
  for (const [mod, rels] of [...groups.entries()].sort()) {
    const readme = `curriculum/${mod}/README.md`;
    // 모듈 이름: README 제목 "M06. 애플리케이션 통합과 디커플링"
    const label = rels.includes(readme) ? readTitle(readme).replace(/^(M\d\d)\.\s*/, '$1 ') : mod;
    sidebar.push({
      label,
      collapsed: true,
      items: rels
        .sort((a, b) => sortKey(a).localeCompare(sortKey(b)))
        .map((rel) => ({ label: shortLabel(rel), link: routeForRepoPath(rel) })),
    });
  }
  const docs = files.filter((f) => f.startsWith('docs/'));
  if (docs.length) {
    sidebar.push({
      label: ko.site.refDocsGroup,
      collapsed: true,
      items: docs.map((rel) => ({ label: readTitle(rel), link: routeForRepoPath(rel) })),
    });
  }
  return sidebar;
}
