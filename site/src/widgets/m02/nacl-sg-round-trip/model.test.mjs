// node --test src/widgets/m02/nacl-sg-round-trip/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { roundTrip, normalize, evaluateNacl, inCidr, ipToInt, ruleMatches, rulesFor, summarize, PRESETS, HOPS, APP_B_IP, EPHEMERAL_RANGE } from './model.mjs';
import { readNaclFacts, LESSON } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const text = fs.readFileSync(path.resolve(here, '../../../../..', LESSON), 'utf8');
const f = readNaclFacts(text);
const defaults = { port: 5432, ephemeral: f.ephemeral.port };
const run = (o) => roundTrip(normalize(o, defaults), f);
const hop = (rt, id) => rt.hops.find((h) => h.id === id);

test('원고에서 DB NACL 규칙·SG 규칙·주소를 읽는다', () => {
  assert.equal(f.rules.length, 6);
  assert.deepEqual(
    f.rules.map((r) => `${r.egress ? 'out' : 'in'} ${r.number} ${r.action} ${r.protocol} ${r.cidr} ${r.from}-${r.to}`),
    ['out 100 allow 6 10.0.10.0/24 1024-65535', 'in 100 allow 6 10.0.10.0/24 5432-5432', 'out 110 allow 6 10.0.11.0/24 1024-65535', 'in 110 allow 6 10.0.11.0/24 5432-5432', 'out 32767 deny -1 0.0.0.0/0 null-null', 'in 32767 deny -1 0.0.0.0/0 null-null'],
  );
  assert.deepEqual(f.dbSgRule.port, 5432);
  assert.equal(f.dbSgRule.fromSg, 'app');
  assert.deepEqual(f.ip, { alb: '10.0.0.50', app: '10.0.10.25', db: '10.0.20.30', line: f.ip.line });
  assert.equal(f.ephemeral.port, 49152);
  assert.deepEqual(f.ephemeral.linux, [32768, 60999]);
  const lines = text.split('\n');
  for (const r of f.rules) assert.match(lines[r.line - 1], new RegExp(`\\|\\s*${r.number}\\s*\\|`));
});

test('원고 lab05 워크시트 Q4~Q6과 같은 규칙에서 같은 판정', () => {
  const q4 = evaluateNacl(f.rules, { egress: false, peer: f.ip.app, port: 5432 });
  assert.deepEqual([q4.rule.number, q4.rule.action], [f.worksheet.Q4.number, f.worksheet.Q4.action]);
  const q5 = evaluateNacl(f.rules, { egress: true, peer: f.ip.app, port: f.ephemeral.port });
  assert.deepEqual([q5.rule.number, q5.rule.action], [f.worksheet.Q5.number, f.worksheet.Q5.action]);
  const q6 = evaluateNacl(f.rules, { egress: false, peer: f.ip.alb, port: 5432 });
  assert.deepEqual([q6.rule.number, q6.rule.action], [f.worksheet.Q6.number, f.worksheet.Q6.action]);
  assert.match(f.worksheet.Q6.text, /10\.0\.0\.50/);
});

test('원고 lab04 워크시트 Q3·Q4(SG)와 같은 판정', () => {
  // Q4 앱 → DB:5432 ALLOW: 왕복 전체가 연결된다
  assert.equal(f.sgWorksheet.Q4.verdict, 'ALLOW');
  assert.equal(run({ source: 'app-a' }).result, 'ok');
  // Q3 ALB → DB:5432 DENY: NACL을 통과시켜도(규칙 없이) SG에서 거부된다 — 이중 방어
  assert.equal(f.sgWorksheet.Q3.verdict, 'DENY');
  const open = { ...f, rules: [{ egress: false, number: 1, action: 'allow', protocol: '-1', cidr: '0.0.0.0/0', from: null, to: null }, ...f.rules] };
  assert.equal(roundTrip(normalize({ source: 'alb' }, defaults), open).result, 'sg-in');
});

test('예: 앱 a → DB:5432 연결, 단계마다 통과', () => {
  const rt = run({ source: 'app-a' });
  assert.equal(rt.result, 'ok');
  assert.deepEqual(rt.hops.map((h) => h.id), HOPS.map(([id]) => id));
  assert.ok(rt.hops.every((h) => h.pass === true));
  assert.equal(hop(rt, 'nacl-in').rule.number, 100);
  assert.equal(hop(rt, 'nacl-out').rule.number, 100);
});

test('예: ALB → DB:5432는 DB NACL 32767에서 막히고 뒤 단계는 가지 않는다', () => {
  const rt = run({ source: 'alb' });
  assert.equal(rt.result, 'nacl-in');
  assert.equal(hop(rt, 'nacl-in').rule.number, 32767);
  for (const id of ['sg-in', 'sg-out', 'nacl-out', 'src-in']) assert.equal(hop(rt, id).pass, null);
  assert.deepEqual(rt.hops.map((h) => h.id), HOPS.map(([id]) => id));
});

test('예: 앱 a → DB:22는 NACL 인바운드(포트 불일치)에서 32767 deny', () => {
  const rt = run({ source: 'app-a', port: 22 });
  assert.equal(rt.result, 'nacl-in');
  assert.deepEqual(hop(rt, 'nacl-in').checked.map((c) => `${c.number}:${c.hit}`), ['100:false', '110:false', '32767:true']);
});

test('예: 아웃바운드 임시 포트 규칙을 빠뜨리면 요청은 들어가고 응답이 막힌다(타임아웃)', () => {
  const rt = run({ source: 'app-a', dropEgress: true });
  assert.equal(rt.result, 'timeout');
  assert.equal(hop(rt, 'sg-in').pass, true);
  assert.equal(hop(rt, 'nacl-out').rule.number, 32767);
  assert.match(summarize(rt, normalize({ dropEgress: true }, defaults)), /타임아웃/);
  assert.equal(rulesFor(f.rules, true).length, 4);
});

test('앱 b(모형 주소)는 110번 규칙으로 통과', () => {
  const rt = run({ source: 'app-b' });
  assert.equal(rt.src.ip, APP_B_IP);
  assert.equal(rt.src.modelIp, true);
  assert.equal(rt.result, 'ok');
  assert.equal(hop(rt, 'nacl-in').rule.number, 110);
  assert.equal(hop(rt, 'nacl-out').rule.number, 110);
});

test('임시 포트 경계: 1024와 65535는 허용 규칙 안, 범위 밖 입력은 맞춘다', () => {
  assert.equal(run({ ephemeral: 1024 }).result, 'ok');
  assert.equal(run({ ephemeral: 65535 }).result, 'ok');
  assert.equal(normalize({ ephemeral: 80 }, defaults).ephemeral, EPHEMERAL_RANGE.min);
  assert.equal(normalize({ ephemeral: 70000 }, defaults).ephemeral, EPHEMERAL_RANGE.max);
  assert.equal(normalize({ ephemeral: 'x', port: '' }, defaults).ephemeral, 49152);
  assert.equal(normalize({ port: 0 }, defaults).port, 1);
  assert.equal(normalize({ source: 'nope' }, defaults).source, 'app-a');
});

test('CIDR·규칙 맞추기', () => {
  assert.equal(ipToInt('10.0.10.25'), 167774745);
  assert.ok(inCidr('10.0.10.255', '10.0.10.0/24'));
  assert.ok(!inCidr('10.0.11.0', '10.0.10.0/24'));
  assert.ok(inCidr('203.0.113.9', '0.0.0.0/0'));
  assert.throws(() => ipToInt('10.0.0'));
  const r = { protocol: '6', cidr: '10.0.10.0/24', from: 5432, to: 5432 };
  assert.ok(ruleMatches(r, { peer: '10.0.10.25', port: 5432 }));
  assert.ok(!ruleMatches(r, { peer: '10.0.10.25', port: 5433 }));
  assert.ok(!ruleMatches({ ...r, protocol: '17' }, { peer: '10.0.10.25', port: 5432 }));
});

test('모든 출발지·포트: 결과는 네 가지 중 하나이고 단계는 7개', () => {
  for (const source of ['app-a', 'app-b', 'alb'])
    for (const port of [1, 22, 443, 5431, 5432, 5433, 65535])
      for (const ephemeral of [1024, 32768, 49152, 65535])
        for (const dropEgress of [false, true]) {
          const rt = run({ source, port, ephemeral, dropEgress });
          assert.ok(['ok', 'nacl-in', 'sg-in', 'timeout'].includes(rt.result));
          assert.equal(rt.hops.length, 7);
          assert.equal(rt.result === 'ok', source !== 'alb' && port === 5432 && !dropEgress);
        }
});

test('원고 문장이 바뀌면 읽기가 실패한다', () => {
  assert.throws(() => readNaclFacts('# 빈 원고\n'), /찾지 못했다/);
  assert.throws(() => readNaclFacts(text.replace(/^\|\s*(True|False)\s*\|.*$/gm, '')), /규칙 표를 읽지 못했다/);
});
