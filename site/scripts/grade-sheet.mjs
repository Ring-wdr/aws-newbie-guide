// 사이트의 모의고사 채점 코드(src/lib/exam-core.mjs)로 답안 파일을 채점해 JSON으로 출력한다.
// tools/sitecheck 가 grade.py 의 출력과 비교하는 데 쓴다. 사용: node scripts/grade-sheet.mjs <답안 파일>...
import fs from 'node:fs';
import path from 'node:path';
import { REPO_ROOT } from '../src/lib/repo.mjs';
import { gradeExam, parseAnswerSheet, parseGradeConstants, parseKey } from '../src/lib/exam-core.mjs';

const dir = path.join(REPO_ROOT, 'curriculum/m14-capstone-exam/mock-exam');
const consts = parseGradeConstants(fs.readFileSync(path.join(dir, 'grade.py'), 'utf8'));
const key = parseKey(fs.readFileSync(path.join(dir, 'answer-key.md'), 'utf8'));
const out = {};
for (const f of process.argv.slice(2)) {
  const parsed = parseAnswerSheet(fs.readFileSync(f, 'utf8'), Object.keys(key).length);
  if (parsed.error) {
    out[f] = { error: parsed.error };
    continue;
  }
  const r = gradeExam(key, parsed.answers, parsed.unsure, consts);
  out[f] = {
    domains: r.domains.map((d) => ({ domain: d.domain, ok: d.ok, total: d.total, pct: d.pct.toFixed(1) })),
    totalOk: r.totalOk,
    totalQ: r.totalQ,
    pct: r.pctText,
    blank: r.blank,
    pass: r.pass,
    more: r.more,
    weak: r.weak,
    wrong: r.wrong.map((n) => ({ n, mine: (parsed.answers[n] || []).join('') || '무응답', key: key[n].answer.join('') })),
    lucky: r.lucky,
    warnings: parsed.warnings.length,
  };
}
console.log(JSON.stringify(out, null, 1));
