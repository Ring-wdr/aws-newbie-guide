// 브라우저 쪽의 base 경로. 하위 경로 배포(GUIDE_BASE)면 import.meta.env.BASE_URL 이 "/aws-newbie-guide/", 아니면 "/".
// 저장 키(퀴즈·체크리스트)와 경로 비교에는 base 를 뺀 사이트 경로를 쓴다 — 로컬(루트)과 배포본에서 키가 같고,
// 진행 상태를 내보내 다른 쪽에서 가져와도 그대로 맞는다. 빌드 쪽 대응은 src/lib/base.mjs.
export const BASE = (import.meta.env.BASE_URL || '/').replace(/\/+$/, '');

/** 주소 경로(location.pathname 등) → base 를 뺀 사이트 경로("/curriculum/…/"). base 밖의 경로는 그대로. */
export function siteRoute(pathname: string): string {
  if (!BASE) return pathname;
  if (pathname === BASE) return '/';
  return pathname.startsWith(`${BASE}/`) ? pathname.slice(BASE.length) : pathname;
}
