// lab05 파일 크기·스캔 결과·작업 그룹 상한·스스로 확인 1, 그리고 테이블 열 목록을 원고에서 빌드 때 읽는다(GUIDE-SITE 원칙 4).
//  - 레슨 4: curriculum/m11-analytics/04-query-services.md
//  - 레슨 3: curriculum/m11-analytics/03-glue-catalog-etl.md (orders 테이블 열 목록 출력)
// 원고 문장이 바뀌어 읽지 못하거나, 파일 크기의 합이 기록된 ScannedBytes와 다르면 빌드를 실패시킨다.
// 순수 함수(파일을 읽지 않는다). 단위 시험: model.test.mjs

export const LESSON = 'curriculum/m11-analytics/04-query-services.md';
export const CATALOG_LESSON = 'curriculum/m11-analytics/03-glue-catalog-etl.md';

function findLine(lines, re, file, what, after = 0) {
  for (let i = after; i < lines.length; i++) {
    const m = re.exec(lines[i]);
    if (m) return { m, line: i + 1 };
  }
  throw new Error(`${file}에서 ${what}을(를) 찾지 못했다(원고가 바뀌었으면 위젯 facts.mjs도 맞춘다)`);
}

export function readScanFacts(lessonText, catalogText) {
  const L = lessonText.split('\n');
  const C = catalogText.split('\n');

  // 비용 원칙 네 줄: "1. **파티션**(…) → 읽을 폴더 수 ↓" … "4. **작업 그룹의 쿼리당 스캔 상한**"
  const head = findLine(L, /^### Athena 비용은 "스캔한 바이트"/, LESSON, '스캔 비용 절');
  const rules = {};
  for (const [k, re] of [
    ['partition', /^1\. \*\*파티션\*\*/],
    ['columnar', /^2\. \*\*열 지향 형식\*\*/],
    ['compression', /^3\. \*\*압축\*\*/],
    ['cutoff', /^4\. \*\*작업 그룹의 쿼리당 스캔 상한\*\*/],
  ]) rules[k] = findLine(L, re, LESSON, `스캔 줄이기 ${k} 줄`, head.line).line;

  // lab05 파일 목록: "534 raw/orders/dt=2026-11-10/backfill-0000.json" …(연속된 줄)
  const first = findLine(L, /^(\d+) raw\/orders\/dt=(\d{4}-\d{2}-\d{2})\//, LESSON, 'lab05 파일 목록', rules.cutoff);
  const files = [];
  for (let i = first.line - 1; i < L.length; i++) {
    const m = /^(\d+) raw\/orders\/dt=(\d{4}-\d{2}-\d{2})\//.exec(L[i]);
    if (!m) break;
    files.push({ bytes: Number(m[1]), dt: m[2], line: i + 1 });
  }
  // 작업 그룹 상한: "CutoffBytes": 104857600 (명령 출력)
  const cutoff = findLine(L, /"CutoffBytes":\s*(\d+)/, LESSON, '작업 그룹 CutoffBytes 출력', first.line);
  // 기록된 스캔량: "ScannedBytes": 1595
  const scanned = findLine(L, /"ScannedBytes":\s*(\d+)/, LESSON, 'lab05 ScannedBytes 출력', cutoff.line);
  const sum = files.reduce((a, f) => a + f.bytes, 0);
  if (sum !== Number(scanned.m[1])) throw new Error(`${LESSON}:${scanned.line} ScannedBytes ${scanned.m[1]} ≠ 파일 크기 합 ${sum}`);
  // 파티션 프루닝 쿼리: "SELECT count(*) AS orders, sum(amount) AS revenue FROM orders WHERE dt = '2026-11-12'"
  const prune = findLine(L, /^SELECT count\(\*\) AS orders, sum\((\w+)\) AS revenue FROM orders WHERE dt = '(\d{4}-\d{2}-\d{2})'$/, LESSON, '파티션 프루닝 쿼리', scanned.line);
  if (files.at(-1).dt !== prune.m[2]) throw new Error(`${LESSON}:${prune.line} 쿼리 날짜 ${prune.m[2]}가 lab05의 마지막 파티션(${files.at(-1).dt})이 아니다`);
  // 스스로 확인 1: "1년치 주문 로그(10 TB, JSON)를 … "최근 7일, 매장별 매출""
  const sc = findLine(L, /^1\. .*1년치 주문 로그\((\d+) TB, (JSON)\).*"최근 (\d+)일, 매장별 매출"/, LESSON, '스스로 확인 1번 문장');

  // 레슨 3: orders 테이블 열 목록 "Columns": "order_id, store, menu, qty, amount, payment, ordered_at"
  const cols = findLine(C, /"Columns":\s*"([^"]+)"/, CATALOG_LESSON, 'orders 테이블 열 목록 출력');
  const columns = cols.m[1].split(',').map((s) => s.trim());
  for (const need of [prune.m[1], 'store']) if (!columns.includes(need)) throw new Error(`${CATALOG_LESSON}:${cols.line} 열 목록에 ${need}가 없다`);

  return {
    lesson: LESSON,
    rules,
    lab05: { files, cutoffBytes: Number(cutoff.m[1]), cutoffLine: cutoff.line, scannedBytes: Number(scanned.m[1]), scannedLine: scanned.line, query: { column: prune.m[1], dt: prune.m[2], line: prune.line } },
    selfCheck: { tb: Number(sc.m[1]), format: sc.m[2], days: Number(sc.m[3]), line: sc.line },
    columns,
    columnsLine: cols.line,
  };
}
