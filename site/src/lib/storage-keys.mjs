// localStorage 키 이름. 공개 배포본(ring-wdr.github.io)은 같은 소유자의 다른 Pages 사이트들과 출처(origin)를 공유하므로
// 저장소를 나눠 쓴다. 그래서 이 사이트의 키는 모두 사이트 이름 접두사로 시작하고, 진행 상태 내보내기·가져오기는
// 이 접두사의 키만 다룬다(src/scripts/storage.ts). 테마(ThemeProvider·ThemeSelect)도 같은 접두사를 쓴다.
export const PREFIX = 'aws-newbie-guide:';
/** 이전(공개 배포 전) 접두사. 이 사이트가 만든 꼴의 키만 한 번 옮긴다(migrateLegacy). */
export const LEGACY_PREFIX = 'guide:';
/** 테마 키(접두사 포함 전체 이름 — Starlight 기본 "starlight-theme" 대신). */
export const THEME_KEY = `${PREFIX}theme`;

// 이 사이트가 "guide:" 접두사로 만들던 키의 정확한 꼴: 진행 추적, 퀴즈·체크리스트(사이트 경로), 모의고사 진행·응시 기록.
const LEGACY_KEY = /^guide:(progress:m\d\d|(?:quiz|checklist):\/(?:[a-z0-9._-]+\/)*[a-z0-9._-]*|exam:m14-mock-exam(?::history)?)$/;

/** 옛 키 → 새 키(이 사이트가 만든 꼴이 아니면 null). */
export function legacyTarget(key) {
  const m = LEGACY_KEY.exec(key);
  return m ? PREFIX + m[1] : null;
}

/**
 * 옛 키를 한 번 옮긴다: 이 사이트가 만든 꼴이고 새 키가 아직 없으면 값을 새 키로 복사하고 옛 키를 지운다.
 * 새 키가 이미 있으면 둘 다 그대로 둔다. 꼴이 맞지 않는 "guide:*" 키(같은 출처의 다른 사이트 것일 수 있다)는 건드리지 않는다.
 * @param {Storage} storage localStorage(또는 같은 모양의 객체)
 * @returns {string[]} 옮긴 옛 키
 */
export function migrateLegacy(storage) {
  const keys = [];
  for (let i = 0; i < storage.length; i++) {
    const k = storage.key(i);
    if (k && k.startsWith(LEGACY_PREFIX)) keys.push(k);
  }
  const moved = [];
  for (const k of keys) {
    const to = legacyTarget(k);
    if (!to || storage.getItem(to) !== null) continue;
    const v = storage.getItem(k);
    if (v === null) continue;
    storage.setItem(to, v);
    storage.removeItem(k);
    moved.push(k);
  }
  return moved;
}
