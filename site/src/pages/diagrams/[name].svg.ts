// 넓은 다이어그램을 원래 크기로 보는 SVG 파일(/diagrams/<id>.svg — 하위 경로 배포면 그 아래). 페이지에 넣은 것과 같은 SVG를 그대로 꺼내 쓴다.
// 다크 그림은 바탕색을 넣어 단독으로 열어도 읽히게 한다. 외부 리소스는 없다(빌드 시점 SVG).
import { getCollection } from 'astro:content';
import type { APIRoute } from 'astro';

/** html 에서 <svg ... id="ID" ...> 로 시작하는 요소를 짝이 맞는 </svg> 까지 꺼낸다. */
function extractSvg(html: string, id: string): string | null {
  const start = html.search(new RegExp(`<svg[^>]*\\sid="${id}-0"`));
  if (start < 0) return null;
  const re = /<svg\b|<\/svg>/g;
  re.lastIndex = start;
  let depth = 0;
  for (let m = re.exec(html); m; m = re.exec(html)) {
    depth += m[0] === '</svg>' ? -1 : 1;
    if (depth === 0) return html.slice(start, m.index + 6);
  }
  return null;
}

export async function getStaticPaths() {
  const out = new Map<string, string>();
  for (const entry of await getCollection('docs')) {
    const html = (entry as any).rendered?.html ?? '';
    for (const m of html.matchAll(/href="[^"]*?\/diagrams\/(mmd-[0-9a-f]+-(?:light|dark))\.svg"/g)) {
      if (out.has(m[1])) continue;
      const svg = extractSvg(html, m[1]);
      if (svg) out.set(m[1], svg);
    }
  }
  return [...out.entries()].map(([name, svg]) => ({ params: { name }, props: { svg, dark: name.endsWith('-dark') } }));
}

export const GET: APIRoute = ({ props }) => {
  const { svg, dark } = props as { svg: string; dark: boolean };
  const vb = /viewBox="([-\d.]+) ([-\d.]+) ([\d.]+) ([\d.]+)"/.exec(svg);
  const size = vb ? ` width="${Math.ceil(Number(vb[3]))}" height="${Math.ceil(Number(vb[4]))}"` : '';
  const bg = dark ? '#1b1e24' : '#ffffff';
  const body = svg
    .replace(/^<svg\b([^>]*?)\sstyle="[^"]*"/, '<svg$1')
    .replace(/^<svg\b([^>]*?)\swidth="[^"]*"/, '<svg$1')
    .replace(/^<svg\b/, `<svg${size} style="background-color:${bg}"`)
    // 단독 SVG 파일은 XML 로 해석되므로 HTML 식 빈 요소(<br>)를 닫아 준다.
    .replace(/<(br|hr|wbr|img)\b([^>]*?)\/?>/g, '<$1$2/>');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n${body}`, { headers: { 'Content-Type': 'image/svg+xml; charset=utf-8' } });
};
