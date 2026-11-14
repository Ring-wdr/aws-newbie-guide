// DR 전략 고르기(설명용 모형). 계산은 model.mjs, 전략 표·워크시트는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { pick, RPO_TIERS, RTO_TIERS, MODEL_PRESET_REQ } from './model.mjs';

const VERDICT = {
  pick: { mark: '★', text: '고름 — 만족하는 것 중 가장 쌈' },
  over: { mark: '✓', text: '만족하지만 더 비쌈' },
  no: { mark: '✗', text: '요구에 못 미침' },
};
const verdictOf = (r) => (r.pick ? 'pick' : r.ok ? 'over' : 'no');

export default function Picker({ facts }) {
  const S = facts.strategies;
  const byId = Object.fromEntries(S.map((s) => [s.id, s]));
  const lessonFile = facts.lesson.split('/').pop().slice(0, 2);
  const src = (line) => `${lessonFile}:${line}`;
  const presets = [
    ...['a', 'b', 'c', 'd'].map((k) => ({
      id: k,
      label: `워크시트 ${k}`,
      note: `${facts.worksheet[k].situation} (${src(facts.worksheet[k].line)}, 모범 답안 ${src(facts.worksheet[k].answerLine)})`,
      v: MODEL_PRESET_REQ[k],
    })),
    {
      id: 'selfCheck',
      label: `스스로 확인 1: RPO ${facts.selfCheck.rpo}, RTO ${facts.selfCheck.rto}`,
      note: `RPO ${facts.selfCheck.rpo} → "${RPO_TIERS.find((t) => t.id === MODEL_PRESET_REQ.selfCheck.rpo).label}", RTO ${facts.selfCheck.rto} → "${RTO_TIERS.find((t) => t.id === MODEL_PRESET_REQ.selfCheck.rto).label}" (${src(facts.selfCheck.line)}, 답 ${src(facts.selfCheck.answerLine)})`,
      v: MODEL_PRESET_REQ.selfCheck,
    },
  ];
  const [req, setReq] = useState(presets[1].v);
  const [preset, setPreset] = useState('b');
  const res = useMemo(() => pick(S, req), [req.rpo, req.rto]);
  const set = (patch) => {
    setReq((r) => ({ ...r, ...patch }));
    setPreset('');
  };
  const chosen = res.pick ? byId[res.pick] : null;
  const tierLabel = (tiers, id) => tiers.find((t) => t.id === id).label;

  return (
    <section class="drp" aria-labelledby="drp-title">
      <div class="drp-head">
        <h4 id="drp-title">요구 사항으로 DR 전략 고르기</h4>
        <span class="drp-model">모형</span>
      </div>
      <p class="drp-intro">
        <strong>설명용 모형이다.</strong> 허용할 RPO·RTO를 고르면, 레슨의 전략 표({src(facts.tableLine)})에서 두 요구를 모두 만족하는 전략 중 표에서 가장 싼 것을 고른다. 실제 비용·복구 시간을 계산하지 않는다.
      </p>

      <fieldset class="drp-presets">
        <legend>원고의 상황으로 채우기</legend>
        <div class="drp-row">
          {presets.map((p) => (
            <button
              type="button"
              key={p.id}
              data-preset={p.id}
              aria-pressed={preset === p.id ? 'true' : 'false'}
              onClick={() => {
                setReq(p.v);
                setPreset(p.id);
              }}
            >
              {p.label}
            </button>
          ))}
        </div>
        <p class="drp-hint">{preset ? `상황: ${presets.find((p) => p.id === preset).note}. 문장을 단계로 읽은 것은 모형의 해석이다.` : '직접 고른 요구다.'}</p>
      </fieldset>

      <div class="drp-controls">
        <fieldset class="drp-radios">
          <legend>허용 RPO — 잃어도 되는 데이터의 시간 폭</legend>
          {[...RPO_TIERS].reverse().map((t) => (
            <label key={t.id}>
              <input type="radio" name="drp-rpo" value={t.id} checked={req.rpo === t.id} onChange={() => set({ rpo: t.id })} /> {t.label}
            </label>
          ))}
        </fieldset>
        <fieldset class="drp-radios">
          <legend>허용 RTO — 멈춰 있어도 되는 시간</legend>
          {[...RTO_TIERS].reverse().map((t) => (
            <label key={t.id}>
              <input type="radio" name="drp-rto" value={t.id} checked={req.rto === t.id} onChange={() => set({ rto: t.id })} /> {t.label}
            </label>
          ))}
        </fieldset>
      </div>

      <div class="drp-result" role="status" aria-live="polite" aria-atomic="true" data-pick={res.pick ?? 'none'}>
        <p>
          <span class="drp-tag">★ {chosen ? chosen.name : '없음'}</span>{' '}
          {chosen
            ? `RPO "${tierLabel(RPO_TIERS, req.rpo)}" · RTO "${tierLabel(RTO_TIERS, req.rto)}"을(를) 만족하는 전략 중 비용이 가장 낮다(비용: ${chosen.cost}).`
            : '만족하는 전략이 없다.'}
        </p>
        {res.split ? (
          <p class="drp-split">
            두 축으로 나눠 보면 데이터(RPO)는 <strong>{byId[res.dataLevel].name}</strong> 수준, 컴퓨트(RTO)는 <strong>{byId[res.computeLevel].name}</strong> 수준이면 된다 — 스스로 확인 1의 답처럼 데이터만 연속 복제하고 서버는 장애 때 만드는 조합을 생각해 볼 수 있다({src(facts.selfCheck.answerLine)}).
          </p>
        ) : null}
      </div>

      <ol class="drp-cards">
        {S.map((s) => {
          const r = res.rows.find((x) => x.id === s.id);
          const v = verdictOf(r);
          return (
            <li class="drp-card" data-verdict={v} data-strategy={s.id} key={s.id}>
              <p class="drp-card-head">
                <strong>{s.name}</strong>
                <span class="drp-verdict" data-verdict={v}>
                  {VERDICT[v].mark} {VERDICT[v].text}
                </span>
              </p>
              <dl>
                <div>
                  <dt>RPO</dt>
                  <dd>
                    {s.rpoText} {r.rpoOk ? '✓' : '✗'}
                  </dd>
                </div>
                <div>
                  <dt>RTO</dt>
                  <dd>
                    {s.rtoText} {r.rtoOk ? '✓' : '✗'}
                  </dd>
                </div>
                <div>
                  <dt>비용</dt>
                  <dd>{s.cost}</dd>
                </div>
              </dl>
              <p class="drp-small">평소 DR 리전: {s.standby}</p>
              <p class="drp-small">장애 때: {s.onFailure}</p>
              <p class="drp-small">판별 질문: {s.question}</p>
            </li>
          );
        })}
      </ol>
      <p class="drp-legend">★ 고름 · ✓ 만족(더 비쌈) · ✗ 못 미침. 왼쪽 위부터 비용이 낮은 순서. 출처: 레슨 표 {src(facts.tableLine)}, 판별 질문은 치트시트.</p>

      <details class="drp-table-box">
        <summary>같은 내용을 표로 보기</summary>
        <div class="drp-table-scroll">
          <table class="drp-table">
            <caption class="sr-only">전략마다 요구를 만족하는지(모형)</caption>
            <thead>
              <tr>
                <th scope="col">전략(비용 순)</th>
                <th scope="col">RPO</th>
                <th scope="col">RTO</th>
                <th scope="col">판정</th>
              </tr>
            </thead>
            <tbody>
              {S.map((s) => {
                const r = res.rows.find((x) => x.id === s.id);
                const v = verdictOf(r);
                return (
                  <tr key={s.id}>
                    <th scope="row">{s.name}</th>
                    <td>
                      {s.rpoText} — {r.rpoOk ? '만족' : '못 미침'}
                    </td>
                    <td>
                      {s.rtoText} — {r.rtoOk ? '만족' : '못 미침'}
                    </td>
                    <td>
                      {VERDICT[v].mark} {VERDICT[v].text}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </details>

      <details class="drp-assume">
        <summary>이 모형의 가정(실제와 다른 점)</summary>
        <ul>
          <li>RPO·RTO를 원고 표의 단계(시간 · 수십 분 · 분 · 초~분 · 거의 0)로만 비교한다. 몇 분부터 "수십 분"인지 같은 경계는 원고에 없어서 숫자로 바꾸지 않는다.</li>
          <li>비용은 표의 순서(가장 낮음 → 가장 높음)로만 비교한다. 실제 금액은 규모와 쓰는 서비스에 따라 다르다.</li>
          <li>워크시트·스스로 확인 문장을 단계로 읽은 것은 모형의 해석이다. 워크시트 c는 RPO 요구가 없어서 가장 넉넉한 "시간"으로 둔다.</li>
          <li>복제만으로 DR이 끝나지 않는다 — 전환 절차(런북)와 페일백 연습은 모형이 다루지 않는다.</li>
        </ul>
      </details>
    </section>
  );
}
