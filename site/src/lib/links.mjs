// 원고의 상대 링크를 사이트 경로로 바꾸는 규칙. 변환기(remark)와 소스 보기 페이지 목록, 보고서가 같은 함수를 쓴다.
import fs from 'node:fs';
import path from 'node:path';
import {
  REPO_ROOT,
  allContentFiles,
  builtContentFiles,
  fileViewRoute,
  isInsideRepo,
  repoRel,
  routeForRepoPath,
} from './repo.mjs';

/**
 * @param {string} fromRel 링크가 있는 원고의 저장소 상대 경로
 * @param {string} url 원고에 적힌 링크
 * @returns {{kind: 'external'|'anchor'|'page'|'file'|'dir'|'broken'|'outside'|'unbuilt', href?: string, target?: string}}
 */
export function resolveLink(fromRel, url) {
  if (!url) return { kind: 'broken' };
  if (/^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith('//')) return { kind: 'external', href: url };
  if (url.startsWith('#')) return { kind: 'anchor', href: url };
  const hashAt = url.indexOf('#');
  const rawPath = hashAt >= 0 ? url.slice(0, hashAt) : url;
  const hash = hashAt >= 0 ? url.slice(hashAt) : '';
  let decoded;
  try {
    decoded = decodeURIComponent(rawPath);
  } catch {
    decoded = rawPath;
  }
  const abs = decoded.startsWith('/')
    ? path.join(REPO_ROOT, decoded)
    : path.resolve(path.dirname(path.join(REPO_ROOT, fromRel)), decoded);
  if (!isInsideRepo(abs) && abs !== REPO_ROOT) return { kind: 'outside', href: url };
  const rel = abs === REPO_ROOT ? '' : repoRel(abs);
  if (!fs.existsSync(abs)) return { kind: 'broken', target: rel };
  const stat = fs.statSync(abs);
  if (stat.isDirectory()) {
    const readme = rel ? `${rel}/README.md` : 'README.md';
    if (allContentFiles().includes(readme)) {
      if (!builtContentFiles().includes(readme)) return { kind: 'unbuilt', href: fileViewRoute(readme), target: readme };
      return { kind: 'page', href: routeForRepoPath(readme) + hash, target: readme };
    }
    return { kind: 'dir', href: fileViewRoute(rel), target: rel };
  }
  if (rel.endsWith('.md') && allContentFiles().includes(rel)) {
    if (!builtContentFiles().includes(rel)) return { kind: 'unbuilt', href: fileViewRoute(rel), target: rel };
    return { kind: 'page', href: routeForRepoPath(rel) + hash, target: rel };
  }
  return { kind: 'file', href: fileViewRoute(rel) + hash, target: rel };
}
