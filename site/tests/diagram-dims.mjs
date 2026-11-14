// 다이어그램 치수 비교: 두 산출물(dist)의 Mermaid SVG 크기와 라벨 상자(foreignObject) 크기가 같은지 본다.
// 다른 OS 에서 빌드한 산출물끼리(예: ubuntu 컨테이너에서 빌드한 것과 macOS 에서 빌드한 것) 비교해, 실린 다이어그램 글꼴
// (src/plugins/diagram-font.mjs) 덕에 빌드한 기계와 상관없이 같은 크기로 재는지 확인한다. 브라우저는 쓰지 않는다.
// 사용:
//   node tests/diagram-dims.mjs <dist 폴더> > a.json                       # 치수 뽑기
//   node tests/diagram-dims.mjs --compare a.json b.json [--tolerance 0.5]  # 비교(차이가 허용 오차를 넘으면 종료 코드 1)
import fs from 'node:fs';
import path from 'node:path';

const num = (v) => Number.parseFloat(v);

/** HTML·SVG 글에서 Mermaid SVG(id="mmd-…")마다 viewBox 와 라벨 상자 크기 목록을 꺼낸다. */
export function dimsOf(text) {
  const out = {};
  const re = /<svg\b[^>]*\sid="(mmd-[0-9a-f]+-(?:light|dark)-\d+)"[^>]*>/g;
  for (const m of text.matchAll(re)) {
    const id = m[1];
    const vb = /viewBox="([-\d.]+) ([-\d.]+) ([\d.]+) ([\d.]+)"/.exec(m[0]);
    const end = text.indexOf('</svg>', m.index);
    const body = text.slice(m.index, end);
    const labels = [...body.matchAll(/<foreignObject\b[^>]*?\swidth="([\d.]+)"[^>]*?\sheight="([\d.]+)"/g)].map((x) => [num(x[1]), num(x[2])]);
    out[id] = { w: vb ? num(vb[3]) : null, h: vb ? num(vb[4]) : null, labels };
  }
  return out;
}

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (/\.(html|svg)$/.test(e.name)) out.push(p);
  }
  return out.sort();
}

export function collect(dist) {
  const all = {};
  for (const f of walk(dist)) Object.assign(all, dimsOf(fs.readFileSync(f, 'utf8')));
  return all;
}

export function compare(a, b, tol = 0.5) {
  const diffs = [];
  for (const id of new Set([...Object.keys(a), ...Object.keys(b)])) {
    const x = a[id];
    const y = b[id];
    if (!x || !y) {
      diffs.push(`${id}: 한쪽에만 있음`);
      continue;
    }
    if (Math.abs(x.w - y.w) > tol || Math.abs(x.h - y.h) > tol) diffs.push(`${id}: 그림 ${x.w}×${x.h} / ${y.w}×${y.h}`);
    if (x.labels.length !== y.labels.length) diffs.push(`${id}: 라벨 수 ${x.labels.length} / ${y.labels.length}`);
    else
      x.labels.forEach((l, i) => {
        const m = y.labels[i];
        if (Math.abs(l[0] - m[0]) > tol || Math.abs(l[1] - m[1]) > tol) diffs.push(`${id} 라벨 ${i + 1}: ${l.join('×')} / ${m.join('×')}`);
      });
  }
  return diffs;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  if (args[0] === '--compare') {
    const ti = args.indexOf('--tolerance');
    const tol = ti >= 0 ? Number(args[ti + 1]) : 0.5;
    const a = JSON.parse(fs.readFileSync(args[1], 'utf8'));
    const b = JSON.parse(fs.readFileSync(args[2], 'utf8'));
    const diffs = compare(a, b, tol);
    const labels = Object.values(a).reduce((s, x) => s + x.labels.length, 0);
    for (const d of diffs.slice(0, 40)) console.log(d);
    if (diffs.length > 40) console.log(`… 외 ${diffs.length - 40}건`);
    console.log(`${diffs.length ? 'DIFF' : 'SAME'} diagram-dims: 그림 ${Object.keys(a).length}개·라벨 ${labels}개 비교(허용 오차 ${tol}px), 차이 ${diffs.length}건`);
    process.exit(diffs.length ? 1 : 0);
  } else if (args[0]) {
    process.stdout.write(JSON.stringify(collect(args[0])));
  } else {
    console.error('사용: node tests/diagram-dims.mjs <dist> | --compare a.json b.json [--tolerance 0.5]');
    process.exit(2);
  }
}
