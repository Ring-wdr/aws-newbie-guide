// Athena 스캔량 어림(설명용 모형). 계산은 model.mjs, 수치는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { scan, normalize, formatBytes, formatPct, evenPartitions, TB, COMPRESSION_CHOICES } from './model.mjs';

// 스스로 확인 1의 "1년치"를 하루 단위 파티션 365개로 나눈다(모형 해석). 쓰는 열 2개(store·amount)는 "매장별 매출"에서 읽은 해석이다.
const MODEL_DAYS_PER_YEAR = 365;
const MODEL_SELF_CHECK_COLUMNS = ['store', 'amount'];

export default function Estimator({ facts: f }) {
  const src = (line) => `04:${line}`;
  const lab = f.lab05;
  const labParts = lab.files.map((x) => x.bytes);
  const yearParts = useMemo(() => evenPartitions(f.selfCheck.tb * TB, MODEL_DAYS_PER_YEAR), []);
  const C = f.columns.length;
  const presets = [
    {
      id: 'lab05-all',
      label: 'lab05: 필터 없이 전체(에뮬레이터와 같은 양)',
      note: `파일 ${lab.files.map((x) => x.bytes).join('·')}바이트(${src(lab.files[0].line)}), 기록된 ScannedBytes ${lab.scannedBytes}(${src(lab.scannedLine)})`,
      data: 'lab',
      v: { filter: false, days: 1, format: 'json', read: 1, compression: 1, cutoff: true },
    },
    {
      id: 'lab05-dt',
      label: `lab05: WHERE dt = '${lab.query.dt}'(실제 Athena)`,
      note: `실제 Athena는 dt=${lab.query.dt}/ 폴더만 읽는다(${src(lab.query.line)}). 쓰는 열은 ${lab.query.column} 하나`,
      data: 'lab',
      v: { filter: true, days: 1, format: 'json', read: 1, compression: 1, cutoff: true },
    },
    {
      id: 'self-check',
      label: `스스로 확인 1: ${f.selfCheck.tb} TB ${f.selfCheck.format}, 최근 ${f.selfCheck.days}일`,
      note: `${src(f.selfCheck.line)}. 1년 = 파티션 ${MODEL_DAYS_PER_YEAR}개(같은 크기), 쓰는 열 ${MODEL_SELF_CHECK_COLUMNS.join('·')}는 모형 해석. 아래 항목을 하나씩 켜 본다`,
      data: 'year',
      v: { filter: false, days: f.selfCheck.days, format: 'json', read: MODEL_SELF_CHECK_COLUMNS.length, compression: 1, cutoff: true },
    },
  ];
  const [state, setState] = useState({ ...presets[1].v, data: 'lab' });
  const [preset, setPreset] = useState('lab05-dt');
  const parts = state.data === 'lab' ? labParts : yearParts;
  const q = useMemo(() => normalize({ ...state, partitions: parts, columns: C, cutoff: state.cutoff ? lab.cutoffBytes : null }), [state, parts]);
  const r = useMemo(() => scan(q), [q]);
  const set = (patch) => {
    setState((s) => ({ ...s, ...patch }));
    setPreset('');
  };
  // 막대 길이(로그 눈금, 0~100%). 원래 크기가 축의 끝(100%)이다.
  const logPct = (b) => Math.min(100, Math.max(0, (Math.log10(b + 1) / Math.log10(r.total + 1)) * 100));
  const logW = (b) => `${Math.max(1.5, logPct(b))}%`;
  const cutOnAxis = q.cutoff != null && q.cutoff <= r.total;
  const dataLabel = state.data === 'lab' ? `lab05 파티션 ${labParts.length}개(${lab.files.map((x) => x.dt.slice(5)).join(', ')})` : `${f.selfCheck.tb} TB를 파티션 ${MODEL_DAYS_PER_YEAR}개로`;

  return (
    <section class="asc" aria-labelledby="asc-title">
      <div class="asc-head">
        <h4 id="asc-title">Athena 스캔량 어림</h4>
        <span class="asc-model">모형</span>
      </div>
      <p class="asc-intro">
        <strong>설명용 모형이다.</strong> Athena를 실행하지 않고, 파티션({src(f.rules.partition)}) · 열 지향 형식({src(f.rules.columnar)}) · 압축({src(f.rules.compression)}) · 스캔 상한({src(f.rules.cutoff)})이 쿼리 하나의 스캔량을 어떻게 바꾸는지 계산한다. 요금은 스캔량에 비례하지만 단가는 리전마다 달라 원고에 없으므로 바이트로만 보여 준다.
      </p>

      <fieldset class="asc-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="asc-row">
          {presets.map((p) => (
            <button
              type="button"
              key={p.id}
              data-preset={p.id}
              aria-pressed={preset === p.id ? 'true' : 'false'}
              onClick={() => {
                setState({ ...p.v, data: p.data });
                setPreset(p.id);
              }}
            >
              {p.label}
            </button>
          ))}
        </div>
        <p class="asc-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : `직접 바꾼 조건이다. 데이터: ${dataLabel}.`}</p>
      </fieldset>

      <div class="asc-controls">
        <div class="asc-field">
          <label class="asc-check">
            <input type="checkbox" checked={state.filter} data-field="filter" onChange={(e) => set({ filter: e.currentTarget.checked })} /> ① 파티션으로 거르기(<code>WHERE dt …</code>)
          </label>
          <label class="asc-sub">
            <span>최근 며칠(파티션 수)</span>
            <input type="number" inputMode="numeric" min="1" max={parts.length} step="1" value={state.days} disabled={!state.filter} data-field="days" onInput={(e) => set({ days: e.currentTarget.value })} />
          </label>
          <small>데이터: {dataLabel}. 지금 {r.partitionsRead}/{parts.length}개를 읽는다.</small>
        </div>
        <fieldset class="asc-field asc-radios">
          <legend>② 저장 형식</legend>
          <label>
            <input type="radio" name="asc-format" value="json" checked={state.format === 'json'} onChange={() => set({ format: 'json' })} /> JSON(행 형식 — 모든 열을 읽는다)
          </label>
          <label>
            <input type="radio" name="asc-format" value="parquet" checked={state.format === 'parquet'} onChange={() => set({ format: 'parquet' })} /> Parquet(열 지향 — 쓰는 열만)
          </label>
          <label class="asc-sub">
            <span>쿼리가 쓰는 열 수(SELECT * 이면 {C})</span>
            <input type="number" inputMode="numeric" min="1" max={C} step="1" value={state.read} data-field="read" aria-describedby="asc-cols" onInput={(e) => set({ read: e.currentTarget.value })} />
          </label>
          <small id="asc-cols">
            orders 테이블의 열 {C}개: {f.columns.join(', ')}(03:{f.columnsLine}). 지금 읽는 열 {r.colsRead}개.
          </small>
        </fieldset>
        <fieldset class="asc-field asc-radios">
          <legend>③ 압축 비율</legend>
          {COMPRESSION_CHOICES.map((c) => (
            <label key={c}>
              <input type="radio" name="asc-compression" value={String(c)} checked={state.compression === c} onChange={() => set({ compression: c })} /> {c === 1 ? '압축 없음' : `${c}배로 줄어듦(모형 값)`}
            </label>
          ))}
          <small>원고에 압축 비율 수치가 없다. 실제 비율은 데이터와 코덱(Snappy/GZIP/ZSTD)마다 다르다.</small>
        </fieldset>
        <div class="asc-field">
          <label class="asc-check">
            <input type="checkbox" checked={state.cutoff} data-field="cutoff" onChange={(e) => set({ cutoff: e.currentTarget.checked })} /> ④ 작업 그룹 스캔 상한 {formatBytes(lab.cutoffBytes)}
          </label>
          <small>lab05 작업 그룹의 CutoffBytes {lab.cutoffBytes.toLocaleString('ko-KR')}({src(lab.cutoffLine)})</small>
        </div>
      </div>

      <p class="asc-result" role="status" aria-live="polite" aria-atomic="true" data-blocked={r.blocked ? 'true' : 'false'}>
        <strong class="asc-bytes">스캔 {formatBytes(r.bytes)}</strong> — 원래 {formatBytes(r.total)}의 {formatPct(r.ratio)}.{' '}
        {r.blocked ? <span class="asc-block">⛔ 상한 {formatBytes(lab.cutoffBytes)}보다 많아 이 쿼리는 차단된다.</span> : q.cutoff != null ? <span>✓ 상한 안이라 실행된다.</span> : <span>상한이 없어 그대로 실행되고 스캔한 만큼 과금된다.</span>}
      </p>

      <figure class="asc-fig">
        <figcaption>단계마다 남는 스캔량(막대는 로그 눈금)</figcaption>
        <ol class="asc-steps">
          {r.steps.map((s) => (
            <li key={s.id} data-step={s.id}>
              <span class="asc-step-label">
                {s.label}: <strong>{formatBytes(s.bytes)}</strong>
              </span>
              <span class="asc-track" aria-hidden="true">
                <span class="asc-fill" style={{ width: logW(s.bytes) }}></span>
                {cutOnAxis ? <span class="asc-cut" style={{ left: `${logPct(lab.cutoffBytes)}%` }}></span> : null}
              </span>
            </li>
          ))}
        </ol>
        {q.cutoff != null ? (
          <p class="asc-legend">{cutOnAxis ? '세로 점선 = 스캔 상한.' : `스캔 상한 ${formatBytes(lab.cutoffBytes)}은 이 축(최대 ${formatBytes(r.total)})보다 커서 축 밖에 있다 — 어느 단계도 상한에 닿지 않는다.`}</p>
        ) : null}
      </figure>

      <details class="asc-assume">
        <summary>이 모형의 가정(실제 Athena와 다른 점)</summary>
        <ul>
          <li>파티션 필터는 가장 최근 파티션부터 고른 개수만 읽는다. 스스로 확인 1의 1년치는 크기가 같은 하루 파티션 {MODEL_DAYS_PER_YEAR}개로 나눴다.</li>
          <li>열 지향 형식에서 열마다 크기가 같다고 둔다. 실제로는 열마다 크기가 다르다.</li>
          <li>JSON → Parquet 변환 자체의 크기 변화는 넣지 않고, 크기 변화는 압축 비율(모형 값) 하나로만 나타낸다. JSON도 압축해 둘 수 있다.</li>
          <li>스캔 상한을 넘는 쿼리는 차단된다고만 보여 준다. 차단되기 전까지 읽은 양은 계산하지 않는다.</li>
          <li>에뮬레이터의 Athena는 파티션 열을 모르고 위치 아래 파일을 모두 읽는다(원고 "에뮬레이터가 다른 곳"). 이 모형의 파티션 필터는 실제 Athena의 동작을 따른다.</li>
        </ul>
      </details>
    </section>
  );
}
