// 위젯의 수치·문장 근거를 원고(curriculum/m05-databases/02-multi-az-vs-read-replica.md)에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
// 원고 문장이 바뀌어 읽지 못하면 빌드를 실패시킨다 — 위젯이 원고와 다른 수치를 조용히 보여 주지 않게.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs(원고 읽기 시험 포함)

export const LESSON = 'curriculum/m05-databases/02-multi-az-vs-read-replica.md';

function findLine(lines, re, what, after = 0) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${LESSON}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

/**
 * @param {string} text 02-multi-az-vs-read-replica.md 내용
 */
export function readReplicaFacts(text) {
  const lines = text.split('\n');
  const L = (re, what, after) => findLine(lines, re, what, after);

  // 비교 표(| | Multi-AZ (인스턴스 배포) | 읽기 전용 복제본(Read Replica) |)의 행들
  const head = L(/^\|\s*\|\s*Multi-AZ \(인스턴스 배포\)\s*\|\s*읽기 전용 복제본/, '비교 표 머리');
  const row = (label) => L(new RegExp(`^\\|\\s*${label}\\s*\\|`), `비교 표의 "${label}" 행`, head.line);

  const sync = row('복제 방식');
  if (!/\*\*동기\*\*/.test(lines[sync.line - 1]) || !/\*\*비동기\*\*/.test(lines[sync.line - 1])) throw new Error(`${LESSON}:${sync.line} 복제 방식 행에 동기/비동기가 없다`);
  const readStandby = row('두 번째 DB로 읽기');
  if (!/\*\*불가\*\*/.test(lines[readStandby.line - 1])) throw new Error(`${LESSON}:${readStandby.line} 대기 인스턴스 읽기 불가가 없다`);

  const fo = row('장애 시');
  const ft = /\(보통 ([^)]+)\)/.exec(lines[fo.line - 1]);
  if (!ft) throw new Error(`${LESSON}:${fo.line} 장애 조치 시간("보통 …")이 없다`);
  const failover = { time: ft[1], line: fo.line };

  const cnt = row('개수');
  const c = /최대 \*\*(\d+)\*\*\(([^)]+)\), \*\*(\S+?)은 최대 (\d+)\*\*/.exec(lines[cnt.line - 1]);
  if (!c) throw new Error(`${LESSON}:${cnt.line} 복제본 개수 행을 해석할 수 없다`);
  const engines = [...c[2].split('·').map((e) => ({ id: e, max: Number(c[1]) })), { id: c[3], max: Number(c[4]) }];
  const replicaMax = { engines, line: cnt.line };

  const pre = row('전제 조건');
  const b = /보존 기간 ≥ (\d+)/.exec(lines[pre.line - 1]);
  if (!b) throw new Error(`${LESSON}:${pre.line} 자동 백업 보존 기간 조건이 없다`);
  const backup = { minRetention: Number(b[1]), line: pre.line };

  const loc = row('위치');
  if (!/같은 AZ·다른 AZ·\*\*다른 리전\*\*/.test(lines[loc.line - 1])) throw new Error(`${LESSON}:${loc.line} 복제본 위치(같은 AZ·다른 AZ·다른 리전)가 없다`);

  // 장애 조치 순서(시퀀스 그림)
  const promoteStandby = L(/S->>S: 대기 → 기본으로 승격/, '시퀀스 그림의 대기 승격');
  const dnsSwap = L(/DNS-->>DNS: 같은 이름을 1b의 IP로 변경/, '시퀀스 그림의 DNS 변경');
  const noLoss = L(/데이터 손실 없음 — 동기 복제/, '시퀀스 그림의 데이터 손실 없음');

  // 쓰기 병목의 답, 교차 리전 요금, lab02 5단계 오류
  const wr = L(/^- 쓰기가 한계라면\? → (.+)\(레슨 4\)\.$/, '쓰기 병목의 답');
  const writeRemedy = { text: wr.m[1].trim(), line: wr.line };
  const xr = L(/\*\*교차 리전 복제본은 데이터 전송 요금\*\*/, '교차 리전 복제본 요금');
  const noBackup = L(/InvalidDBInstanceState.*Automated backups are not enabled/, 'lab02 5단계 오류 출력');

  // 시험 포인트: "AZ 장애에도 DB 자동 복구, 데이터 손실 최소" → Multi-AZ
  const exam = L(/^- "AZ 장애에도 DB 자동 복구, 데이터 손실 최소" → \*\*Multi-AZ\*\*/, '시험 포인트의 Multi-AZ 문장');

  // lab02 1단계: Multi-AZ 인스턴스를 만드는 명령의 자동 백업 보존 기간(위젯의 처음 값)
  const lr = L(/--multi-az --backup-retention-period (\d+)/, 'lab02 1단계의 보존 기간');
  const labRetention = { days: Number(lr.m[1]), line: lr.line };

  // 스스로 확인 답
  const ans1 = L(/^1\. 안 된다\. Multi-AZ 대기 인스턴스는 트래픽을 받지 않는다/, '스스로 확인 1번 답');
  const ans2 = L(/^2\. Multi-AZ는 같은 DNS 이름을 유지하므로/, '스스로 확인 2번 답');
  const ans3 = L(/^3\. 버그가 아니라 비동기 복제의 지연이다/, '스스로 확인 3번 답');

  return {
    lesson: LESSON,
    tableLine: head.line,
    syncLine: sync.line,
    readStandbyLine: readStandby.line,
    locationLine: loc.line,
    failover,
    replicaMax,
    backup,
    seq: { promote: promoteStandby.line, dns: dnsSwap.line, noLoss: noLoss.line },
    writeRemedy,
    labRetention,
    examLine: exam.line,
    crossRegionFeeLine: xr.line,
    noBackupErrorLine: noBackup.line,
    answers: { report: ans1.line, endpoint: ans2.line, lag: ans3.line },
  };
}
