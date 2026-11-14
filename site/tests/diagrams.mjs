// 다이어그램 배치 검사: 빌드된 페이지의 Mermaid SVG(라이트·다크)에서
//  - 라벨 잘림: HTML 라벨(foreignObject) 안 내용이 상자보다 넓거나 높다
//  - 겹침: 서브그래프(cluster) 상자끼리 한쪽이 다른 쪽을 품지 않은 채 겹친다, 노드끼리 겹친다,
//          간선 라벨이 노드·서브그래프 제목·다른 간선 라벨에 가려진다
// 를 찾는다. 실제 화면 폭(1280px)에서 본다.
// 사용: node tests/diagrams.mjs --port <포트> [--fail]   (--fail: 하나라도 있으면 종료 코드 1)
import fs from 'node:fs';
import { listPages, offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

// 원고 구조 때문에 배치로는 고칠 수 없어 편집자에게 넘긴 겹침(이유와 함께). 여기 없는 것은 실패.
const KNOWN = JSON.parse(fs.readFileSync(new URL('./diagrams-known.json', import.meta.url), 'utf8')).known;
const isKnown = (page, index, issue) => KNOWN.some((k) => k.page === page && k.index === index && issue.includes(k.match));

const port = portFromArgs(4321);
const server = await serve(port);
const results = [];
const opens = new Set();
const svgFail = [];
let svgChecked = 0;
try {
  for (const colorScheme of ['light', 'dark']) {
    const { browser, context } = await offlineBrowser({ colorScheme, viewport: { width: 1280, height: 900 } });
    const page = await context.newPage();
    for (const p of listPages()) {
      if (p.startsWith('/files/')) continue;
      await page.goto(`http://127.0.0.1:${port}${p}`, { waitUntil: 'load' });
      const found = await page.evaluate((theme) => {
        const out = [];
        const svgs = [...document.querySelectorAll(`.diagram-${theme} svg`)];
        svgs.forEach((svg, i) => {
          const issues = [];
          for (const fo of svg.querySelectorAll('foreignObject')) {
            const inner = fo.firstElementChild;
            if (!inner) continue;
            const fr = fo.getBoundingClientRect();
            const ir = inner.getBoundingClientRect();
            const sw = inner.scrollWidth - inner.clientWidth;
            const sh = inner.scrollHeight - inner.clientHeight;
            if (ir.width - fr.width > 1.5 || ir.height - fr.height > 1.5 || sw > 1 || sh > 1) {
              issues.push(`라벨 잘림 "${inner.textContent.trim().slice(0, 30)}" (+${Math.round(Math.max(ir.width - fr.width, sw))}×+${Math.round(Math.max(ir.height - fr.height, sh))}px)`);
            }
          }
          const box = (el) => el.getBoundingClientRect();
          const clusters = [...svg.querySelectorAll('g.cluster > rect')].map((r) => ({ r: box(r), name: r.parentElement.id }));
          const inter = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
          const contains = (a, b) => a.left <= b.left + 1 && a.right >= b.right - 1 && a.top <= b.top + 1 && a.bottom >= b.bottom - 1;
          for (let x = 0; x < clusters.length; x++)
            for (let y = x + 1; y < clusters.length; y++) {
              const a = clusters[x].r;
              const b = clusters[y].r;
              if (inter(a, b) && !contains(a, b) && !contains(b, a)) issues.push(`서브그래프 겹침 ${clusters[x].name} / ${clusters[y].name}`);
            }
          const nodes = [...svg.querySelectorAll('g.node')].map((n) => ({ r: box(n), name: n.id }));
          for (let x = 0; x < nodes.length; x++)
            for (let y = x + 1; y < nodes.length; y++) if (inter(nodes[x].r, nodes[y].r)) issues.push(`노드 겹침 ${nodes[x].name} / ${nodes[y].name}`);
          // 간선 라벨: 노드·서브그래프 제목·다른 간선 라벨에 가려지면 안 된다
          const labels = [...svg.querySelectorAll('g.edgeLabel')]
            .map((e) => ({ r: box(e), text: e.textContent.trim() }))
            .filter((e) => e.text && e.r.width > 1 && e.r.height > 1);
          const titles = [...svg.querySelectorAll('g.cluster-label')].map((t) => ({ r: box(t), name: t.textContent.trim().slice(0, 20) }));
          for (const l of labels) {
            for (const n of nodes) if (inter(l.r, n.r)) issues.push(`간선 라벨 "${l.text.slice(0, 20)}"이 노드 ${n.name}에 가려짐`);
            for (const t of titles) if (inter(l.r, t.r)) issues.push(`간선 라벨 "${l.text.slice(0, 20)}"이 서브그래프 제목 "${t.name}"과 겹침`);
          }
          for (let x = 0; x < labels.length; x++)
            for (let y = x + 1; y < labels.length; y++)
              if (inter(labels[x].r, labels[y].r)) issues.push(`간선 라벨끼리 겹침 "${labels[x].text.slice(0, 15)}" / "${labels[y].text.slice(0, 15)}"`);
          if (issues.length) out.push({ index: i + 1, issues });
        });
        return { count: svgs.length, out };
      }, colorScheme);
      for (const f of found.out) results.push({ page: p, theme: colorScheme, ...f });
      for (const href of await page.$$eval(`.diagram-open-${colorScheme}`, (as) => as.map((a) => a.getAttribute('href')))) opens.add(href);
    }
    // '원래 크기로 보기' 링크가 가리키는 단독 SVG 가 XML 로 읽히고 그림이 그려지는지
    for (const href of opens) {
      if (!href.startsWith('/diagrams/') || !href.endsWith(`-${colorScheme}.svg`)) continue;
      const res = await page.goto(`http://127.0.0.1:${port}${href}`, { waitUntil: 'load' });
      const ok = await page.evaluate(() => document.documentElement.localName === 'svg' && !document.querySelector('parsererror') && (() => { const b = document.documentElement.getBBox(); return b.width > 50 && b.height > 20 && document.documentElement.textContent.trim().length > 0; })());
      if (!res || res.status() !== 200 || !ok) svgFail.push(`${href}: ${res ? res.status() : '응답 없음'}${ok ? '' : ', SVG 로 그려지지 않음'}`);
      svgChecked++;
    }
    await browser.close();
  }
} finally {
  server.close();
}
const known = [];
const fresh = [];
for (const r of results) {
  const k = r.issues.filter((x) => isKnown(r.page, r.index, x));
  const f = r.issues.filter((x) => !isKnown(r.page, r.index, x));
  if (k.length) known.push({ ...r, issues: k });
  if (f.length) fresh.push({ ...r, issues: f });
}
for (const r of known) console.log(`알려진 원고 문제(편집자 몫) ${r.page} 그림 ${r.index} (${r.theme}): ${r.issues.join('; ')}`);
for (const r of fresh.sort((a, b) => b.issues.length - a.issues.length)) console.log(`${r.issues.length}건 ${r.page} 그림 ${r.index} (${r.theme}): ${r.issues.slice(0, 4).join('; ')}`);
for (const f of svgFail) console.log(`단독 SVG 실패 ${f}`);
console.log(`단독 SVG(원래 크기 보기) ${svgChecked}개 확인, 실패 ${svgFail.length}개`);
const total = fresh.reduce((s, r) => s + r.issues.length, 0) + svgFail.length;
console.log(`${total ? 'FOUND' : 'PASS'} diagrams: 새 문제 ${total}건(그림 ${fresh.length}개), 알려진 원고 문제 ${known.length}건`);
if (total && process.argv.includes('--fail')) process.exit(1);
