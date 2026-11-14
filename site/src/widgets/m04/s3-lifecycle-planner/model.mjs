// S3 수명 주기 규칙 점검기 — 설명용 모형(실제 S3·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(줄 번호는 화면에 원고에서 읽은 값으로 표시한다 — facts.mjs):
//  - 클래스별 최소 보관 기간·검색 시간: 레슨 "스토리지 클래스 한눈에" 표
//  - 갈 수 있는 전환: 레슨 수명 주기 절의 폭포(waterfall) Mermaid 그림의 간선
//  - 거부(InvalidArgument): 폭포를 거스르는 전환(같은 클래스로 두 번 전환 포함), 한 규칙 안에서 다음 전환이 이전 클래스의
//    최소 보관 기간보다 빠름, 0일 만료(레슨 "AWS가 거부하는 규칙"·lab02 11·12단계 설명),
//    만료가 어느 전환보다 빠르거나 같음 — 만료 일수는 모든 전환 일수보다 커야 한다(레슨 같은 목록. 근거 문서:
//    AWS CloudFormation 템플릿 참조 "AWS::S3::Bucket Rule"의 ExpirationInDays·Transitions 설명
//    "The expiration time must also be later than the transition time.", S3 오류 메시지
//    "'Days' in the Expiration action … must be greater than 'Days' in the Transition action").
//    이 저장소의 에뮬레이터는 이 규칙을 검사하지 않고 저장한다(레슨에 적힘).
//  - 저장되지만 돈이 새는 규칙(조기 삭제 요금): curriculum/m04-storage/sdk/lifecycle_lint.py 의 _lint_chain 과 같은 판정(WARN)
//  - 128 KB 미만 객체는 기본적으로 전환되지 않음, 2026-07 이전에는 IA 전환이 30일 이상이어야 했음: 레슨 본문(INFO)
//
// 모형의 가정(화면에도 적는다):
//  1. 객체는 0일에 Standard로 만들어지고, 규칙 하나(현재 버전 전환·만료)만 걸려 있다.
//  2. 전환은 규칙 날짜에 정확히 일어난다(실제로는 비동기라 늦을 수 있고, 하루 단위로 평가된다 — 레슨 "실제 AWS에서는").
//  3. 같은 날짜의 전환이 둘이면 입력한 순서대로 본다(원고에 없는 경우).
//  4. Intelligent-Tiering 안의 계층 이동, 이전 버전 전환, 요금 금액은 다루지 않는다.

/** 화면의 전환 칸 수(모형 화면, AWS 한도가 아니다). */
export const MAX_TRANSITIONS = 3;
/** 일수 입력 상한(모형 화면 범위, 100년). */
export const MAX_DAYS = 36500;
/** 만료가 없을 때 마지막 클래스에 머무는 모습을 그릴 최소 길이(모형 화면 값). */
export const OPEN_TAIL_MIN = 30;

/** 입력을 정수 범위로 맞춘다. 클래스는 고를 수 있는 것(폭포 그림의 Standard 밖 노드)만 남긴다. */
export function normalize(raw, choosable) {
  const int = (v, dflt) => {
    const s = String(v ?? '').trim();
    if (s === '') return dflt;
    const n = Number(s);
    if (!Number.isFinite(n)) return dflt;
    return Math.min(MAX_DAYS, Math.max(0, Math.round(n)));
  };
  const rows = (raw.transitions || []).slice(0, MAX_TRANSITIONS).map((t) => ({
    cls: choosable.includes(t?.cls) ? t.cls : '',
    days: int(t?.days, 0),
  }));
  while (rows.length < MAX_TRANSITIONS) rows.push({ cls: '', days: 0 });
  return {
    transitions: rows,
    expiration: { on: Boolean(raw.expiration?.on), days: int(raw.expiration?.days, 0) },
    small: Boolean(raw.small),
  };
}

/**
 * @param {{ transitions: {cls: string, days: number}[], expiration: {on: boolean, days: number}, small: boolean }} input normalize 된 값
 * @param {{ minDays: Record<string, number>, next: Record<string, string[]>, oldIaMinDays: number, expirationMinDays: number, restore: string[], smallKb: number }} rules
 */
export function evaluate(input, rules) {
  const steps = input.transitions
    .map((t, i) => ({ ...t, row: i + 1 }))
    .filter((t) => t.cls)
    .sort((a, b) => a.days - b.days); // 안정 정렬: 같은 날짜면 입력 순서(가정 3)
  const exp = input.expiration.on ? input.expiration.days : null;
  /** @type {{ level: 'error' | 'warn' | 'info', code: string, data: any }[]} */
  const findings = [];

  let prev = 'STANDARD';
  let prevDay = 0;
  let hasPrev = false;
  const seen = new Set();
  for (const s of steps) {
    if ((s.cls === 'STANDARD_IA' || s.cls === 'ONEZONE_IA') && s.days < rules.oldIaMinDays) {
      findings.push({ level: 'info', code: 'old-ia', data: { cls: s.cls, days: s.days, min: rules.oldIaMinDays } });
    }
    if (seen.has(s.cls)) {
      // 같은 클래스로 두 번 전환: 폭포에 X → X 간선이 없으니 거부(문구만 따로)
      findings.push({ level: 'error', code: 'duplicate-class', data: { cls: s.cls, day: s.days } });
    } else if (!(rules.next[prev] || []).includes(s.cls)) {
      findings.push({ level: 'error', code: 'backwards', data: { from: prev, to: s.cls, fromDay: hasPrev ? prevDay : null, day: s.days } });
    } else if (hasPrev && s.days - prevDay < rules.minDays[prev]) {
      findings.push({ level: 'error', code: 'too-soon', data: { from: prev, to: s.cls, fromDay: prevDay, day: s.days, min: rules.minDays[prev], need: prevDay + rules.minDays[prev] } });
    }
    seen.add(s.cls);
    prev = s.cls;
    prevDay = s.days;
    hasPrev = true;
  }
  if (exp !== null && exp < rules.expirationMinDays) {
    findings.push({ level: 'error', code: 'expire-zero', data: { days: exp, min: rules.expirationMinDays } });
  }
  // 만료는 모든 전환보다 늦어야 한다(위 머리 주석의 근거 문서). steps 는 날짜순이라 마지막이 가장 늦은 전환이다.
  const lastStep = steps[steps.length - 1];
  if (exp !== null && lastStep && exp <= lastStep.days) {
    findings.push({ level: 'error', code: 'expire-not-after-transition', data: { exp, lastDay: lastStep.days, cls: lastStep.cls, need: lastStep.days + 1 } });
  }
  const saved = !findings.some((f) => f.level === 'error');

  if (exp !== null && steps.length && saved) {
    const last = lastStep;
    if (exp - last.days < rules.minDays[last.cls]) {
      const held = exp - last.days;
      findings.push({ level: 'warn', code: 'early-delete', data: { cls: last.cls, held, min: rules.minDays[last.cls], remaining: rules.minDays[last.cls] - held } });
    }
  }
  if (steps.length && saved && input.small) findings.push({ level: 'info', code: 'small', data: { kb: rules.smallKb } });
  if (!steps.length && exp === null) findings.push({ level: 'info', code: 'empty', data: {} });

  /** 객체가 실제로 머무는 구간(규칙이 저장됐을 때만). */
  const stages = [];
  if (saved) {
    const moves = input.small ? [] : steps.filter((s) => exp === null || s.days < exp);
    const path = [{ cls: 'STANDARD', from: 0 }, ...moves.map((s) => ({ cls: s.cls, from: s.days }))];
    path.forEach((p, i) => {
      const to = i + 1 < path.length ? path[i + 1].from : exp;
      if (to !== null && to === p.from) return; // 0일 머무는 구간(만들자마자 전환)은 그리지 않는다
      const min = rules.minDays[p.cls];
      const held = to === null ? null : to - p.from;
      stages.push({
        cls: p.cls,
        from: p.from,
        to,
        held,
        min,
        endKind: i + 1 < path.length ? 'transition' : to === null ? 'open' : 'expire',
        shortBy: held !== null && held < min ? min - held : 0,
        restore: rules.restore.includes(p.cls),
      });
    });
  }
  const lastStage = stages[stages.length - 1];
  const openEnded = !!lastStage && lastStage.to === null;
  const end = !lastStage ? Math.max(exp ?? 0, 1) : openEnded ? lastStage.from + Math.max(lastStage.min, OPEN_TAIL_MIN) : lastStage.to;
  const result = !saved ? 'rejected' : findings.some((f) => f.level === 'warn') ? 'warned' : 'ok';
  return { result, saved, steps, findings, stages, end, openEnded, expiration: exp };
}

/** 일 → "30일", 365일 이상이면 "2555일(약 7년)". */
export function formatDays(n) {
  if (n >= 365) {
    const y = Math.round((n / 365) * 10) / 10;
    return `${n}일(약 ${Number.isInteger(y) ? y : y.toFixed(1)}년)`;
  }
  return `${n}일`;
}

/** 발견 사항 하나를 한 문장으로. name(api) → 화면 이름. */
export function describeFinding(f, name) {
  const d = f.data;
  switch (f.code) {
    case 'backwards':
      return `${name(d.from)}${d.fromDay === null ? '' : `(${d.fromDay}일)`} → ${name(d.to)}(${d.day}일): 폭포 방향에 없는 전환이라 거부된다(InvalidArgument).`;
    case 'too-soon':
      return `${name(d.from)}(${d.fromDay}일) → ${name(d.to)}(${d.day}일): 다음 전환이 ${name(d.from)}의 최소 보관 기간 ${d.min}일보다 빨라 거부된다(InvalidArgument). ${d.need}일 이후여야 한다.`;
    case 'expire-zero':
      return `만료 ${d.days}일: 0일 만료는 거부된다. ${d.min}일 이상이어야 한다.`;
    case 'expire-not-after-transition':
      return `만료(${d.exp}일)가 ${name(d.cls)} 전환(${d.lastDay}일)보다 빠르거나 같아 거부된다(InvalidArgument). 만료는 모든 전환보다 늦어야 한다 — ${d.need}일 이후여야 한다.`;
    case 'duplicate-class':
      return `한 규칙에 같은 클래스 전환 중복: ${name(d.cls)}(${d.day}일)로 이미 전환했다 — 거부된다(InvalidArgument).`;
    case 'early-delete':
      return `${name(d.cls)}에 ${d.held}일만 두고 삭제한다 → 최소 보관 ${d.min}일 중 남은 ${d.remaining}일치 조기 삭제 요금이 나온다(저장은 된다).`;
    case 'old-ia':
      return `${name(d.cls)} 전환 ${d.days}일: 지금은 허용되지만 2026-07 이전에는 ${d.min}일 이상이어야 했다(옛 자료·시험은 "${d.min}일 이후부터"를 정답으로 볼 수 있다).`;
    case 'small':
      return `${d.kb} KB 미만 객체는 기본적으로 어떤 클래스로도 전환되지 않는다 — 이 객체는 Standard에 머문다(위 판정은 ${d.kb} KB 이상 객체에 해당).`;
    case 'empty':
      return '전환도 만료도 없다 — 객체는 Standard에 계속 머문다.';
    default:
      return f.code;
  }
}

/** 결과 요약 한 문장. */
export function summarize(r, name) {
  if (r.result === 'rejected') {
    const n = r.findings.filter((f) => f.level === 'error').length;
    return `InvalidArgument로 규칙이 저장되지 않는다(문제 ${n}건). 객체는 Standard에 그대로 있다.`;
  }
  const where = r.stages.length > 1 ? `${r.stages.map((s) => name(s.cls)).join(' → ')} 순서로 옮겨 가고` : `${name(r.stages[0].cls)}에 머물고`;
  const tail = r.openEnded ? ' 계속 보관된다.' : ` ${formatDays(r.stages.at(-1).to)}에 삭제된다.`;
  const warn = r.result === 'warned' ? ' 다만 아래 주의 사항(비용)이 있다.' : '';
  return `객체는 ${where}${tail}${warn}`;
}

/** facts.mjs 가 원고에서 읽은 값 → evaluate 의 규칙. */
export function rulesFromFacts(f) {
  const minDays = {};
  for (const [api, c] of Object.entries(f.classes)) minDays[api] = c.minDays;
  return {
    minDays,
    next: f.waterfall.next,
    oldIaMinDays: f.oldIaMin.days,
    expirationMinDays: f.expirationMin.days,
    restore: f.restore,
    smallKb: f.smallObject.kb,
  };
}

/** 전환 대상으로 고를 수 있는 클래스(폭포 그림에서 Standard 밖의 노드, 그림 순서). */
export function choosableClasses(f) {
  const seen = [];
  for (const to of f.waterfall.next.STANDARD) if (!seen.includes(to)) seen.push(to);
  return seen;
}
