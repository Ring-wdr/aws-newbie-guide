// 위젯 키보드 검사 자동 발견의 자체 시험(keyboard 관문이 먼저 돌린다). 실제 위젯·dist 는 건드리지 않는다(임시 폴더).
// - 고정 위젯 폴더의 keyboard.check.mjs 3개(통과·실패·표시 없음)를 찾는가
// - 원고의 표시로 페이지를 맞추고, 대상 페이지일 때만 돌리는가(--port 를 넘기는가)
// - 실패(0이 아닌 종료 코드)와 표시 없는 위젯을 문제로 보고하는가
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { discoverWidgetChecks, runWidgetChecks } from './lib/widget-checks.mjs';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'guide-widget-checks-'));
const problems = [];
try {
  const repo = path.join(tmp, 'repo');
  const widgets = path.join(tmp, 'widgets');
  const write = (p, s) => {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, s);
  };
  write(path.join(repo, 'curriculum/m98-fixture/README.md'), '# M98\n\n<!-- widget: good-one -->\n');
  write(path.join(repo, 'curriculum/m98-fixture/02-lesson.md'), '# M98-02\n\n본문\n\n<!-- widget: bad-one -->\n\n끝\n');
  // 통과: --port 값을 받았는지 확인하고 0, 실패: 3, 표시 없음: 돌면 안 된다(돌면 파일을 남긴다)
  const script = (code) => `const i = process.argv.indexOf('--port');\nif (i < 0 || !/^\\d+$/.test(process.argv[i + 1] || '')) { console.log('포트 없음'); process.exit(9); }\nconsole.log('PASS fixture port ' + process.argv[i + 1]);\nprocess.exit(${code});\n`;
  write(path.join(widgets, 'm98/good-one/index.astro'), '<p>good</p>\n');
  write(path.join(widgets, 'm98/good-one/keyboard.check.mjs'), script(0));
  write(path.join(widgets, 'm98/bad-one/index.astro'), '<p>bad</p>\n');
  write(path.join(widgets, 'm98/bad-one/keyboard.check.mjs'), script(3));
  write(path.join(widgets, 'm98/orphan/index.astro'), '<p>orphan</p>\n');
  write(path.join(widgets, 'm98/orphan/keyboard.check.mjs'), `import fs from 'node:fs';\nfs.writeFileSync(${JSON.stringify(path.join(tmp, 'orphan-ran'))}, '1');\n`);
  write(path.join(widgets, 'm98/no-check/index.astro'), '<p>none</p>\n');

  const checks = discoverWidgetChecks({ widgetsDir: widgets, repoRoot: repo });
  const got = checks.map((c) => `${c.widget}=${c.pages.join('|')}`).join(' ');
  const want = 'm98/bad-one=/curriculum/m98-fixture/02-lesson/ m98/good-one=/curriculum/m98-fixture/ m98/orphan=';
  if (got !== want) problems.push(`발견 결과가 다름: ${got} / 기대 ${want}`);

  // 대상에 위젯 페이지가 없으면 아무것도 돌리지 않는다(표시 없는 위젯만 문제)
  const none = runWidgetChecks(checks, { port: 4999, pages: ['/'], cwd: tmp, log: () => {} });
  if (none.ran.length !== 0) problems.push(`대상 밖인데 돌렸다: ${JSON.stringify(none.ran)}`);
  if (none.problems.length !== 1 || !none.problems[0].includes('orphan')) problems.push(`표시 없는 위젯을 보고하지 않음: ${none.problems}`);

  // 대상에 두 페이지가 다 있으면 둘 다 돌리고, 실패한 것은 종료 코드와 함께 보고한다
  const lines = [];
  const all = runWidgetChecks(checks, { port: 4999, pages: ['/curriculum/m98-fixture/', '/curriculum/m98-fixture/02-lesson/'], cwd: tmp, log: (l) => lines.push(l) });
  if (all.ran.map((r) => `${r.widget}:${r.ok}`).join(',') !== 'm98/bad-one:false,m98/good-one:true') problems.push(`실행 결과가 다름: ${JSON.stringify(all.ran)}`);
  if (!all.problems.some((p) => p.includes('bad-one') && p.includes('종료 코드 3'))) problems.push(`실패를 종료 코드와 함께 보고하지 않음: ${all.problems}`);
  if (!lines.some((l) => l.includes('good-one') && l.includes('port 4999'))) problems.push(`통과 기록에 --port 가 넘어간 흔적이 없음: ${lines}`);
  if (fs.existsSync(path.join(tmp, 'orphan-ran'))) problems.push('표시 없는 위젯의 검사를 돌렸다');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log('FAIL widget-checks-selftest');
  process.exit(1);
}
console.log('PASS widget-checks-selftest: keyboard.check.mjs 발견(3개)·페이지 대응·대상일 때만 실행·--port 전달·실패 종료 코드·표시 없는 위젯 보고');
