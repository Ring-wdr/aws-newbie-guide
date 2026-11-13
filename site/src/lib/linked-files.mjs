// 원고가 링크하는 Markdown 밖의 파일(lab·sdk·scripts 등)과 디렉터리 목록. 소스 보기 페이지를 이 목록으로 만든다.
import fs from 'node:fs';
import path from 'node:path';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import { visit } from 'unist-util-visit';
import { REPO_ROOT, builtContentFiles } from './repo.mjs';
import { resolveLink } from './links.mjs';

let cache;
/** @returns {{files: Map<string, Set<string>>, dirs: Map<string, Set<string>>}} 대상 → 그 대상을 링크한 원고들 */
export function collectLinkedFiles() {
  if (cache) return cache;
  const files = new Map();
  const dirs = new Map();
  const add = (map, key, from) => {
    if (!map.has(key)) map.set(key, new Set());
    if (from) map.get(key).add(from);
  };
  const parser = unified().use(remarkParse).use(remarkGfm, { singleTilde: false });
  for (const rel of builtContentFiles()) {
    const tree = parser.parse(fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8'));
    visit(tree, (node) => {
      if (node.type !== 'link' && node.type !== 'definition') return;
      const r = resolveLink(rel, node.url);
      if (r.kind === 'file' || r.kind === 'unbuilt') add(files, r.target, rel);
      if (r.kind === 'dir') add(dirs, r.target, rel);
    });
  }
  // 디렉터리 보기에서 바로 열 수 있게, 링크된 디렉터리 안의 파일도 소스 보기를 만든다.
  for (const d of dirs.keys()) {
    for (const ent of fs.readdirSync(path.join(REPO_ROOT, d), { withFileTypes: true })) {
      if (ent.isFile() && !ent.name.startsWith('.')) add(files, `${d}/${ent.name}`, null);
    }
  }
  cache = { files, dirs };
  return cache;
}

const LANG = {
  sh: 'bash',
  bash: 'bash',
  py: 'python',
  json: 'json',
  yaml: 'yaml',
  yml: 'yaml',
  toml: 'toml',
  md: 'markdown',
  js: 'javascript',
  mjs: 'javascript',
  ts: 'typescript',
  sql: 'sql',
  html: 'html',
  txt: 'plaintext',
  csv: 'plaintext',
};

export function langFor(rel) {
  const ext = rel.split('.').pop().toLowerCase();
  return LANG[ext] || 'plaintext';
}

/**
 * 저장소 루트에서 이 파일을 실행하는 명령. 원고(레슨·README)에 쓰인 형태를 따른다.
 * 실행하는 파일이 아니면(라이브러리·데이터·Lambda 코드) null.
 */
export function runCommandFor(rel) {
  const base = rel.split('/').pop();
  if (base.startsWith('_')) return null; // source 되는 공용 함수 모음(labs/_lib.sh 등)
  if (/^scripts\/(env|dr-env)\.sh$/.test(rel)) return `source ${rel}`;
  if (rel.endsWith('.sh')) return rel.startsWith('curriculum/') ? `bash ${rel}` : rel;
  if (rel.endsWith('.py') && /\/(sdk|mock-exam)\/|^tools\//.test(rel)) return `uv run python ${rel}`;
  return null;
}
