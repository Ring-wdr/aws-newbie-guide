// CloudWatch 알람 상태 평가(설명용 모형). 계산은 model.mjs, 수치·문구는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { evaluate, normalize, parsePoints, formatPoints, sampleValue, explain, pointLabel, formatSec, average, OPS, TMD_KEYS, MODEL_LIMITS } from './model.mjs';

const STATE_MARK = { OK: '● OK', ALARM: '▲ ALARM', INSUFFICIENT_DATA: '? INSUFFICIENT_DATA' };
const STATE_SHORT = { OK: 'OK', ALARM: 'ALARM', INSUFFICIENT_DATA: '데이터 부족' };
const AS_MARK = { breach: '▲', ok: '●', missing: '○' };
const AS_WORD = { breach: '위반', ok: '정상', missing: '누락' };

// 아래 구간 값들은 원고에 없는 모형 값이다(임계값 500·연산자는 lab02에서 읽은 값).
const MODEL_SPIKE_POINTS = [300, 900, 300, 300, 800, 850];
const MODEL_SPIKE_N = 3;
const MODEL_SPIKE_M = 2;
// 하트비트: 정상일 때 1분마다 1을 보내다가 끊긴다(값 1과 임계값 1·LessThanThreshold는 모형 값).
const MODEL_HEARTBEAT_POINTS = [1, 1, 1, null, null, null];

export default function Evaluator({ facts }) {
  const src = (line) => `${facts.lesson.split('/').pop().replace(/-.*$/, '')}:${line}`;
  const lab = facts.lab02;
  const labPoint = average(lab.values);
  const presets = [
    {
      id: 'lab02',
      label: `lab02: N=${lab.n}, M=${lab.m}, 값 ${labPoint}`,
      note: `lab02 명령(${src(lab.cmdLine)}): Period ${lab.periodSec}초, 임계값 ${lab.threshold}, ${lab.op}, ${lab.tmd}. 게시한 ${lab.values.join('·')}의 ${lab.statistic} = ${labPoint}(${src(lab.valuesLine)}, 이유 ${src(lab.reason.line)})`,
      v: { threshold: lab.threshold, op: lab.op, n: lab.n, m: lab.m, tmd: lab.tmd, periodSec: lab.periodSec, points: [labPoint] },
    },
    {
      id: 'spike',
      label: `M of N: 최근 ${MODEL_SPIKE_N}개 중 ${MODEL_SPIKE_M}개`,
      note: `규칙 ${src(facts.mofn.line)}. 임계값 ${lab.threshold}·연산자는 lab02, N·M·구간 값은 모형 값`,
      v: { threshold: lab.threshold, op: lab.op, n: MODEL_SPIKE_N, m: MODEL_SPIKE_M, tmd: 'missing', periodSec: facts.periods.standardSec, points: MODEL_SPIKE_POINTS },
    },
    {
      id: 'heartbeat',
      label: `스스로 확인 2: 하트비트가 끊김`,
      note: `${formatSec(facts.heartbeat.periodSec)}마다 하트비트(${src(facts.heartbeat.line)}), 원고의 답은 ${facts.heartbeat.tmd}(${src(facts.heartbeat.answerLine)}). 값 1·임계값 1·LessThanThreshold는 모형 값 — TreatMissingData를 바꿔 비교해 본다`,
      v: { threshold: 1, op: 'LessThanThreshold', n: 1, m: 1, tmd: 'missing', periodSec: facts.heartbeat.periodSec, points: MODEL_HEARTBEAT_POINTS },
    },
  ];
  const periodChoices = [...facts.periods.highRes, facts.periods.standardSec, 5 * facts.periods.standardSec];

  const toRaw = (v) => ({ threshold: String(v.threshold), op: v.op, n: String(v.n), m: String(v.m), tmd: v.tmd, periodSec: v.periodSec, text: formatPoints(v.points) });
  const [raw, setRaw] = useState(toRaw(presets[0].v));
  const [preset, setPreset] = useState('lab02');
  const parsed = useMemo(() => parsePoints(raw.text), [raw.text]);
  const cfg = useMemo(() => normalize({ ...raw, points: parsed.points, initial: lab.initialState }), [raw, parsed]);
  const res = useMemo(() => evaluate(cfg), [cfg]);
  const [at, setAt] = useState(-1); // -1 = 마지막 구간
  const last = res.steps.length - 1;
  const cur = at < 0 || at > last ? last : at;
  const step = res.steps[cur];

  const set = (patch) => {
    setRaw((r) => ({ ...r, ...patch }));
    setPreset('');
    setAt(-1);
  };
  const applyPreset = (p) => {
    setRaw(toRaw(p.v));
    setPreset(p.id);
    setAt(-1);
  };
  const append = (v) => {
    const pts = parsed.points.length >= MODEL_LIMITS.maxPoints ? parsed.points.slice(1) : parsed.points;
    set({ text: formatPoints([...pts, v]) });
  };
  const dropLast = () => set({ text: formatPoints(parsed.points.slice(0, -1)) });
  const sym = OPS[cfg.op].sym;

  return (
    <section class="cwa" aria-labelledby="cwa-title">
      <div class="cwa-head">
        <h4 id="cwa-title">알람 상태 평가기</h4>
        <span class="cwa-model">모형</span>
      </div>
      <p class="cwa-intro">
        <strong>설명용 모형이다.</strong> CloudWatch나 에뮬레이터를 부르지 않고, 구간마다 "{facts.mofn.text}"({src(facts.mofn.line)}) 규칙으로 상태를 계산해 보여 준다. 알람은 <strong>{lab.initialState}</strong>로 시작한다({src(lab.initialLine)}).
      </p>

      <fieldset class="cwa-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="cwa-row">
          {presets.map((p) => (
            <button type="button" key={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => applyPreset(p)} data-preset={p.id}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="cwa-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="cwa-controls">
        <label class="cwa-field">
          <span>임계값(Threshold)</span>
          <input type="number" step="any" value={raw.threshold} data-field="threshold" onInput={(e) => set({ threshold: e.currentTarget.value })} />
        </label>
        <label class="cwa-field">
          <span>비교(ComparisonOperator)</span>
          <select value={raw.op} data-field="op" onChange={(e) => set({ op: e.currentTarget.value })}>
            {Object.entries(OPS).map(([k, o]) => (
              <option value={k} key={k}>
                {o.sym} {k}
              </option>
            ))}
          </select>
        </label>
        <label class="cwa-field">
          <span>구간 길이(Period)</span>
          <select value={String(raw.periodSec)} data-field="period" aria-describedby="cwa-period-hint" onChange={(e) => set({ periodSec: Number(e.currentTarget.value) })}>
            {[...new Set([...periodChoices, raw.periodSec])].sort((a, b) => a - b).map((s) => (
              <option value={String(s)} key={s}>
                {formatSec(s)}
                {facts.periods.highRes.includes(s) ? '(고해상도 지표만)' : ''}
              </option>
            ))}
          </select>
          <small id="cwa-period-hint">10초·30초 알람은 고해상도 지표에만({src(facts.periods.highResLine)}). 이 모형에서 구간 길이는 시각 표시에만 쓰인다.</small>
        </label>
        <label class="cwa-field">
          <span>평가 구간 수 N(EvaluationPeriods)</span>
          <input type="number" inputMode="numeric" min="1" max={MODEL_LIMITS.maxN} step="1" value={raw.n} data-field="n" aria-describedby="cwa-n-hint" onInput={(e) => set({ n: e.currentTarget.value })} />
          <small id="cwa-n-hint">
            지금 N={cfg.n}: 최근 {formatSec(cfg.n * cfg.periodSec)}를 본다. 화면 범위 1~{MODEL_LIMITS.maxN}(모형 값)
          </small>
        </label>
        <label class="cwa-field">
          <span>ALARM에 필요한 위반 수 M(DatapointsToAlarm)</span>
          <input type="number" inputMode="numeric" min="1" max={cfg.n} step="1" value={raw.m} data-field="m" aria-describedby="cwa-m-hint" onInput={(e) => set({ m: e.currentTarget.value })} />
          <small id="cwa-m-hint">지금 M={cfg.m}. M은 N을 넘을 수 없다.</small>
        </label>
        <fieldset class="cwa-field cwa-radios">
          <legend>데이터가 없을 때(TreatMissingData)</legend>
          {TMD_KEYS.map((k) => (
            <label key={k}>
              <input type="radio" name="cwa-tmd" value={k} checked={raw.tmd === k} onChange={() => set({ tmd: k })} /> <code>{k}</code> — {facts.tmd.labels[k]}
            </label>
          ))}
          <small>원고 {src(facts.tmd.line)}</small>
        </fieldset>
      </div>

      <div class="cwa-data">
        <label class="cwa-field">
          <span>구간별 값(쉼표로 구분, 누락은 -)</span>
          <input type="text" value={raw.text} data-field="points" spellcheck={false} autocomplete="off" aria-describedby="cwa-points-hint" onInput={(e) => set({ text: e.currentTarget.value })} />
          <small id="cwa-points-hint">
            구간마다 통계 값 하나(최대 {MODEL_LIMITS.maxPoints}구간, 모형 범위).
            {parsed.bad.length ? ` 숫자가 아니라 뺀 칸: ${parsed.bad.join(', ')}.` : ''}
            {parsed.cut ? ` 앞의 ${MODEL_LIMITS.maxPoints}구간만 본다.` : ''}
          </small>
        </label>
        <div class="cwa-row" role="group" aria-label="구간 값 덧붙이기">
          <button type="button" data-add="breach" onClick={() => append(sampleValue(cfg, true))}>+ 위반 값({sampleValue(cfg, true)})</button>
          <button type="button" data-add="ok" onClick={() => append(sampleValue(cfg, false))}>+ 정상 값({sampleValue(cfg, false)})</button>
          <button type="button" data-add="missing" onClick={() => append(null)}>+ 누락</button>
          <button type="button" data-add="drop" onClick={dropLast} disabled={!parsed.points.length}>마지막 구간 지우기</button>
        </div>
      </div>

      <p class="cwa-result" data-state={res.final} role="status" aria-live="polite" aria-atomic="true">
        <span class="cwa-badge" data-state={res.final}>{STATE_MARK[res.final]}</span>{' '}
        {res.steps.length
          ? `구간 ${res.steps.length}개를 지난 마지막 상태. 상태가 ${res.changes}번 바뀌었다 — 액션은 상태가 바뀔 때만 실행된다(${src(facts.actionLine)}).`
          : '아직 구간 값이 없다 — 처음 상태 그대로다.'}
      </p>

      {res.steps.length ? (
        <div class="cwa-steps">
          <label class="cwa-field cwa-at">
            <span>평가 시점 고르기</span>
            <input
              type="range"
              min="0"
              max={last}
              step="1"
              value={cur}
              data-field="at"
              aria-valuetext={`구간 ${cur + 1}, ${formatSec(step.t)}: ${step.state}`}
              onInput={(e) => setAt(Number(e.currentTarget.value))}
            />
          </label>
          <p class="cwa-now" aria-live="polite">
            <strong>
              구간 {cur + 1}/{last + 1}({formatSec(step.t)})
            </strong>{' '}
            {pointLabel(step, cfg)}. {explain(step, cfg)}
          </p>

          <ol class="cwa-tiles" aria-hidden="true">
            {res.steps.map((s) => {
              const inWin = s.i >= step.from && s.i <= cur;
              return (
                <li key={s.i} class={`cwa-tile${inWin ? ' cwa-in' : ''}${s.i === cur ? ' cwa-cur' : ''}`} data-as={s.as}>
                  <span class="cwa-t">
                    {s.i + 1}
                    {inWin ? ' 창' : ''}
                  </span>
                  <span class="cwa-v">
                    {AS_MARK[s.as]} {s.value === null ? '없음' : s.value}
                  </span>
                  <span class="cwa-badge cwa-small" data-state={s.state}>
                    {STATE_SHORT[s.state]}
                    {s.changed ? ' ⚑' : ''}
                  </span>
                </li>
              );
            })}
          </ol>
          <p class="cwa-legend" aria-hidden="true">
            ▲ 위반 · ● 정상 · ○ 누락(세지 않음) · 점선 테두리 "창" = 지금 평가하는 최근 N개 · ⚑ 상태가 바뀜(액션 실행) · 판정 {sym} {cfg.threshold}
          </p>
        </div>
      ) : null}

      <details class="cwa-table-box" open>
        <summary>같은 내용을 표로 보기</summary>
        <div class="cwa-table-scroll">
          <table class="cwa-table">
            <caption class="sr-only">구간마다 알람 평가 결과(모형)</caption>
            <thead>
              <tr>
                <th scope="col">구간</th>
                <th scope="col">값과 판정</th>
                <th scope="col">창의 위반 / 필요</th>
                <th scope="col">상태</th>
              </tr>
            </thead>
            <tbody>
              {res.steps.map((s) => (
                <tr key={s.i} aria-current={s.i === cur ? 'step' : undefined}>
                  <td>
                    {s.i + 1}({formatSec(s.t)}){s.i === cur ? <span class="cwa-here"> ◀ 지금</span> : null}
                  </td>
                  <td>
                    {AS_MARK[s.as]} {s.value === null ? '없음' : s.value} — {s.value === null ? (s.treated ? `${AS_WORD[s.as]}로 취급` : '세지 않음') : AS_WORD[s.as]}
                  </td>
                  <td>
                    {s.breaches} / {cfg.m}
                  </td>
                  <td>
                    {s.changed ? `${s.prev} → ${s.state} (액션)` : `${s.state} (그대로)`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>

      <details class="cwa-assume">
        <summary>이 모형의 가정(실제 CloudWatch와 다른 점)</summary>
        <ul>
          <li>구간마다 데이터 포인트는 그 구간의 통계 값 하나이거나 없다(누락). lab02는 한 번에 게시한 값 세 개의 평균 {labPoint}을 하나의 데이터 포인트로 판정했다({src(lab.reason.line)}).</li>
          <li>구간이 끝날 때마다 곧바로 평가한다. 실제 알람 평가는 분 단위로 늦을 수 있다(원고 "실제 AWS에서는").</li>
          <li>창(최근 N개) 안에서 위반이 M개 이상이면 ALARM, 아니면 셀 수 있는 데이터가 하나라도 있으면 OK, 하나도 없으면 INSUFFICIENT_DATA(ignore면 직전 상태 유지).</li>
          <li>창 안에 누락이 섞였을 때 실제 CloudWatch의 판정 규칙은 이보다 복잡하다(원고가 다루지 않는다). 모형은 창 안의 데이터만 센다.</li>
          <li>알람을 만든 뒤의 구간만 센다. N개가 차기 전에는 있는 구간만으로 판정한다.</li>
          <li>임계값과 같은 값은 "보다 큼/작음"(Threshold)이면 위반이 아니고 "같거나"(OrEqualTo)면 위반이다.</li>
        </ul>
      </details>
    </section>
  );
}
