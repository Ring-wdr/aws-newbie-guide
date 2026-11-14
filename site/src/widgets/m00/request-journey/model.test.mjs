// node --test src/widgets/m00/request-journey/*.test.mjs   (site/ 에서. 위젯 시험 전부: pnpm test:widgets)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { journey, normalize, credentialUsed, describeStage, STAGES, FAULTS, CRED_SOURCES } from './model.mjs';
import { readRequestFacts, LESSON, SETUP } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../../../..');
const lesson = fs.readFileSync(path.join(repo, LESSON), 'utf8');
const setup = fs.readFileSync(path.join(repo, SETUP), 'utf8');
const f = readRequestFacts(lesson, setup);

test('원고에서 순서도·종료 코드·오류 코드를 읽는다', () => {
  assert.deepEqual(Object.keys(f.flow), ['creds', 'endpoint', 'sign', 'send', 'verify', 'response']);
  assert.deepEqual(Object.keys(f.exitCodes).map(Number), [0, 252, 253, 254, 255]);
  assert.match(f.exitCodes[253].meaning, /자격 증명을 못 찾음/);
  assert.match(f.exitCodes[254].meaning, /서비스가 오류를 돌려줌/);
  assert.equal(f.signature.code, 'SignatureDoesNotMatch');
  assert.equal(f.signature.skewMinutes, 15);
  assert.deepEqual([f.clock.sts, f.clock.other], ['SignatureDoesNotMatch', 'RequestTimeTooSkewed']);
  assert.equal(f.endpoint.aws, 'https://sts.us-east-1.amazonaws.com'); // sitecheck-allow: 원고(레슨 4 순서도)의 문구를 읽었는지 대조할 뿐 접속하지 않는다
  assert.match(f.endpoint.emulator, /^https:\/\/127\.0\.0\.1:\d+$/);
  assert.deepEqual([f.unsigned.code, f.unsigned.status], ['InvalidClientTokenId', 403]);
  const lines = lesson.split('\n');
  assert.match(lines[f.exitCodes[252].line - 1], /^\| 252 \|/);
  assert.match(lines[f.envFirstLine - 1], /환경 변수가 파일보다 우선/);
});

test('잘못된 것이 없으면 끝까지 가고 0', () => {
  const r = journey({ creds: 'file', fault: 'none' }, f);
  assert.equal(r.exit, 0);
  assert.equal(r.stoppedAt, 'response');
  assert.ok(r.stages.every((s) => s.state === 'ok'));
  assert.equal(r.used, 'file');
});

test('경우마다 멈추는 단계와 종료 코드(원고 표)', () => {
  const cases = [
    ['syntax', 'parse', 252],
    ['connect', 'send', 255],
    ['tamper', 'verify', 254],
    ['skew', 'verify', 254],
    ['denied', 'service', 254],
  ];
  for (const [fault, at, exit] of cases) {
    const r = journey({ creds: 'file', fault }, f);
    assert.deepEqual([r.stoppedAt, r.exit], [at, exit], fault);
    const i = STAGES.indexOf(at);
    assert.ok(r.stages.slice(0, i).every((s) => s.state === 'ok'));
    assert.equal(r.stages[i].state, 'fail');
    assert.ok(r.stages.slice(i + 1).every((s) => s.state === 'skip'));
    assert.ok(Object.keys(f.exitCodes).map(Number).includes(r.exit));
  }
  assert.equal(journey({ fault: 'tamper' }, f).error, 'SignatureDoesNotMatch');
  assert.match(journey({ fault: 'skew' }, f).error, /SignatureDoesNotMatch\(STS\) 또는 RequestTimeTooSkewed/);
});

test('자격 증명이 없으면 253, 단 문법 오류가 먼저면 252', () => {
  assert.deepEqual([journey({ creds: 'none' }, f).stoppedAt, journey({ creds: 'none' }, f).exit], ['creds', 253]);
  assert.equal(journey({ creds: 'none', fault: 'connect' }, f).exit, 253); // 키를 못 찾으면 보내지도 않는다
  assert.equal(journey({ creds: 'none', fault: 'syntax' }, f).exit, 252);
});

test('환경 변수가 파일보다 우선', () => {
  assert.equal(credentialUsed('both'), 'env');
  assert.equal(credentialUsed('env'), 'env');
  assert.equal(credentialUsed('file'), 'file');
  assert.equal(credentialUsed('none'), null);
  assert.match(describeStage('creds', 'ok', journey({ creds: 'both' }, f), f), /환경 변수가 파일보다 우선/);
});

test('모든 조합: 단계 상태가 앞 ok → 하나 fail(또는 없음) → 뒤 skip, 설명이 있다', () => {
  for (const creds of CRED_SOURCES)
    for (const fault of FAULTS) {
      const r = journey({ creds, fault }, f);
      const states = r.stages.map((s) => s.state).join('');
      assert.match(states, /^(ok)*(fail)?(skip)*$/);
      assert.equal(r.exit === 0, r.stages.every((s) => s.state === 'ok'));
      for (const s of r.stages) assert.ok(describeStage(s.id, s.state, r, f).length > 0);
    }
});

test('normalize: 모르는 값은 기본값', () => {
  assert.deepEqual(normalize({ creds: 'x', fault: 'y' }), { creds: 'file', fault: 'none' });
  assert.deepEqual(normalize(undefined), { creds: 'file', fault: 'none' });
});

test('원고가 바뀌면 읽기가 실패한다', () => {
  assert.throws(() => readRequestFacts('# 빈 원고\n', setup), /찾지 못했다/);
  assert.throws(() => readRequestFacts(lesson, '# 빈 원고\n'), /찾지 못했다/);
  assert.throws(() => readRequestFacts(lesson.replace('| 253 |', '| 999 |'), setup), /종료 코드 253/);
});
