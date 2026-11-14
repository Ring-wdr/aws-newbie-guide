// node --test src/widgets/m04/s3-lifecycle-planner/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalize, evaluate, formatDays, describeFinding, summarize, rulesFromFacts, choosableClasses, MAX_TRANSITIONS, MAX_DAYS, OPEN_TAIL_MIN } from './model.mjs';
import { readLifecycleFacts, parseMinDays, LESSON } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '../../../../..');
const text = fs.readFileSync(path.join(REPO, LESSON), 'utf8');
const facts = readLifecycleFacts(text);
const rules = rulesFromFacts(facts);
const choosable = choosableClasses(facts);
const name = (api) => facts.classes[api].name;

const run = (transitions, exp = null, small = false) =>
  evaluate(normalize({ transitions, expiration: { on: exp !== null, days: exp ?? 0 }, small }, choosable), rules);
const codes = (r) => r.findings.map((f) => `${f.level}:${f.code}`);

test('원고 표에서 클래스·최소 보관 기간·검색 시간을 읽는다', () => {
  const md = Object.fromEntries(Object.entries(facts.classes).map(([k, c]) => [k, c.minDays]));
  assert.deepEqual(md, { STANDARD: 0, INTELLIGENT_TIERING: 0, STANDARD_IA: 30, ONEZONE_IA: 30, GLACIER_IR: 90, GLACIER: 90, DEEP_ARCHIVE: 180, EXPRESS_ONEZONE: null });
  assert.equal(facts.classes.GLACIER.retrieval, '신속 1–5분 · 표준 3–5시간 · 대량 5–12시간');
  assert.match(text.split('\n')[facts.classes.DEEP_ARCHIVE.line - 1], /DEEP_ARCHIVE.*180일/);
  assert.deepEqual(facts.restore, ['GLACIER', 'DEEP_ARCHIVE']);
  assert.equal(facts.smallObject.kb, 128);
  assert.equal(facts.oldIaMin.days, 30);
  assert.equal(facts.expirationMin.days, 1);
});

test('폭포 그림의 간선 = sdk/lifecycle_lint.py 의 ALLOWED_NEXT, 표의 최소 보관 = MIN_DAYS (원고와 SDK가 같은 규칙)', () => {
  const py = fs.readFileSync(path.join(REPO, 'curriculum/m04-storage/sdk/lifecycle_lint.py'), 'utf8');
  const block = (nm) => py.slice(py.indexOf(`${nm}:`), py.indexOf('\n}', py.indexOf(`${nm}:`)));
  const allowed = {};
  for (const m of block('ALLOWED_NEXT').matchAll(/"([A-Z_]+)": (?:\{([^}]*)\}|set\(\))/g)) allowed[m[1]] = [...(m[2] || '').matchAll(/"([A-Z_]+)"/g)].map((x) => x[1]).sort();
  const fromLesson = Object.fromEntries(Object.entries(facts.waterfall.next).map(([k, v]) => [k, [...v].sort()]));
  assert.deepEqual(fromLesson, allowed);
  const mins = {};
  for (const m of block('MIN_DAYS').matchAll(/"([A-Z_]+)": (\d+)/g)) mins[m[1]] = Number(m[2]);
  for (const [k, v] of Object.entries(mins)) assert.equal(rules.minDays[k], v, k);
});

test('lab02 8단계 영수증 규칙(30일 IA → 90일 GIR → 365일 DA → 2555일 삭제): 저장, 경고 없음', () => {
  assert.deepEqual(facts.receipts.transitions, [{ cls: 'STANDARD_IA', days: 30 }, { cls: 'GLACIER_IR', days: 90 }, { cls: 'DEEP_ARCHIVE', days: 365 }]);
  assert.equal(facts.receipts.expireDays, 2555);
  const r = run(facts.receipts.transitions, facts.receipts.expireDays);
  assert.equal(r.result, 'ok');
  assert.deepEqual(r.stages.map((s) => [s.cls, s.from, s.to, s.held]), [
    ['STANDARD', 0, 30, 30], ['STANDARD_IA', 30, 90, 60], ['GLACIER_IR', 90, 365, 275], ['DEEP_ARCHIVE', 365, 2555, 2190],
  ]);
  assert.ok(r.stages.every((s) => s.shortBy === 0));
  assert.deepEqual(r.stages.map((s) => s.restore), [false, false, false, true]);
  assert.equal(r.stages.at(-1).endKind, 'expire');
});

test('레슨의 예: Glacier IR 4일 → Deep Archive 20일은 거부, 94일부터 저장(경계)', () => {
  const { girDays, daDays, okFrom } = facts.rejectExample;
  assert.deepEqual([girDays, daDays, okFrom], [4, 20, 94]);
  const bad = run([{ cls: 'GLACIER_IR', days: girDays }, { cls: 'DEEP_ARCHIVE', days: daDays }]);
  assert.equal(bad.result, 'rejected');
  assert.deepEqual(codes(bad), ['error:too-soon']);
  assert.equal(bad.findings[0].data.need, okFrom);
  assert.equal(bad.stages.length, 0);
  assert.equal(run([{ cls: 'GLACIER_IR', days: girDays }, { cls: 'DEEP_ARCHIVE', days: okFrom - 1 }]).result, 'rejected');
  assert.equal(run([{ cls: 'GLACIER_IR', days: girDays }, { cls: 'DEEP_ARCHIVE', days: okFrom }]).result, 'ok');
});

test('lab02 11·12단계: 너무 이른 연쇄 전환과 역방향 전환은 거부', () => {
  assert.deepEqual(codes(run(facts.labRejects.tooSoon.transitions)), ['error:too-soon']);
  const back = run(facts.labRejects.backwards.transitions);
  assert.deepEqual(codes(back), ['error:backwards']);
  assert.deepEqual([back.findings[0].data.from, back.findings[0].data.to], ['GLACIER', 'STANDARD_IA']);
  // 입력 순서와 상관없이 날짜순으로 본다
  assert.deepEqual(codes(run([...facts.labRejects.backwards.transitions].reverse())), ['error:backwards']);
});

test('스스로 확인 1번: 7일 IA, 20일 삭제 → 저장되지만 13일만 두고 17일치 조기 삭제 요금(답과 같다)', () => {
  const r = run(facts.selfCheck.transitions, facts.selfCheck.expireDays);
  assert.equal(r.result, 'warned');
  assert.deepEqual(codes(r), ['info:old-ia', 'warn:early-delete']);
  const w = r.findings.find((f) => f.code === 'early-delete').data;
  assert.deepEqual({ held: w.held, remaining: w.remaining }, { held: facts.selfCheck.answer.held, remaining: facts.selfCheck.answer.remaining });
  assert.equal(r.stages.at(-1).shortBy, facts.selfCheck.answer.remaining);
});

test('조기 삭제 경계: 최소 보관을 딱 채우면 경고 없음, 하루 모자라면 1일치', () => {
  assert.equal(run([{ cls: 'DEEP_ARCHIVE', days: 10 }], 190).result, 'ok');
  const r = run([{ cls: 'DEEP_ARCHIVE', days: 10 }], 189);
  assert.equal(r.findings.find((f) => f.code === 'early-delete').data.remaining, 1);
});

test('IA 전환 2026-07 변경: 0일도 저장(참고만), 30일은 참고 없음', () => {
  const r0 = run([{ cls: 'STANDARD_IA', days: 0 }]);
  assert.equal(r0.result, 'ok');
  assert.deepEqual(codes(r0), ['info:old-ia']);
  // 0일 전환이면 Standard에 머무는 구간이 없다
  assert.deepEqual(r0.stages.map((s) => s.cls), ['STANDARD_IA']);
  assert.equal(r0.openEnded, true);
  assert.equal(r0.end, 0 + Math.max(30, OPEN_TAIL_MIN));
  assert.deepEqual(codes(run([{ cls: 'ONEZONE_IA', days: 29 }])), ['info:old-ia']);
  assert.deepEqual(codes(run([{ cls: 'ONEZONE_IA', days: 30 }])), []);
});

test('폭포: One Zone-IA → Glacier IR, 같은 클래스로 다시 전환, Deep Archive 다음은 모두 거부', () => {
  assert.deepEqual(codes(run([{ cls: 'ONEZONE_IA', days: 30 }, { cls: 'GLACIER_IR', days: 90 }])), ['error:backwards']);
  assert.deepEqual(codes(run([{ cls: 'ONEZONE_IA', days: 30 }, { cls: 'GLACIER', days: 90 }])), []);
  const dup = run([{ cls: 'STANDARD_IA', days: 30 }, { cls: 'STANDARD_IA', days: 90 }]);
  assert.deepEqual(codes(dup), ['error:duplicate-class']);
  assert.match(describeFinding(dup.findings[0], name), /^한 규칙에 같은 클래스 전환 중복: Standard-IA\(90일\)/);
  assert.deepEqual(codes(run([{ cls: 'DEEP_ARCHIVE', days: 0 }, { cls: 'GLACIER', days: 200 }])), ['error:backwards']);
  // Intelligent-Tiering 은 최소 보관 0일이라 같은 날 다음 전환도 받는다
  assert.equal(run([{ cls: 'INTELLIGENT_TIERING', days: 5 }, { cls: 'GLACIER', days: 5 }]).result, 'ok');
});

test('만료: 0일은 거부, 1일은 저장', () => {
  assert.deepEqual(codes(run([], 0)), ['error:expire-zero']);
  const one = run([], 1);
  assert.equal(one.result, 'ok');
  assert.deepEqual(one.stages.map((s) => [s.cls, s.from, s.to]), [['STANDARD', 0, 1]]);
});

test('만료가 어느 전환보다 빠르거나 같으면 거부(레슨 목록·CloudFormation AWS::S3::Bucket Rule), 하루 늦으면 저장(경계)', () => {
  assert.match(text.split('\n')[facts.expireAfter.line - 1], /만료 일수는 그 규칙의 모든 전환 일수보다 커야 한다/);
  // 검증자 재현: Glacier Flexible 90일 + 만료 60일·90일
  for (const exp of [60, 90]) {
    const r = run([{ cls: 'GLACIER', days: 90 }], exp);
    assert.equal(r.result, 'rejected', String(exp));
    assert.deepEqual(codes(r), ['error:expire-not-after-transition']);
    assert.equal(r.stages.length, 0);
    assert.match(describeFinding(r.findings[0], name), /거부된다\(InvalidArgument\).*91일 이후/);
  }
  const ok = run([{ cls: 'GLACIER', days: 90 }], 91);
  assert.equal(ok.saved, true);
  assert.deepEqual(codes(ok), ['warn:early-delete']);
  assert.equal(ok.findings[0].data.remaining, 89);
  // 가운데 전환보다만 늦어도 마지막 전환보다 빠르면 거부(만료는 모든 전환보다 늦어야)
  assert.deepEqual(codes(run([{ cls: 'STANDARD_IA', days: 30 }, { cls: 'GLACIER', days: 120 }], 100)), ['error:expire-not-after-transition']);
  // 입력 순서와 상관없다
  assert.deepEqual(codes(run([{ cls: 'GLACIER', days: 120 }, { cls: 'STANDARD_IA', days: 30 }], 120)), ['error:expire-not-after-transition']);
  assert.match(summarize(run([{ cls: 'GLACIER', days: 90 }], 90), name), /저장되지 않는다/);
});

test('sdk/lifecycle_lint.py 도 만료가 마지막 전환보다 빠르거나 같으면 ERROR(위젯과 같은 판정)', () => {
  const py = fs.readFileSync(path.join(REPO, 'curriculum/m04-storage/sdk/lifecycle_lint.py'), 'utf8');
  assert.match(py, /if expire <= last_day:\n\s+out\.append\(Finding\("ERROR"/);
});

test('128 KB 미만: 규칙은 저장되지만 객체는 Standard에 머문다', () => {
  const r = run(facts.receipts.transitions, facts.receipts.expireDays, true);
  assert.equal(r.result, 'ok');
  assert.deepEqual(codes(r), ['info:small']);
  assert.deepEqual(r.stages.map((s) => [s.cls, s.from, s.to]), [['STANDARD', 0, 2555]]);
});

test('빈 규칙, 만료 없음: 계속 Standard', () => {
  const r = run([]);
  assert.deepEqual(codes(r), ['info:empty']);
  assert.equal(r.openEnded, true);
  assert.match(summarize(r, name), /Standard에 머물고 계속 보관/);
});

test('normalize: 범위 밖·숫자 아님·모르는 클래스는 맞춰진다', () => {
  const n = normalize({ transitions: [{ cls: 'EXPRESS_ONEZONE', days: 5 }, { cls: 'GLACIER', days: -3 }, { cls: 'STANDARD', days: 'x' }, { cls: 'GLACIER', days: 1 }], expiration: { on: 1, days: 1e9 } }, choosable);
  assert.equal(n.transitions.length, MAX_TRANSITIONS);
  assert.deepEqual(n.transitions, [{ cls: '', days: 5 }, { cls: 'GLACIER', days: 0 }, { cls: '', days: 0 }]);
  assert.deepEqual(n.expiration, { on: true, days: MAX_DAYS });
  assert.equal(normalize({}, choosable).transitions.length, MAX_TRANSITIONS);
  assert.ok(!choosable.includes('STANDARD') && !choosable.includes('EXPRESS_ONEZONE') && choosable.length === 6);
});

test('문장: 발견 사항과 요약', () => {
  const bad = run(facts.labRejects.tooSoon.transitions);
  assert.match(describeFinding(bad.findings[0], name), /Glacier Instant Retrieval\(4일\) → Glacier Deep Archive\(20일\).*최소 보관 기간 90일.*94일 이후/);
  assert.match(summarize(bad, name), /저장되지 않는다.*문제 1건/);
  const ok = run(facts.receipts.transitions, facts.receipts.expireDays);
  assert.match(summarize(ok, name), /Standard → Standard-IA → Glacier Instant Retrieval → Glacier Deep Archive 순서.*2555일\(약 7년\)에 삭제/);
  for (const f of [...run(facts.selfCheck.transitions, facts.selfCheck.expireDays).findings, ...run([], 0).findings, ...run([{ cls: 'GLACIER', days: 1 }], 1).findings])
    assert.ok(describeFinding(f, name).length > 10 && !describeFinding(f, name).includes('undefined'));
});

test('formatDays · parseMinDays', () => {
  assert.equal(formatDays(30), '30일');
  assert.equal(formatDays(365), '365일(약 1년)');
  assert.equal(formatDays(2555), '2555일(약 7년)');
  assert.equal(formatDays(500), '500일(약 1.4년)');
  assert.equal(parseMinDays('없음'), 0);
  assert.equal(parseMinDays('90일'), 90);
  assert.equal(parseMinDays('(시험 범위 밖)'), null);
});

test('원고 문장이 바뀌면 읽기가 실패한다(조용히 다른 수치를 쓰지 않는다)', () => {
  assert.throws(() => readLifecycleFacts('# 빈 원고\n'), /찾지 못했다/);
  assert.throws(() => readLifecycleFacts(text.replace('GFR --> GDA', 'GFR --> XX')), /찾지 못했다/);
  assert.throws(() => readLifecycleFacts(text.replace('"ID": "receipts-tiering"', '"ID": "other"')), /찾지 못했다/);
});
