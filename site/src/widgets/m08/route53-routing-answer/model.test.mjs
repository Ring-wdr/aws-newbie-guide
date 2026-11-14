// node --test src/widgets/m08/route53-routing-answer/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolve, initialState, groupByName, caseState, WORKSHEET_CASES, LOCATIONS, locationById, summarize, simpleRecords, fmtPct } from './model.mjs';
import { readRoutingFacts, parsePolicy, expandValues, LESSON } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const text = fs.readFileSync(path.resolve(here, '../../../../..', LESSON), 'utf8');
const facts = readRoutingFacts(text);
const records = [...facts.records, ...simpleRecords(facts.simple.values, facts.simple.line)];
const byName = groupByName(records);
const run = (name, state, loc = 'KR') => resolve(byName.get(name), state, locationById(loc), { multiMax: facts.multiMax.value });

test('원고 워크시트 레코드 표를 읽는다', () => {
  assert.deepEqual([...groupByName(facts.records).keys()], ['api', 'shop', 'pay', 'img', 'new']);
  assert.equal(facts.records.length, 12);
  const img = byName.get('img');
  assert.deepEqual(img.map((r) => [r.id, r.value, r.hc]), [['a', '192.0.2.31', 'HC-a'], ['b', '192.0.2.32', 'HC-b'], ['c', '192.0.2.33', 'HC-c']]);
  assert.deepEqual(byName.get('new').map((r) => [r.id, r.weight]), [['blue', 255], ['green', 0]]);
  assert.deepEqual(byName.get('shop').map((r) => r.geo), [{ kind: 'country', code: 'KR' }, { kind: 'continent', code: 'AS' }, { kind: 'default', code: '*' }]);
  assert.deepEqual(byName.get('pay').map((r) => [r.role, r.hc]), [['PRIMARY', 'HC-pay (HTTPS /health)'], ['SECONDARY', null]]);
  assert.deepEqual(byName.get('api').map((r) => r.region), ['ap-northeast-2', 'us-east-1']);
  assert.deepEqual(facts.simple.values, ['192.0.2.10', '192.0.2.11']);
  assert.deepEqual([facts.weightRange.min, facts.weightRange.max, facts.multiMax.value], [0, 255, 8]);
  const lines = text.split('\n');
  assert.match(lines[facts.worksheetLine - 1], /^\| 이름 \| SetIdentifier/);
  assert.match(lines[facts.rules.allHealthy - 1], /If no record is healthy/);
  assert.match(lines[facts.answers['7'].line - 1], /^7\. \*\*PRIMARY를 그대로 준다/);
});

// 워크시트 정답(원고의 굵은 글씨)과 모형의 답이 같은지 — 원고와 위젯이 어긋나면 이 시험이 실패한다.
const EXPECT = {
  1: { bold: /^서울 ALB/, ids: ['seoul'] },
  2: { bold: /^버지니아 ALB/, ids: ['virginia'] },
  3: { bold: /^asia \(203\.0\.113\.3\)/, ids: ['asia'] },
  4: { bold: /^kr \(203\.0\.113\.1\)/, ids: ['kr'] },
  5: { bold: /^빈 응답\(NOERROR, 값 없음\)/, kind: 'nodata' },
  6: { bold: /^secondary/, ids: ['secondary'] },
  7: { bold: /^PRIMARY를 그대로 준다/, ids: ['primary'], allHealthy: true },
  8: { bold: /^a, c 두 값만/, ids: ['a', 'c'] },
  9: { bold: /^0번/, green: 0 },
};
for (const [k, e] of Object.entries(EXPECT)) {
  test(`워크시트 ${k}번: 모형의 답 = 원고의 답(${facts.answers[k].bold})`, () => {
    assert.match(facts.answers[k].bold, e.bold);
    const c = WORKSHEET_CASES[k];
    const res = run(c.name, caseState(records, c), c.loc || 'KR');
    if (e.kind) assert.equal(res.kind, e.kind);
    if (e.ids) assert.deepEqual(res.answers.map((a) => a.id), e.ids);
    if (e.allHealthy) assert.equal(res.usedAllHealthy, true);
    if ('green' in e) {
      const green = res.answers.find((a) => a.id === 'green');
      assert.equal(Math.round(1000 * green.p), e.green);
    }
  });
}

test('워크시트 9번 후반: blue 90 : green 10, 225 : 25 → green 10%', () => {
  for (const [b, g] of [[90, 10], [225, 25]]) {
    const s = initialState(records);
    s.weight['new/blue'] = b;
    s.weight['new/green'] = g;
    const res = run('new', s);
    assert.equal(res.answers.find((a) => a.id === 'green').p, 0.1);
  }
});

test('가중치가 모두 0이면 똑같은 비율', () => {
  const s = initialState(records);
  s.weight['new/blue'] = 0;
  const res = run('new', s);
  assert.deepEqual(res.answers.map((a) => a.p), [0.5, 0.5]);
});

test('지연 시간: 두 리전 모두 비정상 → 모두 건강하다고 보고 가장 빠른 쪽', () => {
  const s = initialState(records);
  s.healthy['api/seoul'] = false;
  s.healthy['api/virginia'] = false;
  const res = run('api', s, 'US');
  assert.deepEqual(res.answers.map((a) => a.id), ['virginia']);
  assert.equal(res.usedAllHealthy, true);
  assert.deepEqual(run('api', initialState(records), 'KR').answers.map((a) => a.id), ['seoul']);
});

test('다중값: 모두 비정상이면 모두 준다, 건강한 것만이면 그것만', () => {
  const s = initialState(records);
  for (const id of ['a', 'b', 'c']) s.healthy[`img/${id}`] = false;
  const all = run('img', s);
  assert.deepEqual(all.answers.map((a) => a.id), ['a', 'b', 'c']);
  assert.equal(all.usedAllHealthy, true);
  s.healthy['img/c'] = true;
  assert.deepEqual(run('img', s).answers.map((a) => a.id), ['c']);
});

test('다중값 최대 개수(경계)', () => {
  const many = Array.from({ length: 10 }, (_, i) => ({ name: 'm', id: `w${i}`, policy: 'multivalue', value: `192.0.2.${i}`, hc: null }));
  const res = resolve(many, initialState(many), LOCATIONS[0], { multiMax: 8 });
  assert.equal(res.answers.length, 8);
  assert.equal(resolve(many.slice(0, 8), initialState(many), LOCATIONS[0], { multiMax: 8 }).answers.length, 8);
});

test('장애 조치: PRIMARY를 지우면 SECONDARY(lab03 6단계)', () => {
  const s = initialState(records);
  s.present['pay/primary'] = false;
  assert.deepEqual(run('pay', s).answers.map((a) => a.id), ['secondary']);
  assert.deepEqual(run('pay', initialState(records)).answers.map((a) => a.id), ['primary']);
});

test('지리적 위치: 유럽·미국은 기본, 기본이 없으면 빈 응답', () => {
  assert.deepEqual(run('shop', initialState(records), 'DE').answers.map((a) => a.id), ['default']);
  const s = initialState(records);
  s.present['shop/default'] = false;
  assert.equal(run('shop', s, 'US').kind, 'nodata');
  assert.deepEqual(run('shop', s, 'KR').answers.map((a) => a.id), ['kr']);
});

test('단순: 값 전부, 상태와 무관', () => {
  const res = run('simple', initialState(records));
  assert.deepEqual(res.answers.map((a) => a.value), ['192.0.2.10', '192.0.2.11']);
  assert.match(summarize(res), /192\.0\.2\.10 · 192\.0\.2\.11/);
});

test('레코드를 모두 지우면 계산하지 않는다', () => {
  const s = initialState(records);
  s.present['img/a'] = s.present['img/b'] = s.present['img/c'] = false;
  assert.equal(run('img', s).kind, 'none');
});

test('모든 이름·위치·상태 조합에서 답이 정의된다', () => {
  for (const [name, recs] of byName) {
    const keys = recs.map((r) => `${r.name}/${r.id}`);
    for (let mask = 0; mask < 1 << keys.length; mask++) {
      for (let hm = 0; hm < 1 << keys.length; hm++) {
        const s = initialState(records);
        keys.forEach((k, i) => {
          s.present[k] = !(mask & (1 << i));
          s.healthy[k] = !(hm & (1 << i));
        });
        for (const loc of LOCATIONS) {
          const res = resolve(recs, s, loc, { multiMax: 8 });
          const anyPresent = keys.some((k) => s.present[k]);
          assert.ok(['answer', 'nodata', 'weighted', 'none'].includes(res.kind));
          assert.equal(res.kind === 'none', !anyPresent, `${name} ${mask} ${hm}`);
          for (const a of res.answers) assert.ok(s.present[a.key], `지운 레코드가 답함 ${name} ${a.key}`);
          if (res.kind === 'answer') assert.ok(res.answers.length >= 1);
          assert.equal(Object.keys(res.status).length, keys.length, `${name}: 모든 레코드에 상태 글`);
          assert.ok(summarize(res).length > 0);
        }
      }
    }
  }
});

test('parsePolicy·expandValues·fmtPct', () => {
  assert.deepEqual(parsePolicy('가중치 255 / 0', 2, 1).map((p) => p.weight), [255, 0]);
  assert.throws(() => parsePolicy('IP 기반, isp-a', 1, 1), /해석하지 못했다/);
  assert.deepEqual(expandValues('192.0.2.31 / .32', 2, 1), ['192.0.2.31', '192.0.2.32']);
  assert.throws(() => expandValues('192.0.2.1', 2, 1));
  assert.equal(fmtPct(1 / 3), '33.3%');
  assert.equal(fmtPct(0.1), '10%');
});

test('원고 문장이 바뀌면 읽기가 실패한다', () => {
  assert.throws(() => readRoutingFacts('# 빈 원고\n'), /찾지 못했다/);
  assert.throws(() => readRoutingFacts(text.replace('| `img` | a / b / c | 다중값 응답 |', '| `img` | a / b / c | 다중 응답 |')), /해석하지 못했다/);
});
