// IAM 정책 평가 순서 따라가기(설명용 모형). 판정은 model.mjs, 원고의 순서·문구·예의 줄 번호는 facts.mjs가 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { evaluate, normalize, PRESETS, presetInput, displayOrder, question, describeStep, summarize, REASON_PHRASE, DECISION_LABEL, DECISION_CODE, RESOURCE_TO_LABEL } from './model.mjs';

const MARK = { allowed: '✓', explicitDeny: '✕', implicitDeny: '○' };

function Radios({ legend, name, value, options, onChange, hint, disabled = false }) {
  return (
    <fieldset class="pe-field">
      <legend>{legend}</legend>
      {options.map(([v, label]) => (
        <label key={v}>
          <input type="radio" name={name} value={v} checked={value === v} disabled={disabled} onChange={() => onChange(v)} /> {label}
        </label>
      ))}
      {hint ? <small>{hint}</small> : null}
    </fieldset>
  );
}

export default function PolicyEval({ facts }) {
  const file = { lesson: facts.lesson, roles: facts.roles, cheatsheet: facts.cheatsheet };
  const src = (which, line) => `${file[which].split('/').pop()}:${line}`;
  const [input, setInput] = useState(() => presetInput(PRESETS[0]));
  const [preset, setPreset] = useState(PRESETS[0].id);
  const x = useMemo(() => normalize(input), [input]);
  const r = useMemo(() => evaluate(x), [x]);
  const order = displayOrder(x.account);
  const steps = order.map((id) => r.steps.find((s) => s.id === id));
  // 역할 ARN을 지정한 리소스 정책 경로의 거부 문구는 원고에 기록이 없어 보여 주지 않는다
  const viaRole = x.account === 'same' && x.resource && x.resourceTo === 'role';
  const phraseKey = viaRole ? null : REASON_PHRASE[r.reason];
  const phrase = phraseKey ? facts.phrases[phraseKey] : null;

  const set = (patch) => {
    setInput((o) => ({ ...o, ...patch }));
    setPreset('');
  };
  const applyPreset = (p) => {
    setInput(presetInput(p));
    setPreset(p.id);
  };
  const cur = PRESETS.find((p) => p.id === preset);
  const stepLine = (id) => src('lesson', facts.flow[id]);

  return (
    <section class="pe" aria-labelledby="pe-title">
      <div class="pe-head">
        <h4 id="pe-title">정책 평가 순서 따라가기</h4>
        <span class="pe-model">모형</span>
      </div>
      <p class="pe-intro">
        <strong>설명용 모형이다.</strong> IAM이나 정책 시뮬레이터를 실행하지 않는다. 정책마다 "이 요청을 허용하는가"를 직접 고르면, 위 흐름도({src('lesson', facts.flow.deny)}~{facts.flow.session}줄)의 순서대로 어디에서 판정이 끝나는지 보여 준다. 정책 문장의 실제 판정은 이 레슨의 워크시트처럼 시뮬레이터로 확인한다.
      </p>

      <fieldset class="pe-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="pe-row">
          {PRESETS.map((p) => (
            <button type="button" key={p.id} data-preset={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => applyPreset(p)}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="pe-hint">{cur ? (cur.where === 'footnote' ? `출처: ${src(cur.file, facts.examples[cur.where])}(각주) — 각주의 규칙대로라면 ${DECISION_LABEL[cur.expect]}` : `출처: ${src(cur.file, facts.examples[cur.where])} — 원고에 기록된 결과는 ${DECISION_LABEL[cur.expect]}`) : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="pe-controls">
        <Radios
          legend="누구의 리소스인가"
          name="pe-account"
          value={x.account}
          onChange={(v) => set({ account: v })}
          options={[
            ['same', '같은 계정'],
            ['cross', '다른 계정(교차 계정)'],
          ]}
          hint={`교차 계정은 치트시트의 식(${src('cheatsheet', facts.crossFormula)})대로 양쪽 모두 허용해야 한다.`}
        />
        <Radios
          legend="요청하는 주체"
          name="pe-caller"
          value={x.caller}
          onChange={(v) => set({ caller: v })}
          options={[
            ['user', 'IAM 사용자(장기 액세스 키)'],
            ['role', '역할 세션(AssumeRole로 받은 임시 자격 증명)'],
          ]}
          hint="세션 정책은 역할 세션에만 있다. IAM 사용자를 고르면 세션 정책 단계는 해당 없음이다."
        />
        <Radios
          legend="명시적 Deny가 맞는 정책"
          name="pe-deny"
          value={x.deny}
          onChange={(v) => set({ deny: v })}
          options={[
            ['none', '없음'],
            ['identity', '자격 증명 기반 정책의 Deny'],
            ['resource', '리소스 기반 정책의 Deny'],
            ['other', '그 밖(SCP·권한 경계·세션 정책)의 Deny'],
          ]}
        />
        <fieldset class="pe-field">
          <legend>조직의 상한선</legend>
          <label>
            <input type="checkbox" data-field="scp" checked={x.scp} onChange={(e) => set({ scp: e.currentTarget.checked })} /> SCP가 이 작업을 허용
          </label>
          <label>
            <input type="checkbox" data-field="rcp" checked={x.rcp} onChange={(e) => set({ rcp: e.currentTarget.checked })} /> RCP가 이 작업을 허용
          </label>
          <small>조직에 속하지 않았거나 관리 계정이라 적용되지 않으면 켜 둔다.</small>
        </fieldset>
        <fieldset class="pe-field">
          <legend>권한을 주는 정책</legend>
          <label>
            <input type="checkbox" data-field="identity" checked={x.identity} onChange={(e) => set({ identity: e.currentTarget.checked })} /> 자격 증명 기반 정책(사용자·그룹·역할)이 허용
          </label>
          <label>
            <input type="checkbox" data-field="resource" checked={x.resource} onChange={(e) => set({ resource: e.currentTarget.checked })} /> 리소스 기반 정책이 이 주체를 허용
          </label>
        </fieldset>
        <Radios
          legend="리소스 정책이 Principal로 지정한 것"
          name="pe-resource-to"
          value={x.resourceTo}
          onChange={(v) => set({ resourceTo: v })}
          disabled={!x.resource || x.account === 'cross'}
          options={x.caller === 'user' ? [['user', `${RESOURCE_TO_LABEL.user}(요청한 사용자 자신)`]] : [['role', `${RESOURCE_TO_LABEL.role}(맡은 역할)`], ['session', `${RESOURCE_TO_LABEL.session}(이 세션)`]]}
          hint={`같은 계정에서만 결과가 갈린다(${src('lesson', facts.footnote)}): 사용자·역할 세션 ARN이면 허용 *, 역할 ARN이면 권한 경계·세션 정책 판정으로 이어진다. ${x.resource ? '' : '리소스 정책이 허용할 때만 고른다.'}`}
        />
        <Radios
          legend="권한 경계"
          name="pe-boundary"
          value={x.boundary}
          onChange={(v) => set({ boundary: v })}
          options={[
            ['none', '없음'],
            ['allow', '있고, 이 작업을 허용'],
            ['deny', '있지만 이 작업은 경계 밖'],
          ]}
        />
        <Radios
          legend="세션 정책(역할 세션)"
          name="pe-session"
          value={x.session}
          disabled={x.caller === 'user'}
          hint={x.caller === 'user' ? 'IAM 사용자 요청에는 세션 정책이 없다(요청하는 주체를 역할 세션으로 바꾸면 고를 수 있다).' : undefined}
          onChange={(v) => set({ session: v })}
          options={[
            ['none', '없음'],
            ['allow', '있고, 이 작업을 허용'],
            ['deny', '있지만 이 작업은 세션 정책 밖'],
          ]}
        />
      </div>

      <div class="pe-result" data-decision={r.decision} role="status" aria-live="polite" aria-atomic="true">
        <p>
          <span class="pe-tag">
            <span aria-hidden="true">{MARK[r.decision]} </span>
            {DECISION_LABEL[r.decision]}
            {r.reason === 'allowedByResource' ? ' *' : ''} — 워크시트 기호 {DECISION_CODE[r.decision]}
          </span>{' '}
          {summarize(r, x)}
        </p>
        <p class="pe-phrase">
          {phrase ? (
            <>
              오류 메시지의 단서: <code>{phrase.text}</code> ({src('cheatsheet', phrase.line)})
            </>
          ) : r.decision === 'allowed' ? (
            '허용이라 오류 메시지가 없다.'
          ) : (
            `이 경우의 오류 문구는 원고(치트시트 ${src('cheatsheet', facts.phrases.identityDeny.line)}~${facts.phrases.noSession.line}줄 표)에 없다.`
          )}
        </p>
      </div>

      <ol class="pe-flow" aria-label="판정 단계">
        {steps.map((s, i) => (
          <li key={s.id} class="pe-step" data-outcome={s.outcome} data-step={s.id} aria-current={r.stoppedAt === s.id ? 'step' : undefined}>
            <span class="pe-q">
              <span class="pe-n" aria-hidden="true">{i + 1}</span>
              {question(s.id, x.account)}
            </span>
            <span class="pe-a">
              <span class="pe-badge">{describeStep(s, x.account, x)}</span>
              {r.stoppedAt === s.id ? <strong class="pe-here"> ◀ 여기서 끝</strong> : null}
            </span>
          </li>
        ))}
        <li class="pe-step pe-final" data-decision={r.decision}>
          <span class="pe-q">최종 판정</span>
          <span class="pe-a">
            <span aria-hidden="true">{MARK[r.decision]} </span>
            {DECISION_LABEL[r.decision]}
            {r.reason === 'allowedByResource' ? ' *' : ''}
          </span>
        </li>
      </ol>

      <details class="pe-table-box">
        <summary>같은 내용을 표로 보기</summary>
        <div class="pe-table-scroll">
          <table class="pe-table">
            <caption class="sr-only">판정 단계와 결과(모형)</caption>
            <thead>
              <tr>
                <th scope="col">단계</th>
                <th scope="col">질문</th>
                <th scope="col">답</th>
                <th scope="col">원고</th>
              </tr>
            </thead>
            <tbody>
              {steps.map((s, i) => (
                <tr key={s.id} aria-current={r.stoppedAt === s.id ? 'step' : undefined}>
                  <td>{i + 1}</td>
                  <td>{question(s.id, x.account)}</td>
                  <td>{describeStep(s, x.account, x)}</td>
                  <td>{x.account === 'cross' ? src('cheatsheet', facts.crossFormula) : stepLine(s.id)}</td>
                </tr>
              ))}
              <tr>
                <td>끝</td>
                <td>최종 판정</td>
                <td>{DECISION_LABEL[r.decision]}</td>
                <td>{phrase ? src('cheatsheet', phrase.line) : '—'}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>

      <details class="pe-assume">
        <summary>이 모형의 가정(실제 AWS와 다른 점)</summary>
        <ul>
          <li>정책마다 "이 요청을 허용하는가, Deny가 맞는가"는 직접 고른다. 정책 문장의 Action·Resource·조건 키·와일드카드는 해석하지 않는다.</li>
          <li>같은 계정에서 리소스 기반 정책이 허용하면 흐름도·각주({src('lesson', facts.edges.direct)}~{facts.edges.role}줄, {src('lesson', facts.footnote)})대로 지정한 주체에 따라 나눈다: IAM 사용자 ARN·역할 세션 ARN은 허용 *, 역할 ARN은 자격 증명 정책 없이 권한 경계·세션 정책 판정으로 이어진다(AWS IAM 사용 설명서 "Policy evaluation logic"). 명시적 Deny는 늘 먼저다.</li>
          <li>요청하는 주체는 IAM 사용자와 역할 세션만 고른다. STS 연동 사용자 세션(GetFederationToken), Principal의 와일드카드(*)와 aws:PrincipalArn 조건 키는 다루지 않는다.</li>
          <li>KMS 키 정책(같은 계정에서도 키 정책이 허용해야 한다)과 역할 신뢰 정책의 예외는 다루지 않는다({src('lesson', facts.footnote)}).</li>
          <li>교차 계정은 치트시트의 식({src('cheatsheet', facts.crossFormula)})대로 호출자 계정(자격 증명 정책 ∩ 경계 ∩ 세션 정책 ∩ SCP)과 리소스 계정(리소스 정책 ∩ RCP)이 모두 허용해야 허용으로 둔다.</li>
          <li>"SCP가 허용"에는 조직에 속하지 않았거나 관리 계정이라 SCP가 적용되지 않는 경우도 넣었다.</li>
          <li>에뮬레이터는 일부 API(S3 버킷 관리 등)에 사용자 정책을 평가하지 않는다(이 레슨 Part B). 모형은 실제 AWS의 평가 순서를 보여 준다.</li>
        </ul>
      </details>
    </section>
  );
}
