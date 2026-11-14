// node --test src/widgets/m09/kms-envelope-steps/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalize, buildSteps, directNote, MODEL_MAX_SIZE } from './model.mjs';
import { readEnvelopeFacts, LESSON } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const text = fs.readFileSync(path.resolve(here, '../../../../..', LESSON), 'utf8');
const facts = readEnvelopeFacts(text);
const run = (o) => buildSteps(normalize({ size: 64893, keyState: 'Enabled', sameContext: true, tampered: false, ...o }), facts);

test('원고에서 수치를 읽는다', () => {
  assert.equal(facts.encryptLimit.value, 4096);
  assert.equal(facts.encryptError.max, 4096);
  assert.equal(facts.encryptError.name, 'ValidationException');
  assert.equal(facts.dataKeyBytes.value, 32);
  assert.deepEqual([facts.gcm.nonce, facts.gcm.tag], [12, 16]);
  assert.deepEqual([facts.lab03.plain, facts.lab03.cipher, facts.lab03.nonce, facts.lab03.tag, facts.lab03.encryptedKey], [64893, 64921, 12, 16, 98]);
  assert.equal(facts.sdk.plain, 9232);
  assert.deepEqual([facts.lab01.plain, facts.lab01.cipher], [24, 90]);
  assert.deepEqual(Object.values(facts.errors).map((e) => e.name), ['DisabledException', 'KMSInvalidStateException', 'InvalidCiphertextException', 'InvalidTag']);
  const lines = text.split('\n');
  assert.match(lines[facts.encryptLimit.line - 1], /4 KiB\(4,096바이트\)/);
  assert.match(lines[facts.lab03.line - 1], /^암호문 64921바이트/);
  // 원고 안에서도 수치가 서로 맞는다: 레슨 문장의 nonce·태그 = lab03 출력의 nonce·태그, 한도 문장 = 오류 메시지
  assert.deepEqual([facts.gcm.nonce, facts.gcm.tag], [facts.lab03.nonce, facts.lab03.tag]);
  assert.equal(facts.encryptLimit.value, facts.encryptError.max);
});

test('lab03: 64893바이트 → 암호문 64921바이트(모형이 lab03 출력과 같다)', () => {
  const r = run({ size: facts.lab03.plain });
  assert.equal(r.cipherBytes, facts.lab03.cipher);
  assert.equal(r.result, 'ok');
  assert.equal(r.steps.length, 9);
  assert.deepEqual(r.steps.map((s) => s.phase), ['write', 'write', 'write', 'write', 'write', 'read', 'read', 'read', 'read']);
  assert.equal(r.directEncrypt, false);
});

test('평문 데이터 키는 S3에 한 번도 없고, KMS에는 평문 데이터가 가지 않는다', () => {
  for (const o of [{}, { keyState: 'Disabled' }, { sameContext: false }, { tampered: true }]) {
    const r = run(o);
    for (const s of r.steps) {
      assert.ok(!s.s3.some((i) => i.kind === 'pdk' || i.kind === 'plain'), `${s.n} S3`);
      assert.ok(!s.kms.some((i) => i.kind !== 'cmk'), `${s.n} KMS`);
      if (s.wire) assert.ok(!s.wire.includes('평문 데이터 '), s.wire);
    }
    // 저장 단계 뒤 S3에는 암호문·암호화된 데이터 키·컨텍스트
    assert.deepEqual(r.steps[4].s3.map((i) => i.kind), ['ct', 'edk', 'ctx']);
    // 평문 키를 버린 단계
    assert.ok(!r.steps[3].app.some((i) => i.kind === 'pdk'));
  }
});

test('키 비활성화 → Decrypt에서 DisabledException, 그 뒤 단계 없음', () => {
  const r = run({ keyState: 'Disabled' });
  assert.equal(r.result, 'fail');
  assert.equal(r.error, 'DisabledException');
  assert.equal(r.steps.at(-1).title.startsWith('Decrypt'), true);
  assert.equal(r.steps.at(-1).ok, false);
  assert.ok(!r.steps.at(-1).app.some((i) => i.kind === 'pdk'));
});

test('삭제 대기 → KMSInvalidStateException', () => {
  assert.equal(run({ keyState: 'PendingDeletion' }).error, 'KMSInvalidStateException');
});

test('다른 컨텍스트 → InvalidCiphertextException(KMS 단계)', () => {
  const r = run({ sameContext: false });
  assert.equal(r.error, 'InvalidCiphertextException');
  assert.equal(r.steps.length, 7);
});

test('변조 → KMS는 통과, 로컬 단계에서 InvalidTag', () => {
  const r = run({ tampered: true });
  assert.equal(r.error, 'InvalidTag');
  assert.equal(r.steps.length, 8);
  assert.ok(r.steps[6].ok);
  assert.ok(r.steps[6].app.some((i) => i.kind === 'pdk'));
});

test('키 상태와 컨텍스트가 둘 다 문제면 키 상태 오류를 먼저(모형 가정 A2)', () => {
  assert.equal(run({ keyState: 'Disabled', sameContext: false, tampered: true }).error, 'DisabledException');
  assert.equal(run({ sameContext: false, tampered: true }).error, 'InvalidCiphertextException');
});

test('Encrypt 한도 경계: 4096은 바로 가능, 4097은 봉투', () => {
  assert.equal(run({ size: 4096 }).directEncrypt, true);
  assert.equal(run({ size: 4097 }).directEncrypt, false);
  assert.match(directNote(normalize({ size: 4096 }), facts), /이하라 KMS Encrypt로 바로/);
  assert.match(directNote(normalize({ size: 4097 }), facts), /ValidationException로 거부/);
  assert.match(directNote(normalize({ size: facts.lab01.plain }), facts), /24바이트는/);
});

test('normalize: 범위 밖·숫자 아님', () => {
  assert.deepEqual(normalize({ size: 0, keyState: 'x', sameContext: undefined, tampered: 1 }), { size: 1, keyState: 'Enabled', sameContext: true, tampered: true });
  assert.equal(normalize({ size: 'abc' }).size, 1);
  assert.equal(normalize({ size: 1e12 }).size, MODEL_MAX_SIZE);
  assert.equal(normalize({ size: 9231.6 }).size, 9232);
});

test('단계 번호는 1부터 차례로', () => {
  for (const o of [{}, { keyState: 'Disabled' }, { tampered: true }]) {
    const r = run(o);
    r.steps.forEach((s, i) => assert.equal(s.n, i + 1));
  }
});

test('원고 문장이 바뀌면 읽기가 실패한다', () => {
  assert.throws(() => readEnvelopeFacts('# 빈 원고\n'), /찾지 못했다/);
});
