// 위젯 표시 → 디렉터리 찾기 시험.
// 1) 고정 원고의 <!-- widget: hello --> 가 tests/fixtures/widget/widgets/m99/hello/index.astro 로 그려진다.
// 2) 없는 위젯을 가리키는 표시는 빌드를 실패시킨다.
// 3) bash 명령과 그 출력 블록 사이의 위젯 표시는 빌드를 실패시킨다.
// 실제 site/src/widgets 와 dist 는 건드리지 않는다(출력은 임시 폴더).
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { SITE_DIR } from './lib/harness.mjs';

const F = path.join(SITE_DIR, 'tests/fixtures/widget');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'guide-widget-'));
const build = (repo, outDir) =>
  spawnSync('node_modules/.bin/astro', ['build', '--force', '--outDir', outDir], {
    cwd: SITE_DIR,
    encoding: 'utf8',
    env: {
      ...process.env,
      ASTRO_TELEMETRY_DISABLED: '1',
      ASTRO_DISABLE_UPDATE_CHECK: 'true',
      GUIDE_REPO_ROOT: path.join(F, repo),
      GUIDE_WIDGETS_DIR: path.join(F, 'widgets'),
    },
  });
const problems = [];
const ok = build('repo', path.join(tmp, 'ok'));
const html = path.join(tmp, 'ok/curriculum/m99-fixture/index.html');
if (ok.status !== 0) problems.push(`고정 원고 빌드 실패:\n${ok.stdout.slice(-1500)}${ok.stderr.slice(-1500)}`);
else if (!fs.readFileSync(html, 'utf8').includes('data-fixture="hello-widget"')) problems.push('위젯이 표시 자리에 그려지지 않았다');
else console.log('위젯 찾기: <!-- widget: hello --> → m99/hello/index.astro 가 그려졌다');
const bad = build('repo-missing', path.join(tmp, 'bad'));
const msg = `${bad.stdout}${bad.stderr}`;
if (bad.status === 0) problems.push('없는 위젯을 가리켰는데 빌드가 성공했다');
else if (!msg.includes('does-not-exist')) problems.push(`빌드는 실패했지만 위젯 이름이 오류에 없다:\n${msg.slice(-800)}`);
else console.log(`없는 위젯: 빌드 실패(종료 코드 ${bad.status}) — "${(msg.match(/[^\n]*does-not-exist[^\n]*/) || [''])[0].trim().slice(0, 160)}"`);
const between = build('repo-between', path.join(tmp, 'between'));
const msg2 = `${between.stdout}${between.stderr}`;
if (between.status === 0) problems.push('bash 명령과 출력 사이의 위젯 표시를 빌드가 받아들였다');
else if (!msg2.includes('사이에 있다')) problems.push(`빌드는 실패했지만 이유가 다르다:\n${msg2.slice(-800)}`);
else console.log(`명령과 출력 사이의 위젯 표시: 빌드 실패(종료 코드 ${between.status}) — "${(msg2.match(/[^\n]*사이에 있다[^\n]*/) || [''])[0].trim().slice(0, 160)}"`);
fs.rmSync(tmp, { recursive: true, force: true });
if (problems.length) {
  for (const p of problems) console.log(`  - ${p}`);
  console.log('FAIL widget-fixture');
  process.exit(1);
}
console.log('PASS widget-fixture');
