// 사이트를 하위 경로(예: GitHub Pages 프로젝트 주소의 /aws-newbie-guide/)에 올릴 때의 base 경로.
// 빌드 때 환경 변수 GUIDE_BASE 로만 정한다. 주지 않으면 지금처럼 루트(/)로 빌드한다(scripts/guide-up.sh·검사 기본값).
// 변환기(remark)·빌드 설정·서버 쪽 컴포넌트가 이 파일을 쓴다. 브라우저 스크립트는 src/scripts/base.ts(import.meta.env.BASE_URL).

/**
 * GUIDE_BASE 값 → 끝 슬래시 없는 경로 접두어("" 또는 "/aws-newbie-guide").
 * 경로 조각은 영문 소문자·숫자·하이픈·밑줄·점만 받는다(주소·쿼리·상위 경로를 넣지 못하게).
 */
export function normalizeBase(v) {
  const s = String(v ?? '').trim();
  if (s === '' || s === '/') return '';
  const parts = s.replace(/^\/+|\/+$/g, '').split('/');
  for (const p of parts) {
    if (!/^[A-Za-z0-9._-]+$/.test(p) || p === '.' || p === '..') {
      throw new Error(`GUIDE_BASE 는 "/이름/" 꼴의 경로여야 한다(영문·숫자·-_. 만): ${JSON.stringify(s)}`);
    }
  }
  return `/${parts.join('/')}`;
}

/** 이번 빌드의 base 접두어("" = 루트). */
export const BASE = normalizeBase(process.env.GUIDE_BASE);

/** Astro 설정의 base 값("/" 또는 "/aws-newbie-guide/"). */
export const ASTRO_BASE = `${BASE}/`;

/** 사이트 경로("/curriculum/…/", "/files/…/", "/diagrams/….svg") → 실제 주소 경로. "/"로 시작하지 않으면(앵커·외부) 그대로. */
export function withBase(route) {
  return typeof route === 'string' && route.startsWith('/') && !route.startsWith('//') ? BASE + route : route;
}
