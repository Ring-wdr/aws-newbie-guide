// node --test src/widgets/m11/athena-scan-estimator/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { scan, normalize, formatBytes, formatPct, evenPartitions, TB } from './model.mjs';
import { readScanFacts, LESSON, CATALOG_LESSON } from './facts.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const lessonText = fs.readFileSync(path.join(root, LESSON), 'utf8');
const catText = fs.readFileSync(path.join(root, CATALOG_LESSON), 'utf8');
const f = readScanFacts(lessonText, catText);
const lab = (o) => normalize({ partitions: f.lab05.files.map((x) => x.bytes), filter: false, days: 1, format: 'json', columns: f.columns.length, read: 1, compression: 1, cutoff: f.lab05.cutoffBytes, ...o });

test('원고 값: lab05 파일 세 개, 상한 100 MB, 열 7개', () => {
  assert.deepEqual(f.lab05.files.map((x) => x.bytes), [534, 396, 665]);
  assert.equal(f.lab05.cutoffBytes, 100 * 1024 * 1024);
  assert.equal(f.columns.length, 7);
  assert.deepEqual([f.selfCheck.tb, f.selfCheck.format, f.selfCheck.days], [10, 'JSON', 7]);
  assert.equal(f.lab05.query.column, 'amount');
});

test('lab05: 파티션 필터 없이 JSON → 기록된 ScannedBytes 1595', () => {
  const r = scan(lab({}));
  assert.equal(r.bytes, f.lab05.scannedBytes);
  assert.equal(r.blocked, false);
});

test("lab05: WHERE dt='2026-11-12'(최근 1개 파티션) → 그 폴더 665바이트만", () => {
  const r = scan(lab({ filter: true, days: 1 }));
  assert.equal(r.bytes, 665);
  assert.equal(r.partitionsRead, 1);
});

test('JSON은 필요한 열만 골라도 모든 열을 읽고, Parquet은 고른 열만 읽는다', () => {
  assert.equal(scan(lab({ read: 1 })).colsRead, 7);
  const p = scan(lab({ format: 'parquet', read: 1 }));
  assert.equal(p.colsRead, 1);
  assert.equal(p.bytes, 1595 / 7);
});

test('압축은 바이트를 나눈다(모형 비율), 모르는 비율은 1', () => {
  assert.equal(scan(lab({ compression: 4 })).bytes, 1595 / 4);
  assert.equal(normalize({ partitions: [1], compression: 3 }).compression, 1);
});

test('스스로 확인 1: 10 TB JSON 1년치 → 최근 7일·Parquet·2열·압축으로 단계마다 준다', () => {
  const parts = evenPartitions(f.selfCheck.tb * TB, 365);
  const base = normalize({ partitions: parts, filter: false, days: 7, format: 'json', columns: 7, read: 2, compression: 1, cutoff: f.lab05.cutoffBytes });
  const r0 = scan(base);
  assert.equal(Math.round(r0.bytes / TB), 10);
  assert.equal(r0.blocked, true);
  const r1 = scan({ ...base, filter: true });
  assert.ok(Math.abs(r1.bytes - (10 * TB * 7) / 365) < 1);
  const r2 = scan({ ...base, filter: true, format: 'parquet' });
  assert.ok(Math.abs(r2.bytes - (r1.bytes * 2) / 7) < 1);
  const r3 = scan({ ...base, filter: true, format: 'parquet', compression: 4 });
  assert.ok(Math.abs(r3.bytes - r2.bytes / 4) < 1);
  assert.ok(r3.bytes > f.lab05.cutoffBytes); // 그래도 10 GB 넘게 → 100 MB 상한이면 차단
  assert.equal(r3.steps.length, 4);
});

test('경계: 상한과 같으면 통과, 1바이트 넘으면 차단, 상한 없으면 차단 없음', () => {
  assert.equal(scan(normalize({ partitions: [100], cutoff: 100 })).blocked, false);
  assert.equal(scan(normalize({ partitions: [101], cutoff: 100 })).blocked, true);
  assert.equal(scan(normalize({ partitions: [10 ** 15], cutoff: null })).blocked, false);
});

test('normalize: days는 1..파티션 수, read는 1..columns', () => {
  const q = normalize({ partitions: [1, 2, 3], days: 99, columns: 7, read: 99 });
  assert.equal(q.days, 3);
  assert.equal(q.read, 7);
  assert.equal(normalize({ partitions: [1, 2, 3], days: 0, columns: 7, read: 0 }).days, 1);
  assert.equal(scan(normalize({ partitions: [1, 2, 3], filter: true, days: 3 })).partitionsRead, 3);
});

test('formatBytes·formatPct', () => {
  assert.equal(formatBytes(665), '665바이트');
  assert.equal(formatBytes(1595), '1.56 KB');
  assert.equal(formatBytes(100 * 1024 * 1024), '100 MB');
  assert.equal(formatBytes(10 * TB), '10.0 TB');
  assert.equal(formatPct(1), '100%');
  assert.equal(formatPct(0.0192), '1.9%');
  assert.equal(formatPct(0.00137), '0.14%');
});

test('원고가 바뀌면 실패: ScannedBytes가 파일 합과 다르면', () => {
  const bad = lessonText.replace('"ScannedBytes": 1595', '"ScannedBytes": 1596');
  assert.notEqual(bad, lessonText);
  assert.throws(() => readScanFacts(bad, catText), /≠ 파일 크기 합/);
  assert.throws(() => readScanFacts('# 빈\n', catText), /찾지 못했다/);
});

test('formatBytes: 부동소수 오차(10 TB를 365로 나눠 더한 값)도 10.0 TB', () => {
  const sum = evenPartitions(10 * TB, 365).reduce((a, b) => a + b, 0);
  assert.equal(formatBytes(sum), '10.0 TB');
  assert.equal(formatBytes(99.96 * 1024 ** 3), '100 GB');
});
