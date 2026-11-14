// 위젯의 단계·종료 코드·오류 코드를 빌드 때 원고에서 읽는다(GUIDE-SITE 원칙 4).
// 원고가 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 사실을 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs
//
// 읽는 것:
//  - LESSON(04-first-request-anatomy.md): "요청이 만들어지는 과정" 순서도의 단계(자격 증명 체인·엔드포인트·서명·전송·서버 재계산),
//    SigV4의 15분·SignatureDoesNotMatch 문장, --debug 출력(자격 증명 출처·엔드포인트), 서명 없는 요청의 InvalidClientTokenId,
//    "CLI 종료 코드" 표, "환경 변수가 파일보다 우선"
//  - SETUP(03-environment-setup.md): 시계가 어긋났을 때 서비스별 오류 코드(SignatureDoesNotMatch / RequestTimeTooSkewed)

export const LESSON = 'curriculum/m00-orientation/04-first-request-anatomy.md';
export const SETUP = 'curriculum/m00-orientation/03-environment-setup.md';

export function readRequestFacts(lesson, setup) {
  const mk = (file, text) => {
    const lines = text.split('\n');
    return (re, what, after = 0) => {
      for (let i = after; i < lines.length; i++) {
        const m = re.exec(lines[i]);
        if (m) return { m, line: i + 1 };
      }
      throw new Error(`${file}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
    };
  };
  const L = mk(LESSON, lesson);
  const S = mk(SETUP, setup);

  // 순서도의 단계(이 순서대로 있어야 한다 — model.mjs의 STAGES와 같은 순서)
  const seq = [
    ['creds', /U->>C: 키를 어디서 찾지\?/, '순서도 "키를 어디서 찾지?"'],
    ['endpoint', /U->>E: 어디로 보내지\?/, '순서도 "어디로 보내지?"'],
    ['sign', /U->>U: SigV4 서명/, '순서도 "SigV4 서명"'],
    ['send', /U->>S: POST \/ \+ Authorization 헤더/, '순서도 "POST + Authorization 헤더"'],
    ['verify', /S->>S: 같은 방식으로 서명을 다시 계산해 비교/, '순서도 "서명을 다시 계산해 비교"'],
    ['response', /S-->>U: 200 XML/, '순서도 "200 XML"'],
  ];
  const flow = {};
  let prev = 0;
  for (const [id, re, what] of seq) {
    const f = L(re, what);
    if (f.line <= prev) throw new Error(`${LESSON}의 순서도 순서가 모형과 다르다: ${what}`);
    flow[id] = f.line;
    prev = f.line;
  }
  const chain = L(/Note right of C: (환경 변수 → 공유 자격 증명 파일 → 설정 파일)<br\/>→ \((컨테이너\/EC2 메타데이터)\)/, '자격 증명 체인 순서');
  const endpointNote = L(/Note right of E: AWS_ENDPOINT_URL 이 있으면 그것<br\/>없으면 (https:\/\/sts\.us-east-1\.amazonaws\.com)/, '엔드포인트 결정 규칙');
  const skew = L(/본문이나 헤더를 중간에 바꾸면 `(SignatureDoesNotMatch)`가 되고, 서명 시각이 서버 시계와 \*\*(\d+)분 넘게\*\* 차이 나면 거부된다/, '서명 불일치·시계 차이 문장');
  const found = L(/Found credentials in (shared credentials file)/, '--debug의 자격 증명 출처');
  const endpointResult = L(/Endpoint provider result: (https:\/\/127\.0\.0\.1:\d+)/, '--debug의 엔드포인트');
  const unsigned = L(/<Code>(InvalidClientTokenId)<\/Code>/, '서명 없는 요청의 오류 코드');
  const unsignedStatus = L(/HTTP 상태 코드는 `(\d{3})`이었다/, '서명 없는 요청의 HTTP 상태 코드');
  const envFirst = L(/자격 증명 탐색 순서에서 \*\*환경 변수가 파일보다 우선\*\*한다/, '"환경 변수가 파일보다 우선"');

  // 종료 코드 표
  const head = L(/^### CLI 종료 코드/, 'CLI 종료 코드 표 제목');
  const exitCodes = {};
  for (const code of [0, 252, 253, 254, 255]) {
    const f = L(new RegExp(`^\\| ${code} \\| (.+?) \\|$`), `종료 코드 ${code} 행`, head.line);
    exitCodes[code] = { meaning: f.m[1].replace(/\*\*/g, ''), line: f.line };
  }

  const clock = S(/모든 요청이 `(SignatureDoesNotMatch)`\(STS·boto3\) 또는 `(RequestTimeTooSkewed)`\(S3·DynamoDB 등\)/, '시계 어긋남의 오류 코드');

  return {
    lesson: LESSON,
    setup: SETUP,
    flow,
    chain: { order: chain.m[1], meta: chain.m[2], line: chain.line },
    endpoint: { aws: endpointNote.m[1], line: endpointNote.line, emulator: endpointResult.m[1], emulatorLine: endpointResult.line },
    signature: { code: skew.m[1], skewMinutes: Number(skew.m[2]), line: skew.line },
    foundCreds: { text: found.m[1], line: found.line },
    unsigned: { code: unsigned.m[1], line: unsigned.line, status: Number(unsignedStatus.m[1]), statusLine: unsignedStatus.line },
    envFirstLine: envFirst.line,
    exitCodes,
    clock: { sts: clock.m[1], other: clock.m[2], line: clock.line },
  };
}
