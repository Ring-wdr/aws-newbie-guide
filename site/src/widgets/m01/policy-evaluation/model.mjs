// IAM 정책 평가 순서 — 설명용 모형(실제 IAM·정책 시뮬레이터·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(원고):
//  - 같은 계정: 03-policy-evaluation.md "같은 계정 안의 요청 평가 순서" 흐름도와 각주.
//    명시적 Deny → SCP·RCP → 리소스 기반 정책 → 자격 증명 기반 정책 → 권한 경계 → 세션 정책.
//    리소스 기반 정책이 허용하면 Principal로 누구를 지정했는지에 따라 갈린다(AWS IAM User Guide
//    "Policy evaluation logic" — How AWS enforcement code logic evaluates requests, "Permissions boundaries for IAM entities" —
//    Evaluating effective permissions with boundaries, "Policies and permissions" — Session policies):
//      IAM 사용자 ARN → 자격 증명 정책·권한 경계의 암묵적 거부에 제한되지 않는다(허용 *)
//      역할 세션 ARN  → 자격 증명 정책·권한 경계·세션 정책의 암묵적 거부에 제한되지 않는다(허용 *)
//      역할 ARN       → 자격 증명 정책은 필요 없지만, 권한 경계·세션 정책의 암묵적 거부에 제한된다(경계·세션 판정으로 이어짐)
//    명시적 Deny는 어느 경우든 먼저 판정한다.
//  - 교차 계정: cheatsheet.md 30줄 "두 계정에서 따로 평가해 둘 다 Allow여야 한다 — 호출자 계정: 자격 증명 정책
//    (∩ 경계 ∩ 세션 정책) ∩ 호출자 쪽 SCP / 리소스 계정: 리소스 정책 ∩ 리소스 쪽 RCP".
//  - 세 가지 결과와 "명시적 Deny > Allow > 암묵적 Deny": 03-policy-evaluation.md 12~18줄.
//
// 모형의 가정(화면에도 적는다):
//  1. 각 정책이 "이 요청을 허용하는가/Deny가 맞는가"는 학습자가 고른다. 정책 문장·조건 키·와일드카드를 해석하지 않는다.
//  2. 요청자는 IAM 사용자 또는 역할 세션 둘 중 하나다. IAM 사용자 요청에는 세션 정책이 없다(세션 정책은 역할 세션·
//     STS 연동 사용자 세션에만 — "Policies and permissions" Session policies). STS 연동 사용자 세션은 다루지 않는다.
//     리소스 정책이 지정할 수 있는 주체는 요청자에 맞춘다: IAM 사용자 → 사용자 ARN, 역할 세션 → 역할 ARN 또는 역할 세션 ARN.
//  3. KMS 키 정책(같은 계정에서도 키 정책이 허용해야 함)과 역할 신뢰 정책의 예외(각주)는 다루지 않는다.
//  4. "SCP가 허용"은 조직에 속하지 않았거나 관리 계정이라 SCP가 적용되지 않는 경우도 포함한다(03:67, cheatsheet:24).

/** 판정 단계(흐름도의 판정 노드 순서. facts.mjs가 원고 흐름도에서 같은 순서를 확인한다). */
export const STEP_ORDER = ['deny', 'org', 'resource', 'identity', 'boundary', 'session'];

export const DEFAULT_INPUT = Object.freeze({
  account: 'same', // 'same' | 'cross'
  caller: 'user', // 'user'(IAM 사용자) | 'role'(역할 세션)
  resourceTo: 'user', // 리소스 정책의 Principal: 'user'(IAM 사용자 ARN) | 'role'(역할 ARN) | 'session'(역할 세션 ARN)
  deny: 'none', // 'none' | 'identity' | 'resource' | 'other'
  scp: true,
  rcp: true,
  resource: false,
  identity: false,
  boundary: 'none', // 'none' | 'allow' | 'deny'
  session: 'none', // 'none' | 'allow' | 'deny'
});

const ONE_OF = { account: ['same', 'cross'], caller: ['user', 'role'], resourceTo: ['user', 'role', 'session'], deny: ['none', 'identity', 'resource', 'other'], boundary: ['none', 'allow', 'deny'], session: ['none', 'allow', 'deny'] };

/** 화면 입력을 모형이 다루는 값으로 맞춘다. 모르는 값은 기본값. */
export function normalize(input) {
  const out = { ...DEFAULT_INPUT };
  for (const [k, vals] of Object.entries(ONE_OF)) if (vals.includes(input?.[k])) out[k] = input[k];
  for (const k of ['scp', 'rcp', 'resource', 'identity']) if (input && k in input) out[k] = Boolean(input[k]);
  // 성립하지 않는 조합을 막는다: IAM 사용자에게는 세션 정책이 없고, 리소스 정책은 요청자 자신(사용자 ARN) 또는 그 역할·세션을 지정한다.
  if (out.caller === 'user') {
    out.session = 'none';
    out.resourceTo = 'user';
  } else if (out.resourceTo === 'user') {
    out.resourceTo = 'role';
  }
  return out;
}

/**
 * @typedef {'yes' | 'no' | 'pass' | 'skip' | 'na'} Outcome
 *   yes/no: 질문에 대한 답, pass: 없어서 통과(경계·세션 정책 없음), skip: 앞에서 끝나 보지 않음,
 *   na: 묻지 않음(역할 ARN을 지정한 리소스 정책이 허용해 자격 증명 정책이 필요 없음 / IAM 사용자라 세션 정책이 없음)
 * @typedef {{ id: string, outcome: Outcome }} Step
 * @typedef {'allowed' | 'explicitDeny' | 'implicitDeny'} Decision
 * @typedef {'identityDeny' | 'resourceDeny' | 'otherDeny' | 'scp' | 'rcp' | 'noResource' | 'noIdentity' | 'noBoundary' | 'noSession' | 'allowed' | 'allowedByResource' | 'allowedByResourceRole'} Reason
 */

/**
 * 요청 하나를 평가한다.
 * @returns {{ decision: Decision, reason: Reason, stoppedAt: string | null, steps: Step[] }}
 */
export function evaluate(raw) {
  const x = normalize(raw);
  /** @type {Record<string, Outcome>} */
  const o = Object.fromEntries(STEP_ORDER.map((id) => [id, 'skip']));
  const done = (decision, reason, stoppedAt) => ({
    decision,
    reason,
    stoppedAt,
    steps: STEP_ORDER.map((id) => ({ id, outcome: o[id] })),
  });

  // 1. 어느 정책이든 명시적 Deny가 맞으면 끝(같은 계정·교차 계정 모두)
  if (x.deny !== 'none') {
    o.deny = 'yes';
    return done('explicitDeny', x.deny === 'identity' ? 'identityDeny' : x.deny === 'resource' ? 'resourceDeny' : 'otherDeny', 'deny');
  }
  o.deny = 'no';

  // 2. 조직의 상한선: SCP(주체 쪽)와 RCP(리소스 쪽)
  if (!x.scp || !x.rcp) {
    o.org = 'no';
    return done('implicitDeny', !x.scp ? 'scp' : 'rcp', 'org');
  }
  o.org = 'yes';

  let viaRole = false;
  if (x.account === 'same') {
    // 3. 같은 계정: 리소스 기반 정책이 이 주체를 허용하면, 누구를 지정했는지에 따라
    if (x.resource) {
      o.resource = 'yes';
      // IAM 사용자 ARN·역할 세션 ARN: 경계·세션 정책의 암묵적 거부에 제한되지 않는다 → 허용 *
      if (x.resourceTo !== 'role') return done('allowed', 'allowedByResource', 'resource');
      // 역할 ARN: 자격 증명 정책은 필요 없고, 권한 경계·세션 정책 판정으로 이어진다
      viaRole = true;
    } else {
      o.resource = 'no';
    }
  }

  // 4~6. 자격 증명 기반 정책(역할 ARN 경로면 묻지 않음) ∩ 권한 경계 ∩ 세션 정책
  if (viaRole) {
    o.identity = 'na';
  } else if (!x.identity) {
    o.identity = 'no';
    return done('implicitDeny', 'noIdentity', 'identity');
  } else {
    o.identity = 'yes';
  }
  if (x.boundary === 'deny') {
    o.boundary = 'no';
    return done('implicitDeny', 'noBoundary', 'boundary');
  }
  o.boundary = x.boundary === 'none' ? 'pass' : 'yes';
  if (x.caller === 'user') {
    o.session = 'na';
  } else if (x.session === 'deny') {
    o.session = 'no';
    return done('implicitDeny', 'noSession', 'session');
  } else {
    o.session = x.session === 'none' ? 'pass' : 'yes';
  }

  if (x.account === 'cross') {
    // 교차 계정: 리소스 계정의 리소스 정책도 허용해야 한다(양쪽 모두)
    if (!x.resource) {
      o.resource = 'no';
      return done('implicitDeny', 'noResource', 'resource');
    }
    o.resource = 'yes';
  }
  return done('allowed', viaRole ? 'allowedByResourceRole' : 'allowed', null);
}

/** 교차 계정에서는 리소스 정책을 마지막(리소스 계정 쪽)에 본다. 화면에 그리는 순서. */
export function displayOrder(account) {
  return account === 'cross' ? ['deny', 'org', 'identity', 'boundary', 'session', 'resource'] : STEP_ORDER;
}

/**
 * 원고의 예. 판정(expect)은 원고에 기록된 결과이며, 단위 시험이 모형의 판정과 맞춰 본다.
 * where: facts.examples의 키(원고 줄 번호), file: 'lesson' | 'roles'
 */
export const PRESETS = [
  { id: 'intern', label: '정책 없는 인턴', file: 'lesson', where: 'intern', expect: 'implicitDeny', phrase: 'noIdentity', v: { identity: false } },
  { id: 'allow', label: 'Allow를 붙인 인턴', file: 'lesson', where: 'allow', expect: 'allowed', v: { identity: true } },
  { id: 'deny', label: 'Allow + 명시적 Deny', file: 'lesson', where: 'deny', expect: 'explicitDeny', phrase: 'identityDeny', v: { identity: true, deny: 'identity' } },
  { id: 'boundary', label: '권한 경계 밖(DescribeSubnets)', file: 'lesson', where: 'boundary', expect: 'implicitDeny', phrase: 'noBoundary', v: { identity: true, boundary: 'deny' } },
  { id: 'q9', label: '워크시트 Q9(경계만 sqs 허용)', file: 'lesson', where: 'q9', expect: 'implicitDeny', v: { identity: false, boundary: 'allow' } },
  { id: 'session', label: '세션 정책 밖(ListRoles)', file: 'roles', where: 'session', expect: 'implicitDeny', phrase: 'noSession', v: { caller: 'role', identity: true, session: 'deny' } },
  { id: 'rbp-role', label: '리소스 정책이 역할 ARN 지정 + 경계 밖', file: 'lesson', where: 'footnote', expect: 'implicitDeny', v: { caller: 'role', resource: true, resourceTo: 'role', boundary: 'deny' } },
  { id: 'rbp-session', label: '리소스 정책이 역할 세션 ARN 지정 + 경계 밖', file: 'lesson', where: 'footnote', expect: 'allowed', v: { caller: 'role', resource: true, resourceTo: 'session', boundary: 'deny', session: 'deny' } },
];

export function presetInput(p) {
  return normalize({ ...DEFAULT_INPUT, ...p.v });
}

/** 판정 사유 → 치트시트 "오류 문구로 원인 찾기" 표의 키(없으면 null — 원고에 그 문구가 없다). */
export const REASON_PHRASE = {
  identityDeny: 'identityDeny',
  resourceDeny: 'resourceDeny',
  noIdentity: 'noIdentity',
  noBoundary: 'noBoundary',
  noSession: 'noSession',
  otherDeny: null,
  scp: null,
  rcp: null,
  noResource: null,
  allowed: null,
  allowedByResource: null,
  allowedByResourceRole: null,
};

export const DECISION_LABEL = { allowed: '허용 (allowed)', explicitDeny: '명시적 거부 (explicit deny)', implicitDeny: '암묵적 거부 (implicit deny)' };
export const DECISION_CODE = { allowed: 'A', explicitDeny: 'D', implicitDeny: 'I' };

/** 단계별 질문 문장. */
export function question(id, account) {
  switch (id) {
    case 'deny':
      return '어느 정책이든 명시적 Deny가 맞는가?';
    case 'org':
      return account === 'cross' ? '호출자 쪽 SCP와 리소스 쪽 RCP가 허용하는가?' : '조직 SCP(주체 쪽)와 RCP(리소스 쪽)가 허용하는가?';
    case 'resource':
      return account === 'cross' ? '리소스 계정의 리소스 기반 정책이 이 주체를 허용하는가?' : '리소스 기반 정책이 이 주체를 허용하는가?';
    case 'identity':
      return '자격 증명 기반 정책(사용자·그룹·역할)이 허용하는가?';
    case 'boundary':
      return '권한 경계가 있으면 경계도 허용하는가?';
    case 'session':
      return '역할 세션이면 세션 정책도 허용하는가?';
    default:
      return id;
  }
}

const OUTCOME_TEXT = { yes: '예', no: '아니오', pass: '없음 → 통과', skip: '보지 않음(앞에서 끝남)', na: '—' };
export const RESOURCE_TO_LABEL = { user: 'IAM 사용자 ARN', role: '역할 ARN', session: '역할 세션 ARN' };

/** 단계 하나의 결과를 한 문장으로(목록과 표에 같은 문장을 쓴다). input은 normalize 전후 아무것이나. */
export function describeStep(step, account, input) {
  const x = normalize({ ...input, account });
  if (step.outcome === 'yes' && step.id === 'deny') return '예 → 명시적 거부로 끝';
  if (step.outcome === 'no' && step.id !== 'deny') return '아니오 → 암묵적 거부로 끝';
  if (step.outcome === 'yes' && step.id === 'resource' && account === 'same') {
    return x.resourceTo === 'role' ? '예(역할 ARN 지정) → 권한 경계·세션 정책 판정으로' : `예(${RESOURCE_TO_LABEL[x.resourceTo]} 지정) → 허용 *로 끝(각주)`;
  }
  if (step.outcome === 'na' && step.id === 'identity') return '묻지 않음(역할 ARN을 지정한 리소스 정책이 허용)';
  if (step.outcome === 'na' && step.id === 'session') return '해당 없음(IAM 사용자 요청에는 세션 정책이 없다)';
  return OUTCOME_TEXT[step.outcome];
}

/** 결과 요약 한 문장. */
export function summarize(r, input) {
  const x = normalize(input);
  switch (r.reason) {
    case 'identityDeny':
      return '자격 증명 기반 정책의 Deny가 맞았다. Deny는 어떤 Allow로도 뒤집을 수 없다.';
    case 'resourceDeny':
      return '리소스 기반 정책(버킷 정책 등)의 Deny가 맞았다. Deny는 어떤 Allow로도 뒤집을 수 없다.';
    case 'otherDeny':
      return 'SCP·권한 경계·세션 정책 등 그 밖의 정책에 있는 Deny가 맞았다. 어디든 Deny 하나면 끝이다.';
    case 'scp':
      return 'SCP가 이 작업을 허용하지 않는다. SCP는 권한을 주지 않는 상한선이라, 다른 정책이 허용해도 거부된다.';
    case 'rcp':
      return 'RCP가 이 작업을 허용하지 않는다. RCP는 조직 리소스의 상한선이라, 다른 정책이 허용해도 거부된다.';
    case 'noIdentity':
      return x.boundary === 'allow' || x.session === 'allow'
        ? '자격 증명 기반 정책에 Allow가 없다. 권한 경계·세션 정책이 허용해도 그것은 상한선일 뿐 권한을 주지 않는다.'
        : '아무 정책도 허용하지 않았다. 기본값인 암묵적 거부다.';
    case 'noBoundary':
      return x.account === 'same' && x.resource && x.resourceTo === 'role'
        ? '리소스 정책이 역할 ARN을 지정해 허용했지만, 역할 ARN에 준 허용은 권한 경계의 암묵적 거부에 제한된다 — 경계 밖이라 거부.'
        : '자격 증명 기반 정책은 허용하지만 권한 경계 밖이다. 경계는 Deny가 아니라 "허용 범위 밖"이라 암묵적 거부다.';
    case 'noSession':
      return x.account === 'same' && x.resource && x.resourceTo === 'role'
        ? '리소스 정책이 역할 ARN을 지정해 허용했지만, 역할 ARN에 준 허용은 세션 정책의 암묵적 거부에 제한된다 — 세션 정책 밖이라 거부.'
        : '역할의 권한은 허용하지만 세션 정책 밖이다. 역할 권한 ∩ 세션 정책만 남는다.';
    case 'noResource':
      return '교차 계정이라 양쪽 모두 허용해야 하는데, 리소스 계정의 리소스 기반 정책이 이 주체를 허용하지 않는다.';
    case 'allowedByResource':
      return x.resourceTo === 'session'
        ? '같은 계정의 리소스 기반 정책이 역할 세션 ARN을 지정해 허용했다. 세션에 직접 준 허용이라 자격 증명 정책·권한 경계·세션 정책의 암묵적 거부에 제한되지 않는다(흐름도의 "허용 *").'
        : '같은 계정의 리소스 기반 정책이 IAM 사용자 ARN을 지정해 허용했다. 자격 증명 정책·권한 경계의 암묵적 거부에 제한되지 않는다(흐름도의 "허용 *").';
    case 'allowedByResourceRole':
      return '같은 계정의 리소스 기반 정책이 역할 ARN을 지정해 허용했다. 자격 증명 정책은 없어도 되고, 권한 경계·세션 정책도 허용(또는 없음)이라 허용이다.';
    case 'allowed':
      return x.account === 'cross'
        ? '호출자 계정(자격 증명 정책 ∩ 경계 ∩ 세션 정책 ∩ SCP)과 리소스 계정(리소스 정책 ∩ RCP)이 모두 허용했다.'
        : '필요한 모든 정책 종류가 허용했고 Deny가 없다.';
    default:
      return '';
  }
}
