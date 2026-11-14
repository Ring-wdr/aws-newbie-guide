// Route 53 "이 질의에 어느 레코드가 답하나"(설명용 모형). 계산은 model.mjs, 레코드와 규칙은 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { resolve, initialState, groupByName, caseState, WORKSHEET_CASES, LOCATIONS, locationById, summarize, simpleRecords, keyOf, policyText, fmtPct, POLICY_LABEL } from './model.mjs';

const KIND_LABEL = { answer: '응답', weighted: '응답(무작위, 비율)', nodata: '빈 응답', none: '레코드 없음' };

export default function Routing({ facts }) {
  const file = facts.lesson.split('/').pop();
  const src = (line) => `${file}:${line}`;
  const records = useMemo(() => [...facts.records, ...simpleRecords(facts.simple.values, facts.simple.line)], []);
  const byName = useMemo(() => groupByName(records), [records]);
  const names = [...byName.keys()];

  const [name, setName] = useState('api');
  const [loc, setLoc] = useState('JP');
  const [st, setSt] = useState(() => caseState(records, WORKSHEET_CASES[1]));
  const [preset, setPreset] = useState('1');
  const recs = byName.get(name);
  const location = locationById(loc);
  const res = useMemo(() => resolve(recs, st, location, { multiMax: facts.multiMax.value }), [recs, st, location]);

  const apply = (k) => {
    const c = WORKSHEET_CASES[k];
    setSt(caseState(records, c));
    setName(c.name);
    if (c.loc) setLoc(c.loc);
    setPreset(k);
  };
  const edit = (fn) => {
    setSt((s) => {
      const n = { present: { ...s.present }, healthy: { ...s.healthy }, weight: { ...s.weight } };
      fn(n);
      return n;
    });
    setPreset('');
  };
  const reset = () => {
    setSt(initialState(records));
    setPreset('');
  };
  const q = preset ? facts.questions[preset] : null;
  const a = preset ? facts.answers[preset] : null;
  const verdictMark = res.kind === 'nodata' || res.kind === 'none' ? '∅ ' : '✓ ';

  return (
    <section class="rr" aria-labelledby="rr-title">
      <div class="rr-head">
        <h4 id="rr-title">이 질의에는 어느 레코드가 답하나</h4>
        <span class="rr-model">모형</span>
      </div>
      <p class="rr-intro">
        <strong>설명용 모형이다.</strong> 실제 Route 53이나 에뮬레이터에 묻지 않고, 바로 위 워크시트의 레코드 표({src(facts.worksheetLine)})와 원고의 규칙으로 답을 계산한다. 에뮬레이터가 보여 주지 못하는 위치·상태 확인의 영향을 손 대신 판정해 보는 도구다.
      </p>

      <fieldset>
        <legend>워크시트 문항으로 채우기</legend>
        <div class="rr-row">
          {Object.keys(WORKSHEET_CASES).map((k) => (
            <button type="button" key={k} data-case={k} aria-pressed={preset === k ? 'true' : 'false'} onClick={() => apply(k)} aria-label={`워크시트 ${k}번`}>
              {k}번
            </button>
          ))}
          <button type="button" data-case="reset" onClick={reset}>
            모두 건강·모두 있음으로
          </button>
        </div>
        <p class="rr-hint">
          {q ? (
            <>
              {preset}번({src(q.line)}): {q.text} <br />
              원고의 답({src(a.line)}): <strong>{a.bold}</strong>
            </>
          ) : (
            '직접 바꾼 상태다.'
          )}
        </p>
      </fieldset>

      <div class="rr-controls">
        <fieldset>
          <legend>질의할 이름(정책)</legend>
          <div class="rr-row">
            {names.map((nm) => (
              <button type="button" key={nm} data-name={nm} aria-pressed={name === nm ? 'true' : 'false'} onClick={() => { setName(nm); setPreset(''); }}>
                <code>{nm}</code> {POLICY_LABEL[byName.get(nm)[0].policy]}
              </button>
            ))}
          </div>
        </fieldset>
        <fieldset class="rr-radios">
          <legend>질의자 위치(모형 값)</legend>
          {LOCATIONS.map((l) => (
            <label key={l.id}>
              <input type="radio" name="rr-loc" value={l.id} checked={loc === l.id} onChange={() => { setLoc(l.id); setPreset(''); }} />
              <span>
                {l.label} <small class="rr-inline">국가 {l.country} · 대륙 {l.continent} · 서울 {l.latency['ap-northeast-2']}ms / 버지니아 {l.latency['us-east-1']}ms</small>
              </span>
            </label>
          ))}
        </fieldset>
      </div>

      <div class="rr-result" data-kind={res.kind} role="status" aria-live="polite" aria-atomic="true">
        <p class="rr-tag">
          <span aria-hidden="true">{verdictMark}</span>
          <code>{name}</code> 질의 → {KIND_LABEL[res.kind]}: {summarize(res)}
        </p>
        {res.kind === 'weighted' ? (
          <ul class="rr-dist">
            {res.answers.map((x) => (
              <li key={x.key}>
                <span>
                  {x.id} {x.value}: <strong>{fmtPct(x.p)}</strong> — 1,000번 물으면 약 {Math.round(x.p * 1000).toLocaleString('en-US')}번
                </span>
                <span class="rr-pbar" aria-hidden="true">
                  <span style={{ width: `${x.p * 100}%` }}></span>
                </span>
              </li>
            ))}
          </ul>
        ) : null}
        <ol class="rr-steps">
          {res.steps.map((s, i) => (
            <li key={i}>{s}</li>
          ))}
        </ol>
      </div>

      <fieldset>
        <legend>
          <code>{name}</code>의 레코드 — 지우거나 상태를 바꿔 보기
        </legend>
        <ul class="rr-recs">
          {recs.map((r) => {
            const k = keyOf(r);
            const s = res.status[k] || { mark: '·', text: '' };
            const present = st.present[k] !== false;
            return (
              <li key={k} class="rr-rec" data-rec={k} data-mark={s.mark}>
                <p class="rr-rec-head">
                  <strong>{r.id}</strong> · {policyText(r)} · <span class="rr-val">{r.value}</span>
                </p>
                <p class="rr-status">
                  <span aria-hidden="true">{s.mark} </span>
                  {s.text}
                </p>
                <div class="rr-row">
                  <label class="rr-check">
                    <input type="checkbox" checked={present} data-field="present" onChange={(e) => edit((n) => (n.present[k] = e.currentTarget.checked))} /> 레코드 있음
                  </label>
                  {r.hc ? (
                    <label class="rr-check">
                      <input type="checkbox" checked={st.healthy[k] !== false} disabled={!present} data-field="healthy" onChange={(e) => edit((n) => (n.healthy[k] = e.currentTarget.checked))} /> 건강({r.hc})
                    </label>
                  ) : (
                    <small>{r.policy === 'simple' ? `상태 확인을 붙일 수 없다(${src(facts.simpleNoHcLine)})` : '상태 확인 없음 → 항상 건강'}</small>
                  )}
                  {r.policy === 'weighted' ? (
                    <label class="rr-check">
                      가중치
                      <input
                        type="number"
                        inputMode="numeric"
                        min={facts.weightRange.min}
                        max={facts.weightRange.max}
                        step="1"
                        value={st.weight[k]}
                        disabled={!present}
                        data-field="weight"
                        aria-describedby="rr-w-hint"
                        onInput={(e) => {
                          const v = Math.round(Number(e.currentTarget.value));
                          const ok = Number.isFinite(v) ? Math.min(facts.weightRange.max, Math.max(facts.weightRange.min, v)) : 0;
                          edit((n) => (n.weight[k] = ok));
                        }}
                      />
                    </label>
                  ) : null}
                </div>
              </li>
            );
          })}
        </ul>
        {recs[0].policy === 'weighted' ? (
          <small id="rr-w-hint">
            가중치 {facts.weightRange.min}~{facts.weightRange.max}({src(facts.weightRange.line)}). 범위 밖은 끝값으로 맞춘다.
          </small>
        ) : null}
      </fieldset>

      <details class="rr-table-box">
        <summary>같은 내용을 표로 보기</summary>
        <div class="rr-table-scroll" tabindex="0" role="region" aria-label="레코드별 판정 표(좁은 화면에서는 가로로 스크롤)">
          <table class="rr-table">
            <caption class="sr-only">
              {name} 질의의 레코드별 판정(모형), 질의자 {location.label}
            </caption>
            <thead>
              <tr>
                <th scope="col">SetIdentifier</th>
                <th scope="col">정책 설정</th>
                <th scope="col">값</th>
                <th scope="col">레코드·상태</th>
                <th scope="col">이번 질의</th>
              </tr>
            </thead>
            <tbody>
              {recs.map((r) => {
                const k = keyOf(r);
                const s = res.status[k] || { mark: '·', text: '' };
                const present = st.present[k] !== false;
                return (
                  <tr key={k}>
                    <th scope="row">{r.id}</th>
                    <td>{policyText(r)}{r.policy === 'weighted' ? ` ${st.weight[k]}` : ''}</td>
                    <td>{r.value}</td>
                    <td>{!present ? '지움' : r.hc ? (st.healthy[k] !== false ? `건강(${r.hc})` : `비정상(${r.hc})`) : '상태 확인 없음'}</td>
                    <td>
                      {s.mark} {s.text}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </details>

      <details class="rr-assume">
        <summary>이 모형의 가정(실제 Route 53과 다른 점)</summary>
        <ul>
          <li>질의자 위치의 국가·대륙과 리전까지의 지연(ms)은 모형 값이다. 실제 지연 시간 정책은 AWS가 측정한 값을 쓰므로 같은 도시에서도 답이 바뀔 수 있다(워크시트 1번 해설).</li>
          <li>가중치는 비율(기댓값)만 보여 준다. 실제 응답은 무작위라 lab02처럼 실행마다 숫자가 조금씩 다르다.</li>
          <li>리졸버 캐시(TTL)와 상태 확인 반영 시간(검사 간격 × 실패 임계값)은 다루지 않는다. 상태는 "지금 건강/비정상"만 고른다.</li>
          <li>지리적 위치 레코드에는 워크시트처럼 상태 확인이 없다고 둔다. 주(state) 단위 일치, 지리 근접·IP 기반 정책, Alias 트리로 정책을 조합하는 경우는 다루지 않는다.</li>
          <li>
            건강한 레코드가 하나도 없을 때는 원고 정답 7번의 규칙({src(facts.rules.allHealthy)})대로 모두 건강하다고 보고 고른다. 레코드를 모두 지우면 답을 계산하지 않는다.
          </li>
          <li>단순 레코드 <code>simple</code>의 값은 lab02 4단계의 출력({src(facts.simple.line)})이다.</li>
        </ul>
      </details>
    </section>
  );
}
