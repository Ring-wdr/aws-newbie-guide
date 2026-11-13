// 다이어그램 배치 검사: 빌드된 페이지의 Mermaid SVG(라이트·다크)에서
//  - 라벨 잘림: HTML 라벨(foreignObject) 안 내용이 상자보다 넓거나 높다
//  - 겹침: 서브그래프(cluster) 상자끼리 한쪽이 다른 쪽을 품지 않은 채 겹친다, 노드끼리 겹친다
// 를 찾는다. 실제 화면 폭(1280px)에서 본다.
// 사용: node tests/diagrams.mjs --port <포트> [--fail]   (--fail: 하나라도 있으면 종료 코드 1)
import { listPages, offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const server = await serve(port);
const results = [];
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
          if (issues.length) out.push({ index: i + 1, issues });
        });
        return { count: svgs.length, out };
      }, colorScheme);
      for (const f of found.out) results.push({ page: p, theme: colorScheme, ...f });
    }
    await browser.close();
  }
} finally {
  server.close();
}
const byDiagram = results.sort((a, b) => b.issues.length - a.issues.length);
for (const r of byDiagram) console.log(`${r.issues.length}건 ${r.page} 그림 ${r.index} (${r.theme}): ${r.issues.slice(0, 4).join('; ')}`);
const total = results.reduce((s, r) => s + r.issues.length, 0);
console.log(`${total ? 'FOUND' : 'PASS'} diagrams: 문제 ${total}건, 문제가 있는 그림 ${results.length}개`);
if (total && process.argv.includes('--fail')) process.exit(1);
