import test from 'node:test';
import assert from 'node:assert/strict';
import { PREFIX, legacyTarget, migrateLegacy } from './storage-keys.mjs';

class Mem {
  constructor(o = {}) { this.m = new Map(Object.entries(o)); }
  get length() { return this.m.size; }
  key(i) { return [...this.m.keys()][i] ?? null; }
  getItem(k) { return this.m.has(k) ? this.m.get(k) : null; }
  setItem(k, v) { this.m.set(k, String(v)); }
  removeItem(k) { this.m.delete(k); }
  obj() { return Object.fromEntries(this.m); }
}

test('이 사이트가 만든 꼴의 옛 키만 새 키로 대응한다', () => {
  assert.equal(PREFIX, 'aws-newbie-guide:');
  assert.equal(legacyTarget('guide:progress:m06'), 'aws-newbie-guide:progress:m06');
  assert.equal(legacyTarget('guide:quiz:/curriculum/m06-integration-messaging/quiz'), 'aws-newbie-guide:quiz:/curriculum/m06-integration-messaging/quiz');
  assert.equal(legacyTarget('guide:checklist:/curriculum/m14-capstone-exam/capstone-self-check'), 'aws-newbie-guide:checklist:/curriculum/m14-capstone-exam/capstone-self-check');
  assert.equal(legacyTarget('guide:exam:m14-mock-exam'), 'aws-newbie-guide:exam:m14-mock-exam');
  assert.equal(legacyTarget('guide:exam:m14-mock-exam:history'), 'aws-newbie-guide:exam:m14-mock-exam:history');
  for (const k of ['guide:theme', 'guide:progress:m6', 'guide:progress:m06x', 'guide:quiz:x', 'guide:quiz:/A B', 'guide:exam:other', 'guide:__probe', 'guide:', 'xguide:progress:m06', 'starlight-theme'])
    assert.equal(legacyTarget(k), null, k);
});

test('옮기기: 맞는 키는 옮기고 옛 키를 지운다, 다른 guide:* 키와 새 키가 이미 있는 것은 그대로', () => {
  const s = new Mem({
    'guide:progress:m06': '{"v":1,"done":{"lesson:02-sqs":true}}',
    'guide:quiz:/curriculum/m01-iam-identity/quiz': '{"picked":{},"graded":{}}',
    'guide:exam:m14-mock-exam:history': '{"v":1,"records":[]}',
    'guide:progress:m01': '{"old":true}',
    'aws-newbie-guide:progress:m01': '{"new":true}',
    'guide:settings': '{"other":"site"}',
    'guide:progress:abc': 'x',
    'starlight-theme': 'dark',
  });
  const moved = migrateLegacy(s);
  assert.deepEqual(moved.sort(), ['guide:exam:m14-mock-exam:history', 'guide:progress:m06', 'guide:quiz:/curriculum/m01-iam-identity/quiz']);
  assert.deepEqual(s.obj(), {
    'aws-newbie-guide:progress:m06': '{"v":1,"done":{"lesson:02-sqs":true}}',
    'aws-newbie-guide:quiz:/curriculum/m01-iam-identity/quiz': '{"picked":{},"graded":{}}',
    'aws-newbie-guide:exam:m14-mock-exam:history': '{"v":1,"records":[]}',
    'guide:progress:m01': '{"old":true}',
    'aws-newbie-guide:progress:m01': '{"new":true}',
    'guide:settings': '{"other":"site"}',
    'guide:progress:abc': 'x',
    'starlight-theme': 'dark',
  });
  assert.deepEqual(migrateLegacy(s), [], '두 번째는 옮길 것이 없다');
});
