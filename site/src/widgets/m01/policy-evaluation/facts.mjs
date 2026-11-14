// 위젯이 보여 주는 평가 순서·오류 문구·원고 예를 빌드 때 원고에서 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 규칙을 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs
//
// 읽는 원고:
//  - LESSON(03-policy-evaluation.md): "같은 계정 안의 요청 평가 순서" 흐름도의 판정 노드(순서 확인), 각주(허용 *),
//    리소스 정책이 허용할 때의 두 갈래 간선과 각주의 구분(사용자·세션 ARN → 허용 *, 역할 ARN → 경계·세션 정책), Part A의 실제 출력(암묵적 거부·허용·명시적 거부·권한 경계), 워크시트 Q9 채점 줄
//  - ROLES(04-roles-and-sts.md): 세션 정책 거부 출력
//  - CHEATSHEET(cheatsheet.md): 같은 계정·교차 계정 평가식, "오류 문구로 원인 찾기" 표

export const LESSON = 'curriculum/m01-iam-identity/03-policy-evaluation.md';
export const ROLES = 'curriculum/m01-iam-identity/04-roles-and-sts.md';
export const CHEATSHEET = 'curriculum/m01-iam-identity/cheatsheet.md';

function finder(file, text) {
  const lines = text.split('\n');
  return (re, what, after = 0) => {
    for (let i = after; i < lines.length; i++) {
      const m = re.exec(lines[i]);
      if (m) return { m, line: i + 1 };
    }
    throw new Error(`${file}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
  };
}

/** 흐름도의 판정 노드 — 이 순서대로 원고에 있어야 한다(모형 model.mjs의 STEP_ORDER와 같은 순서). */
const FLOW_NODES = [
  ['deny', /\{어느 정책이든<br\/>명시적 Deny\?\}/, '흐름도 노드 "명시적 Deny?"'],
  ['org', /\{"조직 SCP가 허용\?.*RCP가 허용\?/, '흐름도 노드 "SCP·RCP가 허용?"'],
  ['resource', /\{리소스 기반 정책이<br\/>이 주체를 허용\?\}/, '흐름도 노드 "리소스 기반 정책이 허용?"'],
  ['identity', /\{자격 증명 기반 정책이<br\/>허용\?\}/, '흐름도 노드 "자격 증명 기반 정책이 허용?"'],
  ['boundary', /\{권한 경계가 있으면<br\/>경계도 허용\?\}/, '흐름도 노드 "권한 경계도 허용?"'],
  ['session', /\{역할 세션이면<br\/>세션 정책도 허용\?\}/, '흐름도 노드 "세션 정책도 허용?"'],
];

/**
 * @param {{ lesson: string, roles: string, cheatsheet: string }} texts 세 원고의 내용
 */
export function readPolicyFacts(texts) {
  const L = finder(LESSON, texts.lesson);
  const R = finder(ROLES, texts.roles);
  const C = finder(CHEATSHEET, texts.cheatsheet);

  // 흐름도: 노드가 모형과 같은 순서로 있는지(줄 번호가 늘어나야 한다)
  const flow = {};
  let prev = 0;
  for (const [id, re, what] of FLOW_NODES) {
    const f = L(re, what);
    if (f.line <= prev) throw new Error(`${LESSON}의 흐름도 순서가 모형과 다르다: ${what}(줄 ${f.line})`);
    flow[id] = f.line;
    prev = f.line;
  }
  const footnote = L(/^\\\* 같은 계정에서 리소스 기반 정책이/, '흐름도 각주(허용 *)').line;
  // 리소스 기반 정책이 허용할 때의 두 갈래(누구를 지정했나) — 모형 model.mjs의 resourceTo 판정과 같아야 한다
  const edges = {
    direct: L(/E -- "예: IAM 사용자 ARN·<br\/>역할 세션 ARN 지정" --> OK1\["허용 \*"\]/, '흐름도 간선 "사용자·세션 ARN 지정 → 허용 *"').line,
    role: L(/E -- "예: 역할 ARN 지정" --> G\s*$/, '흐름도 간선 "역할 ARN 지정 → 권한 경계 판정"').line,
  };
  L(/^\\\* 같은 계정에서 리소스 기반 정책이 허용할 때.*\*\*IAM 사용자 ARN\*\*.*\*\*역할 세션 ARN\*\*.*\*\*역할 ARN\*\*을 지정했으면.*권한 경계와 세션 정책의 암묵적 거부에는 제한된다/, '각주의 "누구를 지정했나" 구분');

  // 치트시트: 평가식과 오류 문구 표
  const sameFormula = C(/같은 계정 안\*\*: 최종 = SCP ∩ RCP ∩ \(자격 증명 정책 ∪ 리소스 정책\) ∩ 경계 ∩ 세션 정책 — 리소스 정책이 \*\*역할 ARN\*\*을 지정했거나/, '같은 계정 평가식(역할 ARN 지정의 식이라는 단서 포함)').line;
  const crossFormula = C(/교차 계정\*\*: 두 계정에서 따로 평가해 \*\*둘 다\*\* Allow여야 한다/, '교차 계정 평가식').line;
  const phraseRow = (code, what) => {
    const f = C(new RegExp('^\\|\\s*`(' + code.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')`\\s*\\|\\s*([^|]+?)\\s*\\|'), `오류 문구 표의 ${what}`);
    return { text: f.m[1], meaning: f.m[2], line: f.line };
  };
  const phrases = {
    identityDeny: phraseRow('with an explicit deny in an identity-based policy', '자격 증명 정책 Deny'),
    resourceDeny: phraseRow('with an explicit deny in a resource-based policy', '리소스 정책 Deny'),
    noIdentity: phraseRow('because no identity-based policy allows', 'Allow 없음'),
    noBoundary: phraseRow('because no permissions boundary allows', '권한 경계 밖'),
    noSession: phraseRow('because no session policy allows', '세션 정책 밖'),
  };

  // 원고의 실제 출력(예로 채우기). 각 예의 판정은 단위 시험이 모형과 맞춰 본다.
  const partA = L(/^### Part A — 거부를 재현한다/, 'Part A 제목').line;
  const ex = {
    intern: L(/user\/todayorder-intern is not authorized to perform: iam:ListUsers .* because no identity-based policy allows/, 'Part A 1) 암묵적 거부 출력', partA),
    allow: L(/^iam list-users → 사용자 \d+ 명 · ec2 describe-vpcs → VPC \d+ 개/, 'Part A 2) 허용 출력', partA),
    deny: L(/todayorder-intern is not authorized to perform: ec2:DescribeVpcs with an explicit deny in an identity-based policy/, 'Part A 3) 명시적 거부 출력', partA),
    boundary: L(/todayorder-intern is not authorized to perform: ec2:DescribeSubnets because no permissions boundary allows/, 'Part A 4) 권한 경계 출력', partA),
    q9: L(/^Q9\s+sqs:SendMessage\s+\S+\s+I\s+I\s/, '워크시트 Q9 채점 줄(정답 I)'),
    q9why: L(/^- Q9: 경계는 `sqs:\*`를 허용하지만/, '워크시트 Q9 해설'),
    session: R(/kim-narrow is not authorized to perform: iam:ListRoles .* because no session policy allows/, '세션 정책 거부 출력'),
  };
  const examples = Object.fromEntries(Object.entries(ex).map(([k, v]) => [k, v.line]));
  examples.footnote = footnote; // 리소스 정책이 역할 ARN·역할 세션 ARN을 지정한 예(각주의 구분)

  return { lesson: LESSON, roles: ROLES, cheatsheet: CHEATSHEET, flow, edges, footnote, sameFormula, crossFormula, phrases, examples };
}
