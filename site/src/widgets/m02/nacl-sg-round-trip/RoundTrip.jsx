// DB 연결 하나의 왕복: NACL(상태 비저장)과 보안 그룹(상태 저장)의 판정(설명용 모형). 판정은 model.mjs, 규칙·주소는 facts.mjs가 원고에서 읽어 props로 준다.
import { useMemo, useState } from 'preact/hooks';
import { roundTrip, normalize, rulesFor, summarize, sourceInfo, PRESETS, RESULT_LABEL, EPHEMERAL_RANGE, APP_B_IP } from './model.mjs';

const MARK = { true: '✓ 통과', false: '✕ 막힘', null: '— 가지 않음' };
const RESULT_MARK = { ok: '✓', 'nacl-in': '✕', 'sg-in': '✕', timeout: '⏱' };

export default function RoundTrip({ facts }) {
  const src = (line) => `${facts.lesson.split('/').pop()}:${line}`;
  const defaults = { port: facts.dbSgRule.port, ephemeral: facts.ephemeral.port };
  const toRaw = (v) => ({ source: v.source, port: String(v.port ?? defaults.port), ephemeral: String(v.ephemeral ?? defaults.ephemeral), dropEgress: Boolean(v.dropEgress) });
  const [raw, setRaw] = useState(() => toRaw(PRESETS[0].v));
  const [preset, setPreset] = useState(PRESETS[0].id);
  const x = useMemo(() => normalize(raw, defaults), [raw]);
  const rt = useMemo(() => roundTrip(x, facts), [x]);
  const set = (patch) => {
    setRaw((o) => ({ ...o, ...patch }));
    setPreset('');
  };
  const applyPreset = (p) => {
    setRaw(toRaw(p.v));
    setPreset(p.id);
  };
  const s = rt.src;
  const label = { 'app-a': `앱 a ${facts.ip.app}`, 'app-b': `앱 b ${APP_B_IP}(모형 값)`, alb: `ALB ${facts.ip.alb}` };
  const decided = {};
  for (const h of rt.hops) if (h.rule) decided[`${h.rule.egress ? 'out' : 'in'}-${h.rule.number}`] = h.id === 'nacl-in' ? '요청' : '응답';
  const rules = rulesFor(facts.rules, x.dropEgress);
  const sorted = [...facts.rules].sort((a, b) => Number(a.egress) - Number(b.egress) || a.number - b.number);
  const removed = (r) => !rules.includes(r);
  const presetNote = {
    'app-db': `lab05 Q4·Q5(${src(facts.worksheet.Q4.line)}·${facts.worksheet.Q5.line}), lab04 Q4(${src(facts.sgWorksheet.Q4.line)})`,
    'alb-db': `lab05 Q6(${src(facts.worksheet.Q6.line)}), lab04 Q3(${src(facts.sgWorksheet.Q3.line)})`,
    'app-ssh': `DB NACL 규칙(${src(facts.rulesLine)})으로 판정`,
    'no-egress': `"이걸 빠뜨리면 … 타임아웃"(${src(facts.lines.needOut)})`,
  }[preset];

  const Hop = ({ h }) => (
    <li class="nf-hop" data-pass={String(h.pass)} data-hop={h.id}>
      <span class="nf-where">{h.where}</span>
      <span class="nf-mark">{MARK[String(h.pass)]}</span>
      <span class="nf-note">{h.note}</span>
    </li>
  );

  return (
    <section class="nf" aria-labelledby="nf-title">
      <div class="nf-head">
        <h4 id="nf-title">DB 연결 왕복: NACL과 보안 그룹</h4>
        <span class="nf-model">모형</span>
      </div>
      <p class="nf-intro">
        <strong>설명용 모형이다.</strong> VPC나 에뮬레이터를 실행하지 않는다. 위 lab05·lab04 출력의 DB NACL 규칙({src(facts.rulesLine)})과 DB SG 규칙({src(facts.dbSgRule.line)})으로, DB({facts.ip.db})로 가는 TCP 연결 하나가 요청·응답 두 방향에서 어디를 통과하는지 판정한다.
      </p>

      <fieldset class="nf-presets">
        <legend>원고의 예로 채우기</legend>
        <div class="nf-row">
          {PRESETS.map((p) => (
            <button type="button" key={p.id} data-preset={p.id} aria-pressed={preset === p.id ? 'true' : 'false'} onClick={() => applyPreset(p)}>
              {p.label}
            </button>
          ))}
        </div>
        <p class="nf-hint">{preset ? `출처: ${presetNote}` : '직접 바꾼 값이다.'}</p>
      </fieldset>

      <div class="nf-controls">
        <fieldset class="nf-field">
          <legend>출발지</legend>
          {['app-a', 'app-b', 'alb'].map((id) => (
            <label key={id}>
              <input type="radio" name="nf-source" value={id} checked={x.source === id} onChange={() => set({ source: id })} /> {label[id]} ({sourceInfo(id, facts.ip).sg}-sg)
            </label>
          ))}
          <small>주소는 원고의 설명용 예({src(facts.ip.line)}). 앱 b의 주소만 원고에 없는 모형 값이다.</small>
        </fieldset>
        <div class="nf-field">
          <label class="nf-num">
            <span>DB의 목적지 포트</span>
            <input type="number" inputMode="numeric" min="1" max="65535" step="1" value={raw.port} data-field="port" onInput={(e) => set({ port: e.currentTarget.value })} />
          </label>
          <label class="nf-num">
            <span>클라이언트 임시 포트</span>
            <input type="number" inputMode="numeric" min={EPHEMERAL_RANGE.min} max={EPHEMERAL_RANGE.max} step="1" value={raw.ephemeral} data-field="ephemeral" aria-describedby="nf-eph-hint" onInput={(e) => set({ ephemeral: e.currentTarget.value })} />
          </label>
          <small id="nf-eph-hint">
            원고의 예 {facts.ephemeral.port}({src(facts.ephemeral.line)}). OS마다 다르다: Linux {facts.ephemeral.linux.join('-')}, Windows {facts.ephemeral.windows.join('-')}({src(facts.ephemeral.rangeLine)}). 모형은 {EPHEMERAL_RANGE.min}~{EPHEMERAL_RANGE.max}만 받는다. 지금 포트 {x.port}, 임시 포트 {x.ephemeral}
          </small>
          <label class="nf-check">
            <input type="checkbox" data-field="dropEgress" checked={x.dropEgress} onChange={(e) => set({ dropEgress: e.currentTarget.checked })} /> DB NACL 아웃바운드의 임시 포트 허용 규칙(1024-65535)을 빠뜨린다
          </label>
        </div>
      </div>

      <p class="nf-result" data-result={rt.result} role="status" aria-live="polite" aria-atomic="true">
        <span class="nf-tag">
          <span aria-hidden="true">{RESULT_MARK[rt.result]} </span>
          {RESULT_LABEL[rt.result]}
        </span>{' '}
        {summarize(rt, x)}
      </p>

      <div class="nf-lanes">
        <div class="nf-lane">
          <p class="nf-lane-title">
            요청 <span aria-hidden="true">→</span> {s.ip}:{x.ephemeral} → {facts.ip.db}:{x.port}
          </p>
          <ol class="nf-hops">
            {rt.hops.filter((h) => h.dir === 'req').map((h) => <Hop key={h.id} h={h} />)}
          </ol>
        </div>
        <div class="nf-lane">
          <p class="nf-lane-title">
            응답 <span aria-hidden="true">←</span> {facts.ip.db}:{x.port} → {s.ip}:{x.ephemeral}
          </p>
          <ol class="nf-hops">
            {rt.hops.filter((h) => h.dir === 'res').map((h) => <Hop key={h.id} h={h} />)}
          </ol>
        </div>
      </div>

      <details class="nf-table-box" open>
        <summary>DB NACL 규칙 표(판정한 규칙 표시)</summary>
        <div class="nf-table-scroll" tabIndex={0} role="region" aria-label="DB NACL 규칙 표(가로로 스크롤)">
          <table class="nf-table">
            <caption class="sr-only">DB NACL 규칙과 이번 판정(모형)</caption>
            <thead>
              <tr>
                <th scope="col">방향</th>
                <th scope="col">번호</th>
                <th scope="col">동작</th>
                <th scope="col">프로토콜</th>
                <th scope="col">CIDR</th>
                <th scope="col">포트</th>
                <th scope="col">이번 판정</th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((r) => {
                const k = `${r.egress ? 'out' : 'in'}-${r.number}`;
                return (
                  <tr key={k} data-decided={decided[k] ? 'true' : undefined} class={removed(r) ? 'nf-removed' : undefined}>
                    <td>{r.egress ? '아웃바운드' : '인바운드'}</td>
                    <td>{r.number === 32767 ? '32767(*)' : r.number}</td>
                    <td>{r.action}</td>
                    <td>{r.protocol === '6' ? 'tcp(6)' : r.protocol === '-1' ? '전부(-1)' : r.protocol}</td>
                    <td>{r.cidr}</td>
                    <td>{r.from === null ? '전부' : r.from === r.to ? r.from : `${r.from}-${r.to}`}</td>
                    <td>{removed(r) ? '빠뜨림(이번 모형에서 뺌)' : decided[k] ? `◀ ${decided[k]}을 결정` : ''}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <small>원고 {src(facts.rulesLine)} 아래 표. 번호가 작은 규칙부터 보다가 처음 맞는 규칙으로 결정한다({src(facts.lines.firstMatch)}).</small>
      </details>

      <details class="nf-assume">
        <summary>이 모형의 가정(실제 AWS와 다른 점)</summary>
        <ul>
          <li>TCP 연결 하나만 본다. 라우팅은 같은 VPC 안이라 항상 local이다({src(facts.lines.localRoute)}).</li>
          <li>출발 쪽 서브넷의 NACL은 원고 표의 판정을 그대로 쓴다: 앱 서브넷은 기본 NACL(전부 허용, {src(facts.lines.appNacl)}), 퍼블릭 서브넷은 egress 100 allow all({src(facts.lines.pubOut)})과 ingress 110 allow tcp 1024-65535({src(facts.lines.pubNacl)}).</li>
          <li>SG는 상태 저장이라 허용한 요청의 응답은 규칙과 상관없이 통과한다({src(facts.lines.stateful)}). DB SG의 인바운드 규칙은 "tcp {facts.dbSgRule.port} ← {facts.dbSgRule.fromSg}-sg" 하나다.</li>
          <li>임시 포트는 {EPHEMERAL_RANGE.min}~{EPHEMERAL_RANGE.max}만 받는다(원고의 OS별 범위가 모두 이 안이다).</li>
          <li>앱 b의 주소 {APP_B_IP}는 원고에 없는 모형 값이다. DB NACL 110번 규칙(10.0.11.0/24)이 가리키는 서브넷에 둔다.</li>
          <li>VPC Flow Logs·연결 추적 시간 제한·NAT·엔드포인트는 다루지 않는다.</li>
        </ul>
      </details>
    </section>
  );
}
