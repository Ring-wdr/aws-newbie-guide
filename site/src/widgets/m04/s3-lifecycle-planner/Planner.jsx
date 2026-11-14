// S3 수명 주기 규칙 점검기(설명용 모형). 계산은 model.mjs, 수치·규칙은 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { normalize, evaluate, formatDays, describeFinding, summarize, rulesFromFacts, choosableClasses, MAX_TRANSITIONS, MAX_DAYS, OPEN_TAIL_MIN } from './model.mjs';

const RESULT_LABEL = { ok: '저장됨', warned: '저장됨 — 주의', rejected: '거부됨' };
const RESULT_MARK = { ok: '✓ ', warned: '△ ', rejected: '✗ ' };
const LEVEL_LABEL = { error: '거부', warn: '주의', info: '참고' };
const END_LABEL = { transition: '다음 클래스로 전환', expire: '삭제(만료)', open: '계속 보관' };

const toRaw = (v) => ({
  transitions: Array.from({ length: MAX_TRANSITIONS }, (_, i) => ({ cls: v.transitions[i]?.cls ?? '', days: String(v.transitions[i]?.days ?? 0) })),
  expiration: { on: v.expireDays != null, days: String(v.expireDays ?? 365) },
  small: false,
});

export default function Planner({ facts }) {
  const rules = useMemo(() => rulesFromFacts(facts), []);
  const choosable = useMemo(() => choosableClasses(facts), []);
  const name = (api) => facts.classes[api].name;
  const file = facts.lesson.split('/').pop();
  const src = (line) => `${file}:${line}`;

  const presets = [
    { id: 'receipts', label: 'lab02 영수증 규칙', note: `lab02 8단계 출력의 receipts-tiering 규칙(${src(facts.receipts.line)})`, v: { transitions: facts.receipts.transitions, expireDays: facts.receipts.expireDays } },
    { id: 'self-check', label: '스스로 확인 1번', note: `생성 ${facts.selfCheck.transitions[0].days}일 후 Standard-IA, ${facts.selfCheck.expireDays}일 후 삭제(${src(facts.selfCheck.line)}), 답은 ${src(facts.selfCheck.answer.line)}`, v: { transitions: facts.selfCheck.transitions, expireDays: facts.selfCheck.expireDays } },
    { id: 'too-soon', label: '거부 예: 너무 이른 연쇄 전환', note: `lab02 11단계(${src(facts.labRejects.tooSoon.line)}), 레슨의 예(${src(facts.rejectExample.line)})`, v: { transitions: facts.labRejects.tooSoon.transitions, expireDays: null } },
    { id: 'backwards', label: '거부 예: 역방향 전환', note: `lab02 12단계(${src(facts.labRejects.backwards.line)})`, v: { transitions: facts.labRejects.backwards.transitions, expireDays: null } },
  ];

  const [raw, setRaw] = useState(() => toRaw(presets[0].v));
  const [preset, setPreset] = useState('receipts');
  const input = useMemo(() => normalize(raw, choosable), [raw]);
  const r = useMemo(() => evaluate(input, rules), [input]);

  const set = (fn) => {
    setRaw((cur) => fn(structuredClone(cur)));
    setPreset('');
  };
  const applyPreset = (p) => {
    setRaw(toRaw(p.v));
    setPreset(p.id);
  };

  // 그림: 조기 삭제 요금 구간(지운 뒤에도 최소 보관 기간이 끝날 때까지 요금)까지 축에 넣는다.
  const last = r.stages.at(-1);
  const feeEnd = last && last.shortBy ? last.to + last.shortBy : null;
  const scale = Math.max(r.end, feeEnd ?? 0, 1);
  const pct = (t) => `${(Math.min(t, scale) / scale) * 100}%`;

  return (
    <section class="lc" aria-labelledby="lc-title">
      <div class="lc-head">
        <h4 id="lc-title">수명 주기 규칙 점검기</h4>
        <span class="lc-model">모형</span>
      </div>
      <p class="lc-intro">
        <strong>설명용 모형이다.</strong> 실제 S3나 에뮬레이터를 부르지 않고, 레슨의 표·폭포 그림·거부 규칙으로 규칙 하나를 판정해 객체 하나가 어느 클래스에 며칠 머무는지 계산한다. 실제 저장·거부는 아래 lab02에서 관찰한다.
      </p>

      <fieldset class="lc-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="lc-row">
          {presets.map((p) => (
            <button type="button" key={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => applyPreset(p)} data-preset={p.id}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="lc-hint">{preset ? `출처: ${presets.find((p) => p.id === preset).note}` : '직접 바꾼 규칙이다.'}</p>
      </fieldset>

      <fieldset class="lc-rule">
        <legend>규칙(현재 버전) — 객체는 0일에 Standard로 만들어진다</legend>
        <ol class="lc-trows">
          {raw.transitions.map((t, i) => (
            <li class="lc-trow" key={i}>
              <label class="lc-field">
                <span>전환 {i + 1}: 클래스</span>
                <select value={t.cls} data-field={`cls-${i}`} onChange={(e) => set((c) => ((c.transitions[i].cls = e.currentTarget.value), c))}>
                  <option value="">(없음)</option>
                  {choosable.map((api) => (
                    <option value={api} key={api}>
                      {name(api)}
                    </option>
                  ))}
                </select>
              </label>
              <label class="lc-field">
                <span>생성 후 일수</span>
                <input type="number" inputMode="numeric" min="0" max={MAX_DAYS} step="1" value={t.days} disabled={!t.cls} data-field={`days-${i}`} onInput={(e) => set((c) => ((c.transitions[i].days = e.currentTarget.value), c))} />
              </label>
            </li>
          ))}
        </ol>
        <div class="lc-exp">
          <label class="lc-check">
            <input type="checkbox" checked={raw.expiration.on} data-field="exp-on" onChange={(e) => set((c) => ((c.expiration.on = e.currentTarget.checked), c))} /> 만료(Expiration) — N일 뒤 삭제
          </label>
          <label class="lc-field">
            <span>만료 일수</span>
            <input type="number" inputMode="numeric" min="0" max={MAX_DAYS} step="1" value={raw.expiration.days} disabled={!raw.expiration.on} data-field="exp-days" onInput={(e) => set((c) => ((c.expiration.days = e.currentTarget.value), c))} />
          </label>
        </div>
        <fieldset class="lc-radios">
          <legend>객체 크기</legend>
          <label>
            <input type="radio" name="lc-size" value="large" checked={!raw.small} onChange={() => set((c) => ((c.small = false), c))} /> {facts.smallObject.kb} KB 이상
          </label>
          <label>
            <input type="radio" name="lc-size" value="small" checked={raw.small} onChange={() => set((c) => ((c.small = true), c))} /> {facts.smallObject.kb} KB 미만({src(facts.smallObject.line)})
          </label>
        </fieldset>
        <p class="lc-hint">전환은 날짜순으로 본다. 일수는 0~{MAX_DAYS}(화면 범위). 이전 버전 전환은 다루지 않는다.</p>
      </fieldset>

      <div class="lc-result" data-result={r.result} role="status" aria-live="polite" aria-atomic="true">
        <p>
          <span class="lc-tag">
            <span aria-hidden="true">{RESULT_MARK[r.result]}</span>
            {RESULT_LABEL[r.result]}
          </span>{' '}
          {summarize(r, name)}
        </p>
        {r.findings.length ? (
          <ul class="lc-findings">
            {r.findings.map((f, i) => (
              <li key={i} data-level={f.level}>
                <span class="lc-level">[{LEVEL_LABEL[f.level]}]</span> {describeFinding(f, name)}
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      {r.stages.length ? (
        <figure class="lc-chart">
          <div class="lc-legend" aria-hidden="true">
            <span><i class="lc-sw lc-sw-now"></i>바로 읽힘(밀리초)</span>
            <span><i class="lc-sw lc-sw-restore"></i>복원 필요</span>
            {feeEnd ? <span><i class="lc-sw lc-sw-fee"></i>지운 뒤에도 요금</span> : null}
          </div>
          <div class="lc-track" aria-hidden="true">
            {r.stages.map((s, i) => {
              const to = s.to ?? r.end;
              return (
                <span key={i} class={`lc-seg ${s.restore ? 'lc-seg-restore' : 'lc-seg-now'}${s.to === null ? ' lc-seg-open' : ''}`} style={{ left: pct(s.from), width: `calc(${pct(to)} - ${pct(s.from)})` }}>
                  {i + 1}
                </span>
              );
            })}
            {feeEnd ? <span class="lc-seg lc-seg-fee" style={{ left: pct(last.to), width: `calc(${pct(feeEnd)} - ${pct(last.to)})` }}></span> : null}
          </div>
          <figcaption class="lc-axis" aria-hidden="true">
            <span>0일</span>
            <span>{r.openEnded ? `${formatDays(scale)} → 계속` : formatDays(scale)}</span>
          </figcaption>
          <ol class="lc-keys" aria-hidden="true">
            {r.stages.map((s, i) => (
              <li key={i}>
                <b>{i + 1}</b> {name(s.cls)}
              </li>
            ))}
          </ol>
        </figure>
      ) : null}

      <details class="lc-table-box" open>
        <summary>같은 내용을 표로 보기</summary>
        {r.stages.length ? (
          <>
          <p class="lc-hint lc-scroll-hint" aria-hidden="true">표는 가로로 스크롤된다(Tab으로 고른 뒤 ←/→).</p>
          <div class="lc-table-scroll" tabindex="0" role="region" aria-label="구간 표(가로로 스크롤)">
            <table class="lc-table">
              <caption class="sr-only">객체가 머무는 클래스와 기간(모형)</caption>
              <thead>
                <tr>
                  <th scope="col">구간</th>
                  <th scope="col">클래스</th>
                  <th scope="col">기간</th>
                  <th scope="col">최소 보관</th>
                  <th scope="col">이 기간에 읽으면</th>
                </tr>
              </thead>
              <tbody>
                {r.stages.map((s, i) => (
                  <tr key={i}>
                    <td>{i + 1}</td>
                    <td>
                      {name(s.cls)}
                      <br />
                      <code>{s.cls}</code>
                    </td>
                    <td>
                      {s.from}~{s.to === null ? '' : `${s.to}`}일 · {s.held === null ? '계속' : `${s.held}일 머묾`} · {END_LABEL[s.endKind]}
                    </td>
                    <td>
                      {s.min ? `${s.min}일` : '없음'}
                      {s.shortBy ? ` — ${s.shortBy}일 모자람(조기 삭제 요금)` : s.held !== null && s.min ? ' — 채움' : ''}
                    </td>
                    <td>
                      {facts.classes[s.cls].retrieval}
                      {s.restore ? ' — 복원(RestoreObject) 뒤에 읽힘' : ''}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          </>
        ) : (
          <p class="lc-hint">규칙이 거부되어 객체는 Standard에 그대로 있다(검색 밀리초, 최소 보관 없음).</p>
        )}
        <p class="lc-hint">
          출처: 최소 보관·검색 시간은 레슨 표({src(facts.tableLine)}~), 복원은 {src(facts.restoreLine)}.
        </p>
      </details>

      <details class="lc-water">
        <summary>폭포: 클래스마다 갈 수 있는 전환(레슨 그림 {src(facts.waterfall.lines[0])}~{facts.waterfall.lines[1]})</summary>
        <ul>
          {Object.entries(facts.waterfall.next).map(([from, tos]) => (
            <li key={from}>
              {name(from)} → {tos.length ? tos.map(name).join(', ') : '(없음 — 마지막)'}
            </li>
          ))}
        </ul>
      </details>

      <details class="lc-assume">
        <summary>이 모형의 가정</summary>
        <ul>
          <li>객체 하나가 0일에 Standard로 만들어지고, 규칙 하나(현재 버전 전환·만료)만 걸려 있다. 이전 버전 전환·필터는 다루지 않는다.</li>
          <li>전환은 규칙 날짜에 정확히 일어난다. 실제로는 비동기라 늦을 수 있고 하루 단위로 평가된다.</li>
          <li>거부는 레슨이 든 네 가지(폭포를 거스르는 전환 — 같은 클래스 중복 포함, 이전 클래스의 최소 보관 기간보다 이른 다음 전환, 전환보다 빠르거나 같은 만료({src(facts.expireAfter.line)}), 0일 만료)만 본다. 그 밖의 AWS 검증(필터, 규칙 ID 등)은 다루지 않는다. 에뮬레이터는 만료·전환 순서를 검사하지 않고 저장한다.</li>
          <li>"주의"는 저장은 되지만 돈이 새는 규칙이다 — 판정은 sdk/lifecycle_lint.py와 같다. 요금 금액은 계산하지 않는다(레슨의 비용 워크시트).</li>
          <li>같은 날짜의 전환이 둘이면 입력한 순서대로 본다(원고에 없는 경우).</li>
          <li>만료가 없으면 마지막 클래스에 머무는 모습을 최소 보관 기간과 {OPEN_TAIL_MIN}일 중 긴 쪽만큼 그린다(화면 값).</li>
          <li>Intelligent-Tiering 안의 계층 이동은 다루지 않는다.</li>
        </ul>
      </details>
    </section>
  );
}
