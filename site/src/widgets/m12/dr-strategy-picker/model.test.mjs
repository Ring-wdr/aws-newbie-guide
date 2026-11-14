// node --test src/widgets/m12/dr-strategy-picker/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pick, check, tierOf, RPO_TIERS, RTO_TIERS, MODEL_PRESET_REQ } from './model.mjs';
import { readDrFacts, cellTier, LESSON, CHEATSHEET } from './facts.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const lessonText = fs.readFileSync(path.join(root, LESSON), 'utf8');
const cheatText = fs.readFileSync(path.join(root, CHEATSHEET), 'utf8');
const facts = readDrFacts(lessonText, cheatText);
const S = facts.strategies;

test('원고 표를 읽는다: 4전략의 RPO·RTO 단계와 비용 순서', () => {
  assert.deepEqual(S.map((s) => s.id), ['backup', 'pilot', 'warm', 'multi']);
  assert.deepEqual(S.map((s) => [s.rpo, s.rto]), [['hours', 'hours'], ['sec-min', 'tens-min'], ['sec-min', 'min'], ['zero', 'zero']]);
  assert.deepEqual(S.map((s) => s.costRank), [0, 1, 2, 3]);
  assert.ok(S.every((s) => s.question && s.cheatLine > 0));
});

test('비용과 RTO/RPO가 반대로 간다: 비용 순서대로 RTO·RPO 단계가 늘지 않는다', () => {
  for (let i = 1; i < S.length; i++) {
    const r = (id, tiers) => tiers.find((t) => t.id === id).rank;
    assert.ok(r(S[i].rto, RTO_TIERS) <= r(S[i - 1].rto, RTO_TIERS));
    assert.ok(r(S[i].rpo, RPO_TIERS) <= r(S[i - 1].rpo, RPO_TIERS));
  }
});

test('워크시트 a~d: 모형 해석으로 고른 전략 = 원고 모범 답안', () => {
  for (const k of ['a', 'b', 'c', 'd']) {
    assert.equal(pick(S, MODEL_PRESET_REQ[k]).pick, facts.worksheet[k].answer, `워크시트 ${k}`);
  }
});

test('워크시트 b: 웜 스탠바이도 만족하지만 더 비싸다(over)', () => {
  const r = pick(S, MODEL_PRESET_REQ.b);
  const warm = r.rows.find((x) => x.id === 'warm');
  assert.equal(warm.ok, true);
  assert.equal(warm.over, true);
  assert.equal(r.rows.find((x) => x.id === 'backup').ok, false);
});

test('스스로 확인 1: 두 축으로 나누면 데이터는 파일럿 라이트, 컴퓨트는 백업·복원(원고 답과 같다)', () => {
  const r = pick(S, MODEL_PRESET_REQ.selfCheck);
  assert.equal(r.split, true);
  assert.equal(r.dataLevel, facts.selfCheck.data);
  assert.equal(r.computeLevel, facts.selfCheck.compute);
  assert.equal(r.pick, 'pilot');
});

test('경계: 요구 단계와 같은 단계면 만족, 한 단계 엄격하면 불만족', () => {
  const pilot = S.find((s) => s.id === 'pilot');
  assert.equal(check(pilot, { rpo: 'sec-min', rto: 'tens-min' }).ok, true);
  assert.equal(check(pilot, { rpo: 'sec-min', rto: 'min' }).rtoOk, false);
  assert.equal(check(pilot, { rpo: 'zero', rto: 'hours' }).rpoOk, false);
});

test('가장 넉넉한 요구 → 백업·복원, 가장 엄격 → 다중 사이트, 나눌 필요 없음', () => {
  const loose = pick(S, { rpo: 'hours', rto: 'hours' });
  assert.equal(loose.pick, 'backup');
  assert.equal(loose.split, false);
  assert.equal(loose.rows.filter((r) => r.ok).length, 4);
  const strict = pick(S, { rpo: 'zero', rto: 'zero' });
  assert.equal(strict.pick, 'multi');
  assert.equal(strict.rows.filter((r) => r.ok).length, 1);
});

test('RPO 거의 0이면 RTO가 넉넉해도 다중 사이트뿐(나눠 보면 컴퓨트는 백업·복원)', () => {
  const r = pick(S, { rpo: 'zero', rto: 'hours' });
  assert.equal(r.pick, 'multi');
  assert.equal(r.computeLevel, 'backup');
  assert.equal(r.split, true);
});

test('단계 글자 읽기: 괄호 설명·≈0', () => {
  assert.equal(cellTier('시간 (백업 주기)', RPO_TIERS, 't'), 'hours');
  assert.equal(cellTier('≈0', RTO_TIERS, 't'), 'zero');
  assert.equal(cellTier('수십 분', RTO_TIERS, 't'), 'tens-min');
  assert.throws(() => cellTier('몇 초', RTO_TIERS, 't'), /읽지 못했다/);
  assert.equal(tierOf('초~분', RTO_TIERS), null); // RTO에는 "초~분" 단계가 없다
});

test('원고가 바뀌면 실패: 치트시트와 레슨의 RPO가 다르면', () => {
  const bad = cheatText.replace('| 파일럿 라이트 | 데이터 복제 + 꺼진 인프라 | 초~분 |', '| 파일럿 라이트 | 데이터 복제 + 꺼진 인프라 | 시간 |');
  assert.notEqual(bad, cheatText);
  assert.throws(() => readDrFacts(lessonText, bad), /레슨.*다르다/);
  assert.throws(() => readDrFacts('# 빈\n', cheatText), /찾지 못했다/);
});

test('컴퓨트(RTO)가 더 엄격하면 나눠 보기를 권하지 않는다(웜 스탠바이가 곧 답)', () => {
  const r = pick(S, { rpo: 'hours', rto: 'min' });
  assert.equal(r.pick, 'warm');
  assert.equal(r.dataLevel, 'backup');
  assert.equal(r.split, false);
});
