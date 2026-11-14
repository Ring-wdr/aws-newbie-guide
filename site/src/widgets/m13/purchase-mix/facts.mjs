// 워크시트 2의 예시 숫자와 모범 답안을 원고(curriculum/m13-cost-optimization/02-compute-cost.md)에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하거나, 모형이 모범 답안의 세 월 비용을 다시 내지 못하면 빌드를 실패시킨다.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

import { cost, worksheetPlans, usd } from './model.mjs';

export const LESSON = 'curriculum/m13-cost-optimization/02-compute-cost.md';

function findLine(lines, re, after = 0, what) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

export function readMixFacts(text) {
  const L = text.split('\n');
  const ws = findLine(L, /^### 워크시트 2: 구매 옵션 조합/, 0, '워크시트 2 제목');
  // "예시 단가 `m7i.large` 0.10 USD/시간, Savings Plans 할인 30%, 스팟 할인 70%(모두 **예시 숫자**). 한 달 730시간."
  const p = findLine(L, /^예시 단가 `([\w.]+)` ([\d.]+) USD\/시간, Savings Plans 할인 (\d+)%, 스팟 할인 (\d+)%.*한 달 (\d+)시간/, ws.line, '예시 단가 문장');
  // "- API 바닥 6대 × 730시간"
  const base = findLine(L, /^- API 바닥 (\d+)대 × (\d+)시간$/, p.line, 'API 바닥 줄');
  // "- 피크 추가 6대 × 하루 6시간 × 30일 = 180시간"
  const peak = findLine(L, /^- 피크 추가 (\d+)대 × 하루 (\d+)시간 × (\d+)일 = (\d+)시간$/, p.line, '피크 줄');
  // "- 정산 배치 4대 × 하루 8시간 × 30일 = 240시간 (중단되면 처음부터 다시 돌리면 됨)"
  const batch = findLine(L, /^- 정산 배치 (\d+)대 × 하루 (\d+)시간 × (\d+)일 = (\d+)시간 \(([^)]+)\)$/, p.line, '정산 배치 줄');
  for (const r of [peak, batch]) {
    if (Number(r.m[2]) * Number(r.m[3]) !== Number(r.m[4])) throw new Error(`${LESSON}:${r.line} 시간 계산이 맞지 않는다`);
  }
  // 모범 답안: "| (1) 전부 온디맨드 | … | **642.00** |"
  const answers = {};
  for (const id of ['1', '2', '3']) {
    const a = findLine(L, new RegExp(`^\\| \\(${id}\\) [^|]+\\| [^|]+\\| \\*\\*([\\d.]+)\\*\\* \\|$`), batch.line, `모범 답안 (${id})`);
    answers[id] = { total: Number(a.m[1]), line: a.line };
  }
  // 스스로 확인 2(약정은 최소 지불 금액)의 답 줄
  const sc2 = findLine(L, /^2\. 약정 금액 .*"최소 지불 금액"이다/, batch.line, '스스로 확인 2번 답');
  // 시험 포인트: "중단되면 안 됨" 조건이 보이면 스팟 보기를 지운다
  const noStop = findLine(L, /"중단되면 안 됨" 조건이 보이면 스팟 보기를 지운다/, 0, '스팟 제외 조건(시험 포인트)');
  // 구매 옵션 표의 공식 "최대" 할인(참고로만 보여 준다 — 계산에는 예시 숫자를 쓴다)
  const maxRow = (name) => {
    const r = findLine(L, new RegExp(`^\\| (?:\\*\\*)?${name}(?:\\*\\*)? \\|[^|]+\\| 최대 (\\d+)% \\|`), 0, `구매 옵션 표의 ${name} 행`);
    return { pct: Number(r.m[1]), line: r.line };
  };

  const f = {
    lesson: LESSON,
    instance: p.m[1],
    price: Number(p.m[2]),
    spDiscount: Number(p.m[3]) / 100,
    spotDiscount: Number(p.m[4]) / 100,
    hours: Number(p.m[5]),
    priceLine: p.line,
    base: { count: Number(base.m[1]), hours: Number(base.m[2]), line: base.line },
    peak: { count: Number(peak.m[1]), hours: Number(peak.m[4]), perDay: Number(peak.m[2]), line: peak.line },
    batch: { count: Number(batch.m[1]), hours: Number(batch.m[4]), perDay: Number(batch.m[2]), note: batch.m[5], line: batch.line },
    answers,
    selfCheck2Line: sc2.line,
    noStopLine: noStop.line,
    officialMax: { computeSP: maxRow('Compute Savings Plans'), spot: maxRow('스팟') },
  };
  if (f.base.hours !== f.hours) throw new Error(`${LESSON}:${base.line} 바닥 시간이 한 달 시간(${f.hours})과 다르다`);
  // 모형이 원고의 모범 답안을 그대로 다시 내는지 확인(어긋나면 빌드 실패)
  for (const plan of worksheetPlans(f)) {
    const got = cost(f, plan.choice).total;
    if (usd(got) !== usd(answers[plan.id].total)) throw new Error(`모형의 ${plan.label} = ${usd(got)} ≠ 원고 ${LESSON}:${answers[plan.id].line}의 ${usd(answers[plan.id].total)}`);
  }
  return f;
}
