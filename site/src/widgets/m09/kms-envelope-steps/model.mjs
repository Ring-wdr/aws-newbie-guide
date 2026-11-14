// KMS 봉투 암호화 단계 — 설명용 모형(실제 KMS·에뮬레이터 실행이 아니다. 암호화도 하지 않는다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 단계와 규칙(원고 01-kms.md — 줄 번호는 facts.mjs가 빌드 때 찾는다):
//  쓰기: GenerateDataKey → 평문 데이터 키 + 암호화된 데이터 키 → 평문 키로 로컬 AES-256-GCM 암호화 → 평문 키는 버림
//        → S3에 암호문 + 암호화된 데이터 키 + 컨텍스트 저장(시퀀스 그림, lab03 1~3단계)
//  읽기: S3에서 읽기 → KMS Decrypt(암호화된 데이터 키, 컨텍스트) → 평문 데이터 키 → 로컬 복호화(태그 검증)(lab03 4단계)
//  KMS에 오가는 것은 32바이트 데이터 키뿐, 암호문 = nonce 12 + 평문 + 태그 16 바이트(lab03 출력).
//  키 비활성화 → DisabledException(lab03 6단계), 삭제 대기 → KMSInvalidStateException(lab01 7단계),
//  다른 컨텍스트 → InvalidCiphertextException(SDK 출력), 암호문 변조 → InvalidTag(lab03 5단계).
//  Encrypt는 4,096바이트까지 — 넘으면 ValidationException(lab01 5단계).
//
// 모형의 가정(화면에도 적는다):
//  A1 쓸 때는 키가 활성(Enabled)이고, 고른 키 상태는 "나중에 읽을 때"의 상태다.
//  A2 읽기 단계에서 키 상태와 컨텍스트가 둘 다 문제면 모형은 키 상태 오류를 먼저 보인다(둘 다일 때의 실제 순서는 원고에 없다).
//  A3 암호화된 데이터 키의 크기는 lab03에서 관찰한 값(에뮬레이터)을 쓴다. 실제 KMS에서는 다를 수 있다.
//  A4 권한(키 정책·IAM 정책)은 모두 허용된 상태로 둔다(레슨의 키 정책 절과 lab02에서 따로 다룬다).

export const MODEL_MAX_SIZE = 100_000_000; // 화면에서 받는 평문 크기 상한(바이트, 모형 화면의 범위)

/**
 * @typedef {{ size: number, keyState: 'Enabled' | 'Disabled' | 'PendingDeletion', sameContext: boolean, tampered: boolean }} Input
 * @typedef {{ kind: string, label: string, bytes: number | null, secret?: boolean }} Item
 * @typedef {{ n: number, phase: 'write' | 'read', actor: string, title: string, text: string, wire: string | null, app: Item[], kms: Item[], s3: Item[], ok: boolean, error: string | null }} Step
 */

export function normalize(raw) {
  const s = Number(raw.size);
  return {
    size: Number.isFinite(s) ? Math.min(MODEL_MAX_SIZE, Math.max(1, Math.round(s))) : 1,
    keyState: ['Enabled', 'Disabled', 'PendingDeletion'].includes(raw.keyState) ? raw.keyState : 'Enabled',
    sameContext: raw.sameContext !== false,
    tampered: Boolean(raw.tampered),
  };
}

const b = (n) => `${n.toLocaleString('en-US')}바이트`;

/**
 * 단계 목록을 만든다. 실패하면 그 단계에서 끝난다.
 * @param {Input} input normalize 된 값
 * @param {ReturnType<import('./facts.mjs').readEnvelopeFacts>} facts
 * @returns {{ steps: Step[], result: 'ok' | 'fail', error: string | null, cipherBytes: number, directEncrypt: boolean }}
 */
export function buildSteps(input, facts) {
  const N = input.size;
  const DK = facts.dataKeyBytes.value;
  const EDK = facts.lab03.encryptedKey;
  const cipherBytes = facts.gcm.nonce + N + facts.gcm.tag;
  const it = {
    plain: { kind: 'plain', label: '평문 데이터', bytes: N, secret: true },
    pdk: { kind: 'pdk', label: '평문 데이터 키', bytes: DK, secret: true },
    edk: { kind: 'edk', label: '암호화된 데이터 키', bytes: EDK },
    ct: { kind: 'ct', label: '암호문(nonce + 암호문 + 태그)', bytes: cipherBytes },
    ctx: { kind: 'ctx', label: '암호화 컨텍스트(예: orderId=A-1001)', bytes: null },
    ctxBad: { kind: 'ctx-bad', label: '다른 암호화 컨텍스트', bytes: null },
    ctBad: { kind: 'ct-bad', label: '1바이트 변조된 암호문', bytes: cipherBytes },
    cmk: { kind: 'cmk', label: 'KMS 키(키 재료는 KMS 밖으로 나오지 않음)', bytes: null },
  };
  const cmkState = (state) => ({ ...it.cmk, label: `KMS 키 — ${state}` });
  const steps = [];
  const push = (s) => steps.push({ n: steps.length + 1, wire: null, ok: true, error: null, ...s });

  push({ phase: 'write', actor: '주문 서비스', title: '시작', text: `암호화할 평문 ${b(N)}가 주문 서비스 메모리에 있다. KMS 키는 KMS 안에만 있다.`, app: [it.plain], kms: [cmkState('Enabled')], s3: [] });
  push({
    phase: 'write',
    actor: '주문 서비스 → KMS',
    title: 'GenerateDataKey(KeyId, 컨텍스트)',
    text: `KMS가 데이터 키를 만들어 평문 데이터 키(${b(DK)})와 그것을 KMS 키로 감싼 암호화된 데이터 키를 함께 돌려준다. 평문 데이터는 KMS로 보내지 않는다.`,
    wire: `KMS와 오간 것: 데이터 키뿐 — 돌아온 평문 데이터 키(${b(DK)})와 그것을 감싼 암호화된 데이터 키`,
    app: [it.plain, it.pdk, it.edk, it.ctx],
    kms: [cmkState('Enabled')],
    s3: [],
  });
  push({
    phase: 'write',
    actor: '주문 서비스(로컬)',
    title: '평문 데이터 키로 로컬 AES-256-GCM 암호화',
    text: `새 nonce(${facts.gcm.nonce}바이트)로 암호화하고 컨텍스트를 AAD로 묶는다. 암호문 = nonce ${facts.gcm.nonce} + 평문 ${b(N)} + 태그 ${facts.gcm.tag} = ${b(cipherBytes)}.`,
    app: [it.plain, it.pdk, it.edk, it.ctx, it.ct],
    kms: [cmkState('Enabled')],
    s3: [],
  });
  push({ phase: 'write', actor: '주문 서비스(로컬)', title: '평문 데이터 키를 버린다', text: '평문 데이터 키는 파일·로그·S3 어디에도 남기지 않는다. 남는 것은 암호화된 데이터 키뿐이다.', app: [it.plain, it.edk, it.ctx, it.ct], kms: [cmkState('Enabled')], s3: [] });
  push({
    phase: 'write',
    actor: '주문 서비스 → S3',
    title: '암호문 + 암호화된 데이터 키 + 컨텍스트 저장',
    text: '버킷이 통째로 유출돼도 KMS 권한 없이는 데이터 키를 풀 수 없어 못 연다.',
    app: [],
    kms: [cmkState('Enabled')],
    s3: [it.ct, it.edk, it.ctx],
  });

  const stateLabel = { Enabled: 'Enabled', Disabled: 'Disabled(비활성화됨)', PendingDeletion: 'PendingDeletion(삭제 대기)' };
  const kmsNow = [cmkState(stateLabel[input.keyState])];
  const ct = input.tampered ? it.ctBad : it.ct;
  const ctx = input.sameContext ? it.ctx : it.ctxBad;
  const stored = [input.tampered ? it.ctBad : it.ct, it.edk, it.ctx];
  push({
    phase: 'read',
    actor: 'S3 → 주문 서비스',
    title: '읽기: 암호문과 암호화된 데이터 키를 가져온다',
    text: `나중에 읽는 쪽이 S3에서 가져온다.${input.tampered ? ' (누군가 S3의 암호문을 1바이트 바꿔 두었다.)' : ''}${input.sameContext ? '' : ' 복호화 요청에는 저장할 때와 다른 컨텍스트를 넣는다.'}`,
    app: [ct, it.edk, ctx],
    kms: kmsNow,
    s3: stored,
  });

  let error = null;
  if (input.keyState === 'Disabled') error = facts.errors.disabled.name;
  else if (input.keyState === 'PendingDeletion') error = facts.errors.pending.name;
  else if (!input.sameContext) error = facts.errors.context.name;
  if (error) {
    const why =
      error === facts.errors.disabled.name
        ? 'KMS 키가 비활성화돼 있어 암호화된 데이터 키를 풀 수 없다. 키 하나를 끄면 그 키로 감싼 모든 파일이 잠긴다(다시 켜면 풀린다).'
        : error === facts.errors.pending.name
          ? 'KMS 키가 삭제 대기 중이라 쓸 수 없다. 대기 기간 안에 취소하면 Disabled로 돌아오고, 다시 켜야 쓸 수 있다.'
          : '컨텍스트가 하나라도 다르면 KMS가 데이터 키부터 풀어 주지 않는다.';
    push({ phase: 'read', actor: '주문 서비스 → KMS', title: 'Decrypt(암호화된 데이터 키, 컨텍스트)', text: `${error}: ${why}`, wire: 'KMS와 오간 것: 암호화된 데이터 키 → 오류', app: [ct, it.edk, ctx], kms: kmsNow, s3: stored, ok: false, error });
    return { steps, result: 'fail', error, cipherBytes, directEncrypt: N <= facts.encryptLimit.value };
  }
  push({
    phase: 'read',
    actor: '주문 서비스 → KMS',
    title: 'Decrypt(암호화된 데이터 키, 컨텍스트)',
    text: `KMS가 KMS 키로 데이터 키를 풀어 평문 데이터 키(${b(DK)})를 돌려준다.`,
    wire: `KMS와 오간 것: 데이터 키뿐 — 보낸 암호화된 데이터 키와 돌아온 평문 데이터 키(${b(DK)})`,
    app: [ct, it.edk, ctx, it.pdk],
    kms: kmsNow,
    s3: stored,
  });
  if (input.tampered) {
    error = facts.errors.tag.name;
    push({ phase: 'read', actor: '주문 서비스(로컬)', title: '로컬 AES-GCM 복호화(태그 검증)', text: `${error}: GCM 태그 검증이 실패해 변조를 알아챈다. 깨진 데이터를 조용히 돌려주지 않는다.`, app: [ct, it.edk, ctx, it.pdk], kms: kmsNow, s3: stored, ok: false, error });
    return { steps, result: 'fail', error, cipherBytes, directEncrypt: N <= facts.encryptLimit.value };
  }
  push({ phase: 'read', actor: '주문 서비스(로컬)', title: '로컬 AES-GCM 복호화(태그 검증)', text: `태그 검증을 통과하고 평문 ${b(N)}가 원본과 같게 돌아온다.`, app: [ct, it.edk, ctx, it.pdk, it.plain], kms: kmsNow, s3: stored });
  push({ phase: 'read', actor: '주문 서비스(로컬)', title: '평문 데이터 키를 다시 버린다', text: '쓰기 때와 마찬가지로 평문 데이터 키는 메모리에서만 잠깐 쓰고 남기지 않는다.', app: [ct, it.edk, ctx, it.plain], kms: kmsNow, s3: stored });
  return { steps, result: 'ok', error: null, cipherBytes, directEncrypt: N <= facts.encryptLimit.value };
}

/** "KMS Encrypt로 바로 암호화할 수 있나" 한 문장. */
export function directNote(input, facts) {
  const lim = facts.encryptLimit.value;
  return input.size <= lim
    ? `${b(input.size)}는 Encrypt 한도(${b(lim)}) 이하라 KMS Encrypt로 바로 암호화할 수도 있다. 봉투 암호화를 쓰면 데이터를 KMS로 보내지 않는다.`
    : `${b(input.size)}는 Encrypt 한도(${b(lim)})를 넘어 KMS Encrypt에 바로 넣으면 ${facts.encryptError.name}로 거부된다 → 봉투 암호화.`;
}
