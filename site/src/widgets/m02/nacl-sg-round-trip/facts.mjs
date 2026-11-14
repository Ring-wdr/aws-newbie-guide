// 위젯의 규칙·주소를 빌드 때 원고(curriculum/m02-vpc-networking/04-security-group-vs-nacl.md)에서 읽는다(GUIDE-SITE 원칙 4).
// 원고가 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 규칙을 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs
//
// 읽는 것:
//  - lab05 출력 "== 5. DB NACL 의 규칙" 아래 describe-network-acls 표(DB NACL 규칙 전부: 방향·번호·동작·프로토콜·CIDR·포트)
//  - lab05 워크시트 Q4~Q6 판정 줄(시험이 모형과 맞춰 본다)
//  - lab04 출력의 SG ID(alb/app/db)와 DB SG 인바운드 규칙(tcp 5432 ← 앱 SG), 워크시트 Q3·Q4
//  - "한 요청을 끝까지 따라가기"의 설명용 주소(ALB 10.0.0.50, 앱 10.0.10.25, DB 10.0.20.30)와 임시 포트 예(49152)

export const LESSON = 'curriculum/m02-vpc-networking/04-security-group-vs-nacl.md';

export function readNaclFacts(text) {
  const lines = text.split('\n');
  const find = (re, what, after = 0) => {
    for (let i = after; i < lines.length; i++) {
      const m = re.exec(lines[i]);
      if (m) return { m, line: i + 1 };
    }
    throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
  };

  // DB NACL 규칙 표
  const head = find(/^== 5\. DB NACL 의 규칙/, 'lab05 "DB NACL 의 규칙" 출력');
  const rules = [];
  for (let i = head.line; i < lines.length && i < head.line + 20; i++) {
    const m = /^\|\s*(True|False)\s*\|\s*(\d+)\s*\|\s*(allow|deny)\s*\|\s*(-1|\d+)\s*\|\s*([\d.]+\/\d+)\s*\|\s*(None|\d+)\s*\|\s*(None|\d+)\s*\|/.exec(lines[i]);
    if (m) {
      rules.push({
        egress: m[1] === 'True',
        number: Number(m[2]),
        action: m[3],
        protocol: m[4],
        cidr: m[5],
        from: m[6] === 'None' ? null : Number(m[6]),
        to: m[7] === 'None' ? null : Number(m[7]),
        line: i + 1,
      });
    }
    if (/^== 6\./.test(lines[i])) break;
  }
  if (rules.length < 4 || !rules.some((r) => r.number === 32767)) throw new Error(`${LESSON}의 DB NACL 규칙 표를 읽지 못했다(${rules.length}행)`);

  // lab05 워크시트 판정(Q4~Q6)
  const ws = {};
  for (const q of ['Q4', 'Q5', 'Q6']) {
    const f = find(new RegExp(`^\\s+${q} .*\\s(\\d+) (allow|deny)\\s*$`), `lab05 워크시트 ${q}`, head.line);
    ws[q] = { number: Number(f.m[1]), action: f.m[2], line: f.line, text: lines[f.line - 1].trim() };
  }

  // SG: ID 대응과 DB SG 인바운드 규칙
  const ids = find(/^\s+alb=(sg-[0-9a-f]+) app=(sg-[0-9a-f]+) db=(sg-[0-9a-f]+)/, 'lab04 SG ID 줄');
  const sg = { alb: ids.m[1], app: ids.m[2], db: ids.m[3], line: ids.line };
  const dbRule = find(new RegExp(`^${sg.db}\\s+tcp\\s+(\\d+)\\s+(sg-[0-9a-f]+)\\s*$`), 'DB SG 인바운드 규칙 줄', ids.line);
  const owner = Object.entries(sg).find(([, v]) => v === dbRule.m[2]);
  if (!owner) throw new Error(`${LESSON}: DB SG 규칙의 출처 SG ${dbRule.m[2]}가 alb/app/db 중 무엇인지 모른다`);
  const dbSgRule = { port: Number(dbRule.m[1]), fromSg: owner[0], line: dbRule.line };
  const sgQ3 = find(/^\s+Q3 ALB\(SG sg-[0-9a-f]+\) → DB:5432\s+(ALLOW|DENY)/, 'lab04 워크시트 Q3', ids.line);
  const sgQ4 = find(/^\s+Q4 앱\(SG sg-[0-9a-f]+\) → DB:5432\s+(ALLOW|DENY)/, 'lab04 워크시트 Q4', ids.line);

  // 설명용 주소와 임시 포트
  const trace = find(/IP 중 고객 `[\d.]+`, ALB 사설 IP `([\d.]+)`, 앱 `([\d.]+)`, DB `([\d.]+)`과 임시 포트 번호는 설명용 예시다/, '"한 요청을 끝까지 따라가기"의 설명용 주소');
  const eph = find(/^요청:\s+([\d.]+):(\d+)\s+→\s+([\d.]+):(\d+)\s*$/, '임시 포트 예(요청 줄)');
  const ephRange = find(/Linux 기본 (\d+)-(\d+), Windows (\d+)-(\d+)/, 'OS별 임시 포트 범위');
  const needOut = find(/^- 아웃바운드: `[\d./]+`로 tcp \*\*1024-65535\*\* 허용 ← 이걸 빠뜨리면 요청은 들어가는데 응답이 못 나와 "타임아웃"/, 'DB NACL 아웃바운드 임시 포트 설명');
  const stateful = find(/^\| \*\*상태\*\* \| \*\*상태 저장\(stateful\)\*\*/, '성격 비교 표의 "상태" 행');
  const firstMatch = find(/^\| 평가 \| 모든 규칙 중 하나라도 맞으면 허용 \| \*\*번호가 작은 규칙부터\*\*/, '성격 비교 표의 "평가" 행');
  const localRoute = find(/^\| 3 \| 앱 .* \| app-rt-a: `10\.0\.0\.0\/16 → local`/, '"한 요청을 끝까지 따라가기" 3번 행(라우팅)');
  const appNacl = find(/^\| 4 \| \(응답\) DB .*들어옴 기본 NACL `allow`/, '"한 요청을 끝까지 따라가기" 4번 행(앱 서브넷 기본 NACL)');
  const pubNacl = find(/^\| 5 \| \(응답\) 앱 .*들어옴 public-nacl: `110 allow tcp 1024-65535`/, '"한 요청을 끝까지 따라가기" 5번 행(public-nacl 110번)');
  const pubOut = find(/^\| 2 \| ALB .*나감 public-nacl: egress `100 allow all`/, '"한 요청을 끝까지 따라가기" 2번 행(public-nacl 아웃바운드)');

  return {
    lesson: LESSON,
    rules,
    rulesLine: head.line,
    worksheet: ws,
    sg,
    dbSgRule,
    sgWorksheet: { Q3: { verdict: sgQ3.m[1], line: sgQ3.line }, Q4: { verdict: sgQ4.m[1], line: sgQ4.line } },
    ip: { alb: trace.m[1], app: trace.m[2], db: trace.m[3], line: trace.line },
    ephemeral: { port: Number(eph.m[2]), line: eph.line, linux: [Number(ephRange.m[1]), Number(ephRange.m[2])], windows: [Number(ephRange.m[3]), Number(ephRange.m[4])], rangeLine: ephRange.line },
    lines: { needOut: needOut.line, stateful: stateful.line, firstMatch: firstMatch.line, localRoute: localRoute.line, appNacl: appNacl.line, pubNacl: pubNacl.line, pubOut: pubOut.line },
  };
}
