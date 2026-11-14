// 구매 옵션 섞기(설명용 모형). 계산은 model.mjs, 숫자는 facts.mjs가 원고 워크시트 2에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { cost, sweep, worksheetPlans, usd, MODEL_LIMITS } from './model.mjs';

export default function Mix({ facts: f }) {
  const src = (line) => `02:${line}`;
  const plans = worksheetPlans(f);
  const [choice, setChoice] = useState({ ...plans[1].choice, mustNotStop: false });
  const [preset, setPreset] = useState('2');
  const r = useMemo(() => cost(f, choice), [choice.commit, choice.batch, choice.mustNotStop]);
  const sw = useMemo(() => sweep(f, choice), [choice.batch, choice.mustNotStop]);
  const allOd = cost(f, { commit: 0, batch: 'od' }).total;
  const max = Math.max(...sw.rows.map((x) => x.total));
  // 막대 높이는 차이가 보이게 가장 싼 값의 80%를 바닥으로 둔다(세로축이 0에서 시작하지 않는다 — 글로 알린다).
  const floor = Math.min(...sw.rows.map((x) => x.total)) * 0.8;
  const set = (patch) => {
    setChoice((c) => ({ ...c, ...patch }));
    setPreset('');
  };
  const saved = allOd - r.total;
  const segs = [
    { key: 'sp-used', label: `Savings Plans(쓴 약정)`, v: r.parts.sp - r.unusedCost },
    { key: 'sp-waste', label: `Savings Plans(쓰지 않은 약정)`, v: r.unusedCost },
    { key: 'od', label: '온디맨드(바닥 위 피크)', v: r.parts.od },
    { key: r.batchMode === 'spot' ? 'spot' : 'batch-od', label: `배치(${r.batchMode === 'spot' ? '스팟' : '온디맨드'})`, v: r.parts.batch },
  ];

  return (
    <section class="pmx" aria-labelledby="pmx-title">
      <div class="pmx-head">
        <h4 id="pmx-title">구매 옵션 섞기 계산기</h4>
        <span class="pmx-model">모형</span>
      </div>
      <p class="pmx-intro">
        <strong>설명용 모형이다.</strong> 워크시트 2의 예시 숫자({src(f.priceLine)}: {f.instance} {f.price.toFixed(2)} USD/시간, Savings Plans 할인 {Math.round(f.spDiscount * 100)}%, 스팟 할인 {Math.round(f.spotDiscount * 100)}%, 한 달 {f.hours}시간)로 월 비용을 계산한다. 실제 AWS 가격이 아니다. 참고로 구매 옵션 표의 공식 "최대" 할인은 Compute Savings Plans {f.officialMax.computeSP.pct}%, 스팟 {f.officialMax.spot.pct}%다({src(f.officialMax.computeSP.line)}, {src(f.officialMax.spot.line)}).
      </p>
      <p class="pmx-hint">
        사용 패턴: 상시 바닥 {f.base.count}대 × {f.hours}시간({src(f.base.line)}) · 변동 피크 {f.peak.count}대 × {f.peak.hours}시간({src(f.peak.line)}) · 중단 가능 배치 {f.batch.count}대 × {f.batch.hours}시간({src(f.batch.line)})
      </p>

      <fieldset class="pmx-presets">
        <legend>워크시트 2의 세 안으로 채우기</legend>
        <div class="pmx-row">
          {plans.map((p) => (
            <button
              type="button"
              key={p.id}
              data-preset={p.id}
              aria-pressed={preset === p.id ? 'true' : 'false'}
              onClick={() => {
                setChoice({ ...p.choice, mustNotStop: false });
                setPreset(p.id);
              }}
            >
              {p.label}
            </button>
          ))}
        </div>
        <p class="pmx-hint">{preset ? `원고 모범 답안: ${usd(f.answers[preset].total)} USD/월(${src(f.answers[preset].line)})` : '직접 고른 조합이다.'}</p>
      </fieldset>

      <div class="pmx-controls">
        <label class="pmx-field">
          <span>Savings Plans로 약정할 대수: {r.k}대</span>
          <input type="range" min="0" max={MODEL_LIMITS.maxCommit} step="1" value={r.k} data-field="commit" aria-valuetext={`${r.k}대`} onInput={(e) => set({ commit: Number(e.currentTarget.value) })} />
          <small>바닥은 {f.base.count}대, 피크 시간에는 {f.base.count + f.peak.count}대가 돈다.</small>
        </label>
        <fieldset class="pmx-field pmx-radios">
          <legend>정산 배치 구매 방법</legend>
          <label>
            <input type="radio" name="pmx-batch" value="od" checked={choice.batch === 'od'} onChange={() => set({ batch: 'od' })} /> 온디맨드
          </label>
          <label>
            <input type="radio" name="pmx-batch" value="spot" checked={choice.batch === 'spot'} onChange={() => set({ batch: 'spot' })} /> 스팟(중단될 수 있음)
          </label>
          <label class="pmx-check">
            <input type="checkbox" checked={choice.mustNotStop} data-field="mustNotStop" onChange={(e) => set({ mustNotStop: e.currentTarget.checked })} /> 배치가 중단되면 안 된다
          </label>
          <small>원고의 배치는 "{f.batch.note}"이다. "중단되면 안 됨"이면 스팟을 지운다({src(f.noStopLine)}).</small>
        </fieldset>
      </div>

      <div class="pmx-result" role="status" aria-live="polite" aria-atomic="true">
        <p>
          <strong class="pmx-total">월 {usd(r.total)} USD</strong>{' '}
          {saved > 0.004 ? `— 전부 온디맨드(${usd(allOd)})보다 ${usd(saved)} 싸다(${((saved / allOd) * 100).toFixed(1)}%).` : saved < -0.004 ? `— 전부 온디맨드(${usd(allOd)})보다 ${usd(-saved)} 비싸다.` : `— 전부 온디맨드(${usd(allOd)})와 같다.`}
          {r.k === sw.best ? ' 이 배치 조건에서 가장 싼 약정 대수다.' : ` 이 배치 조건에서 가장 싼 약정은 ${sw.best}대다.`}
        </p>
        {r.spotBlocked ? <p class="pmx-warn">⚠ 배치가 중단되면 안 되므로 스팟 대신 온디맨드로 계산했다.</p> : null}
        {r.unusedHours > 0 ? (
          <p class="pmx-warn">
            ⚠ 약정 중 {r.unusedHours.toLocaleString('ko-KR')} 인스턴스·시간을 쓰지 않았지만 {usd(r.unusedCost)} USD를 그대로 낸다 — 약정은 최소 지불 금액이다({src(f.selfCheck2Line)}).
          </p>
        ) : null}
      </div>

      <figure class="pmx-fig">
        <figcaption>이 조합의 월 비용 구성</figcaption>
        <div class="pmx-stack" aria-hidden="true">
          {segs.filter((s) => s.v > 0).map((s) => (
            <span key={s.key} class={`pmx-seg pmx-${s.key}`} style={{ width: `${(s.v / max) * 100}%` }}></span>
          ))}
        </div>
        <ul class="pmx-parts">
          {segs.map((s) => (
            <li key={s.key}>
              <i class={`pmx-sw pmx-${s.key}`} aria-hidden="true"></i>
              {s.label}: {usd(s.v)} USD
            </li>
          ))}
        </ul>
      </figure>

      <figure class="pmx-fig">
        <figcaption>약정 대수에 따른 월 비용(배치 {r.batchMode === 'spot' ? '스팟' : '온디맨드'})</figcaption>
        <div class="pmx-bars" aria-hidden="true">
          {sw.rows.map((x) => (
            <div key={x.k} class={`pmx-bar${x.k === r.k ? ' pmx-cur' : ''}${x.k === sw.best ? ' pmx-best' : ''}`}>
              <span class="pmx-bar-fill" style={{ height: `${((x.total - floor) / (max - floor)) * 92 + 8}%` }}></span>
              <span class="pmx-bar-k">{x.k}</span>
            </div>
          ))}
        </div>
        <p class="pmx-legend" aria-hidden="true">
          가로: 약정 대수 · 세로: 월 비용(0이 아니라 {usd(floor)} USD부터) · 진한 막대 = 지금 고른 대수 · ★ 가장 쌈({sw.best}대, {usd(sw.rows[sw.best].total)} USD)
        </p>
      </figure>

      <details class="pmx-table-box">
        <summary>같은 내용을 표로 보기</summary>
        <div class="pmx-table-scroll">
          <table class="pmx-table">
            <caption>약정 대수별 월 비용(USD, 모형)</caption>
            <thead>
              <tr>
                <th scope="col">약정 대수</th>
                <th scope="col">월 비용</th>
                <th scope="col">비고</th>
              </tr>
            </thead>
            <tbody>
              {sw.rows.map((x) => (
                <tr key={x.k} aria-current={x.k === r.k ? 'true' : undefined}>
                  <td>{x.k}대</td>
                  <td>{usd(x.total)}</td>
                  <td>
                    {[x.k === sw.best ? '★ 가장 쌈' : '', x.k === r.k ? '◀ 지금' : '', x.k === f.base.count ? '바닥' : ''].filter(Boolean).join(' · ')}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>

      <details class="pmx-assume">
        <summary>이 모형의 가정(실제 AWS와 다른 점)</summary>
        <ul>
          <li>단가·할인율은 원고 워크시트의 예시 숫자다. 실제 할인율은 인스턴스 유형·리전·기간·선결제에 따라 다르고 스팟 가격은 수시로 바뀐다.</li>
          <li>Savings Plans를 "k대를 한 달 내내 쓰는 금액"으로 둔다. 실제 Savings Plans는 시간당 사용 금액($/h)을 약정한다.</li>
          <li>피크 {f.peak.count}대는 한 달 {f.peak.hours}시간 동안 바닥과 함께 돈다. 시간마다 약정이 먼저 덮고, 남는 대수는 온디맨드다.</li>
          <li>배치는 약정과 따로 계산한다. 스팟 중단 뒤 다시 돌리는 시간과 그 비용은 넣지 않는다.</li>
          <li>적정 크기·Graviton·끄기 같은 다른 절감 방법은 다루지 않는다(원고는 "약정보다 적정 크기를 먼저" 하라고 한다).</li>
        </ul>
      </details>
    </section>
  );
}
