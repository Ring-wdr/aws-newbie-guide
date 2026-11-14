// 위젯 키보드 검사 자동 발견(keyboard 관문). UI 저자는 위젯 폴더마다 keyboard.check.mjs 를 둔다:
//   site/src/widgets/mNN/<이름>/keyboard.check.mjs — 독립 실행(스스로 서버를 연다), --port <포트> 인자, 실패면 0이 아닌 종료 코드.
// 이 파일은 그 스크립트들을 찾고, 그 위젯이 놓인 페이지(원고의 <!-- widget: <이름> --> 표시가 있는 mNN 모듈 원고)를
// 정해, 그 페이지가 검사 대상(--pages)일 때만 돌린다. 등록 파일은 없다(위젯 찾기와 같은 원칙).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { REPO_ROOT, WIDGETS_DIR, routeForRepoPath, repoRel } from '../../src/lib/repo.mjs';

const CHECK = 'keyboard.check.mjs';
const MARK = /^<!--\s*widget:\s*([a-z0-9][a-z0-9-]*)\s*-->\s*$/;

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || ent.name === 'node_modules') continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

/** 원고의 위젯 표시 → { "m06/sqs-visibility-timeline": ["/curriculum/.../02-sqs/"] } */
export function widgetPages(repoRoot = REPO_ROOT) {
  const map = {};
  const cur = path.join(repoRoot, 'curriculum');
  if (!fs.existsSync(cur)) return map;
  for (const d of fs.readdirSync(cur).sort()) {
    const m = /^(m\d\d)-/.exec(d);
    if (!m) continue;
    for (const f of walk(path.join(cur, d)).filter((x) => x.endsWith('.md')).sort()) {
      const rel = path.relative(repoRoot, f).split(path.sep).join('/');
      for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
        const w = MARK.exec(line.trim());
        if (!w) continue;
        const key = `${m[1]}/${w[1]}`;
        (map[key] ??= []).push(routeForRepoPath(rel));
      }
    }
  }
  return map;
}

/**
 * site/src/widgets/** /keyboard.check.mjs 를 찾는다.
 * @returns {{ file: string, widget: string, pages: string[] }[]} widget = "mNN/<이름>", pages = 그 위젯이 놓인 페이지
 */
export function discoverWidgetChecks({ widgetsDir = WIDGETS_DIR, repoRoot = REPO_ROOT } = {}) {
  const where = widgetPages(repoRoot);
  return walk(widgetsDir)
    .filter((f) => path.basename(f) === CHECK)
    .sort()
    .map((file) => {
      const parts = path.relative(widgetsDir, path.dirname(file)).split(path.sep);
      const widget = parts.length === 2 && /^m\d\d$/.test(parts[0]) ? `${parts[0]}/${parts[1]}` : parts.join('/');
      return { file, widget, pages: where[widget] ?? [] };
    });
}

/**
 * 대상 페이지에 놓인 위젯의 검사만 차례로 돌린다(같은 포트를 쓰므로 한 번에 하나 — 부르는 쪽은 자기 서버를 먼저 닫는다).
 * 표시가 없는 위젯(어느 페이지에도 놓이지 않음)의 검사는 돌리지 않고 problems 에 적는다.
 */
export function runWidgetChecks(checks, { port, pages, cwd, env = process.env, timeoutMs = 300_000, log = console.log } = {}) {
  const problems = [];
  const ran = [];
  for (const c of checks) {
    const rel = path.relative(cwd, c.file);
    if (!c.pages.length) {
      problems.push(`${rel}: 위젯 ${c.widget}의 표시가 원고 어디에도 없어 검사할 페이지를 모른다`);
      continue;
    }
    if (!c.pages.some((p) => pages.includes(p))) continue;
    const t0 = Date.now();
    const r = spawnSync(process.execPath, [c.file, '--port', String(port)], { cwd, env, encoding: 'utf8', timeout: timeoutMs });
    const tail = `${r.stdout || ''}${r.stderr || ''}`.trim().split('\n').slice(-3).join(' / ');
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    if (r.status !== 0) problems.push(`${rel}: 종료 코드 ${r.status ?? r.signal ?? '?'}(${secs}초) — ${tail.slice(0, 400)}`);
    else log(`위젯 키보드 검사 ${c.widget}: 통과(${secs}초) — ${tail.slice(0, 160)}`);
    ran.push({ widget: c.widget, ok: r.status === 0 });
  }
  return { ran, problems };
}

export { repoRel };
