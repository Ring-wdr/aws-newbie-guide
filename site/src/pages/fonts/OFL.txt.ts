// 다이어그램 글꼴의 라이선스(/fonts/OFL.txt — 하위 경로 배포면 그 아래). SIL OFL 1.1 은 글꼴을 배포할 때 저작권 고지와
// 라이선스를 함께 싣도록 한다. 내용은 실린 글꼴 파일의 저작권 줄 + 패키지 LICENSE 의 OFL 본문이다(src/plugins/diagram-font.mjs
// fontLicenceText). 일반 글자 파일이라 페이지가 불러오는 리소스가 아니다 — 본문의 OFL 안내 주소는 읽는 사람을 위한 글자다.
import type { APIRoute } from 'astro';
import { fontLicenceText } from '../../plugins/diagram-font.mjs';

export const GET: APIRoute = async () =>
  new Response(await fontLicenceText(), { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
