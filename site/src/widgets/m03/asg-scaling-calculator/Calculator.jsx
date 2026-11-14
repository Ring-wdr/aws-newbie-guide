// Auto Scaling "이 지표 값이면 몇 대?" 계산기(설명용 모형). 계산은 model.mjs, 수치는 facts.mjs가 원고·정책 파일에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { compute, normalize, presetInput, PRESETS, MODEL_LIMITS, fmt } from './model.mjs';

const POLICY_LABEL = {
  cpu: '대상 추적 — 평균 CPU',
  alb: '대상 추적 — 대상당 요청 수',
  step: '단계 조정 — CPU 경보',
  simple: '단순 조정 — 쿨다운',
  scheduled: '예약 작업',
};

function Slots({ label, count, min, max, kind }) {
  const cells = [];
  for (let i = 1; i <= max; i++) cells.push(i);
  return (
    <div class="as-slots-row">
      <span class="as-slots-label">{label}</span>
      <span class="as-slots" aria-hidden="true">
        {cells.map((i) => (
          <span key={i} class="as-slot" data-on={i <= count ? 'true' : 'false'} data-kind={kind} data-min={i <= min ? 'true' : 'false'}>
            {i <= count ? '■' : ''}
          </span>
        ))}
      </span>
    </div>
  );
}

export default function Calculator({ facts }) {
  const src = (line, file = facts.lesson) => `${file.split('/').pop()}:${line}`;
  const pfile = (k) => facts.files[k];
  const first = PRESETS[0];
  const toRaw = (v) => ({ ...v, min: String(v.min), max: String(v.max), current: String(v.current), metric: String(v.metric), secondAfter: String(v.secondAfter) });
  const [raw, setRaw] = useState(() => toRaw(presetInput(first, facts.asg)));
  const [preset, setPreset] = useState(first.no);
  const x = useMemo(() => normalize(raw, facts.asg), [raw]);
  const r = useMemo(() => compute(x, facts), [x]);
  const set = (patch) => {
    setRaw((o) => ({ ...o, ...patch }));
    setPreset(null);
  };
  const applyPreset = (p) => {
    setRaw(toRaw(presetInput(p, facts.asg)));
    setPreset(p.no);
  };
  const cur = PRESETS.find((p) => p.no === preset);
  const delta = r.desired - x.current;
  const metricLabel = x.policy === 'alb' ? 'ALB 전체 요청 수' : '평균 CPU(%)';
  const policyNote = {
    cpu: `${pfile('cpu')}: 목표 평균 CPU ${fmt(facts.cpu.target)}%`,
    alb: `${pfile('alb')}: 목표 대상당 요청 ${fmt(facts.alb.target)}`,
    step: `${pfile('step')}: ${facts.step.adjustments.map((s) => `초과 폭 [${s.lower ?? '−∞'}, ${s.upper ?? '∞'}) → ${s.adjust >= 0 ? '+' : ''}${s.adjust}`).join(', ')}. 경보 임계값 CPU ${facts.step.threshold}%(${src(facts.step.thresholdLine)})`,
    simple: `${pfile('simple')}: 경보마다 +${facts.simple.adjust}, 쿨다운 ${facts.simple.cooldown}초`,
    scheduled: `${pfile('scheduled')}: ${facts.scheduled.name}(${facts.scheduled.recurrence} ${facts.scheduled.timeZone}) — min ${facts.scheduled.min}, desired ${facts.scheduled.desired}`,
  }[x.policy];

  return (
    <section class="as" aria-labelledby="as-title">
      <div class="as-head">
        <h4 id="as-title">조정 정책 계산기: 이 지표 값이면 몇 대?</h4>
        <span class="as-model">모형</span>
      </div>
      <p class="as-intro">
        <strong>설명용 모형이다.</strong> Auto Scaling을 실행하지 않는다(에뮬레이터는 조정 정책이 501이다). 아래 워크시트와 같은 규칙으로 새 희망 용량을 계산한다. 대상 추적은 시험 풀이용 근사식이며({src(facts.asg.line)}), AWS는 정확한 식을 공개하지 않는다.
      </p>

      <fieldset class="as-presets">
        <legend>워크시트 문항으로 채우기</legend>
        <div class="as-row">
          {PRESETS.map((p) => (
            <button type="button" key={p.no} data-preset={p.no} aria-pressed={preset === p.no ? 'true' : 'false'} onClick={() => applyPreset(p)}>
              {p.no}번
            </button>
          ))}
        </div>
        <p class="as-hint">{cur ? `${cur.no}번: ${facts.questions[cur.no].text} — 원고 정답 ${facts.answers[cur.no].n}대(${src(facts.answers[cur.no].line)})` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="as-controls">
        <fieldset class="as-field as-radios">
          <legend>조정 정책</legend>
          {Object.entries(POLICY_LABEL).map(([k, label]) => (
            <label key={k}>
              <input type="radio" name="as-policy" value={k} checked={x.policy === k} onChange={() => set({ policy: k })} /> {label}
            </label>
          ))}
          <small>{policyNote}</small>
        </fieldset>
        <div class="as-field">
          <div class="as-nums">
            <label>
              <span>min</span>
              <input type="number" inputMode="numeric" min="0" max={MODEL_LIMITS.maxSize} step="1" value={raw.min} data-field="min" onInput={(e) => set({ min: e.currentTarget.value })} />
            </label>
            <label>
              <span>max</span>
              <input type="number" inputMode="numeric" min="0" max={MODEL_LIMITS.maxSize} step="1" value={raw.max} data-field="max" onInput={(e) => set({ max: e.currentTarget.value })} />
            </label>
            <label>
              <span>현재 대수</span>
              <input type="number" inputMode="numeric" min="0" max={MODEL_LIMITS.maxSize} step="1" value={raw.current} data-field="current" onInput={(e) => set({ current: e.currentTarget.value })} />
            </label>
          </div>
          <small>
            워크시트 ASG는 min {facts.asg.min} / max {facts.asg.max}({src(facts.asg.line)}). 모형은 min ≤ 현재 ≤ max로 맞추고 {MODEL_LIMITS.maxSize}대까지만 받는다(화면 범위). 지금 min {x.min} · 현재 {x.current} · max {x.max}
          </small>
          {x.policy === 'cpu' || x.policy === 'alb' || x.policy === 'step' ? (
            <label class="as-metric">
              <span>{metricLabel}</span>
              <input type="number" inputMode="decimal" min="0" max={x.policy === 'alb' ? MODEL_LIMITS.requests : MODEL_LIMITS.cpu} step={x.policy === 'alb' ? '100' : '1'} value={raw.metric} data-field="metric" onInput={(e) => set({ metric: e.currentTarget.value })} />
            </label>
          ) : null}
          {x.policy === 'simple' ? (
            <div class="as-sub">
              <label class="as-check">
                <input type="checkbox" data-field="secondAlarm" checked={x.secondAlarm} onChange={(e) => set({ secondAlarm: e.currentTarget.checked })} /> 경보가 한 번 더 울린다
              </label>
              <label class="as-metric">
                <span>첫 조정 뒤 몇 초 뒤에(초)</span>
                <input type="number" inputMode="numeric" min="0" max={MODEL_LIMITS.seconds} step="10" value={raw.secondAfter} disabled={!x.secondAlarm} data-field="secondAfter" onInput={(e) => set({ secondAfter: e.currentTarget.value })} />
              </label>
            </div>
          ) : null}
        </div>
      </div>

      <div class="as-result" role="status" aria-live="polite" aria-atomic="true" data-change={delta > 0 ? 'out' : delta < 0 ? 'in' : 'same'}>
        <p>
          <span class="as-tag">
            새 희망 용량 {r.desired}대 <span aria-hidden="true">{delta > 0 ? '▲' : delta < 0 ? '▼' : '='}</span> ({delta > 0 ? `${delta}대 확장` : delta < 0 ? `${-delta}대 축소` : '변화 없음'})
          </span>{' '}
          현재 {x.current}대 → {r.desired}대{r.min !== x.min ? `, min ${x.min} → ${r.min}` : ''}.
        </p>
        <ol class="as-lines">
          {r.lines.map((l, i) => (
            <li key={i}>{l}</li>
          ))}
        </ol>
        {r.scaleIn ? <p class="as-note">실제 축소(scale-in)는 이보다 보수적이라 여러 단계에 걸쳐 천천히 줄어든다({src(facts.answers[3].line)}).</p> : null}
      </div>

      <figure class="as-chart">
        <Slots label={`지금 ${x.current}대`} count={x.current} min={x.min} max={x.max} kind="now" />
        <Slots label={`조정 후 ${r.desired}대`} count={r.desired} min={r.min} max={r.max} kind="after" />
        <figcaption class="as-legend" aria-hidden="true">
          <span><i class="as-slot" data-on="true">■</i> 인스턴스</span>
          <span><i class="as-slot" data-on="false"></i> 빈 자리(max까지)</span>
          <span><i class="as-slot" data-on="false" data-min="true"></i> 굵은 아래 선 = min 안쪽</span>
        </figcaption>
      </figure>

      <details class="as-table-box">
        <summary>같은 내용을 표로 보기</summary>
        <div class="as-table-scroll">
          <table class="as-table">
            <caption class="sr-only">조정 계산(모형)</caption>
            <tbody>
              <tr><th scope="row">정책</th><td>{POLICY_LABEL[x.policy]}</td></tr>
              <tr><th scope="row">정책 값</th><td>{policyNote}</td></tr>
              <tr><th scope="row">min / max</th><td>{x.min} / {x.max}{r.min !== x.min ? ` (예약 작업 뒤 min ${r.min})` : ''}</td></tr>
              <tr><th scope="row">현재 대수</th><td>{x.current}</td></tr>
              {r.lines.map((l, i) => (
                <tr key={i}><th scope="row">계산 {i + 1}</th><td>{l}</td></tr>
              ))}
              <tr><th scope="row">새 희망 용량</th><td>{r.desired}대</td></tr>
            </tbody>
          </table>
        </div>
      </details>

      <details class="as-assume">
        <summary>이 모형의 가정(실제 AWS와 다른 점)</summary>
        <ul>
          <li>대상 추적은 근사식 ⌈현재 대수 × 현재 지표 ÷ 목표값⌉을 min/max로 자른다({src(facts.asg.line)}). 실제 AWS는 정확한 식을 공개하지 않고, 축소는 더 천천히 일어난다.</li>
          <li>계산은 한 번의 판단만 본다. 인스턴스 워밍업({facts.cpu.warmup ?? '—'}초, {pfile('cpu')}), 지표 수집 주기, 경보 평가 기간, 부팅 시간은 다루지 않는다.</li>
          <li>단순 조정은 두 번째 경보가 쿨다운({facts.simple.cooldown}초)보다 <strong>먼저</strong> 오면 무시하고, 쿨다운과 같거나 늦으면 다시 조정한다(경계를 어느 쪽으로 둘지는 원고에 없어 모형이 정했다).</li>
          <li>단계 조정 구간은 하한 포함·상한 미포함이다(06-auto-scaling.md의 "60 이상 80 미만이면 +1"). 이 정책은 확장 전용이라 임계값 아래에서는 아무 일도 없다.</li>
          <li>여러 정책이 함께 있으면 ASG는 가장 큰 용량을 주는 정책을 따른다({src(facts.largestLine)}). 모형은 정책 하나씩 계산한다.</li>
          <li>워크시트 9번(PercentChangeInCapacity)과 12번(종료 정책)은 이 계산기에 넣지 않았다.</li>
        </ul>
      </details>
    </section>
  );
}
