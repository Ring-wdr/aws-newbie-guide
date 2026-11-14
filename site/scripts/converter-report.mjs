// 변환기 보고 모드: 사이트 빌드와 같은 변환기를 curriculum/의 Markdown 전체에 돌려,
// 변환기마다 "처리한 파일 / 해석하지 못한 구조가 있는 파일"을 센다(원고가 자동 변환이 될 만큼 규칙적인지 재는 표).
// Mermaid는 그리지 않는다(구조만 본다). 실행: pnpm --dir site run report [-- --json out.json]
import fs from 'node:fs';
import path from 'node:path';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import { VFile } from 'vfile';
import { REPO_ROOT, allContentFiles, kindOf } from '../src/lib/repo.mjs';
import { remarkGuide, GFM_OPTIONS } from '../src/plugins/remark-guide.mjs';

const args = process.argv.slice(2);
const jsonOut = args.includes('--json') ? args[args.indexOf('--json') + 1] : null;
const all = args.includes('--all'); // README·docs 까지
const files = allContentFiles().filter((f) => all || f.startsWith('curriculum/'));

// 사이트 빌드와 같은 설정: GFM의 한 개 물결(~) 취소선은 끈다(astro.config.mjs 참고).
const processor = unified().use(remarkParse).use(remarkGfm, GFM_OPTIONS).use(remarkGuide, { report: true });

const ORDER = ['title', 'meta', 'sections', 'cmd', 'mermaid', 'quiz', 'selfcheck', 'exam', 'checklist', 'tables', 'links', 'markers'];
const LABEL = {
  title: '제목(H1)',
  meta: '메타 줄 → 칩·등급 배지',
  sections: '레슨 절 구성(AUTHORING 2장)',
  cmd: 'bash 명령 + 출력 짝',
  mermaid: 'Mermaid → SVG',
  quiz: '퀴즈 문항 카드',
  selfcheck: '"스스로 확인" 답 가리기',
  exam: '모의고사 시험 모드',
  checklist: '자기 점검 체크리스트',
  tables: '표(반응형)',
  links: '상대 링크 재작성',
  markers: '주석 표시(external-host-ok·widget)',
};

const agg = {};
const perFile = {};
const kinds = {};
for (const rel of files) {
  const file = new VFile({ path: path.join(REPO_ROOT, rel), value: fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8') });
  const tree = processor.parse(file);
  await processor.run(tree, file);
  const rep = file.data.guideReport || {};
  perFile[rel] = rep;
  kinds[kindOf(rel)] = (kinds[kindOf(rel)] || 0) + 1;
  for (const [name, r] of Object.entries(rep)) {
    const a = (agg[name] ??= { files: 0, filesHandled: 0, filesUnrec: 0, handled: 0, unrecognised: 0, notes: {}, examples: [] });
    a.files++;
    if (r.handled > 0) a.filesHandled++;
    a.handled += r.handled;
    if (r.unrecognised.length) {
      a.filesUnrec++;
      a.unrecognised += r.unrecognised.length;
      for (const u of r.unrecognised) if (a.examples.length < 400) a.examples.push(`${rel}${u.line ? `:${u.line}` : ''} — ${u.what}`);
    }
    for (const [k, v] of Object.entries(r.notes)) a.notes[k] = (a.notes[k] || 0) + v;
  }
}

const lines = [];
lines.push(`대상: Markdown ${files.length}개 (${Object.entries(kinds).map(([k, v]) => `${k} ${v}`).join(' · ')})`);
lines.push('');
lines.push('| 변환기 | 적용한 파일 | 처리한 파일 | 해석 못 한 구조가 있는 파일 | 처리한 요소 | 해석 못 한 요소 | 세부 |');
lines.push('|---|---|---|---|---|---|---|');
for (const name of ORDER) {
  const a = agg[name];
  if (!a) continue;
  const notes = Object.entries(a.notes)
    .sort((x, y) => y[1] - x[1])
    .map(([k, v]) => `${k} ${v}`)
    .join(', ');
  lines.push(`| ${LABEL[name]} | ${a.files} | ${a.filesHandled} | ${a.filesUnrec} | ${a.handled} | ${a.unrecognised} | ${notes} |`);
}
lines.push('');
lines.push('해석하지 못한 구조(변환기별 앞부분):');
for (const name of ORDER) {
  const a = agg[name];
  if (!a || !a.examples.length) continue;
  lines.push(`- ${LABEL[name]} (${a.unrecognised}건)`);
  for (const e of a.examples.slice(0, args.includes('--full') ? 400 : 8)) lines.push(`  - ${e}`);
}
console.log(lines.join('\n'));
if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ files: files.length, aggregate: agg, perFile }, null, 1));
