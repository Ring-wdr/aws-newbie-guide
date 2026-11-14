// 다이어그램 글꼴 파일(/fonts/diagram-<번호>-<해시>.woff2 — 하위 경로 배포면 그 아래). 빌드할 때 원고의 Mermaid 글자로 만든
// 부분집합이다(src/plugins/diagram-font.mjs). 페이지의 첫 그림 앞 <style data-diagram-font> 가 이 주소를 가리킨다.
import type { APIRoute } from 'astro';
import { diagramFonts } from '../../plugins/diagram-font.mjs';

export async function getStaticPaths() {
  const { faces } = await diagramFonts();
  return faces.map((f) => ({ params: { name: f.file.replace(/\.woff2$/, '') }, props: { bytes: f.bytes } }));
}

export const GET: APIRoute = ({ props }) => {
  const { bytes } = props as { bytes: Uint8Array };
  return new Response(bytes, { headers: { 'Content-Type': 'font/woff2' } });
};
