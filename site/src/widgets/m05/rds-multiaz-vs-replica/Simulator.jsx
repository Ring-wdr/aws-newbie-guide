// RDS Multi-AZ vs 읽기 전용 복제본(설명용 모형). 계산은 model.mjs, 수치·근거 줄은 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { normalize, evaluate, sourceLines, MAX_RETENTION_SHOWN } from './model.mjs';

const VERDICT = { ok: { mark: '✓ ', label: '괜찮음' }, partial: { mark: '△ ', label: '조건부' }, bad: { mark: '✗ ', label: '문제' } };
const EVENT_LABEL = {
  'az-failure': 'us-east-1a(원본 AZ) 장애',
  report: '오전 10시 정산 집계 쿼리',
  'read-after-write': '방금 쓴 주문을 다시 읽기',
  'write-bottleneck': '쓰기가 한계에 닿음',
};
const LOC_LABEL = { 'same-az': '같은 AZ(us-east-1a)', 'other-az': '다른 AZ(us-east-1b)', 'other-region': '다른 리전' };

export default function Simulator({ facts }) {
  const engines = facts.replicaMax.engines;
  const file = facts.lesson.split('/').pop();
  const srcMap = useMemo(() => sourceLines(facts), []);
  const src = (key) => `${file}:${srcMap[key]}`;
  const f = { failoverTime: facts.failover.time, minRetention: facts.backup.minRetention, writeRemedy: facts.writeRemedy.text };

  // 처음 값: 레슨 첫 장면(Multi-AZ도 복제본도 없음), 자동 백업은 lab02 1단계 명령의 값(facts.labRetention)
  const [raw, setRaw] = useState({ multiAz: false, engine: engines[0].id, replicas: '0', location: 'other-az', retention: String(facts.labRetention.days), batchTo: 'primary', event: 'az-failure' });
  const c = useMemo(() => normalize(raw, engines), [raw]);
  const r = useMemo(() => evaluate(c, f), [c]);
  const set = (patch) => setRaw((x) => ({ ...x, ...patch }));
  const failed = c.event === 'az-failure';
  const n = r.replicasBuilt;

  const box = (cls, label, sub) => (
    <li class={`rr-box ${cls}`}>
      <b>{label}</b>
      {sub ? <span>{sub}</span> : null}
    </li>
  );
  const replicaBox = n
    ? box('rr-replica', `읽기 복제본 ×${n}`, `비동기 복제 · 자기 엔드포인트 · 읽기 전용${failed && c.location === 'same-az' ? ' · ✗ 함께 멈춤' : ''}`)
    : null;

  return (
    <section class="rr" aria-labelledby="rr-title">
      <div class="rr-head">
        <h4 id="rr-title">Multi-AZ vs 읽기 복제본 실험대</h4>
        <span class="rr-model">모형</span>
      </div>
      <p class="rr-intro">
        <strong>설명용 모형이다.</strong> 실제 RDS나 에뮬레이터를 부르지 않고(에뮬레이터는 장애 조치를 재현하지 못한다), 레슨의 비교 표와 장애 조치 순서로 "이 구성에서 이 일이 생기면"을 단계로 보여 준다.
      </p>

      <div class="rr-controls">
        <fieldset class="rr-group">
          <legend>구성</legend>
          <label class="rr-check">
            <input type="checkbox" checked={raw.multiAz} data-field="multiAz" onChange={(e) => set({ multiAz: e.currentTarget.checked })} /> Multi-AZ(인스턴스 배포) 켜기
          </label>
          <label class="rr-field">
            <span>엔진</span>
            <select value={c.engine} data-field="engine" onChange={(e) => set({ engine: e.currentTarget.value })}>
              {engines.map((e) => (
                <option value={e.id} key={e.id}>
                  {e.id}(복제본 최대 {e.max})
                </option>
              ))}
            </select>
          </label>
          <label class="rr-field">
            <span>읽기 복제본 수</span>
            <input type="number" inputMode="numeric" min="0" max={c.replicaMax} step="1" value={raw.replicas} data-field="replicas" aria-describedby="rr-rep-hint" onInput={(e) => set({ replicas: e.currentTarget.value })} />
            <small id="rr-rep-hint">
              0~{c.replicaMax}({c.engine}, {file}:{facts.replicaMax.line}). 지금 {c.replicas}개
            </small>
          </label>
          <label class="rr-field">
            <span>자동 백업 보존 기간(일)</span>
            <input type="number" inputMode="numeric" min="0" max={MAX_RETENTION_SHOWN} step="1" value={raw.retention} data-field="retention" aria-describedby="rr-ret-hint" onInput={(e) => set({ retention: e.currentTarget.value })} />
            <small id="rr-ret-hint">
              복제본을 만들려면 {facts.backup.minRetention} 이상({file}:{facts.backup.line}). 입력 범위 0~{MAX_RETENTION_SHOWN}은 화면 값
            </small>
          </label>
        </fieldset>
        <fieldset class="rr-group" disabled={!c.replicas}>
          <legend>복제본 위치와 연결{c.replicas ? '' : ' (복제본이 있을 때)'}</legend>
          <fieldset class="rr-radios">
            <legend class="rr-sublegend">복제본 위치</legend>
            {Object.entries(LOC_LABEL).map(([v, label]) => (
              <label key={v}>
                <input type="radio" name="rr-loc" value={v} checked={c.location === v} onChange={() => set({ location: v })} /> {label}
              </label>
            ))}
          </fieldset>
          <fieldset class="rr-radios">
            <legend class="rr-sublegend">정산 배치가 붙는 곳</legend>
            <label>
              <input type="radio" name="rr-batch" value="primary" checked={c.batchTo === 'primary'} onChange={() => set({ batchTo: 'primary' })} /> 정산 배치 → 원본 엔드포인트
            </label>
            <label>
              <input type="radio" name="rr-batch" value="replica" checked={c.batchTo === 'replica'} onChange={() => set({ batchTo: 'replica' })} /> 정산 배치 → 복제본 엔드포인트
            </label>
          </fieldset>
        </fieldset>
      </div>

      <fieldset class="rr-events">
        <legend>사건 고르기</legend>
        <div class="rr-row">
          {Object.entries(EVENT_LABEL).map(([id, label]) => (
            <button type="button" key={id} data-event={id} aria-pressed={c.event === id ? 'true' : 'false'} onClick={() => set({ event: id })}>
              {label}
            </button>
          ))}
        </div>
      </fieldset>

      <div class="rr-topo" aria-label="구성 그림(글로 같은 내용)" role="group">
        <div class={`rr-zone${failed ? ' rr-down' : ''}`}>
          <p class="rr-zone-name">us-east-1a{failed ? ' — ✗ 장애' : ''}</p>
          <ul>
            {box('rr-primary', '원본(기본)', '주문 API 읽기·쓰기 · 하나의 DNS 이름')}
            {c.location === 'same-az' ? replicaBox : null}
          </ul>
        </div>
        <div class="rr-zone">
          <p class="rr-zone-name">us-east-1b</p>
          <ul>
            {c.multiAz ? box('rr-standby', '대기(standby)', `동기 복제 · 접속 불가${failed ? ' · 기본으로 승격됨' : ''}`) : <li class="rr-empty">(대기 없음)</li>}
            {c.location === 'other-az' ? replicaBox : null}
          </ul>
        </div>
        {n && c.location === 'other-region' ? (
          <div class="rr-zone">
            <p class="rr-zone-name">다른 리전</p>
            <ul>{replicaBox}</ul>
          </div>
        ) : null}
      </div>

      <div class="rr-result" data-verdict={r.verdict} role="status" aria-live="polite" aria-atomic="true">
        <p>
          <span class="rr-tag">
            <span aria-hidden="true">{VERDICT[r.verdict].mark}</span>
            {VERDICT[r.verdict].label}
          </span>{' '}
          <span class="rr-ev">[{EVENT_LABEL[c.event]}]</span> {r.headline}
        </p>
        {r.notes.map((x, i) => (
          <p class="rr-note" key={i}>
            <b>참고:</b> {x.text} <small>({src(x.src)}{x.src === 'backup' ? `, lab02 5단계 ${file}:${facts.noBackupErrorLine}` : ''})</small>
          </p>
        ))}
      </div>

      <ol class="rr-steps" aria-label="일어나는 순서">
        {r.steps.map((s, i) => (
          <li key={i}>
            {s.text} <small class="rr-src">근거 {src(s.src)}</small>
          </li>
        ))}
      </ol>

      <div class="rr-table-scroll" tabIndex={0} role="region" aria-label="결과 요약 표(좁은 화면에서는 가로로 스크롤)">
        <table class="rr-table">
          <caption>결과 요약(모형)</caption>
          <tbody>
            <tr>
              <th scope="row">앱의 엔드포인트</th>
              <td>{r.facts.endpoint}</td>
            </tr>
            <tr>
              <th scope="row">데이터 손실</th>
              <td>{r.facts.dataLoss}</td>
            </tr>
            <tr>
              <th scope="row">주문 API</th>
              <td>{r.facts.api}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <details class="rr-assume">
        <summary>이 모형의 가정</summary>
        <ul>
          <li>원본은 us-east-1a(레슨 그림의 AZ)에 있고, 장애는 그 AZ 전체에 난다. 같은 AZ에 둔 복제본은 함께 멈춘다.</li>
          <li>장애 조치 시간은 레슨의 "보통 {facts.failover.time}"({file}:{facts.failover.line})을 보여 줄 뿐 계산하지 않는다. 복제 지연의 길이도 다루지 않는다.</li>
          <li>Multi-AZ는 인스턴스 배포다. 대기도 읽을 수 있는 Multi-AZ DB 클러스터, Aurora, RDS Proxy는 다루지 않는다.</li>
          <li>원본 AZ 장애 뒤 복제본이 무엇을 복제하는지처럼 레슨에 없는 동작은 단정하지 않는다.</li>
          <li>처음 값의 자동 백업 {facts.labRetention.days}일은 lab02 1단계 명령의 --backup-retention-period 값이다({file}:{facts.labRetention.line}).</li>
        </ul>
      </details>
    </section>
  );
}
