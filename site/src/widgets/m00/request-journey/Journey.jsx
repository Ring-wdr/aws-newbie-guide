// CLI 요청 한 번의 여정(설명용 모형). 판정은 model.mjs, 원고의 단계·종료 코드·오류 코드는 facts.mjs가 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { journey, normalize, describeStage, STAGE_LABEL, FAULT_LABEL, CRED_LABEL, FAULTS, CRED_SOURCES } from './model.mjs';

const STATE_MARK = { ok: '✓', fail: '✕', skip: '—' };
const STATE_TEXT = { ok: '통과', fail: '여기서 멈춤', skip: '가지 않음' };

export default function Journey({ facts }) {
  const src = (line, file = facts.lesson) => `${file.split('/').pop()}:${line}`;
  const [raw, setRaw] = useState({ creds: 'file', fault: 'none' });
  const x = normalize(raw);
  const r = useMemo(() => journey(x, facts), [x.creds, x.fault]);
  const set = (patch) => setRaw((o) => ({ ...o, ...patch }));
  const stageSrc = (id) => (facts.flow[id] ? src(facts.flow[id]) : '모형이 더한 단계');
  const code = facts.exitCodes[r.exit];

  return (
    <section class="rj" aria-labelledby="rj-title">
      <div class="rj-head">
        <h4 id="rj-title">요청 한 번의 여정과 종료 코드</h4>
        <span class="rj-model">모형</span>
      </div>
      <p class="rj-intro">
        <strong>설명용 모형이다.</strong> CLI·에뮬레이터를 실행하지 않는다. <code>aws sts get-caller-identity</code> 한 번이 위 순서도({src(facts.flow.creds)}~{facts.flow.response}줄)의 어느 단계에서 멈추는지, 그때 CLI 종료 코드가 무엇인지(아래 "CLI 종료 코드" 표, {src(facts.exitCodes[0].line)}~{facts.exitCodes[255].line}줄) 보여 준다.
      </p>

      <div class="rj-controls">
        <fieldset class="rj-field">
          <legend>키가 어디에 있나</legend>
          {CRED_SOURCES.map((k) => (
            <label key={k}>
              <input type="radio" name="rj-creds" value={k} checked={x.creds === k} onChange={() => set({ creds: k })} /> {CRED_LABEL[k]}
            </label>
          ))}
          <small>
            찾는 순서: {facts.chain.order} → {facts.chain.meta}({src(facts.chain.line)}). 환경 변수가 파일보다 우선한다({src(facts.envFirstLine)}).
          </small>
        </fieldset>
        <fieldset class="rj-field">
          <legend>무엇이 잘못됐나(하나만)</legend>
          {FAULTS.map((k) => (
            <label key={k}>
              <input type="radio" name="rj-fault" value={k} checked={x.fault === k} onChange={() => set({ fault: k })} /> {FAULT_LABEL[k]}
            </label>
          ))}
          <small>
            서명 불일치·{facts.signature.skewMinutes}분 시계 차이: {src(facts.signature.line)}, 시계 차이의 서비스별 오류 코드: {src(facts.clock.line, facts.setup)}.
          </small>
        </fieldset>
      </div>

      <div class="rj-result" data-exit={r.exit} role="status" aria-live="polite" aria-atomic="true">
        <p>
          <span class="rj-tag">
            <span aria-hidden="true">{r.exit === 0 ? '✓ ' : '✕ '}</span>종료 코드 {r.exit}
          </span>{' '}
          — {code.meaning}({src(code.line)}).
          {r.exit === 0 ? ' 응답을 받았다.' : ` "${STAGE_LABEL[r.stoppedAt]}" 단계에서 멈췄다.`}
          {r.error ? ` 오류 코드: ${r.error}.` : ''}
        </p>
        {r.exit === 254 && x.fault !== 'denied' ? <p class="rj-note">원고 표의 일반 규칙("요청은 나갔고 서비스가 오류를 돌려줌")으로 분류한 것이다. 이 경우를 실행해 종료 코드를 기록한 출력은 원고에 없다.</p> : null}
        {x.fault === 'denied' ? <p class="rj-note">get-caller-identity 자체는 권한이 없어도 성공한다. 이 경우는 다른 명령(lab03의 ValidationException 등)을 떠올린 것이다.</p> : null}
      </div>

      <ol class="rj-stages" aria-label="요청의 단계">
        {r.stages.map((s, i) => (
          <li key={s.id} class="rj-stage" data-state={s.state} data-stage={s.id} aria-current={s.state === 'fail' ? 'step' : undefined}>
            <span class="rj-n" aria-hidden="true">{i + 1}</span>
            <span class="rj-body">
              <span class="rj-name">
                {STAGE_LABEL[s.id]} <span class="rj-state">{STATE_MARK[s.state]} {STATE_TEXT[s.state]}</span>
              </span>
              <span class="rj-desc">{describeStage(s.id, s.state, r, facts)}</span>
            </span>
          </li>
        ))}
      </ol>

      <details class="rj-table-box">
        <summary>종료 코드 표와 이 모형의 경우</summary>
        <div class="rj-table-scroll">
          <table class="rj-table">
            <caption class="sr-only">CLI 종료 코드(원고)와 모형에서 그 코드가 나오는 경우</caption>
            <thead>
              <tr>
                <th scope="col">코드</th>
                <th scope="col">의미(원고)</th>
                <th scope="col">이 모형에서 나오는 경우</th>
              </tr>
            </thead>
            <tbody>
              {[0, 252, 253, 254, 255].map((c) => {
                const cases = FAULTS.filter((ft) => journey({ creds: 'file', fault: ft }, facts).exit === c).map((ft) => FAULT_LABEL[ft]);
                if (c === 253) cases.push(CRED_LABEL.none);
                return (
                  <tr key={c} aria-current={c === r.exit ? 'true' : undefined}>
                    <td>
                      {c}
                      {c === r.exit ? ' ◀ 지금' : ''}
                    </td>
                    <td>{facts.exitCodes[c].meaning}</td>
                    <td>{cases.join(' / ')}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </details>

      <details class="rj-assume">
        <summary>이 모형의 가정(실제와 다른 점)</summary>
        <ul>
          <li>단계 1 "명령 해석"과 7 "서비스가 요청 처리"는 순서도에 없는 단계로, 종료 코드 252·254를 놓을 자리로 모형이 더했다. 나머지 단계는 순서도({stageSrc('creds')}~{facts.flow.response}줄) 그대로다.</li>
          <li>잘못된 것은 한 번에 하나만 고른다. 여러 문제가 겹치면 앞 단계의 문제가 먼저 드러난다.</li>
          <li>서명 불일치·시계 차이를 254로 둔 것은 종료 코드 표의 일반 규칙을 적용한 분류다(원고에 실행 기록이 없다).</li>
          <li>엔드포인트는 이 저장소의 실습처럼 AWS_ENDPOINT_URL이 있는 경우({facts.endpoint.emulator}, {src(facts.endpoint.emulatorLine)})만 따라간다.</li>
          <li>서명 없이 curl로 보낸 요청은 HTTP {facts.unsigned.status}·{facts.unsigned.code}였다({src(facts.unsigned.line)}). CLI를 거치지 않아 종료 코드 표와 무관하므로 모형에 넣지 않았다.</li>
          <li>자격 증명 체인의 설정 파일·컨테이너/EC2 메타데이터 단계는 고를 수 없게 줄였다.</li>
        </ul>
      </details>
    </section>
  );
}
