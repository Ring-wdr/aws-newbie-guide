// 진행 상태 저장 — 브라우저 localStorage 에만 둔다(GUIDE-SITE 3장).
// 저장소가 막힌 환경(사생활 보호 모드, 차단된 사이트 데이터)에서도 페이지는 그대로 동작해야 하므로
// 모든 읽기·쓰기를 try/catch로 감싸고, 실패하면 이번 방문 동안만 메모리에 둔다.
import { ko } from '../i18n/ko.mjs';

const PREFIX = 'guide:';
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
}

export function remove(key: string): void {
  memory.delete(PREFIX + key);
  try {
    if (storageAvailable()) window.localStorage.removeItem(PREFIX + key);
  } catch {
    /* 무시 */
  }
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
        for (const [k, v] of Object.entries(data.entries)) save(k, v);
        note.textContent = ko.storage.imported;
      } catch {
        note.textContent = ko.storage.importFailed;
      }
    });
    const row = document.createElement('div');
    row.className = 'storage-actions';
    row.append(exp, imp);
    slot.append(row, note);
  }
}
