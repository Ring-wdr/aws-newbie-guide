// Athena 스캔량 어림 — 설명용 모형(실제 Athena·에뮬레이터 실행이 아니다). 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 규칙의 출처(curriculum/m11-analytics/04-query-services.md):
//  - 04:26~39 Athena 비용은 "스캔한 바이트": ① 파티션 → 읽을 폴더 수 ↓ ② 열 지향 형식(Parquet/ORC) → 읽을 열 ↓
//    ③ 압축 → 바이트 ↓ ④ 작업 그룹의 쿼리당 스캔 상한 → 전체 테이블을 스캔하는 쿼리를 차단.
//  - lab05: 파일 세 개(534·396·665바이트)를 모두 읽어 ScannedBytes 1595. 실제 Athena에서 WHERE dt='2026-11-12'는
//    그 폴더만 읽는다(파티션 프루닝).
//
// 모형의 가정(화면에도 적는다):
//  1. 파티션 필터는 "최근 d개 파티션"만 읽는다(dt 범위 조건). 필터가 없으면 모든 파티션을 읽는다.
//  2. 행 형식(JSON)은 필요한 열만 골라 읽지 못해 모든 열을 읽는다. 열 지향 형식은 고른 열만 읽고,
//     열마다 크기가 같다고 둔다(실제로는 열마다 크기가 다르다).
//  3. JSON → Parquet 변환 자체의 크기 변화는 넣지 않는다. 크기 변화는 "압축 비율" 하나로만 나타낸다(모형 값 — 원고에 수치가 없다).
//  4. 스캔 상한을 넘는 쿼리는 차단된다고만 보여 준다(차단 전까지 읽은 양은 계산하지 않는다).
//  5. 메타데이터만으로 답하는 최적화(예: Parquet의 count)는 넣지 않는다.

export const COMPRESSION_CHOICES = [1, 2, 4]; // 모형 값: 원고에 압축 비율 수치가 없다

/**
 * @param q {
 *   partitions: number[]  파티션(날짜)마다 원본 크기(바이트), 오래된 것부터
 *   filter: boolean       WHERE dt 조건으로 최근 days개만 읽나
 *   days: number
 *   format: 'json' | 'parquet'
 *   columns: number       테이블의 열 수
 *   read: number          쿼리가 쓰는 열 수(SELECT * 이면 columns)
 *   compression: number   압축 비율(1 = 없음)
 *   cutoff: number|null   작업 그룹 스캔 상한(바이트), 없으면 null
 * }
 */
export function normalize(q) {
  const P = q.partitions.length;
  const int = (v, lo, hi) => Math.min(hi, Math.max(lo, Math.round(Number(v) || lo)));
  const columns = int(q.columns, 1, 1000);
  return {
    partitions: q.partitions,
    filter: Boolean(q.filter),
    days: int(q.days, 1, Math.max(1, P)),
    format: q.format === 'parquet' ? 'parquet' : 'json',
    columns,
    read: int(q.read, 1, columns),
    compression: COMPRESSION_CHOICES.includes(Number(q.compression)) ? Number(q.compression) : 1,
    cutoff: q.cutoff == null ? null : Number(q.cutoff),
  };
}

/** 스캔량과 각 단계의 몫. */
export function scan(q) {
  const P = q.partitions.length;
  const total = q.partitions.reduce((a, b) => a + b, 0);
  const picked = q.filter ? q.partitions.slice(P - q.days) : q.partitions;
  const afterPartition = picked.reduce((a, b) => a + b, 0);
  const colsRead = q.format === 'parquet' ? q.read : q.columns;
  const afterColumns = (afterPartition * colsRead) / q.columns;
  const bytes = afterColumns / q.compression;
  const blocked = q.cutoff != null && bytes > q.cutoff;
  return {
    total,
    partitionsRead: picked.length,
    afterPartition,
    colsRead,
    afterColumns,
    bytes,
    ratio: total ? bytes / total : 0,
    blocked,
    steps: [
      { id: 'raw', label: '원래(모든 파티션·모든 열·압축 없음)', bytes: total },
      { id: 'partition', label: q.filter ? `+ 파티션 필터(최근 ${q.days}개)` : '파티션 필터 없음', bytes: afterPartition },
      { id: 'columns', label: q.format === 'parquet' ? `+ 열 지향, ${q.read}/${q.columns}개 열만` : '행 형식(JSON) — 모든 열', bytes: afterColumns },
      { id: 'compression', label: q.compression > 1 ? `+ 압축 ${q.compression}배(모형 값)` : '압축 없음', bytes },
    ],
  };
}

/** 바이트를 사람이 읽는 글자로(1024 단위). */
export function formatBytes(b) {
  const units = ['바이트', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  let v = b;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  if (i === 0) return `${Math.round(v).toLocaleString('ko-KR')}바이트`;
  const r = Number(v.toPrecision(3)); // 9.99999 → 10.0 (부동소수 오차로 자릿수가 바뀌지 않게)
  const digits = r >= 100 ? 0 : r >= 10 ? 1 : 2;
  v = r;
  return `${v.toFixed(digits)} ${units[i]}`;
}

export function formatPct(r) {
  const p = r * 100;
  if (p === 0) return '0%';
  if (p >= 10) return `${p.toFixed(0)}%`;
  if (p >= 1) return `${p.toFixed(1)}%`;
  return `${p.toPrecision(2)}%`;
}

export const TB = 1024 ** 4;

/** 크기가 같은 파티션 n개(스스로 확인 1처럼 "1년치 10 TB"를 날짜로 나눌 때). */
export function evenPartitions(totalBytes, n) {
  return Array.from({ length: n }, () => totalBytes / n);
}
