// 위젯의 수치·규칙 문구를 원고(curriculum/m10-monitoring-iac/01-cloudwatch-metrics-alarms.md)에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 값을 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs(원고 읽기 시험 포함)

export const LESSON = 'curriculum/m10-monitoring-iac/01-cloudwatch-metrics-alarms.md';

const TMD_KEYS = ['missing', 'notBreaching', 'breaching', 'ignore'];
const OPS = ['GreaterThanThreshold', 'GreaterThanOrEqualToThreshold', 'LessThanThreshold', 'LessThanOrEqualToThreshold'];

function findLine(lines, re, after = 0, what) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/** `--name value` 꼴의 CLI 인자 하나를 lines[from..to)에서 찾는다. */
function cliArg(lines, from, to, name) {
  for (let i = from; i < to; i++) {
    const m = new RegExp(`--${name}\\s+(\\S+)`).exec(lines[i]);
    if (m) return { value: m[1], line: i + 1 };
  }
  throw new Error(`${LESSON}의 put-metric-alarm 명령에서 --${name}을(를) 찾지 못했다`);
}

/**
 * @param {string} text 01-cloudwatch-metrics-alarms.md 내용
 * @returns 각 값과 원고 줄 번호
 */
export function readAlarmFacts(text) {
  const lines = text.split('\n');

  // M of N 정의: "- **Period × EvaluationPeriods × DatapointsToAlarm** — "최근 N개 구간 중 M개가 위반이면 ALARM" (M of N)."
  const mofn = findLine(lines, /Period × EvaluationPeriods × DatapointsToAlarm\*\*\s*—\s*"([^"]+)"/, 0, 'M of N 정의');

  // TreatMissingData 네 가지: `missing`(판단 보류) · `notBreaching`(정상 취급) · `breaching`(위반 취급) · `ignore`(직전 상태 유지)
  const tmdLine = findLine(lines, /^- \*\*TreatMissingData\*\*/, 0, 'TreatMissingData 설명');
  const tmd = {};
  for (const m of lines[tmdLine.line - 1].matchAll(/`(\w+)`\(([^)]+)\)/g)) tmd[m[1]] = m[2];
  for (const k of TMD_KEYS) if (!tmd[k]) throw new Error(`${LESSON}:${tmdLine.line}에서 TreatMissingData \`${k}\` 설명을 찾지 못했다`);

  // 액션은 상태가 바뀔 때 실행: "- **액션** — 상태가 **바뀔 때** 실행"
  const action = findLine(lines, /^- \*\*액션\*\*\s*—\s*상태가 \*\*바뀔 때\*\* 실행/, 0, '액션 실행 시점');

  // 고해상도: "고해상도 지표에만 10초·30초 알람을 걸 수 있다"
  const hr = findLine(lines, /고해상도 지표에만 (\d+)초·(\d+)초 알람/, 0, '고해상도 알람 주기');
  // 표준 해상도 1분: "표준(1분)과 고해상도(1초"
  const std = findLine(lines, /표준\((\d+)분\)과 고해상도/, 0, '표준 해상도');

  // lab02: put-metric-alarm 명령(여러 줄)과 바로 뒤 출력의 "State"
  const cmd = findLine(lines, /aws cloudwatch put-metric-alarm --alarm-name todayorder-api-latency-high/, 0, 'lab02 put-metric-alarm 명령');
  const cmdEnd = findLine(lines, /^```$/, cmd.line, 'lab02 명령 블록 끝').line;
  const arg = (n) => cliArg(lines, cmd.line - 1, cmdEnd, n);
  const statistic = arg('statistic');
  const period = arg('period');
  const evalN = arg('evaluation-periods');
  const dta = arg('datapoints-to-alarm');
  const threshold = arg('threshold');
  const op = arg('comparison-operator');
  const treat = arg('treat-missing-data');
  if (!OPS.includes(op.value)) throw new Error(`${LESSON}:${op.line}의 비교 연산자 ${op.value}를 모형이 모른다`);
  if (!TMD_KEYS.includes(treat.value)) throw new Error(`${LESSON}:${treat.line}의 TreatMissingData ${treat.value}를 모형이 모른다`);
  const initial = findLine(lines, /"State":\s*"(OK|ALARM|INSUFFICIENT_DATA)"/, cmdEnd, 'lab02 알람을 만든 직후 상태');

  // lab02: 게시한 값 "Values":[800,900,1000] 과 그 결과 Reason "… [900.0 (…)] was greater than the threshold (500.0) …"
  const vals = findLine(lines, /"Values":\[([\d.,\s]+)\]/, initial.line, 'lab02에서 게시한 값');
  const values = vals.m[1].split(',').map((s) => Number(s.trim()));
  const reason = findLine(lines, /Threshold Crossed: (\d+) out of the last (\d+) datapoints \[([\d.]+)/, vals.line, 'lab02 ALARM 이유');

  // 스스로 확인 2: "결제 워커가 1분마다 하트비트 지표를 보낸다" + 답 "2. `breaching` — 데이터가 없으면 위반으로 본다"
  const hb = findLine(lines, /(\d+)분마다 하트비트 지표를 보낸다/, 0, '스스로 확인 2번 문장');
  const hbAns = findLine(lines, /^2\. `(\w+)` — 데이터가 없으면/, hb.line, '스스로 확인 2번 답');
  if (!TMD_KEYS.includes(hbAns.m[1])) throw new Error(`${LESSON}:${hbAns.line}의 답 ${hbAns.m[1]}을 모형이 모른다`);

  return {
    lesson: LESSON,
    mofn: { text: mofn.m[1], line: mofn.line },
    tmd: { labels: tmd, line: tmdLine.line },
    actionLine: action.line,
    periods: { highRes: [Number(hr.m[1]), Number(hr.m[2])], highResLine: hr.line, standardSec: Number(std.m[1]) * 60, standardLine: std.line },
    lab02: {
      statistic: statistic.value,
      periodSec: Number(period.value),
      n: Number(evalN.value),
      m: Number(dta.value),
      threshold: Number(threshold.value),
      op: op.value,
      tmd: treat.value,
      cmdLine: cmd.line,
      initialState: initial.m[1],
      initialLine: initial.line,
      values,
      valuesLine: vals.line,
      reason: { breaching: Number(reason.m[1]), of: Number(reason.m[2]), datapoint: Number(reason.m[3]), line: reason.line },
    },
    heartbeat: { periodSec: Number(hb.m[1]) * 60, line: hb.line, tmd: hbAns.m[1], answerLine: hbAns.line },
  };
}
