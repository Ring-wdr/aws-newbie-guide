// Lambda 동시성 칸 나누기(설명용 모형). 계산은 model.mjs, 수치는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { normalize, allocate, explain, VERDICT_LABEL, MODEL_MAX_DEMAND, throttleFate, settableMax, UNRESERVED_MIN } from './model.mjs';

const n = (x) => x.toLocaleString('en-US');

// 아래 요청 수는 원고에 없는 모형 값이다(퀴즈 3번·2번의 상황을 숫자로 옮긴 예).
//  - 쿠폰 폭주: quiz.md 3번 "쿠폰 발급 함수가 폭주해 같은 계정의 결제 함수까지 스로틀(429)" — 쿠폰 1,200, 결제 50, 예약 800은 모형 값
//  - 콜드 스타트: quiz.md 2번 "가끔 2초가 넘는다 … 콜드 스타트" — 프로비저닝 50, 요청 80은 모형 값
const MODEL = { couponDemand: 1200, payDemand: 50, couponReserved: 800, prov: 50, provDemand: 80 };

export default function Concurrency({ facts }) {
  const limit = facts.accountLimit.value;
  const thr = facts.throttle;
  const les = (line) => `${facts.lesson.split('/').pop()}:${line}`;
  const cs = (line) => `${facts.cheatsheet.split('/').pop()}:${line}`;
  const presets = [
    {
      id: 'self-check',
      label: `스스로 확인 3번: 예약 ${n(facts.selfCheck.reserved)}, 요청 ${n(facts.selfCheck.demand)}`,
      note: `예약 동시성 ${n(facts.selfCheck.reserved)}, 계정 한도 ${n(facts.selfCheck.limit)}, 동시 요청 ${n(facts.selfCheck.demand)}(${les(facts.selfCheck.line)})`,
      v: { reservedOn: true, reserved: facts.selfCheck.reserved, provisioned: 0, demandA: facts.selfCheck.demand, demandB: 0, invokeA: 'sync' },
    },
    {
      id: 'lab01',
      label: `lab01: 예약 ${facts.lab01.reserved}`,
      note: `예약 동시성 ${facts.lab01.reserved}(${les(facts.lab01.line)}) → 미예약 몫 ${n(facts.lab01.unreserved)}(${les(facts.lab01.unreservedLine)}). 요청 0건`,
      v: { reservedOn: true, reserved: facts.lab01.reserved, provisioned: 0, demandA: 0, demandB: 0, invokeA: 'sync' },
    },
    {
      id: 'coupon',
      label: '퀴즈 3번: 쿠폰 함수 폭주',
      note: `quiz.md 3번의 상황. 쿠폰(A) ${n(MODEL.couponDemand)}건, 결제(나머지) ${n(MODEL.payDemand)}건은 모형 값`,
      v: { reservedOn: false, reserved: MODEL.couponReserved, provisioned: 0, demandA: MODEL.couponDemand, demandB: MODEL.payDemand, invokeA: 'sync' },
    },
    {
      id: 'coupon-fixed',
      label: `퀴즈 3번 답: 쿠폰에 예약 ${n(MODEL.couponReserved)}`,
      note: `quiz.md 3번 정답 A(예약 동시성으로 상한). 예약 ${n(MODEL.couponReserved)}과 요청 수는 모형 값`,
      v: { reservedOn: true, reserved: MODEL.couponReserved, provisioned: 0, demandA: MODEL.couponDemand, demandB: MODEL.payDemand, invokeA: 'sync' },
    },
    {
      id: 'provisioned',
      label: `퀴즈 2번: 프로비저닝 ${MODEL.prov}`,
      note: `quiz.md 2번(콜드 스타트 → 프로비저닝된 동시성). 프로비저닝 ${MODEL.prov}, 요청 ${MODEL.provDemand}건은 모형 값`,
      v: { reservedOn: false, reserved: MODEL.couponReserved, provisioned: MODEL.prov, demandA: MODEL.provDemand, demandB: 0, invokeA: 'sync' },
    },
  ];
  const toRaw = (v) => ({ ...v, reserved: String(v.reserved), provisioned: String(v.provisioned), demandA: String(v.demandA), demandB: String(v.demandB) });

  const [raw, setRaw] = useState(toRaw(presets[0].v));
  const [preset, setPreset] = useState(presets[0].id);
  const input = useMemo(() => normalize(raw, limit), [raw.reservedOn, raw.reserved, raw.provisioned, raw.demandA, raw.demandB, raw.invokeA]);
  const r = useMemo(() => allocate(input, limit), [input]);
  const ex = explain(input, r, thr);
  const set = (patch) => {
    setRaw((x) => ({ ...x, ...patch }));
    setPreset('');
  };
  const pick = (p) => {
    setRaw(toRaw(p.v));
    setPreset(p.id);
  };
  const maxSet = settableMax(limit); // AWS: 미예약 몫 100을 남겨야 한다(model.mjs D1)
  const capProv = input.reservedOn ? input.reserved : maxSet;
  const clipped = (field) => raw[field] !== '' && Number(raw[field]) !== input[field];

  // 막대: 계정 동시성 limit칸을 왼쪽부터 [예약 몫(A)] [미예약 몫] 순서로 그린다.
  const pct = (x) => `${(x / limit) * 100}%`;
  const segs = input.reservedOn
    ? [
        ['warm', r.a.warm],
        ['cold', r.a.cold],
        ['idle', r.a.idleProv],
        ['resfree', r.reservedIdle],
        ['b', r.b.run],
        ['free', r.free],
      ]
    : [
        ['warm', r.a.warm],
        ['cold', r.a.cold],
        ['idle', r.a.idleProv],
        ['b', r.b.run],
        ['free', r.free],
      ];
  const SEG_LABEL = {
    warm: 'A 실행: 프로비저닝된 환경(웜)',
    cold: 'A 실행: 새 환경(콜드 스타트)',
    idle: 'A 프로비저닝된 환경: 대기',
    resfree: 'A 예약 몫: 빈칸',
    b: '나머지 함수 실행',
    free: '미예약 몫: 빈칸',
  };
  const SEG_MARK = { warm: '■', cold: '▨', idle: '□', resfree: '┅', b: '▤', free: '·' };

  return (
    <section class="lc" aria-labelledby="lc-title">
      <div class="lc-head">
        <h4 id="lc-title">동시성 칸 나누기: 예약·프로비저닝·스로틀</h4>
        <span class="lc-model">모형</span>
      </div>
      <p class="lc-intro">
        <strong>설명용 모형이다.</strong> 실제 Lambda나 에뮬레이터를 실행하지 않고, 한순간에 몰린 동시 요청이 계정 동시성 {n(limit)}칸({les(facts.accountLimit.line)})에 어떻게 자리 잡는지 계산해 보여 준다. 함수 A와 "나머지 함수들" 두 무리로 나눈다.
      </p>

      <fieldset class="lc-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="lc-row">
          {presets.map((p) => (
            <button type="button" key={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => pick(p)} data-preset={p.id}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="lc-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="lc-controls">
        <div class="lc-field">
          <label class="lc-check">
            <input type="checkbox" checked={raw.reservedOn} data-field="reservedOn" onChange={(e) => set({ reservedOn: e.currentTarget.checked })} /> 함수 A에 예약 동시성 설정
          </label>
          <label class="lc-sub">
            <span>예약 동시성</span>
            <input type="number" inputMode="numeric" min="0" max={maxSet} step="1" value={raw.reserved} disabled={!raw.reservedOn} data-field="reserved" aria-describedby="lc-res-hint" onInput={(e) => set({ reserved: e.currentTarget.value })} />
          </label>
          <small id="lc-res-hint">
            0 ~ {n(maxSet)}(실제 AWS는 미예약 {n(UNRESERVED_MIN)}을 남겨야 한다). 몫이자 상한(원고 {les(facts.rulesLine)}), 0이면 함수 정지({cs(facts.zeroStopsLine)}).{raw.reservedOn && clipped('reserved') ? ` ${n(input.reserved)}(으)로 맞춤.` : ''}
          </small>
        </div>
        <label class="lc-field">
          <span>함수 A의 프로비저닝된 동시성</span>
          <input type="number" inputMode="numeric" min="0" max={capProv} step="1" value={raw.provisioned} data-field="provisioned" aria-describedby="lc-prov-hint" onInput={(e) => set({ provisioned: e.currentTarget.value })} />
          <small id="lc-prov-hint">
            미리 데워 둔 환경 수(원고 {les(facts.rulesLine)}). 모형은 0 ~ {n(capProv)}{input.reservedOn ? '(예약 동시성 이하)' : `(실제 AWS처럼 미예약 ${n(UNRESERVED_MIN)}을 남긴다)`}만 받는다.{clipped('provisioned') ? ` 지금 ${n(input.provisioned)}(으)로 맞춤.` : ''}
          </small>
        </label>
        <label class="lc-field">
          <span>함수 A의 동시 요청 수</span>
          <input type="number" inputMode="numeric" min="0" max={MODEL_MAX_DEMAND} step="1" value={raw.demandA} data-field="demandA" aria-describedby="lc-da-hint" onInput={(e) => set({ demandA: e.currentTarget.value })} />
          <small id="lc-da-hint">0 ~ {n(MODEL_MAX_DEMAND)}(모형 화면의 범위).{clipped('demandA') ? ` 지금 ${n(input.demandA)}.` : ''}</small>
        </label>
        <fieldset class="lc-field lc-radios">
          <legend>함수 A의 호출 방식</legend>
          <label>
            <input type="radio" name="lc-invoke" value="sync" checked={raw.invokeA === 'sync'} onChange={() => set({ invokeA: 'sync' })} /> 동기(RequestResponse)
          </label>
          <label>
            <input type="radio" name="lc-invoke" value="async" checked={raw.invokeA === 'async'} onChange={() => set({ invokeA: 'async' })} /> 비동기(Event)·이벤트 소스
          </label>
        </fieldset>
        <label class="lc-field">
          <span>나머지 함수들의 동시 요청 수</span>
          <input type="number" inputMode="numeric" min="0" max={MODEL_MAX_DEMAND} step="1" value={raw.demandB} data-field="demandB" aria-describedby="lc-db-hint" onInput={(e) => set({ demandB: e.currentTarget.value })} />
          <small id="lc-db-hint">같은 계정·리전의 다른 함수들(동기 호출로 둔다). 0 ~ {n(MODEL_MAX_DEMAND)}.{clipped('demandB') ? ` 지금 ${n(input.demandB)}.` : ''}</small>
        </label>
      </div>

      <div class="lc-result" data-verdict={ex.verdict} role="status" aria-live="polite" aria-atomic="true">
        <p class="lc-tag">
          <span aria-hidden="true">{ex.verdict === 'ok' ? '✓ ' : ex.verdict === 'stopped' ? '■ ' : '✕ '}</span>
          {VERDICT_LABEL[ex.verdict]}
        </p>
        <ul>
          {ex.lines.map((l, i) => (
            <li key={i}>{l}</li>
          ))}
        </ul>
      </div>

      <figure class="lc-chart">
        <div class="lc-bar" aria-hidden="true">
          {segs.map(([k, v]) => (v > 0 ? <span key={k} class={`lc-seg lc-seg-${k}`} style={{ width: pct(v) }}></span> : null))}
          {input.reservedOn ? <span class="lc-cut" style={{ left: pct(input.reserved) }}></span> : null}
        </div>
        <div class="lc-axis" aria-hidden="true">
          <span>0</span>
          {input.reservedOn ? <span>예약 경계 {n(input.reserved)}</span> : null}
          <span>{n(limit)}</span>
        </div>
        <figcaption>
          <ul class="lc-legend">
            {segs.map(([k, v]) => (
              <li key={k} data-seg={k}>
                <i class={`lc-sw lc-seg-${k}`} aria-hidden="true"></i>
                <span aria-hidden="true">{SEG_MARK[k]} </span>
                {SEG_LABEL[k]}: <strong>{n(v)}</strong>칸
              </li>
            ))}
          </ul>
          <p class="lc-thr">
            칸 밖(스로틀): 함수 A <strong>{n(r.a.throttled)}</strong>건{r.a.throttled ? ` → ${throttleFate(input.invokeA, thr.status, thr.error)}` : ''} · 나머지 함수 <strong>{n(r.b.throttled)}</strong>건{r.b.throttled ? ` → ${throttleFate('sync', thr.status, thr.error)}` : ''}
          </p>
        </figcaption>
      </figure>

      <details class="lc-table-box" open>
        <summary>같은 내용을 표로 보기</summary>
        <div class="lc-table-scroll" tabindex="0" role="region" aria-label="함수별 결과 표(좁은 화면에서는 가로로 스크롤)">
          <table class="lc-table">
            <caption class="sr-only">함수별 동시성 결과(모형)</caption>
            <thead>
              <tr>
                <th scope="col">무리</th>
                <th scope="col">쓸 수 있는 칸</th>
                <th scope="col">요청</th>
                <th scope="col">실행(웜 / 콜드)</th>
                <th scope="col">스로틀</th>
              </tr>
            </thead>
            <tbody>
              <tr data-row="a">
                <th scope="row">함수 A</th>
                <td>{input.reservedOn ? `예약 ${n(input.reserved)}` : `미예약 몫 공유(${n(limit)})`}</td>
                <td>{n(r.a.demand)}</td>
                <td>
                  {n(r.a.run)} ({n(r.a.warm)} / {n(r.a.cold)})
                </td>
                <td>{r.a.throttled ? `${n(r.a.throttled)} → ${throttleFate(input.invokeA, thr.status, thr.error)}` : '0'}</td>
              </tr>
              <tr data-row="b">
                <th scope="row">나머지 함수들</th>
                <td>
                  미예약 {n(r.unreserved)} 중 남은 {n(r.poolForB)}
                </td>
                <td>{n(r.b.demand)}</td>
                <td>{n(r.b.run)} (따지지 않음)</td>
                <td>{r.b.throttled ? `${n(r.b.throttled)} → ${throttleFate('sync', thr.status, thr.error)}` : '0'}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="lc-hint">미예약 몫(UnreservedConcurrentExecutions) = 계정 동시성 − 예약 동시성. lab01에서는 {n(facts.lab01.account)} − {facts.lab01.reserved} = {n(facts.lab01.unreserved)}이었다({les(facts.lab01.unreservedLine)}).</p>
      </details>

      <details class="lc-assume">
        <summary>이 모형의 가정(실제 AWS와 다른 점)</summary>
        <ul>
          <li>한순간의 동시 요청 수만 본다. 요청 하나가 몇 초 걸리는지, 환경이 늘어나는 속도, 재시도가 언제 성공하는지는 계산하지 않는다.</li>
          <li>예약이 없으면 함수 A와 나머지 함수들이 같은 몫을 쓰고, 모형은 A의 요청이 먼저 자리를 잡는다고 둔다. 실제로는 요청이 도착하는 순서에 따라 나뉜다.</li>
          <li>데워진 환경은 프로비저닝된 것뿐이라고 둔다. 실제로는 앞선 호출에서 남은 환경이 재사용되면(웜 스타트) 콜드 스타트가 그보다 적다.</li>
          <li>프로비저닝된 환경은 요청이 없어도 칸을 차지하고, 예약 동시성을 넘지 않게 맞춘다(원고에 없는 내용 — 모형 가정).</li>
          <li>실제 AWS처럼 예약 동시성과 (예약 없이 거는) 프로비저닝된 동시성은 미예약 몫 {n(UNRESERVED_MIN)}을 남긴 {n(maxSet)}까지만 받는다(AWS Lambda 개발자 안내서의 예약·프로비저닝 동시성 설정 절 — 원고에 없는 내용). 다른 함수에는 예약·프로비저닝이 없다고 둔다.</li>
          <li>나머지 함수들은 동기 호출로 두고 콜드 스타트를 따지지 않는다. 계정 동시성은 증설 요청 전의 기본값 {n(limit)}으로 고정한다.</li>
        </ul>
      </details>
    </section>
  );
}
