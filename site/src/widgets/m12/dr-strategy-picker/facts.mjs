// DR 4전략 표와 워크시트·스스로 확인을 원고에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
//  - 레슨: curriculum/m12-resilience-dr-migration/02-rto-rpo-dr-strategies.md (전략 표, 워크시트 2, 스스로 확인 1)
//  - 치트시트: curriculum/m12-resilience-dr-migration/cheatsheet.md (같은 표 + 판별 질문). 두 표의 RPO·RTO가 다르면 빌드를 실패시킨다.
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다. 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

import { RPO_TIERS, RTO_TIERS, tierOf } from './model.mjs';

export const LESSON = 'curriculum/m12-resilience-dr-migration/02-rto-rpo-dr-strategies.md';
export const CHEATSHEET = 'curriculum/m12-resilience-dr-migration/cheatsheet.md';

const cells = (line) => line.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((c) => c.trim().replace(/\*\*/g, ''));

function fail(file, what) {
  throw new Error(`${file}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/** 머리 줄(정규식)을 찾고 구분 줄 다음의 행들을 돌려준다. */
function tableAfter(lines, headRe, file, what) {
  const h = lines.findIndex((l) => headRe.test(l));
  if (h < 0) fail(file, what);
  const rows = [];
  for (let i = h + 2; i < lines.length && lines[i].startsWith('|'); i++) rows.push({ cells: cells(lines[i]), line: i + 1 });
  return { head: cells(lines[h]), rows, line: h + 1 };
}

/** RPO·RTO 칸 글자 → 단계 id. "시간 (백업 주기)" → 시간, "≈0" → 거의 0. 모르는 글자면 실패. */
export function cellTier(text, tiers, where) {
  const t = text.replace(/\s*\(.*\)\s*$/, '').replace(/^≈\s*0$/, '거의 0').trim();
  const tier = tierOf(t, tiers);
  if (!tier) throw new Error(`${where}: RPO/RTO 칸 "${text}"을(를) 모형의 단계(${tiers.map((x) => x.label).join(', ')})로 읽지 못했다`);
  return tier.id;
}

export function readDrFacts(lessonText, cheatText) {
  const L = lessonText.split('\n');
  const C = cheatText.split('\n');
  const file = LESSON.split('/').pop();

  const t = tableAfter(L, /^\| 전략 \| DR 리전에 평소 있는 것 \| 장애 때 할 일 \| RPO \| RTO \| 비용 \|/, LESSON, 'DR 4전략 표');
  if (t.rows.length !== 4) throw new Error(`${LESSON}:${t.line} DR 전략 표의 행이 4개가 아니다(${t.rows.length})`);
  const strategies = t.rows.map((r, i) => ({
    id: ['backup', 'pilot', 'warm', 'multi'][i],
    name: r.cells[0],
    standby: r.cells[1],
    onFailure: r.cells[2],
    rpoText: r.cells[3],
    rtoText: r.cells[4],
    rpo: cellTier(r.cells[3], RPO_TIERS, `${file}:${r.line}`),
    rto: cellTier(r.cells[4], RTO_TIERS, `${file}:${r.line}`),
    cost: r.cells[5],
    costRank: i, // 표의 순서 = 비용 순서(레슨 그림 "비용 ↑ · RTO/RPO ↓", 비용 칸 "가장 낮음 … 가장 높음")
    line: r.line,
  }));
  if (!/가장 낮음/.test(strategies[0].cost) || !/가장 높음/.test(strategies[3].cost)) throw new Error(`${LESSON}:${t.line} 비용 칸의 순서(가장 낮음 → 가장 높음)를 확인하지 못했다`);

  // 판별 질문 문장(레슨): **"DR 리전이 지금 이 순간 요청을 받을 수 있나?"**
  const q = L.findIndex((l) => /\*\*"DR 리전이 지금 이 순간 요청을 받을 수 있나\?"\*\*/.test(l));
  if (q < 0) fail(LESSON, '판별 질문 문장');

  // 치트시트 표: 같은 순서, 같은 RPO·RTO, 판별 질문
  const c = tableAfter(C, /^\| 전략 \| 평소 DR 리전 \| RPO \| RTO \| 비용 \| 판별 질문 \|/, CHEATSHEET, 'DR 4전략 표');
  if (c.rows.length !== 4) throw new Error(`${CHEATSHEET}:${c.line} DR 전략 표의 행이 4개가 아니다`);
  c.rows.forEach((r, i) => {
    const s = strategies[i];
    if (r.cells[0] !== s.name) throw new Error(`${CHEATSHEET}:${r.line} 전략 이름 "${r.cells[0]}" ≠ 레슨 "${s.name}"`);
    const rpo = cellTier(r.cells[2], RPO_TIERS, `cheatsheet.md:${r.line}`);
    const rto = cellTier(r.cells[3], RTO_TIERS, `cheatsheet.md:${r.line}`);
    if (rpo !== s.rpo || rto !== s.rto) throw new Error(`${CHEATSHEET}:${r.line} ${s.name}의 RPO/RTO가 레슨(${file}:${s.line})과 다르다`);
    s.question = r.cells[5];
    s.cheatLine = r.line;
  });

  // 워크시트 2: 상황 a~f 와 모범 답안 a~f
  const ws = tableAfter(L, /^\| # \| 상황 \|$/, LESSON, '워크시트 2 상황 표');
  const ans = tableAfter(L, /^\| # \| 전략 \| 근거 \|$/, LESSON, '워크시트 2 모범 답안 표');
  const worksheet = {};
  for (const r of ws.rows) worksheet[r.cells[0]] = { situation: r.cells[1], line: r.line };
  for (const r of ans.rows) {
    const w = worksheet[r.cells[0]];
    if (!w) continue;
    const s = strategies.find((x) => r.cells[1] === x.name);
    w.answer = s ? s.id : null; // e·f는 4전략 중 하나가 아니다(교차 계정 복사·Elastic Disaster Recovery)
    w.answerText = r.cells[1];
    w.answerLine = r.line;
  }
  for (const k of ['a', 'b', 'c', 'd']) if (!worksheet[k]?.answer) fail(LESSON, `워크시트 ${k}의 모범 답안(4전략 중 하나)`);

  // 스스로 확인 1: "RPO 5분, RTO 4시간인 서비스에 …" 와 답 "… 사실상 "데이터는 파일럿 라이트, 컴퓨트는 백업·복원" …"
  const sc = L.findIndex((l) => /^1\. RPO (\d+)(분|시간), RTO (\d+)(분|시간)인 서비스/.test(l));
  if (sc < 0) fail(LESSON, '스스로 확인 1번 문장');
  const scm = /^1\. RPO (\d+)(분|시간), RTO (\d+)(분|시간)인 서비스/.exec(L[sc]);
  const sca = L.findIndex((l, i) => i > sc && /사실상 "데이터는 ([^,]+), 컴퓨트는 ([^"]+)"/.test(l));
  if (sca < 0) fail(LESSON, '스스로 확인 1번 답("데이터는 …, 컴퓨트는 …")');
  const scam = /사실상 "데이터는 ([^,]+), 컴퓨트는 ([^"]+)"/.exec(L[sca]);
  const byName = (n) => {
    const s = strategies.find((x) => x.name === n.trim());
    if (!s) throw new Error(`${LESSON}:${sca + 1} 스스로 확인 답의 "${n}"이 전략 표에 없다`);
    return s.id;
  };

  return {
    lesson: LESSON,
    cheatsheet: CHEATSHEET,
    tableLine: t.line,
    questionLine: q + 1,
    strategies,
    worksheet,
    selfCheck: {
      rpo: `${scm[1]}${scm[2]}`,
      rto: `${scm[3]}${scm[4]}`,
      line: sc + 1,
      data: byName(scam[1]),
      compute: byName(scam[2]),
      answerLine: sca + 1,
    },
  };
}
