// KMS 봉투 암호화 단계(설명용 모형). 계산은 model.mjs, 수치와 오류 이름은 facts.mjs가 원고에서 읽어 props로 준다.
import { useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks';
import { normalize, buildSteps, directNote, MODEL_MAX_SIZE } from './model.mjs';

const MARK = { plain: '📄', pdk: '🔑', edk: '🔒', ct: '🔐', 'ct-bad': '⚠', ctx: '🏷', 'ctx-bad': '🏷', cmk: '🗝' };
const STATE_LABEL = { Enabled: '활성(Enabled)', Disabled: '비활성(Disabled)', PendingDeletion: '삭제 대기(PendingDeletion)' };

export default function Envelope({ facts }) {
  const file = facts.lesson.split('/').pop();
  const src = (line) => `${file}:${line}`;
  const presets = [
    { id: 'lab03', label: `lab03: 주문 내보내기 ${facts.lab03.plain.toLocaleString('en-US')}바이트`, note: `lab03 0단계(${src(facts.lab03.plainLine)}), 암호문 ${facts.lab03.cipher.toLocaleString('en-US')}바이트(${src(facts.lab03.line)})`, v: { size: facts.lab03.plain, keyState: 'Enabled', sameContext: true, tampered: false } },
    { id: 'sdk', label: `SDK: 영수증 ${facts.sdk.plain.toLocaleString('en-US')}바이트`, note: `sdk/envelope_encryption.py 출력(${src(facts.sdk.line)})`, v: { size: facts.sdk.plain, keyState: 'Enabled', sameContext: true, tampered: false } },
    { id: 'lab01', label: `lab01: 카드 토큰 ${facts.lab01.plain}바이트`, note: `lab01 2단계(${src(facts.lab01.line)}) — 한도 이하라 Encrypt로 바로 했던 예`, v: { size: facts.lab01.plain, keyState: 'Enabled', sameContext: true, tampered: false } },
    { id: 'disabled', label: 'lab03 6단계: 키 비활성화', note: `${facts.errors.disabled.name}(${src(facts.errors.disabled.line)})`, v: { size: facts.lab03.plain, keyState: 'Disabled', sameContext: true, tampered: false } },
    { id: 'tampered', label: 'lab03 5단계: 1바이트 변조', note: `${facts.errors.tag.name}(${src(facts.errors.tag.line)})`, v: { size: facts.lab03.plain, keyState: 'Enabled', sameContext: true, tampered: true } },
  ];
  const [raw, setRaw] = useState({ ...presets[0].v, size: String(presets[0].v.size) });
  const [preset, setPreset] = useState('lab03');
  const input = useMemo(() => normalize(raw), [raw.size, raw.keyState, raw.sameContext, raw.tampered]);
  const r = useMemo(() => buildSteps(input, facts), [input]);
  const [step, setStep] = useState(0);
  const last = r.steps.length - 1;
  const cur = Math.min(step, last);
  const s = r.steps[cur];

  const nextRef = useRef(null);
  const prevRef = useRef(null);
  const pendingFocus = useRef(null);
  useLayoutEffect(() => {
    if (pendingFocus.current) {
      pendingFocus.current.current?.focus();
      pendingFocus.current = null;
    }
  });
  const set = (patch) => {
    setRaw((x) => ({ ...x, ...patch }));
    setPreset('');
  };
  const pick = (p) => {
    setRaw({ ...p.v, size: String(p.v.size) });
    setPreset(p.id);
  };
  const goto = (n, focusRef) => {
    setStep(n);
    if (focusRef) pendingFocus.current = focusRef;
  };
  const errLine = { DisabledException: facts.errors.disabled.line, KMSInvalidStateException: facts.errors.pending.line, InvalidCiphertextException: facts.errors.context.line, InvalidTag: facts.errors.tag.line };

  const Box = ({ title, items, k }) => (
    <div class={`ev-box ev-box-${k}`}>
      <p class="ev-box-title">{title}</p>
      {items.length ? (
        <ul>
          {items.map((i) => (
            <li key={i.kind} data-item={i.kind} class={i.secret ? 'ev-secret' : undefined}>
              <span aria-hidden="true">{MARK[i.kind]} </span>
              {i.label}
              {i.bytes != null ? ` · ${i.bytes.toLocaleString('en-US')}바이트` : ''}
              {i.secret ? <span class="ev-tag-secret"> 평문(비밀)</span> : null}
            </li>
          ))}
        </ul>
      ) : (
        <p class="ev-empty">(없음)</p>
      )}
    </div>
  );

  return (
    <section class="ev" aria-labelledby="ev-title">
      <div class="ev-head">
        <h4 id="ev-title">봉투 암호화 한 단계씩: 누가 무엇을 들고 있나</h4>
        <span class="ev-model">모형</span>
      </div>
      <p class="ev-intro">
        <strong>설명용 모형이다.</strong> 실제 KMS나 에뮬레이터를 부르지 않고 암호화도 하지 않는다. 위 시퀀스 그림(그리고 아래 "직접 해 보기"의 lab03)의 순서대로, 단계마다 주문 서비스·KMS·S3가 무엇을 들고 있는지 보여 준다. 크기와 오류 이름은 원고의 lab 출력에서 읽었다.
      </p>

      <fieldset>
        <legend>원고의 예로 채우기</legend>
        <div class="ev-row">
          {presets.map((p) => (
            <button type="button" key={p.id} data-preset={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => pick(p)}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="ev-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="ev-controls">
        <label class="ev-field">
          <span>평문 크기(바이트)</span>
          <input type="number" inputMode="numeric" min="1" max={MODEL_MAX_SIZE} step="1" value={raw.size} data-field="size" aria-describedby="ev-size-hint" onInput={(e) => set({ size: e.currentTarget.value })} />
          <small id="ev-size-hint">{directNote(input, facts)} (한도: {src(facts.encryptLimit.line)})</small>
        </label>
        <fieldset class="ev-field ev-radios">
          <legend>읽을 때 KMS 키 상태</legend>
          {['Enabled', 'Disabled', 'PendingDeletion'].map((k) => (
            <label key={k}>
              <input type="radio" name="ev-key" value={k} checked={raw.keyState === k} onChange={() => set({ keyState: k })} /> {STATE_LABEL[k]}
            </label>
          ))}
        </fieldset>
        <div class="ev-field">
          <span class="ev-label">읽을 때 바뀐 것</span>
          <label class="ev-check">
            <input type="checkbox" checked={!raw.sameContext} data-field="otherContext" onChange={(e) => set({ sameContext: !e.currentTarget.checked })} /> 복호화에 다른 암호화 컨텍스트를 넣는다
          </label>
          <label class="ev-check">
            <input type="checkbox" checked={raw.tampered} data-field="tampered" onChange={(e) => set({ tampered: e.currentTarget.checked })} /> S3의 암호문이 1바이트 변조됐다
          </label>
        </div>
      </div>

      <p class="ev-result" data-result={r.result} role="status" aria-live="polite" aria-atomic="true">
        <span class="ev-tag">
          <span aria-hidden="true">{r.result === 'ok' ? '✓ ' : '✕ '}</span>
          {r.result === 'ok' ? '복호화 성공' : `${r.error}로 실패`}
        </span>{' '}
        {r.result === 'ok'
          ? `${r.steps.length}단계 끝에 평문 ${input.size.toLocaleString('en-US')}바이트가 원본과 같게 돌아온다. KMS와는 데이터 키만 오갔다 — 평문 데이터 키(${facts.dataKeyBytes.value}바이트)와 그것을 감싼 암호화된 데이터 키.`
          : `${r.steps.length}단계(읽기)에서 멈춘다(원고 ${src(errLine[r.error])}).`}
      </p>

      <div class="ev-steps" role="group" aria-label="단계별로 보기">
        <div class="ev-row">
          <button type="button" data-step="first" onClick={() => goto(0, nextRef)} disabled={cur === 0}>처음</button>
          <button type="button" data-step="prev" ref={prevRef} onClick={() => goto(Math.max(0, cur - 1))} disabled={cur === 0}>이전 단계</button>
          <button type="button" data-step="next" ref={nextRef} onClick={() => goto(Math.min(last, cur + 1))} disabled={cur === last}>다음 단계</button>
          <button type="button" data-step="last" onClick={() => goto(last, prevRef)} disabled={cur === last}>끝까지</button>
        </div>
        <div class="ev-now" data-ok={s.ok ? 'true' : 'false'} aria-live="polite">
          <p>
            <strong>
              단계 {cur + 1}/{last + 1} · {s.phase === 'write' ? '쓰기' : '읽기'} · {s.actor}
            </strong>
          </p>
          <p class="ev-now-title">
            <span aria-hidden="true">{s.ok ? '' : '✕ '}</span>
            {s.title}
          </p>
          <p>{s.text}</p>
          {s.wire ? <p class="ev-wire">↔ {s.wire}</p> : null}
        </div>
      </div>

      <div class="ev-boxes" aria-label={`단계 ${cur + 1}에서 각자 들고 있는 것`} role="group">
        <Box k="app" title="주문 서비스(메모리)" items={s.app} />
        <Box k="kms" title="KMS" items={s.kms} />
        <Box k="s3" title="S3(저장)" items={s.s3} />
      </div>

      <details class="ev-table-box">
        <summary>모든 단계를 표로 보기</summary>
        <div class="ev-table-scroll" tabindex="0" role="region" aria-label="단계 표(좁은 화면에서는 가로로 스크롤)">
          <table class="ev-table">
            <caption class="sr-only">봉투 암호화 단계(모형)</caption>
            <thead>
              <tr>
                <th scope="col">단계</th>
                <th scope="col">누가</th>
                <th scope="col">무엇을</th>
                <th scope="col">주문 서비스가 들고 있는 것</th>
                <th scope="col">S3에 있는 것</th>
              </tr>
            </thead>
            <tbody>
              {r.steps.map((x, i) => (
                <tr key={i} aria-current={i === cur ? 'step' : undefined}>
                  <td>
                    {x.n} {x.phase === 'write' ? '쓰기' : '읽기'}
                    {i === cur ? <span> ◀ 지금</span> : null}
                  </td>
                  <td>{x.actor}</td>
                  <td>
                    {x.ok ? '' : '✕ '}
                    {x.title}
                    {x.error ? ` — ${x.error}` : ''}
                  </td>
                  <td>{x.app.map((a) => a.label).join(', ') || '(없음)'}</td>
                  <td>{x.s3.map((a) => a.label).join(', ') || '(없음)'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>

      <details class="ev-assume">
        <summary>이 모형의 가정(실제 KMS와 다른 점)</summary>
        <ul>
          <li>실제로 암호화하지 않는다. 크기와 순서만 원고(lab03, SDK 예제)대로 보여 준다.</li>
          <li>쓸 때 키는 활성이고, 고른 키 상태는 나중에 읽을 때의 상태다.</li>
          <li>키 상태와 컨텍스트가 둘 다 문제면 모형은 키 상태 오류를 먼저 보인다(둘 다일 때 실제로 어느 오류가 나는지는 원고에 없다).</li>
          <li>
            암호화된 데이터 키의 크기({facts.lab03.encryptedKey}바이트)는 lab03에서 에뮬레이터로 관찰한 값({src(facts.lab03.line)})이다. 실제 KMS에서는 다를 수 있다.
          </li>
          <li>키 정책·IAM 정책은 모두 허용된 상태로 둔다(권한 평가는 레슨의 키 정책 절과 lab02에서 다룬다). 데이터 키 캐시, AWS Encryption SDK의 형식은 다루지 않는다.</li>
        </ul>
      </details>
    </section>
  );
}
