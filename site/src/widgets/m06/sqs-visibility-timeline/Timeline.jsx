// SQS 가시성 타임아웃 타임라인(설명용 모형). 계산은 model.mjs, 수치는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { simulate, normalize, formatDuration, describe, summarize, MODEL_MAX_RECEIVE_RANGE, MAX_RECEIVES_SHOWN } from './model.mjs';

const RESULT_LABEL = { deleted: '삭제됨', dlq: 'DLQ로 옮겨짐', looping: '계속 반복' };
const KIND_LABEL = { receive: '받음', 'hidden-end': '다시 보임', delete: '삭제', fail: '처리 실패', dlq: 'DLQ 이동', stop: '반복(생략)' };
const END_LABEL = { delete: '삭제', fail: '실패', cut: '처리 중' };

// 처리 시간은 SQS 설정이 아니라 모형 입력이다. 아래 두 값(10초, 1초)은 원고에 없는 모형 값이다.
const MODEL_PROCESSING_DEFAULT = 10;
const MODEL_PROCESSING_FAIL_FAST = 1;

export default function Timeline({ facts }) {
  const limits = { defaultSec: facts.timeout.defaultSec, minSec: facts.timeout.minSec, maxSec: facts.timeout.maxSec };
  const src = (line) => `${facts.lesson.split('/').pop()}:${line}`;
  const presets = [
    {
      id: 'default',
      label: `기본값: 타임아웃 ${formatDuration(limits.defaultSec)}`,
      note: `가시성 타임아웃 기본값(${src(facts.timeout.line)}), 처리 시간 ${MODEL_PROCESSING_DEFAULT}초(모형 값)`,
      v: { visibility: limits.defaultSec, processing: MODEL_PROCESSING_DEFAULT, outcome: 'success', redrive: false, maxReceiveCount: facts.lab02.maxReceiveCount },
    },
    {
      id: 'self-check',
      label: `스스로 확인 1번: 처리 ${formatDuration(facts.selfCheck.processingSec)}`,
      note: `처리 ${formatDuration(facts.selfCheck.processingSec)}, 타임아웃 ${formatDuration(facts.selfCheck.visibilitySec)}(${src(facts.selfCheck.line)})`,
      v: { visibility: facts.selfCheck.visibilitySec, processing: facts.selfCheck.processingSec, outcome: 'success', redrive: false, maxReceiveCount: facts.lab02.maxReceiveCount },
    },
    {
      id: 'lab02',
      label: `lab02 독 메시지: maxReceiveCount=${facts.lab02.maxReceiveCount}`,
      note: `maxReceiveCount=${facts.lab02.maxReceiveCount}(${src(facts.lab02.maxReceiveLine)}), 타임아웃 ${formatDuration(facts.lab02.visibilitySec)}(${src(facts.lab02.visibilityLine)}), 처리 ${MODEL_PROCESSING_FAIL_FAST}초 뒤 실패(모형 값)`,
      v: { visibility: facts.lab02.visibilitySec, processing: MODEL_PROCESSING_FAIL_FAST, outcome: 'fail', redrive: true, maxReceiveCount: facts.lab02.maxReceiveCount },
    },
  ];

  const [raw, setRaw] = useState({ ...presets[0].v, visibility: String(presets[0].v.visibility), processing: String(presets[0].v.processing), maxReceiveCount: String(presets[0].v.maxReceiveCount) });
  const [preset, setPreset] = useState('default');
  const input = useMemo(() => normalize(raw, limits), [raw.visibility, raw.processing, raw.maxReceiveCount, raw.redrive, raw.outcome]);
  const sim = useMemo(() => simulate(input), [input]);
  const [step, setStep] = useState(-1); // -1 = 끝까지 모두
  const last = sim.events.length - 1;
  const cur = step < 0 || step > last ? last : step;
  const now = sim.events[cur].t;
  const scale = Math.max(sim.end, 1);
  const pct = (t) => `${(Math.min(t, scale) / scale) * 100}%`;

  const set = (patch) => {
    setRaw((r) => ({ ...r, ...patch }));
    setPreset('');
    setStep(-1);
  };
  const applyPreset = (p) => {
    setRaw({ ...p.v, visibility: String(p.v.visibility), processing: String(p.v.processing), maxReceiveCount: String(p.v.maxReceiveCount) });
    setPreset(p.id);
    setStep(-1);
  };
  // 지금 단계까지 일어난 사건만 그린다(같은 시각의 사건도 순서대로).
  const seen = sim.events.slice(0, cur + 1);
  const received = new Set(seen.filter((e) => e.kind === 'receive').map((e) => e.worker));
  const finished = new Set(seen.filter((e) => e.kind === 'delete' || e.kind === 'fail').map((e) => e.worker));
  const lanes = sim.lanes.filter((l) => received.has(l.worker));

  return (
    <section class="vt" aria-labelledby="vt-title">
      <div class="vt-head">
        <h4 id="vt-title">가시성 타임아웃 타임라인</h4>
        <span class="vt-model">모형</span>
      </div>
      <p class="vt-intro">
        <strong>설명용 모형이다.</strong> 실제 SQS나 에뮬레이터를 실행하지 않고, 아래 값으로 메시지 하나의 일생을 계산해 보여 준다. 실제 동작은 아래 "직접 해 보기"의 lab에서 관찰한다.
      </p>

      <fieldset class="vt-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="vt-row">
          {presets.map((p) => (
            <button type="button" key={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => applyPreset(p)} data-preset={p.id}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="vt-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="vt-controls">
        <label class="vt-field">
          <span>가시성 타임아웃(초)</span>
          <input type="number" inputMode="numeric" min={limits.minSec} max={limits.maxSec} step="1" value={raw.visibility} data-field="visibility" aria-describedby="vt-vis-hint" onInput={(e) => set({ visibility: e.currentTarget.value })} />
          <small id="vt-vis-hint">
            원고: 기본 {formatDuration(limits.defaultSec)}, {formatDuration(limits.minSec)} ~ {formatDuration(limits.maxSec)}({src(facts.timeout.line)}). 지금 {formatDuration(input.visibility)}
          </small>
        </label>
        <label class="vt-field">
          <span>처리 시간(초)</span>
          <input type="number" inputMode="numeric" min="0" max={limits.maxSec} step="1" value={raw.processing} data-field="processing" aria-describedby="vt-proc-hint" onInput={(e) => set({ processing: e.currentTarget.value })} />
          <small id="vt-proc-hint">SQS 설정이 아니라 워커가 메시지 하나를 처리하는 시간. 지금 {formatDuration(input.processing)}</small>
        </label>
        <fieldset class="vt-field vt-radios">
          <legend>처리 결과</legend>
          <label>
            <input type="radio" name="vt-outcome" value="success" checked={raw.outcome === 'success'} onChange={() => set({ outcome: 'success' })} /> 성공하면 DeleteMessage
          </label>
          <label>
            <input type="radio" name="vt-outcome" value="fail" checked={raw.outcome === 'fail'} onChange={() => set({ outcome: 'fail' })} /> 매번 실패(독 메시지) — 지우지 않음
          </label>
        </fieldset>
        <div class="vt-field">
          <label class="vt-check">
            <input type="checkbox" checked={raw.redrive} data-field="redrive" onChange={(e) => set({ redrive: e.currentTarget.checked })} /> 재드라이브 정책(DLQ) 사용
          </label>
          <label class="vt-sub">
            <span>maxReceiveCount</span>
            <input type="number" inputMode="numeric" min={MODEL_MAX_RECEIVE_RANGE.min} max={MODEL_MAX_RECEIVE_RANGE.max} step="1" value={raw.maxReceiveCount} disabled={!raw.redrive} data-field="maxReceiveCount" aria-describedby="vt-mrc-hint" onInput={(e) => set({ maxReceiveCount: e.currentTarget.value })} />
          </label>
          <small id="vt-mrc-hint">
            원고 lab02의 값은 {facts.lab02.maxReceiveCount}({src(facts.lab02.maxReceiveLine)}). 이 모형은 {MODEL_MAX_RECEIVE_RANGE.min}~{MODEL_MAX_RECEIVE_RANGE.max}만 받는다(AWS 한도가 아니라 화면 범위).
          </small>
        </div>
      </div>

      <p class="vt-result" data-result={sim.result} role="status" aria-live="polite" aria-atomic="true">
        <span class="vt-tag">
          <span aria-hidden="true">{sim.result === 'deleted' ? (sim.duplicates ? '△ ' : '✓ ') : sim.result === 'dlq' ? '⇢ ' : '↻ '}</span>
          {RESULT_LABEL[sim.result]}
          {sim.result === 'deleted' && sim.duplicates ? ' (중복 처리)' : ''}
        </span>{' '}
        {summarize(sim, input)}
      </p>

      <div class="vt-steps" role="group" aria-label="단계별로 보기">
        <div class="vt-row">
          <button type="button" data-step="first" onClick={() => setStep(0)} disabled={cur === 0}>처음</button>
          <button type="button" data-step="prev" onClick={() => setStep(Math.max(0, cur - 1))} disabled={cur === 0}>이전 단계</button>
          <button type="button" data-step="next" onClick={() => setStep(Math.min(last, cur + 1))} disabled={cur === last}>다음 단계</button>
          <button type="button" data-step="last" onClick={() => setStep(-1)} disabled={cur === last}>끝까지</button>
        </div>
        <p class="vt-now" aria-live="polite">
          <strong>
            단계 {cur + 1}/{last + 1}
          </strong>{' '}
          {describe(sim.events[cur], input)}
        </p>
      </div>

      <figure class="vt-chart">
        <div class="vt-legend" aria-hidden="true">
          <span><i class="vt-sw vt-sw-hidden"></i>안 보임(가시성 타임아웃)</span>
          <span><i class="vt-sw vt-sw-work"></i>워커가 처리 중</span>
        </div>
        <ol class="vt-lanes" aria-label={`워커별 막대, 0초부터 ${formatDuration(sim.end)}까지(지금 ${formatDuration(now)})`}>
          {lanes.map((l) => {
            const hidEnd = Math.min(l.visibleAt, now, sim.end);
            const workEnd = Math.min(l.end, now);
            const done = finished.has(l.worker);
            const status = done ? END_LABEL[l.endKind] : '처리 중';
            return (
              <li class="vt-lane" key={l.worker}>
                <span class="vt-lane-label">
                  워커 {l.worker} · {formatDuration(l.start)}에 받음 · <span class="vt-status" data-status={done ? l.endKind : 'busy'}>{status}{done ? `(${formatDuration(l.finish)})` : ''}</span>
                </span>
                <span class="vt-track" aria-hidden="true">
                  <span class="vt-seg vt-seg-hidden" style={{ left: pct(l.start), width: `calc(${pct(hidEnd)} - ${pct(l.start)})` }}></span>
                  <span class="vt-seg vt-seg-work" style={{ left: pct(l.start), width: `calc(${pct(workEnd)} - ${pct(l.start)})` }}></span>
                  <span class="vt-now-line" style={{ left: pct(now) }}></span>
                </span>
              </li>
            );
          })}
        </ol>
        <figcaption class="vt-axis" aria-hidden="true">
          <span>0초</span>
          <span>{formatDuration(sim.end)}</span>
        </figcaption>
      </figure>

      <details class="vt-table-box" open>
        <summary>같은 내용을 표로 보기</summary>
        <div class="vt-table-scroll">
          <table class="vt-table">
            <caption class="sr-only">메시지 하나의 사건 순서(모형)</caption>
            <thead>
              <tr>
                <th scope="col">단계</th>
                <th scope="col">일</th>
                <th scope="col">설명</th>
              </tr>
            </thead>
            <tbody>
              {sim.events.map((e, i) => (
                <tr key={i} aria-current={i === cur ? 'step' : undefined} class={i > cur ? 'vt-future' : undefined}>
                  <td>
                    {i + 1}
                    {i === cur ? <span class="vt-here"> ◀ 지금</span> : null}
                  </td>
                  <td>{KIND_LABEL[e.kind]}</td>
                  <td>{describe(e, input)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>

      <details class="vt-assume">
        <summary>이 모형의 가정</summary>
        <ul>
          <li>메시지가 보이면 놀고 있는 워커가 곧바로 받아 간다(폴링 대기 0초).</li>
          <li>처리 시간과 타임아웃이 같으면 메시지가 다시 보이는 쪽을 먼저 둔다 — 원고대로 타임아웃은 처리 시간보다 <strong>길게</strong> 잡는다.</li>
          <li>재드라이브 정책이 있으면 이미 maxReceiveCount번 받아 간 메시지를 다음에 받으려는 순간 DLQ로 옮긴다(lab02에서 관찰한 순서).</li>
          <li>처리를 끝낸 워커의 DeleteMessage는 성공한다고 둔다. 메시지 보존 기간과 ChangeMessageVisibility는 다루지 않는다.</li>
          <li>재드라이브 정책이 없으면 수신을 {MAX_RECEIVES_SHOWN}번까지만 펼친다(화면의 상한).</li>
        </ul>
      </details>
    </section>
  );
}
