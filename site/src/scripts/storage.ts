// 진행 상태 저장 — 브라우저 localStorage 에만 둔다(GUIDE-SITE 3장).
// 저장소가 막힌 환경(사생활 보호 모드, 차단된 사이트 데이터)에서도 페이지는 그대로 동작해야 하므로
// 모든 읽기·쓰기를 try/catch로 감싸고, 실패하면 이번 방문 동안만 메모리에 둔다.
import { ko } from '../i18n/ko.mjs';

const PREFIX = 'guide:';
/** 같은 창 안에서 저장값이 바뀌었음을 알린다(브라우저의 storage 이벤트는 다른 창에만 간다).
 *  detail.key: 바뀐 키("guide:" 뺀 것), 백업을 가져왔으면 null. 진행 추적·퀴즈·체크리스트·시험 모드가 듣고 다시 읽는다. */
export const CHANGE_EVENT = 'guide:storage-change';
function notify(key: string | null): void {
  try {
    window.dispatchEvent(new CustomEvent(CHANGE_EVENT, { detail: { key } }));
  } catch {
    /* 무시 */
  }
}
/** 다른 창(storage 이벤트)이나 같은 창(CHANGE_EVENT)에서 저장값이 바뀌면 부른다. 해제 함수를 돌려준다. */
export function onStorageChange(fn: (key: string | null) => void): () => void {
  const local = (e: Event) => fn((e as CustomEvent).detail?.key ?? null);
  const other = (e: StorageEvent) => {
    if (!e.key) fn(null);
    else if (e.key.startsWith(PREFIX)) fn(e.key.slice(PREFIX.length));
  };
  window.addEventListener(CHANGE_EVENT, local);
  window.addEventListener('storage', other);
  return () => {
    window.removeEventListener(CHANGE_EVENT, local);
    window.removeEventListener('storage', other);
  };
}
const memory = new Map<string, string>();
let available: boolean | null = null;

export function storageAvailable(): boolean {
  if (available !== null) return available;
  try {
    const k = `${PREFIX}__probe`;
    window.localStorage.setItem(k, '1');
    window.localStorage.removeItem(k);
    available = true;
  } catch {
    available = false;
  }
  return available;
}

export function load<T>(key: string, fallback: T): T {
  const k = PREFIX + key;
  try {
    const raw = storageAvailable() ? window.localStorage.getItem(k) : (memory.get(k) ?? null);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

export function save(key: string, value: unknown): void {
  const k = PREFIX + key;
  const raw = JSON.stringify(value);
  memory.set(k, raw);
  try {
    if (storageAvailable()) window.localStorage.setItem(k, raw);
  } catch {
    /* 저장 실패는 조용히 넘긴다 — 화면 상태는 유지된다 */
  }
  notify(key);
}

/** 알림 없이 쓴다(가져오기에서 여러 키를 쓴 뒤 한 번만 알린다). */
function setQuiet(key: string, value: unknown): void {
  const k = PREFIX + key;
  const raw = JSON.stringify(value);
  memory.set(k, raw);
  try {
    if (storageAvailable()) window.localStorage.setItem(k, raw);
  } catch {
    /* 무시 */
  }
}

export function remove(key: string): void {
  memory.delete(PREFIX + key);
  try {
    if (storageAvailable()) window.localStorage.removeItem(PREFIX + key);
  } catch {
    /* 무시 */
  }
  notify(key);
}

function allEntries(): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const keys = new Set<string>(memory.keys());
  try {
    if (storageAvailable()) {
      for (let i = 0; i < window.localStorage.length; i++) {
        const k = window.localStorage.key(i);
        if (k && k.startsWith(PREFIX) && !k.endsWith('__probe')) keys.add(k);
      }
    }
  } catch {
    /* 무시 */
  }
  for (const k of keys) {
    try {
      const raw = (storageAvailable() ? window.localStorage.getItem(k) : null) ?? memory.get(k);
      if (raw) out[k.slice(PREFIX.length)] = JSON.parse(raw);
    } catch {
      /* 깨진 값은 건너뛴다 */
    }
  }
  return out;
}

export function download(filename: string, text: string, type = 'application/json'): void {
  const blob = new Blob([text], { type: `${type};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function pickFile(accept: string): Promise<string | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.addEventListener('change', async () => {
      const f = input.files?.[0];
      resolve(f ? await f.text() : null);
    });
    input.click();
  });
}

/** data-guide-storage 자리에 저장 상태 안내 + JSON 내보내기/가져오기 단추를 놓는다. */
export function mountStoragePanels(): void {
  for (const slot of document.querySelectorAll<HTMLElement>('[data-guide-storage]')) {
    if (slot.dataset.mounted) continue;
    slot.dataset.mounted = '1';
    slot.classList.add('storage-panel');
    const note = document.createElement('p');
    note.className = 'storage-note';
    note.setAttribute('role', 'status');
    if (!storageAvailable()) note.textContent = ko.storage.unavailable;
    const exp = document.createElement('button');
    exp.type = 'button';
    exp.textContent = ko.storage.export;
    exp.addEventListener('click', () => {
      const data = { format: 'aws-newbie-guide-progress', version: 1, exportedAt: new Date().toISOString(), entries: allEntries() };
      download('guide-progress.json', `${JSON.stringify(data, null, 2)}\n`);
    });
    const imp = document.createElement('button');
    imp.type = 'button';
    imp.textContent = ko.storage.import;
    imp.addEventListener('click', async () => {
      const text = await pickFile('application/json,.json');
      if (text === null) return;
      try {
        const data = JSON.parse(text);
        if (data?.format !== 'aws-newbie-guide-progress' || typeof data.entries !== 'object') throw new Error('format');
        for (const [k, v] of Object.entries(data.entries)) setQuiet(k, v);
        notify(null); // 같은 창의 진행 표시·퀴즈·체크리스트가 바로 다시 읽는다
        note.textContent = ko.storage.imported;
      } catch {
        note.textContent = ko.storage.importFailed;
      }
    });
    const row = document.createElement('div');
    row.className = 'storage-actions';
    row.append(exp, imp);
    // 백업 단추는 접어 둔다(퀴즈 요약 상자를 작게 유지). 저장 불가 안내는 접지 않고 보인다.
    const box = document.createElement('details');
    const sum = document.createElement('summary');
    sum.textContent = ko.storage.panelTitle;
    box.append(sum, row);
    slot.append(box, note);
  }
}
