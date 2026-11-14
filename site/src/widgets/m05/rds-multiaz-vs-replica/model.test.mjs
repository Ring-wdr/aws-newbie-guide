// node --test src/widgets/m05/rds-multiaz-vs-replica/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalize, evaluate, sourceLines, EVENTS, MAX_RETENTION_SHOWN } from './model.mjs';
import { readReplicaFacts, LESSON } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const text = fs.readFileSync(path.resolve(here, '../../../../..', LESSON), 'utf8');
const lines = text.split('\n');
const facts = readReplicaFacts(text);
const f = { failoverTime: facts.failover.time, minRetention: facts.backup.minRetention, writeRemedy: facts.writeRemedy.text };
const run = (o) => evaluate(normalize({ multiAz: false, engine: 'MySQL', replicas: 0, location: 'other-az', retention: 7, batchTo: 'primary', event: 'az-failure', ...o }, facts.replicaMax.engines), f);

test('원고에서 수치를 읽는다', () => {
  assert.equal(facts.failover.time, '1~2분');
  assert.deepEqual(facts.replicaMax.engines, [
    { id: 'MySQL', max: 15 }, { id: 'MariaDB', max: 15 }, { id: 'PostgreSQL', max: 15 }, { id: 'SQL Server', max: 15 }, { id: 'Oracle', max: 5 },
  ]);
  assert.equal(facts.backup.minRetention, 1);
  assert.equal(facts.labRetention.days, 7);
  assert.equal(facts.writeRemedy.text, '더 큰 인스턴스, Aurora, 샤딩, 또는 DynamoDB 같은 다른 모델');
  assert.match(lines[facts.failover.line - 1], /^\| 장애 시 \|/);
  assert.match(lines[facts.noBackupErrorLine - 1], /Automated backups are not enabled/);
  // 근거 줄 번호가 모두 원고 안의 실제 줄이다
  for (const [k, n] of Object.entries(sourceLines(facts))) assert.ok(Number.isInteger(n) && n > 0 && n <= lines.length && lines[n - 1].trim(), k);
});

test('AZ 장애 + Multi-AZ: 자동 장애 조치, 같은 엔드포인트, 손실 없음(시퀀스 그림 순서)', () => {
  const r = run({ multiAz: true });
  assert.equal(r.verdict, 'ok');
  assert.deepEqual(r.steps.map((s) => s.src), ['sync', 'promote', 'dns', 'failover', 'noLoss']);
  assert.match(r.facts.endpoint, /그대로/);
  assert.match(r.facts.dataLoss, /없음/);
  assert.match(r.facts.api, /1~2분/);
});

test('AZ 장애 + Multi-AZ + 같은 AZ 복제본: 장애 조치는 되지만 복제본도 멈춘다', () => {
  const r = run({ multiAz: true, replicas: 2, location: 'same-az' });
  assert.equal(r.verdict, 'ok');
  assert.match(r.steps.at(-1).text, /같은 AZ.*함께 멈춘다/);
});

test('AZ 장애, Multi-AZ 없음 + 다른 AZ·다른 리전 복제본: 수동 승격, 새 엔드포인트, 손실 가능', () => {
  for (const location of ['other-az', 'other-region']) {
    const r = run({ replicas: 1, location });
    assert.equal(r.verdict, 'partial', location);
    assert.match(r.facts.endpoint, /바뀜/);
    assert.match(r.facts.dataLoss, /있을 수 있음/);
  }
  assert.ok(run({ replicas: 1, location: 'other-region' }).notes.some((n) => n.src === 'xr'));
});

test('AZ 장애, Multi-AZ 없음 + 복제본 없음 또는 같은 AZ: 멈춘다', () => {
  assert.equal(run({}).verdict, 'bad');
  const r = run({ replicas: 3, location: 'same-az' });
  assert.equal(r.verdict, 'bad');
  assert.match(r.steps[1].text, /함께 멈춘다/);
});

test('스스로 확인 1번: Multi-AZ만 켜면 정산 쿼리 문제는 그대로, 복제본 + 배치 연결 바꾸면 해결', () => {
  const maz = run({ multiAz: true, event: 'report' });
  assert.equal(maz.verdict, 'bad');
  assert.match(maz.steps[0].text, /대기 인스턴스는 트래픽을 받지 않는다/);
  const rrPrimary = run({ replicas: 1, event: 'report', batchTo: 'primary' });
  assert.equal(rrPrimary.verdict, 'bad');
  assert.match(rrPrimary.steps[0].text, /여전히 원본 엔드포인트/);
  const ok = run({ replicas: 1, event: 'report', batchTo: 'replica' });
  assert.equal(ok.verdict, 'ok');
});

test('스스로 확인 3번: 복제본에서 방금 쓴 주문이 없을 수 있다(비동기), 복제본이 없으면 바로 보인다', () => {
  assert.equal(run({ replicas: 1, event: 'read-after-write' }).verdict, 'partial');
  assert.match(run({ replicas: 1, event: 'read-after-write' }).headline, /버그가 아니라 비동기/);
  assert.equal(run({ multiAz: true, event: 'read-after-write' }).verdict, 'ok');
});

test('쓰기 병목: 어떤 구성이든 복제로는 해결 안 됨, 해법은 원고 문장', () => {
  for (const o of [{}, { multiAz: true }, { replicas: 15 }, { multiAz: true, replicas: 5 }]) {
    const r = run({ ...o, event: 'write-bottleneck' });
    assert.equal(r.verdict, 'bad');
    assert.ok(r.steps.at(-1).text.includes(facts.writeRemedy.text));
  }
});

test('자동 백업 경계: 보존 0일이면 복제본을 못 만들고 복제본 없이 판정, 1일이면 만든다', () => {
  const r0 = run({ replicas: 2, retention: 0, event: 'report', batchTo: 'replica' });
  assert.equal(r0.replicasBuilt, 0);
  assert.equal(r0.verdict, 'bad');
  assert.match(r0.notes[0].text, /만들 수 없다\(InvalidDBInstanceState\)/);
  const r1 = run({ replicas: 2, retention: 1, event: 'report', batchTo: 'replica' });
  assert.equal(r1.replicasBuilt, 2);
  assert.equal(r1.verdict, 'ok');
  // 복제본 0개면 보존 기간 0이어도 문제 없음
  assert.equal(run({ retention: 0 }).notes.length, 0);
});

test('normalize: 엔진별 복제본 상한(Oracle 5, 그 밖 15)과 범위 밖 값', () => {
  const eng = facts.replicaMax.engines;
  assert.equal(normalize({ engine: 'Oracle', replicas: 6 }, eng).replicas, 5);
  assert.equal(normalize({ engine: 'Oracle', replicas: 5 }, eng).replicas, 5);
  assert.equal(normalize({ engine: 'PostgreSQL', replicas: 16 }, eng).replicas, 15);
  const n = normalize({ engine: 'nope', replicas: 'x', retention: 99, location: '?', batchTo: '?', event: '?' }, eng);
  assert.deepEqual(
    { e: n.engine, r: n.replicas, t: n.retention, l: n.location, b: n.batchTo, ev: n.event },
    { e: 'MySQL', r: 0, t: MAX_RETENTION_SHOWN, l: 'other-az', b: 'primary', ev: EVENTS[0] },
  );
});

test('모든 조합에서 판정·문장이 비지 않는다', () => {
  for (const event of EVENTS)
    for (const multiAz of [true, false])
      for (const replicas of [0, 1, 15])
        for (const location of ['same-az', 'other-az', 'other-region'])
          for (const retention of [0, 1])
            for (const batchTo of ['primary', 'replica']) {
              const r = run({ event, multiAz, replicas, location, retention, batchTo });
              assert.ok(['ok', 'partial', 'bad'].includes(r.verdict));
              assert.ok(r.steps.length >= 2 && r.steps.every((s) => s.text.length > 5 && !s.text.includes('undefined') && sourceLines(facts)[s.src]));
            }
});

test('원고 문장이 바뀌면 읽기가 실패한다(조용히 다른 수치를 쓰지 않는다)', () => {
  assert.throws(() => readReplicaFacts('# 빈 원고\n'), /찾지 못했다/);
  assert.throws(() => readReplicaFacts(text.replace('**Oracle은 최대 5**', 'Oracle 5')), /해석할 수 없다/);
});
