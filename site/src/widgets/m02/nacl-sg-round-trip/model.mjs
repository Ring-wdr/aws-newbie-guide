// DB로 가는 TCP 연결 하나의 왕복 — NACL(상태 비저장)과 보안 그룹(상태 저장)의 판정. 설명용 모형(실제 VPC·에뮬레이터 실행이 아니다).
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(원고 04-security-group-vs-nacl.md):
//  - NACL: 번호가 작은 규칙부터 보다가 처음 맞는 규칙으로 결정(성격 비교 표 "평가" 행). 상태 비저장 — 응답도 반대 방향 규칙이 따로 허용해야 한다("상태" 행).
//  - SG: 규칙 중 하나라도 맞으면 허용, Allow만 있다. 상태 저장 — 허용한 요청의 응답은 규칙과 상관없이 통과.
//  - DB NACL 규칙과 DB SG 규칙은 lab05·lab04 출력에서 읽는다(facts.mjs).
//  - 출발 쪽 서브넷: 앱 서브넷은 기본 NACL(양방향 전부 허용), 퍼블릭 서브넷은 public-nacl의 egress `100 allow all`과
//    ingress `110 allow tcp 1024-65535`("한 요청을 끝까지 따라가기" 표 2·4·5번 행). 이 둘은 원고 표의 판정을 그대로 쓴다.
//
// 모형의 가정(화면에도 적는다):
//  1. 프로토콜은 TCP만, 라우팅은 같은 VPC 안이라 항상 `local`이다.
//  2. 클라이언트 임시 포트는 1024~65535만 받는다(원고의 OS별 범위가 모두 이 안이다). 그래서 출발 쪽 서브넷으로 돌아오는 응답은
//     원고 표대로 허용된다.
//  3. "앱 b 서브넷"의 주소(APP_B_IP)는 원고에 없는 모형 값이다. 원고 DB NACL의 110번 규칙(10.0.11.0/24)이 가리키는 서브넷에 둔다.

/** 원고에 없는 모형 값: 앱 b 서브넷(10.0.11.0/24)에 둔 앱 서버 주소. */
export const APP_B_IP = '10.0.11.25';
export const EPHEMERAL_RANGE = Object.freeze({ min: 1024, max: 65535 });

/** IPv4 주소 → 32비트 정수. */
export function ipToInt(ip) {
  const p = ip.split('.').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) throw new Error(`IPv4 주소가 아니다: ${ip}`);
  return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3];
}

export function inCidr(ip, cidr) {
  const [base, bits] = cidr.split('/');
  const n = Number(bits);
  const mask = n === 0 ? 0 : (0xffffffff << (32 - n)) >>> 0;
  return ((ipToInt(ip) & mask) >>> 0) === ((ipToInt(base) & mask) >>> 0);
}

/** 규칙이 이 패킷에 맞는가(TCP만). protocol "-1" = 모든 프로토콜, "6" = tcp. 포트가 None이면 모든 포트. */
export function ruleMatches(rule, { peer, port }) {
  if (rule.protocol !== '-1' && rule.protocol !== '6') return false;
  if (!inCidr(peer, rule.cidr)) return false;
  if (rule.from === null || rule.protocol === '-1') return true;
  return port >= rule.from && port <= rule.to;
}

/**
 * NACL 한 방향의 판정: 번호가 작은 규칙부터 처음 맞는 규칙.
 * @param rules 원고에서 읽은 규칙 전부, egress 방향 선택, peer: 상대 주소(인바운드면 출발지, 아웃바운드면 목적지), port: 목적지 포트
 */
export function evaluateNacl(rules, { egress, peer, port }) {
  const sorted = rules.filter((r) => r.egress === egress).sort((a, b) => a.number - b.number);
  const checked = [];
  for (const r of sorted) {
    const hit = ruleMatches(r, { peer, port });
    checked.push({ number: r.number, hit });
    if (hit) return { allow: r.action === 'allow', rule: r, checked };
  }
  return { allow: false, rule: null, checked }; // 32767 규칙이 늘 있으므로 여기 오지 않는다
}

export const SOURCES = ['app-a', 'app-b', 'alb'];

/** 왕복의 단계(순서대로)와 방향. */
export const HOPS = [
  ['route', 'req'],
  ['src-out', 'req'],
  ['nacl-in', 'req'],
  ['sg-in', 'req'],
  ['sg-out', 'res'],
  ['nacl-out', 'res'],
  ['src-in', 'res'],
];

/** 출발지의 주소·SG·서브넷 종류. ip는 facts.ip(원고)에서, 앱 b만 모형 값. */
export function sourceInfo(id, ip) {
  switch (id) {
    case 'app-b':
      return { id, ip: APP_B_IP, sg: 'app', subnet: 'app', modelIp: true };
    case 'alb':
      return { id, ip: ip.alb, sg: 'alb', subnet: 'public', modelIp: false };
    default:
      return { id: 'app-a', ip: ip.app, sg: 'app', subnet: 'app', modelIp: false };
  }
}

export function normalize(raw, defaults) {
  const int = (v, lo, hi, d) => {
    if (v === '' || v === null || v === undefined) return d;
    const n = Number(v);
    return Number.isFinite(n) ? Math.min(hi, Math.max(lo, Math.round(n))) : d;
  };
  return {
    source: SOURCES.includes(raw?.source) ? raw.source : 'app-a',
    port: int(raw?.port, 1, 65535, defaults.port),
    ephemeral: int(raw?.ephemeral, EPHEMERAL_RANGE.min, EPHEMERAL_RANGE.max, defaults.ephemeral),
    dropEgress: Boolean(raw?.dropEgress),
  };
}

/** "아웃바운드 임시 포트 규칙을 빠뜨리면": DB NACL의 egress allow 규칙(1024-65535)을 뺀다. */
export function rulesFor(rules, dropEgress) {
  return dropEgress ? rules.filter((r) => !(r.egress && r.action === 'allow' && r.from === 1024 && r.to === 65535)) : rules;
}

/**
 * 연결 하나의 왕복을 단계별로 판정한다.
 * @param x normalize 된 입력
 * @param f facts(원고): rules, dbSgRule, ip
 * @returns {{ result: 'ok' | 'nacl-in' | 'sg-in' | 'timeout', hops: Array<{ id: string, dir: 'req' | 'res', where: string, pass: boolean | null, rule?: object, note: string }>, src: object }}
 */
export function roundTrip(x, f) {
  const src = sourceInfo(x.source, f.ip);
  const rules = rulesFor(f.rules, x.dropEgress);
  const hops = [];
  const stop = (result) => {
    // 끝난 뒤의 단계는 "가지 않음"으로 채운다
    for (const [id, dir] of HOPS) if (!hops.some((h) => h.id === id)) hops.push({ id, dir, where: hopWhere(id, src), pass: null, note: '가지 않음(앞에서 끝남)' });
    return { result, hops, src };
  };

  // 요청: 출발 → DB:port
  hops.push({ id: 'route', dir: 'req', where: '라우팅 테이블', pass: true, note: `${src.ip} → ${f.ip.db}: 같은 VPC(10.0.0.0/16)라 local 경로` });
  hops.push({ id: 'src-out', dir: 'req', where: src.subnet === 'public' ? 'public-nacl 아웃바운드' : '앱 서브넷 기본 NACL 아웃바운드', pass: true, note: src.subnet === 'public' ? 'egress 100 allow all' : '기본 NACL: 전부 허용' });
  const nIn = evaluateNacl(rules, { egress: false, peer: src.ip, port: x.port });
  hops.push({ id: 'nacl-in', dir: 'req', where: 'DB NACL 인바운드', pass: nIn.allow, rule: nIn.rule, checked: nIn.checked, note: naclNote(nIn, src.ip, x.port) });
  if (!nIn.allow) return stop('nacl-in');
  const sgOk = x.port === f.dbSgRule.port && src.sg === f.dbSgRule.fromSg;
  hops.push({ id: 'sg-in', dir: 'req', where: 'DB SG 인바운드', pass: sgOk, note: sgOk ? `tcp ${f.dbSgRule.port} ← ${f.dbSgRule.fromSg}-sg 규칙에 맞음 → ALLOW` : `규칙은 tcp ${f.dbSgRule.port} ← ${f.dbSgRule.fromSg}-sg 하나뿐. 출발 ${src.sg}-sg · 포트 ${x.port}는 맞지 않음 → 거부(SG에는 Deny 규칙이 없고, 목록에 없으면 거부)` });
  if (!sgOk) return stop('sg-in');

  // 응답: DB:port → 출발:임시 포트
  hops.push({ id: 'sg-out', dir: 'res', where: 'DB SG 아웃바운드', pass: true, note: '상태 저장: 허용한 요청의 응답이라 규칙과 상관없이 통과' });
  const nOut = evaluateNacl(rules, { egress: true, peer: src.ip, port: x.ephemeral });
  hops.push({ id: 'nacl-out', dir: 'res', where: 'DB NACL 아웃바운드', pass: nOut.allow, rule: nOut.rule, checked: nOut.checked, note: `상태 비저장: 응답도 따로 판정. ${naclNote(nOut, src.ip, x.ephemeral)}` });
  if (!nOut.allow) return stop('timeout');
  hops.push({ id: 'src-in', dir: 'res', where: src.subnet === 'public' ? 'public-nacl 인바운드' : '앱 서브넷 기본 NACL 인바운드', pass: true, note: src.subnet === 'public' ? `110 allow tcp 1024-65535(목적지 포트 ${x.ephemeral})` : '기본 NACL: 전부 허용' });
  return { result: 'ok', hops, src };
}

function naclNote(r, peer, port) {
  const passed = r.checked.filter((c) => !c.hit).map((c) => c.number);
  const skipped = passed.length ? `${passed.join('·')}번은 맞지 않아 지나감 → ` : '';
  return `${skipped}${r.rule.number}번 ${r.rule.action}에서 결정(상대 ${peer}, 포트 ${port})`;
}

/** 단계의 자리 이름. */
export function hopWhere(id, src) {
  const pub = src.subnet === 'public';
  return {
    route: '라우팅 테이블',
    'src-out': pub ? 'public-nacl 아웃바운드' : '앱 서브넷 기본 NACL 아웃바운드',
    'nacl-in': 'DB NACL 인바운드',
    'sg-in': 'DB SG 인바운드',
    'sg-out': 'DB SG 아웃바운드',
    'nacl-out': 'DB NACL 아웃바운드',
    'src-in': pub ? 'public-nacl 인바운드' : '앱 서브넷 기본 NACL 인바운드',
  }[id];
}

/** 결과 요약 한 문장. */
export function summarize(rt, x) {
  switch (rt.result) {
    case 'ok':
      return `연결된다. 요청은 DB NACL 인바운드와 DB SG를 통과하고, 응답은 SG(상태 저장)를 그냥 지나 DB NACL 아웃바운드의 임시 포트 규칙으로 나간다.`;
    case 'nacl-in':
      return `요청이 DB 서브넷 경계(NACL)에서 막힌다. SG까지 가지도 않는다.`;
    case 'sg-in':
      return `요청이 NACL은 통과했지만 DB SG에서 막힌다. DB SG는 앱 SG에서 오는 5432만 허용한다.`;
    case 'timeout':
      return `요청은 DB까지 들어갔지만 응답(목적지 포트 ${x.ephemeral})이 DB NACL 아웃바운드에서 막힌다. 클라이언트는 응답을 못 받아 "타임아웃"을 본다 — NACL은 상태 비저장이다.`;
    default:
      return '';
  }
}

export const RESULT_LABEL = { ok: '연결됨', 'nacl-in': '요청 거부(NACL)', 'sg-in': '요청 거부(SG)', timeout: '응답 막힘 → 타임아웃' };

/** 원고의 예. where: 원고 줄 번호를 가리키는 facts 경로 설명. 시험이 원고 판정과 맞춰 본다. */
export const PRESETS = [
  { id: 'app-db', label: '앱 a → DB:5432', v: { source: 'app-a', port: 5432, dropEgress: false } },
  { id: 'alb-db', label: 'ALB → DB:5432 직접', v: { source: 'alb', port: 5432, dropEgress: false } },
  { id: 'app-ssh', label: '앱 a → DB:22', v: { source: 'app-a', port: 22, dropEgress: false } },
  { id: 'no-egress', label: '아웃바운드 임시 포트 규칙을 빠뜨리면', v: { source: 'app-a', port: 5432, dropEgress: true } },
];
