// node --test src/widgets/m01/policy-evaluation/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluate, normalize, PRESETS, presetInput, REASON_PHRASE, STEP_ORDER, displayOrder, describeStep, summarize, DEFAULT_INPUT, DECISION_CODE } from './model.mjs';
import { readPolicyFacts, LESSON, ROLES, CHEATSHEET } from './facts.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../../../..');
const read = (rel) => fs.readFileSync(path.join(repo, rel), 'utf8');
const texts = { lesson: read(LESSON), roles: read(ROLES), cheatsheet: read(CHEATSHEET) };
const ev = (o) => evaluate({ ...DEFAULT_INPUT, ...o });

test('기본값(아무 정책도 허용하지 않음) → 암묵적 거부, 자격 증명 단계에서 끝', () => {
  const r = ev({});
  assert.equal(r.decision, 'implicitDeny');
  assert.equal(r.reason, 'noIdentity');
  assert.equal(r.stoppedAt, 'identity');
  assert.deepEqual(r.steps.map((s) => s.outcome), ['no', 'yes', 'no', 'no', 'skip', 'skip']);
});

test('명시적 Deny는 모든 Allow를 이긴다(같은 계정·교차 계정)', () => {
  for (const account of ['same', 'cross']) {
    for (const deny of ['identity', 'resource', 'other']) {
      const r = ev({ account, deny, identity: true, resource: true, boundary: 'allow', session: 'allow' });
      assert.equal(r.decision, 'explicitDeny', `${account}/${deny}`);
      assert.equal(r.stoppedAt, 'deny');
      assert.ok(r.steps.slice(1).every((s) => s.outcome === 'skip'));
    }
  }
  assert.equal(ev({ deny: 'identity' }).reason, 'identityDeny');
  assert.equal(ev({ deny: 'resource' }).reason, 'resourceDeny');
  assert.equal(ev({ deny: 'other' }).reason, 'otherDeny');
});

test('SCP·RCP는 상한선: 허용하지 않으면 다른 Allow가 있어도 암묵적 거부', () => {
  const s = ev({ scp: false, identity: true, resource: true });
  assert.deepEqual([s.decision, s.reason, s.stoppedAt], ['implicitDeny', 'scp', 'org']);
  const r = ev({ rcp: false, identity: true });
  assert.deepEqual([r.decision, r.reason], ['implicitDeny', 'rcp']);
  // 상한선은 권한을 주지 않는다: SCP·RCP 허용만으로는 거부
  assert.equal(ev({ scp: true, rcp: true }).decision, 'implicitDeny');
});

// 근거(AWS IAM User Guide): "Policy evaluation logic" — How AWS enforcement code logic evaluates requests to allow or deny access
// (Resource-based policies: IAM role / IAM role session / IAM user), "Permissions boundaries for IAM entities" — Evaluating effective
// permissions with boundaries, "Policies and permissions" — Session policies.
test('같은 계정: 리소스 정책이 IAM 사용자 ARN을 지정해 허용 → 자격 증명 정책·권한 경계와 상관없이 허용 *', () => {
  for (const identity of [true, false])
    for (const boundary of ['none', 'allow', 'deny']) {
      const r = ev({ caller: 'user', resource: true, resourceTo: 'user', identity, boundary });
      assert.deepEqual([r.decision, r.reason, r.stoppedAt], ['allowed', 'allowedByResource', 'resource'], `${identity}/${boundary}`);
      assert.deepEqual(r.steps.map((s) => s.outcome), ['no', 'yes', 'yes', 'skip', 'skip', 'skip']);
    }
});

test('같은 계정: 리소스 정책이 역할 세션 ARN을 지정해 허용 → 자격 증명 정책·권한 경계·세션 정책과 상관없이 허용 *', () => {
  for (const identity of [true, false])
    for (const boundary of ['none', 'allow', 'deny'])
      for (const session of ['none', 'allow', 'deny']) {
        const r = ev({ caller: 'role', resource: true, resourceTo: 'session', identity, boundary, session });
        assert.deepEqual([r.decision, r.reason, r.stoppedAt], ['allowed', 'allowedByResource', 'resource'], `${identity}/${boundary}/${session}`);
      }
});

test('같은 계정: 리소스 정책이 역할 ARN을 지정해 허용 → 자격 증명 정책은 필요 없고, 권한 경계·세션 정책의 암묵적 거부에 제한된다', () => {
  for (const identity of [true, false])
    for (const boundary of ['none', 'allow', 'deny'])
      for (const session of ['none', 'allow', 'deny']) {
        const r = ev({ caller: 'role', resource: true, resourceTo: 'role', identity, boundary, session });
        const want = boundary === 'deny' ? 'noBoundary' : session === 'deny' ? 'noSession' : 'allowedByResourceRole';
        assert.equal(r.reason, want, `${identity}/${boundary}/${session}`);
        assert.equal(r.decision, want.startsWith('allowed') ? 'allowed' : 'implicitDeny');
        assert.equal(r.steps.find((s) => s.id === 'identity').outcome, 'na'); // 자격 증명 정책은 묻지 않는다
      }
  assert.equal(ev({ caller: 'role', resource: true, resourceTo: 'role', boundary: 'deny' }).stoppedAt, 'boundary');
  assert.equal(ev({ caller: 'role', resource: true, resourceTo: 'role', session: 'deny' }).stoppedAt, 'session');
});

test('명시적 Deny는 어느 지정이든 먼저 이긴다', () => {
  for (const [caller, resourceTo] of [['user', 'user'], ['role', 'role'], ['role', 'session']]) {
    const r = ev({ caller, resourceTo, resource: true, deny: 'resource' });
    assert.equal(r.decision, 'explicitDeny');
  }
});

test('성립하지 않는 조합은 입력에서 맞춘다: IAM 사용자에게 세션 정책·역할 ARN 없음, 역할 세션에 사용자 ARN 없음', () => {
  assert.deepEqual([normalize({ caller: 'user', session: 'deny', resourceTo: 'role' }).session, normalize({ caller: 'user', session: 'deny', resourceTo: 'role' }).resourceTo], ['none', 'user']);
  assert.equal(normalize({ caller: 'role', resourceTo: 'user' }).resourceTo, 'role');
  assert.equal(normalize({ caller: 'role', resourceTo: 'session' }).resourceTo, 'session');
  // IAM 사용자 요청의 세션 정책 단계는 "해당 없음"
  const r = ev({ caller: 'user', identity: true });
  assert.equal(r.steps.find((s) => s.id === 'session').outcome, 'na');
  assert.match(describeStep(r.steps.find((s) => s.id === 'session'), 'same', { caller: 'user' }), /IAM 사용자 요청에는 세션 정책이 없다/);
});

test('교차 계정: 양쪽 모두 허용해야 한다', () => {
  assert.deepEqual([ev({ account: 'cross', resource: true }).decision, ev({ account: 'cross', resource: true }).reason], ['implicitDeny', 'noIdentity']);
  const noRes = ev({ account: 'cross', identity: true });
  assert.deepEqual([noRes.decision, noRes.reason, noRes.stoppedAt], ['implicitDeny', 'noResource', 'resource']);
  const ok = ev({ account: 'cross', identity: true, resource: true });
  assert.equal(ok.decision, 'allowed');
  assert.equal(ok.reason, 'allowed');
  assert.equal(ev({ account: 'cross', identity: true, resource: true, boundary: 'deny' }).reason, 'noBoundary');
  assert.equal(ev({ account: 'cross', caller: 'role', identity: true, resource: true, session: 'deny' }).reason, 'noSession');
  assert.deepEqual(displayOrder('cross'), ['deny', 'org', 'identity', 'boundary', 'session', 'resource']);
  assert.deepEqual(displayOrder('same'), STEP_ORDER);
});

test('권한 경계·세션 정책: 없으면 통과, 있으면 교집합', () => {
  assert.equal(ev({ identity: true }).decision, 'allowed');
  assert.equal(ev({ identity: true }).steps.find((s) => s.id === 'boundary').outcome, 'pass');
  assert.equal(ev({ caller: 'role', identity: true, boundary: 'allow', session: 'allow' }).decision, 'allowed');
  assert.deepEqual([ev({ identity: true, boundary: 'deny' }).reason, ev({ identity: true, boundary: 'deny' }).stoppedAt], ['noBoundary', 'boundary']);
  assert.deepEqual([ev({ caller: 'role', identity: true, session: 'deny' }).reason, ev({ caller: 'role', identity: true, session: 'deny' }).stoppedAt], ['noSession', 'session']);
  // 경계만 허용하고 자격 증명 정책이 없으면 거부(경계는 권한을 주지 않는다)
  assert.equal(ev({ boundary: 'allow' }).reason, 'noIdentity');
  assert.match(summarize(ev({ boundary: 'allow' }), { boundary: 'allow' }), /상한선일 뿐 권한을 주지 않는다/);
});

test('모든 입력 조합: 판정은 세 가지 중 하나, 끝난 단계 뒤는 보지 않는다, 문장이 있다', () => {
  let n = 0;
  for (const account of ['same', 'cross'])
   for (const [caller, resourceTo] of [['user', 'user'], ['role', 'role'], ['role', 'session']])
    for (const deny of ['none', 'identity', 'resource', 'other'])
      for (const scp of [true, false])
        for (const rcp of [true, false])
          for (const resource of [true, false])
            for (const identity of [true, false])
              for (const boundary of ['none', 'allow', 'deny'])
                for (const session of ['none', 'allow', 'deny']) {
                  if (caller === 'user' && session !== 'none') continue; // 입력에서 막는 조합
                  const input = { account, caller, resourceTo, deny, scp, rcp, resource, identity, boundary, session };
                  const r = evaluate(input);
                  n++;
                  assert.ok(['allowed', 'explicitDeny', 'implicitDeny'].includes(r.decision));
                  assert.equal(r.decision === 'explicitDeny', deny !== 'none');
                  // 허용이면 SCP·RCP가 허용했고, (같은 계정) 리소스 또는 자격 증명 정책 / (교차 계정) 둘 다 허용했다
                  if (r.decision === 'allowed') {
                    assert.ok(scp && rcp);
                    assert.ok(account === 'same' ? resource || identity : resource && identity);
                  }
                  // 같은 계정, Deny·SCP·RCP 통과, 리소스 정책 허용일 때: 사용자·세션 ARN은 늘 허용, 역할 ARN은 경계·세션 정책을 따른다
                  if (account === 'same' && deny === 'none' && scp && rcp && resource) {
                    const want = resourceTo === 'role' ? (boundary === 'deny' || session === 'deny' ? 'implicitDeny' : 'allowed') : 'allowed';
                    assert.equal(r.decision, want, JSON.stringify(input));
                  }
                  const order = displayOrder(account);
                  const at = r.stoppedAt ? order.indexOf(r.stoppedAt) : order.length;
                  for (const id of order.slice(at + 1)) assert.equal(r.steps.find((s) => s.id === id).outcome, 'skip', JSON.stringify(input));
                  assert.ok(summarize(r, input).length > 10);
                  for (const s of r.steps) assert.ok(describeStep(s, account, input).length > 0);
                }
  assert.equal(n, 2 * (4 * 2 * 2 * 2 * 2 * 3 * 1 + 2 * 4 * 2 * 2 * 2 * 2 * 3 * 3));
});

test('normalize: 모르는 값은 기본값, 참거짓은 Boolean', () => {
  assert.deepEqual(normalize({ account: 'x', caller: 'q', resourceTo: 'r', deny: 'y', boundary: 'z', session: 1, scp: 0, identity: 'yes' }), { ...DEFAULT_INPUT, scp: false, identity: true });
  assert.deepEqual(normalize(undefined), DEFAULT_INPUT);
});

test('원고에서 흐름도 순서·오류 문구·예의 줄을 읽는다(실제 원고)', () => {
  const f = readPolicyFacts(texts);
  const lines = texts.lesson.split('\n');
  assert.deepEqual(Object.keys(f.flow), STEP_ORDER);
  assert.match(lines[f.edges.direct - 1], /IAM 사용자 ARN·<br\/>역할 세션 ARN 지정" --> OK1/);
  assert.match(lines[f.edges.role - 1], /역할 ARN 지정" --> G/);
  assert.match(lines[f.flow.deny - 1], /명시적 Deny\?/);
  assert.match(lines[f.flow.session - 1], /세션 정책도 허용\?/);
  assert.match(lines[f.footnote - 1], /^\\\* 같은 계정에서/);
  assert.equal(f.phrases.noBoundary.text, 'because no permissions boundary allows');
  assert.equal(f.phrases.noSession.meaning, '세션 정책 밖');
  const cs = texts.cheatsheet.split('\n');
  for (const p of Object.values(f.phrases)) assert.ok(cs[p.line - 1].includes(p.text));
  assert.match(cs[f.crossFormula - 1], /교차 계정/);
});

test('원고의 예마다 모형 판정이 원고에 기록된 결과와 같고, 원고 줄에 그 결과 문구가 있다', () => {
  const f = readPolicyFacts(texts);
  const byFile = { lesson: texts.lesson.split('\n'), roles: texts.roles.split('\n') };
  for (const p of PRESETS) {
    const r = evaluate(presetInput(p));
    assert.equal(r.decision, p.expect, p.id);
    const line = byFile[p.file][f.examples[p.where] - 1];
    assert.ok(line, p.id);
    if (p.phrase) {
      assert.equal(REASON_PHRASE[r.reason], p.phrase, p.id);
      if (p.where !== 'footnote') assert.ok(line.includes(f.phrases[p.phrase].text.replace(/^because /, '')), `${p.id}: ${line}`);
    }
    if (p.where === 'footnote') assert.match(line, p.expect === 'allowed' ? /역할 세션 ARN/ : /역할 ARN\*\*을 지정했으면.*권한 경계와 세션 정책의 암묵적 거부에는 제한된다/);
    if (p.id === 'q9') assert.match(line, new RegExp(`\\s${DECISION_CODE[r.decision]}\\s+${DECISION_CODE[r.decision]}\\s`));
  }
});

test('원고 문장이 바뀌면 읽기가 실패한다(조용히 다른 규칙을 쓰지 않는다)', () => {
  assert.throws(() => readPolicyFacts({ lesson: '# 빈 원고\n', roles: texts.roles, cheatsheet: texts.cheatsheet }), /찾지 못했다/);
  // 흐름도 노드 순서가 바뀌면 실패
  const A = '{자격 증명 기반 정책이<br/>허용?}';
  const B = '{권한 경계가 있으면<br/>경계도 허용?}';
  const swapped = texts.lesson.replace(A, '\u0000').replace(B, A).replace('\u0000', B);
  assert.notEqual(swapped, texts.lesson);
  assert.throws(() => readPolicyFacts({ ...texts, lesson: swapped }), /순서가 모형과 다르다/);
});
