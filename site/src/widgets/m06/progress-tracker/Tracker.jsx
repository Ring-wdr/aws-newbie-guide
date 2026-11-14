// M06 진행 추적. 항목은 index.astro가 원고에서 읽어 props로 준다. 저장은 storage.ts(try/catch, 막혀도 동작).
import { useEffect, useState } from 'preact/hooks';
import { load, save, remove, storageAvailable } from '../../../scripts/storage';
import { STORAGE_KEY, QUIZ_STATE_KEY, sanitize, toggle, computeProgress, quizGradedCount } from './progress.mjs';

const GROUPS = [
  { kind: 'lesson', title: '레슨' },
  { kind: 'lab', title: '실습' },
  { kind: 'quiz', title: '퀴즈' },
];

export default function Tracker({ items, quizRoute, quizTotal, moduleTitle }) {
  const [state, setState] = useState(() => sanitize(null, items));
  const [ready, setReady] = useState(false);
  const [canStore, setCanStore] = useState(true);
  const [quizGraded, setQuizGraded] = useState(0);

  useEffect(() => {
    const refresh = () => {
      setState(sanitize(load(STORAGE_KEY, null), items));
      setQuizGraded(quizGradedCount(load(QUIZ_STATE_KEY(quizRoute), null)));
    };
    setCanStore(storageAvailable());
    refresh();
    setReady(true);
    // 다른 탭에서 바꿨거나, 다른 페이지(퀴즈)에 다녀왔거나, 백업을 가져온 뒤 창으로 돌아오면 다시 읽는다.
    const onStorage = (e) => {
      if (!e.key || e.key.startsWith('guide:')) refresh();
    };
    window.addEventListener('storage', onStorage);
    window.addEventListener('pageshow', refresh);
    window.addEventListener('focus', refresh);
    return () => {
      window.removeEventListener('storage', onStorage);
      window.removeEventListener('pageshow', refresh);
      window.removeEventListener('focus', refresh);
    };
  }, []);

  const set = (id, on) => {
    const next = toggle(state, id, on);
    setState(next);
    save(STORAGE_KEY, next);
  };
  const reset = () => {
    const next = sanitize(null, items);
    setState(next);
    remove(STORAGE_KEY);
  };
  const p = computeProgress(items, state);

  return (
    <section class="pt" aria-labelledby="pt-title">
      <h3 id="pt-title">{moduleTitle} 진행 추적</h3>
      <p class="pt-summary">
        <strong data-progress-text>
          {p.total}항목 중 {p.done}항목 완료({p.pct}%)
        </strong>
        <span class="pt-kinds">
          {GROUPS.map((g, i) => (
            <span key={g.kind}>
              {i ? ' · ' : ''}
              {g.title} {p.by[g.kind].done}/{p.by[g.kind].total}
            </span>
          ))}
        </span>
      </p>
      <progress class="pt-bar" max={p.total} value={p.done} aria-label={`${moduleTitle} 진행률`} aria-valuetext={`${p.total}항목 중 ${p.done}항목 완료, ${p.pct}%`}></progress>
      <p class="pt-note">
        {!ready
          ? '완료 표시는 스크립트가 켜진 브라우저에서 쓸 수 있다. 목록은 그대로 읽을 수 있다.'
          : canStore
            ? '완료 표시는 이 브라우저(localStorage)에만 저장되고 어디로도 보내지 않는다. 원고는 바꾸지 않는다.'
            : '이 브라우저에서는 저장소를 쓸 수 없어 완료 표시가 이 페이지를 닫으면 사라진다(목록과 표시는 그대로 쓸 수 있다).'}
      </p>

      {GROUPS.map((g) => {
        const list = items.filter((it) => it.kind === g.kind);
        return (
          <fieldset class="pt-group" key={g.kind}>
            <legend>
              {g.title} <span class="pt-count">({p.by[g.kind].done}/{p.by[g.kind].total} 완료)</span>
            </legend>
            <ul>
              {list.map((it) => {
                const on = Boolean(state.done[it.id]);
                const cid = `pt-${it.id.replace(/[^a-z0-9]+/gi, '-')}`;
                return (
                  <li key={it.id} data-done={on ? 'true' : 'false'}>
                    <input type="checkbox" id={cid} data-item={it.id} checked={on} disabled={!ready} onChange={(e) => set(it.id, e.currentTarget.checked)} />
                    <label for={cid}>
                      <span class="pt-mark" aria-hidden="true">{on ? '✓' : '○'}</span>
                      <span class="pt-label">{it.label}</span>
                      <span class="pt-state">{on ? ' — 완료' : ''}</span>
                    </label>
                    <a class="pt-open" href={it.href} aria-label={`${it.label} 열기`}>
                      열기
                    </a>
                    {it.kind === 'quiz' && ready && quizGraded > 0 ? (
                      <small class="pt-quiz-record">
                        퀴즈 페이지 기록: {quizTotal}문항 중 {quizGraded}문항 채점함{quizGraded >= quizTotal && !on ? ' — 다 풀었으면 완료로 표시하자' : ''}
                      </small>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          </fieldset>
        );
      })}

      <div class="pt-actions">
        <button type="button" class="pt-reset" onClick={reset} disabled={!ready || p.done === 0}>
          완료 표시 모두 지우기
        </button>
      </div>
    </section>
  );
}
