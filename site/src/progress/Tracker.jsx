// 모듈 진행 추적(전 모듈 공용). 항목은 ProgressTracker.astro가 원고에서 읽어 props로 준다.
// 저장은 storage.ts(try/catch, 막혀도 동작). 같은 창에서 백업을 가져오거나 레슨 페이지에서 바꿔도 바로 다시 읽는다.
import { useEffect, useRef, useState } from 'preact/hooks';
import { load, save, remove, storageAvailable, onStorageChange } from '../scripts/storage';
import { confirmDialog } from '../scripts/dialog';
import { GROUPS, EXAM_HISTORY_KEY, QUIZ_STATE_KEY, sanitize, toggle, computeProgress, quizGradedCount } from './progress.mjs';
import { latestExam } from '../lib/exam-history.mjs';

export default function Tracker({ items, storeKey, quizRoute, quizTotal, moduleTitle }) {
  const [state, setState] = useState(() => sanitize(null, items));
  const [ready, setReady] = useState(false);
  const [canStore, setCanStore] = useState(true);
  const [quizGraded, setQuizGraded] = useState(0);
  const [lastExam, setLastExam] = useState(null);
  const [msg, setMsg] = useState('');
  const resetRef = useRef(null);
  const hasExam = items.some((it) => it.id === 'exam:mock-exam');

  useEffect(() => {
    const refresh = () => {
      setState(sanitize(load(storeKey, null), items));
      if (quizTotal > 0) setQuizGraded(quizGradedCount(load(QUIZ_STATE_KEY(quizRoute), null)));
      if (hasExam) setLastExam(latestExam(load(EXAM_HISTORY_KEY, null)));
    };
    setCanStore(storageAvailable());
    refresh();
    setReady(true);
    // 다른 탭·같은 창(백업 가져오기, 레슨 페이지의 완료 표시)에서 바뀌었거나, 다른 페이지(퀴즈)에 다녀오면 다시 읽는다.
    const off = onStorageChange((key) => {
      if (key === null || key === storeKey || key.startsWith('quiz:') || key === EXAM_HISTORY_KEY) refresh();
    });
    window.addEventListener('pageshow', refresh);
    window.addEventListener('focus', refresh);
    return () => {
      off();
      window.removeEventListener('pageshow', refresh);
      window.removeEventListener('focus', refresh);
    };
  }, []);

  const set = (id, on) => {
    const next = toggle(state, id, on);
    setState(next);
    setMsg('');
    save(storeKey, next);
  };
  const reset = async () => {
    const n = computeProgress(items, state).done;
    const ok = await confirmDialog(`${moduleTitle}의 완료 표시 ${n}개를 모두 지울까요? 되돌릴 수 없습니다. 먼저 진행 상태를 내보내 두면 다시 가져올 수 있습니다.`, {
      yes: '모두 지우기',
      no: '취소',
      focus: 'no',
    });
    if (!ok) return;
    const next = sanitize(null, items);
    setState(next);
    remove(storeKey);
    setMsg(`${moduleTitle}의 완료 표시를 모두 지웠다.`);
    // 지운 뒤에는 단추가 비활성화되므로 초점을 진행 요약으로 옮긴다(body로 빠지지 않게).
    requestAnimationFrame(() => resetRef.current?.focus());
  };
  const p = computeProgress(items, state);
  const groups = GROUPS.filter((g) => p.by[g.kind]);
  const titleId = `pt-title-${storeKey.replace(/[^a-z0-9]+/gi, '-')}`;

  return (
    <section class="pt" aria-labelledby={titleId}>
      <h3 id={titleId}>{moduleTitle} 진행 추적</h3>
      <p class="pt-summary" tabIndex={-1} ref={resetRef}>
        <strong data-progress-text>
          {p.total}항목 중 {p.done}항목 완료({p.pct}%)
        </strong>
        <span class="pt-kinds">
          {groups.map((g, i) => (
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
            ? '완료 표시는 이 브라우저(localStorage)에만 저장되고 어디로도 보내지 않는다. 원고는 바꾸지 않는다. 레슨 페이지 끝의 "이 레슨 완료"와 같은 기록이다.'
            : '이 브라우저에서는 저장소를 쓸 수 없어 완료 표시가 이 페이지를 닫으면 사라진다(목록과 표시는 그대로 쓸 수 있다).'}
      </p>

      {groups.map((g) => {
        const list = items.filter((it) => it.kind === g.kind);
        return (
          <fieldset class="pt-group" key={g.kind}>
            <legend>
              {g.title} <span class="pt-count">({p.by[g.kind].done}/{p.by[g.kind].total} 완료)</span>
            </legend>
            <ul>
              {list.map((it) => {
                const on = Boolean(state.done[it.id]);
                const cid = `pt-${storeKey.slice(-3)}-${it.id.replace(/[^a-z0-9]+/gi, '-')}-${items.indexOf(it)}`;
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
                    {it.id === 'exam:mock-exam' && ready && lastExam ? (
                      <small class="pt-quiz-record" data-exam-last>
                        최근 응시: {lastExam.when} · {lastExam.ok}/{lastExam.total} = {lastExam.pct}% · {lastExam.pass ? '통과' : '미달'} (기록 {lastExam.count}회)
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
        <p class="pt-msg" role="status">
          {msg}
        </p>
      </div>
    </section>
  );
}
