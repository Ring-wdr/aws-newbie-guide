// "이 레슨 완료" — 모듈 진행 추적과 같은 저장값의 항목 하나만 바꾼다(setOne: 다른 항목은 건드리지 않는다).
import { useEffect, useState } from 'preact/hooks';
import { load, save, storageAvailable, onStorageChange } from '../scripts/storage';
import { setOne } from './progress.mjs';

const isDone = (key, id) => {
  const raw = load(key, null);
  return Boolean(raw && typeof raw === 'object' && raw.done && raw.done[id] === true);
};

export default function LessonDoneBox({ storeKey, itemId, label, moduleCode, moduleHref }) {
  const [on, setOn] = useState(false);
  const [ready, setReady] = useState(false);
  const [canStore, setCanStore] = useState(true);
  useEffect(() => {
    const refresh = () => setOn(isDone(storeKey, itemId));
    setCanStore(storageAvailable());
    refresh();
    setReady(true);
    const off = onStorageChange((key) => {
      if (key === null || key === storeKey) refresh();
    });
    window.addEventListener('pageshow', refresh);
    return () => {
      off();
      window.removeEventListener('pageshow', refresh);
    };
  }, []);
  const set = (v) => {
    setOn(v);
    save(storeKey, setOne(load(storeKey, null), itemId, v));
  };
  const id = `ld-${itemId.replace(/[^a-z0-9]+/gi, '-')}`;
  return (
    <aside class="ld" aria-label="레슨 진행" data-done={on ? 'true' : 'false'} data-lesson-done={itemId}>
      <label class="ld-check" for={id}>
        <input type="checkbox" id={id} checked={on} disabled={!ready} onChange={(e) => set(e.currentTarget.checked)} />
        <span>
          이 레슨 완료<span class="ld-state">{on ? ' — 완료로 표시함' : ''}</span>
        </span>
      </label>
      <p class="ld-note">
        {label}
        {canStore ? ' · ' : ' · 저장소를 쓸 수 없어 이 페이지를 닫으면 사라진다 · '}
        <a href={moduleHref}>{moduleCode} 진행 추적 보기</a>
      </p>
    </aside>
  );
}
