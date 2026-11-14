// CLI 요청 한 번의 여정 — 어느 단계에서 멈추면 어떤 종료 코드가 나오나. 설명용 모형(실제 CLI·에뮬레이터·AWS를 실행하지 않는다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(원고 04-first-request-anatomy.md):
//  - 단계 순서: "요청이 만들어지는 과정" 순서도(자격 증명 체인 → 엔드포인트 결정 → SigV4 서명 → POST → 서버가 서명을 다시 계산 → 200 XML).
//    순서도 앞의 "명령 해석"과 뒤의 "서비스 처리"는 종료 코드 표의 252(명령 문법 오류)·254(서비스가 오류를 돌려줌)를 놓을 자리로 모형이 더했다.
//  - 종료 코드: "CLI 종료 코드" 표(0·252·253·254·255).
//  - 환경 변수가 파일보다 우선("시험 포인트").
//  - 서명 뒤 본문·헤더가 바뀌면 SignatureDoesNotMatch, 시계가 15분 넘게 차이 나면 거부("SigV4 서명").
//    시계 차이의 오류 코드는 03-environment-setup.md 문제 해결 표(STS는 SignatureDoesNotMatch, S3·DynamoDB 등은 RequestTimeTooSkewed).
//
// 모형의 가정(화면에도 적는다):
//  1. 잘못된 것은 한 번에 하나만 고른다.
//  2. 서명 불일치·시계 차이도 "요청은 나갔고 서비스가 오류를 돌려준" 경우라 254로 분류한다(종료 코드 표의 일반 규칙을 적용한 것 — 원고에 이 두 경우의 종료 코드를 실행해 기록한 출력은 없다).
//  3. 엔드포인트는 이 저장소의 실습처럼 AWS_ENDPOINT_URL이 설정된 경우(에뮬레이터)만 따라간다.

export const STAGES = ['parse', 'creds', 'endpoint', 'sign', 'send', 'verify', 'service', 'response'];
export const CRED_SOURCES = ['file', 'env', 'both', 'none'];
export const FAULTS = ['none', 'syntax', 'connect', 'tamper', 'skew', 'denied'];

export function normalize(raw) {
  return {
    creds: CRED_SOURCES.includes(raw?.creds) ? raw.creds : 'file',
    fault: FAULTS.includes(raw?.fault) ? raw.fault : 'none',
  };
}

/** 고른 자격 증명 위치에서 CLI가 실제로 쓰는 것(환경 변수가 파일보다 우선). null이면 못 찾음. */
export function credentialUsed(creds) {
  if (creds === 'none') return null;
  return creds === 'file' ? 'file' : 'env';
}

/**
 * @returns {{ stoppedAt: string, exit: 0 | 252 | 253 | 254 | 255, error: string | null, used: 'env' | 'file' | null, stages: Array<{ id: string, state: 'ok' | 'fail' | 'skip' }> }}
 */
export function journey(raw, f) {
  const x = normalize(raw);
  const used = credentialUsed(x.creds);
  let stoppedAt = 'response';
  let exit = 0;
  let error = null;
  if (x.fault === 'syntax') [stoppedAt, exit] = ['parse', 252];
  else if (!used) [stoppedAt, exit] = ['creds', 253];
  else if (x.fault === 'connect') [stoppedAt, exit] = ['send', 255];
  else if (x.fault === 'tamper') [stoppedAt, exit, error] = ['verify', 254, f.signature.code];
  else if (x.fault === 'skew') [stoppedAt, exit, error] = ['verify', 254, `${f.clock.sts}(STS) 또는 ${f.clock.other}(S3·DynamoDB 등)`];
  else if (x.fault === 'denied') [stoppedAt, exit, error] = ['service', 254, 'AccessDenied·ValidationException …'];
  const at = STAGES.indexOf(stoppedAt);
  const stages = STAGES.map((id, i) => ({ id, state: i < at ? 'ok' : i === at ? (exit === 0 ? 'ok' : 'fail') : 'skip' }));
  return { stoppedAt, exit, error, used, stages };
}

export const STAGE_LABEL = {
  parse: '명령 해석(옵션·인자)',
  creds: '자격 증명 찾기',
  endpoint: '엔드포인트 결정',
  sign: 'SigV4 서명',
  send: 'HTTPS 전송(POST + Authorization)',
  verify: '서버가 서명을 다시 계산해 비교',
  service: '서비스가 요청 처리',
  response: '응답 받음',
};

export const FAULT_LABEL = {
  none: '잘못된 것 없음',
  syntax: '알 수 없는 옵션을 넣었다(명령 문법 오류)',
  connect: '엔드포인트에 연결할 수 없다(에뮬레이터가 꺼짐 등)',
  tamper: '서명한 뒤 본문·헤더가 바뀌었다',
  skew: '내 시계와 서버 시계가 15분 넘게 차이 난다',
  denied: '서비스가 요청을 거부한다(권한 없음·값 오류 — 다른 명령의 경우)',
};

export const CRED_LABEL = {
  file: '공유 자격 증명 파일에만 키가 있다',
  env: '환경 변수에만 키가 있다',
  both: '환경 변수와 파일 둘 다에 (서로 다른) 키가 있다',
  none: '어디에도 키가 없다',
};

/** 단계 하나의 설명(목록과 표에 같은 문장). */
export function describeStage(id, state, r, f) {
  if (state === 'skip') return '가지 않음(앞에서 끝남)';
  switch (id) {
    case 'parse':
      return state === 'fail' ? 'CLI가 명령을 해석하지 못해 요청을 만들지 않는다' : '서비스 sts, 작업 GetCallerIdentity';
    case 'creds':
      if (state === 'fail') return `${f.chain.order} → ${f.chain.meta}를 차례로 찾았지만 키가 없다`;
      return r.used === 'env' ? '환경 변수의 키를 쓴다(환경 변수가 파일보다 우선)' : `공유 자격 증명 파일의 키를 쓴다(--debug: "Found credentials in ${f.foundCreds.text}")`;
    case 'endpoint':
      return `AWS_ENDPOINT_URL → ${f.endpoint.emulator}(없으면 ${f.endpoint.aws})`;
    case 'sign':
      return '비밀 키로 HMAC-SHA256 서명. 비밀 키 자체는 보내지 않는다';
    case 'send':
      return state === 'fail' ? '연결하지 못했다 — 서버에 닿지 않았다' : 'Authorization 헤더에 키 ID·범위·서명값을 담아 보낸다';
    case 'verify':
      if (state === 'fail') return `서명이 맞지 않아 거부: ${r.error}`;
      return '같은 계산 결과가 같아 통과';
    case 'service':
      return state === 'fail' ? `서비스가 오류를 돌려준다: ${r.error}` : 'GetCallerIdentity는 권한이 없어도 성공한다';
    case 'response':
      return '200 XML(UserId, Account, Arn) → CLI가 JSON으로 보여 준다';
    default:
      return '';
  }
}
