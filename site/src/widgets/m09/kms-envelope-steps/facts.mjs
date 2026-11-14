// 위젯의 수치와 오류 이름을 원고 curriculum/m09-security-encryption/01-kms.md 에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다. 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

export const LESSON = 'curriculum/m09-security-encryption/01-kms.md';

const num = (s) => Number(String(s).replace(/,/g, ''));

function findLine(lines, re, after, what) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/** @param {string} text 01-kms.md 내용 */
export function readEnvelopeFacts(text) {
  const L = text.split('\n');
  const f = (re, what, after = 0) => findLine(L, re, after, what);

  // 핵심 개념: KMS `Encrypt`는 **4 KiB(4,096바이트)** 까지만 받는다.
  const limit = f(/KMS `Encrypt`는 \*\*4 KiB\(([\d,]+)바이트\)\*\*\s*까지만 받는다/, 'Encrypt 한도 문장');
  // 핵심 개념: KMS에 오가는 것은 32바이트 데이터 키뿐이다.
  const dk = f(/KMS에 오가는 것은 (\d+)바이트 데이터 키뿐이다/, '데이터 키 크기 문장');
  // lab03 설명: 저장 형식은 `nonce(12바이트) || 암호문 || 태그(16바이트)`
  const fmt = f(/저장 형식은 `nonce\((\d+)바이트\) \|\| 암호문 \|\| 태그\((\d+)바이트\)`/, '저장 형식 문장');
  // lab01 5단계: Encrypt 한도 초과 오류
  const encErr = f(/\((ValidationException)\) when calling the Encrypt operation:.*less than or equal to (\d+)/, 'lab01 5단계 Encrypt 한도 오류');
  // lab01 2단계: 평문 24바이트 → 암호문 90바이트
  const lab01 = f(/^평문 (\d+)바이트 → 암호문 (\d+)바이트/, 'lab01 2단계 크기');
  // lab01 7단계: 삭제 대기 중인 키로 Decrypt
  const pending = f(/\((KMSInvalidStateException)\) when calling the Decrypt operation: .* is pending deletion/, 'lab01 7단계 삭제 대기 오류');
  // lab03 0단계·1·2단계
  const lab03In = f(/^orders\.jsonl: (\d+)바이트/, 'lab03 0단계 평문 크기');
  const lab03Out = f(/^암호문 (\d+)바이트\(= nonce (\d+) \+ 평문 \+ GCM 태그 (\d+)\) · 암호화된 데이터 키 (\d+)바이트/, 'lab03 1·2단계 암호문 크기', lab03In.line);
  // lab03 5단계: 변조 → InvalidTag
  const tag = f(/^(InvalidTag): /, 'lab03 5단계 InvalidTag', lab03Out.line);
  // lab03 6단계: 키 비활성화 → DisabledException
  const disabled = f(/\((DisabledException)\) when calling the Decrypt operation: .* is disabled/, 'lab03 6단계 DisabledException', tag.line);
  // SDK 출력: 영수증 평문 9,232바이트 / 다른 암호화 컨텍스트 → InvalidCiphertextException
  const sdkIn = f(/^영수증 평문 ([\d,]+)바이트/, 'SDK 평문 크기');
  const ctx = f(/^다른 암호화 컨텍스트 → (InvalidCiphertextException)/, 'SDK 다른 컨텍스트 오류', sdkIn.line);

  return {
    lesson: LESSON,
    encryptLimit: { value: num(limit.m[1]), line: limit.line },
    dataKeyBytes: { value: Number(dk.m[1]), line: dk.line },
    gcm: { nonce: Number(fmt.m[1]), tag: Number(fmt.m[2]), line: fmt.line },
    encryptError: { name: encErr.m[1], max: Number(encErr.m[2]), line: encErr.line },
    lab01: { plain: Number(lab01.m[1]), cipher: Number(lab01.m[2]), line: lab01.line },
    lab03: {
      plain: Number(lab03In.m[1]),
      plainLine: lab03In.line,
      cipher: Number(lab03Out.m[1]),
      nonce: Number(lab03Out.m[2]),
      tag: Number(lab03Out.m[3]),
      encryptedKey: Number(lab03Out.m[4]),
      line: lab03Out.line,
    },
    sdk: { plain: num(sdkIn.m[1]), line: sdkIn.line },
    errors: {
      disabled: { name: disabled.m[1], line: disabled.line },
      pending: { name: pending.m[1], line: pending.line },
      context: { name: ctx.m[1], line: ctx.line },
      tag: { name: tag.m[1], line: tag.line },
    },
  };
}
