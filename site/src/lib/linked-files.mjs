// 원고가 링크하는 Markdown 밖의 파일(lab·sdk·scripts 등)과 디렉터리 목록. 소스 보기 페이지를 이 목록으로 만든다.
import fs from 'node:fs';
import path from 'node:path';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import { visit } from 'unist-util-visit';
import { REPO_ROOT, allContentFiles, builtContentFiles } from './repo.mjs';
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

/* ------------------------------------------------------------------ 실행 명령
 * 소스 보기 페이지의 "실행 명령"은 저장소에 근거가 있을 때만 보인다(원고에 없는 것을 지어내지 않는다).
 *  1) 원고(README·docs·curriculum)의 ```bash 블록에서 그 파일을 실제로 부르는 줄이 있으면 그 줄
 *     (줄 끝 주석은 뺀다. 여러 형태면 가장 자주 쓰인 것, 같으면 짧은 것).
 *  2) 없으면 실행 진입점일 때만 정해진 형태:
 *     - 셸: 이름이 "_"로 시작하지 않고, 실행 비트가 있거나 labs/labNN-*.sh·labs/verify.sh 이름 규칙
 *           → curriculum/ 안은 "bash <경로>", 그 밖은 "<경로>"
 *     - Python: 파일에 `if __name__ == "__main__":` 이 있음 → "uv run python <경로>"
 *  3) 그 밖에는 명령을 보이지 않는다. 셸 도우미(source 해서 쓰는 함수 모음)와 Python 모듈은 그렇다고 적는다.
 * tools/sitecheck 의 run-commands 관문이 같은 규칙을 따로(Python으로) 구현해 산출물을 검사한다.
 */

/** 줄 끝의 셸 주석을 뗀다: 따옴표 밖에서 공백 뒤에 오는 "#" 부터. */
export function stripShellComment(line) {
  let q = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === q) q = null;
      continue;
    }
    if (c === "'" || c === '"') q = c;
    else if (c === '#' && i > 0 && /\s/.test(line[i - 1])) return line.slice(0, i).trimEnd();
  }
  return line.trimEnd();
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 이 줄이 rel 파일을 실행(또는 source)하는가: 줄의 첫 명령이 그 파일이거나 bash/sh/source/./python/uv run python 의 인자. */
export function invokes(line, rel) {
  const re = new RegExp(
    `^\\s*(?:[A-Z_][A-Z0-9_]*=\\S*\\s+)*(?:bash\\s+|sh\\s+|source\\s+|\\.\\s+|uv\\s+run\\s+(?:--\\S+\\s+)*python3?\\s+|python3?\\s+)?(?:\\./)?${escapeRe(rel)}(?=\\s|$|;|&&|\\|)`,
  );
  return re.test(line);
}

let manuscriptLines;
/** 원고의 ```bash 블록 줄(이어진 줄은 합침) 목록: [{line, from}] */
function bashLines() {
  if (manuscriptLines) return manuscriptLines;
  manuscriptLines = [];
  const parser = unified().use(remarkParse).use(remarkGfm, { singleTilde: false });
  for (const rel of allContentFiles()) {
    const tree = parser.parse(fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8'));
    visit(tree, 'code', (node) => {
      if ((node.lang || '').toLowerCase() !== 'bash') return;
      const raw = node.value.split('\n');
      for (let i = 0; i < raw.length; i++) {
        let l = raw[i];
        while (/\\\s*$/.test(l) && i + 1 < raw.length) l = `${l.replace(/\\\s*$/, '')} ${raw[++i].trim()}`;
        manuscriptLines.push({ line: stripShellComment(l).trim(), from: rel });
      }
    });
  }
  return manuscriptLines;
}

/**
 * @returns {{command: string|null, basis: 'manuscript'|'entry'|'helper'|'module'|'none', from?: string}}
 */
export function runInfo(rel) {
  const hits = bashLines().filter((h) => h.line && invokes(h.line, rel));
  if (hits.length) {
    const count = new Map();
    for (const h of hits) count.set(h.line, (count.get(h.line) || 0) + 1);
    const best = [...count.entries()].sort((a, b) => b[1] - a[1] || a[0].length - b[0].length)[0][0];
    return { command: best, basis: 'manuscript', from: hits.find((h) => h.line === best).from };
  }
  const abs = path.join(REPO_ROOT, rel);
  const base = rel.split('/').pop();
  if (rel.endsWith('.sh')) {
    if (base.startsWith('_')) return { command: null, basis: 'helper' };
    const exec = (fs.statSync(abs).mode & 0o111) !== 0;
    const named = /(^|\/)labs\/(lab\d\d-[^/]+|verify)\.sh$/.test(rel);
    if (exec || named) return { command: rel.startsWith('curriculum/') ? `bash ${rel}` : rel, basis: 'entry' };
    return { command: null, basis: 'helper' };
  }
  if (rel.endsWith('.py')) {
    const text = fs.readFileSync(abs, 'utf8');
    if (/^if __name__ == ["']__main__["']\s*:/m.test(text)) return { command: `uv run python ${rel}`, basis: 'entry' };
    return { command: null, basis: 'module' };
  }
  return { command: null, basis: 'none' };
}
