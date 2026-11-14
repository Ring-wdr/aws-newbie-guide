// 위젯의 수치를 빌드 때 원고와 lab 정책 파일에서 읽는다(GUIDE-SITE 원칙 1·4).
// 원고 문장이나 정책 JSON이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 다른 수치를 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs
//
// 읽는 것:
//  - LESSON(06-auto-scaling.md): 워크시트 ASG의 min/max와 근사식 문장(291줄 부근), 단계 조정의 경보 임계값(워크시트 5번),
//    워크시트 문항 표와 정답 표(시험이 모형과 맞춰 본다), 쿨다운 기본값, "가장 큰 용량" 규칙
//  - POLICY_FILES(labs/policies/*.json): 목표값·단계·조정량·쿨다운·예약 작업 값 — lab09에서 CLI에 넣는 바로 그 파일

export const LESSON = 'curriculum/m03-compute-scaling/06-auto-scaling.md';
export const POLICY_DIR = 'curriculum/m03-compute-scaling/labs/policies';
export const POLICY_FILES = {
  cpu: 'target-tracking-cpu50.json',
  alb: 'target-tracking-alb-requests.json',
  step: 'step-scaling-cpu.json',
  simple: 'simple-scaling.json',
  scheduled: 'scheduled-lunch-peak.json',
};

function need(cond, what) {
  if (!cond) throw new Error(`${what}을(를) 읽지 못했다(원고·정책 파일이 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/**
 * @param {string} lesson 06-auto-scaling.md 내용
 * @param {Record<keyof POLICY_FILES, string>} policies 정책 JSON 파일 내용(문자열)
 */
export function readScalingFacts(lesson, policies) {
  const lines = lesson.split('\n');
  const find = (re, what, after = 0) => {
    for (let i = after; i < lines.length; i++) {
      const m = re.exec(lines[i]);
      if (m) return { m, line: i + 1 };
    }
    throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
  };

  const ws = find(/^## 워크시트: "이 지표 값이면 몇 대\?"/, '워크시트 제목');
  const asg = find(/ASG `todayorder-policy-asg`: \*\*min (\d+) \/ max (\d+)\*\*.*필요 대수 = ⌈현재 대수 × 현재 지표 ÷ 목표값⌉\*\* \(min\/max로 자른다\)/, '워크시트 ASG의 min/max와 근사식', ws.line);
  const threshold = find(/^\| 5 \| 단계 조정\(경보 임계값 CPU (\d+)%\)/, '단계 조정 경보 임계값(워크시트 5번)', ws.line);
  const cooldownDefault = find(/\*\*쿨다운\(cooldown\)\*\*:.*\(기본 (\d+)초\)/, '쿨다운 기본값');
  const largest = find(/여러 정책이 동시에 작동하면 ASG는 \*\*가장 큰 용량을 주는 정책\*\*을 따른다/, '"가장 큰 용량" 규칙');
  const bounds = find(/\*\*최소\(min\) ≤ 희망\(desired\) ≤ 최대\(max\)\*\*/, 'min ≤ desired ≤ max 문장');

  // 워크시트 문항(| n | 상황 | ? |)과 정답(| n | **N대** | 풀이 |)
  const questions = {};
  const answers = {};
  for (let i = ws.line; i < lines.length; i++) {
    const q = /^\| (\d+) \| (.+?) \| (?:\?|어느 인스턴스\?) \|$/.exec(lines[i]);
    if (q) questions[q[1]] = { text: q[2], line: i + 1 };
    const a = /^\| (\d+) \| \*\*(\d+)대\*\* \| (.+?) \|$/.exec(lines[i]);
    if (a) answers[a[1]] = { n: Number(a[2]), why: a[3], line: i + 1 };
    if (/^## 실제 AWS에서는/.test(lines[i])) break;
  }
  need(Object.keys(questions).length >= 11 && Object.keys(answers).length >= 11, '워크시트 문항·정답 표(11개 이상)');

  const j = Object.fromEntries(Object.entries(policies).map(([k, v]) => [k, JSON.parse(v)]));
  const cpuTarget = j.cpu?.TargetTrackingConfiguration?.TargetValue;
  const albTarget = j.alb?.TargetTrackingConfiguration?.TargetValue;
  need(typeof cpuTarget === 'number' && j.cpu.TargetTrackingConfiguration.PredefinedMetricSpecification?.PredefinedMetricType === 'ASGAverageCPUUtilization', `${POLICY_FILES.cpu}의 CPU 목표값`);
  need(typeof albTarget === 'number' && j.alb.TargetTrackingConfiguration.PredefinedMetricSpecification?.PredefinedMetricType === 'ALBRequestCountPerTarget', `${POLICY_FILES.alb}의 대상당 요청 목표값`);
  need(j.step?.AdjustmentType === 'ChangeInCapacity' && Array.isArray(j.step.StepAdjustments) && j.step.StepAdjustments.length > 0, `${POLICY_FILES.step}의 단계`);
  need(Number.isInteger(j.simple?.ScalingAdjustment) && Number.isInteger(j.simple?.Cooldown), `${POLICY_FILES.simple}의 조정량·쿨다운`);
  need(Number.isInteger(j.scheduled?.MinSize) && Number.isInteger(j.scheduled?.DesiredCapacity), `${POLICY_FILES.scheduled}의 MinSize·DesiredCapacity`);

  return {
    lesson: LESSON,
    policyDir: POLICY_DIR,
    files: POLICY_FILES,
    asg: { min: Number(asg.m[1]), max: Number(asg.m[2]), line: asg.line },
    boundsLine: bounds.line,
    largestLine: largest.line,
    cooldownDefault: { sec: Number(cooldownDefault.m[1]), line: cooldownDefault.line },
    cpu: { target: cpuTarget, warmup: j.cpu.EstimatedInstanceWarmup ?? null },
    alb: { target: albTarget },
    step: { threshold: Number(threshold.m[1]), thresholdLine: threshold.line, adjustments: j.step.StepAdjustments.map((s) => ({ lower: s.MetricIntervalLowerBound ?? null, upper: s.MetricIntervalUpperBound ?? null, adjust: s.ScalingAdjustment })) },
    simple: { adjust: j.simple.ScalingAdjustment, cooldown: j.simple.Cooldown },
    scheduled: { name: j.scheduled.ScheduledActionName, recurrence: j.scheduled.Recurrence, timeZone: j.scheduled.TimeZone, min: j.scheduled.MinSize, desired: j.scheduled.DesiredCapacity },
    questions,
    answers,
  };
}
