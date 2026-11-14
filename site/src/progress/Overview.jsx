// 홈의 전체 진행 요약. 모듈마다 "progress:mNN"을 읽어 그 모듈의 항목 id로 걸러 센다(모르는 id는 세지 않는다).
import { useEffect, useState } from 'preact/hooks';
import { load, storageAvailable, onStorageChange } from '../scripts/storage';
import { sanitize } from './progress.mjs';

const count = (m) => Object.keys(sanitize(load(m.key, null), m.ids).done).length;

export default function Overview({ modules }) {
  const [done, setDone] = useState(() => modules.map(() => 0));
  const [ready, setReady] = useState(false);
  const [canStore, setCanStore] = useState(true);

  useEffect(() => {
    const refresh = () => setDone(modules.map(count));
    setCanStore(storageAvailable());
    refresh();
    setReady(true);
    const off = onStorageChange((key) => {
      if (key === null || key.startsWith('progress:')) refresh();
    });
    window.addEventListener('pageshow', refresh);
    window.addEventListener('focus', refresh);
    return () => {
      off();
      window.removeEventListener('pageshow', refresh);
      window.removeEventListener('focus', refresh);
    };
  }, []);

  const total = modules.reduce((s, m) => s + m.ids.length, 0);
  const sum = done.reduce((s, n) => s + n, 0);
  const finished = modules.filter((m, i) => done[i] === m.ids.length).length;
  return (
    <section class="po" aria-labelledby="po-title">
      <h2 id="po-title">전체 진행</h2>
      <p class="po-summary">
        <strong data-overview-text>
          {total}항목 중 {sum}항목 완료 · 모듈 {modules.length}개 중 {finished}개 끝냄
        </strong>
      </p>
      <p class="po-note">
        {!ready
          ? '완료 수는 스크립트가 켜진 브라우저에서 보인다. 각 모듈의 첫 페이지에서 레슨·실습·퀴즈를 완료로 표시한다.'
          : canStore
            ? '각 모듈 첫 페이지의 진행 추적과 레슨 끝의 "이 레슨 완료"에서 표시한 것을 센다. 이 브라우저에만 저장된다.'
            : '이 브라우저에서는 저장소를 쓸 수 없어 완료 수를 기억하지 못한다.'}
      </p>
      <ol class="po-list">
        {modules.map((m, i) => {
          const n = done[i];
          const all = m.ids.length;
          const pct = all ? Math.floor((n / all) * 100) : 0;
          return (
            <li key={m.key} data-module={m.key.slice(-3)} data-state={n === all ? 'done' : n ? 'some' : 'none'}>
              <a class="po-name" href={m.href}>
                {m.code} {m.title}
              </a>
              <span class="po-count">
                {n}/{all}
                {n === all ? ' 완료' : ''}
              </span>
              <progress class="po-bar" max={all} value={n} aria-label={`${m.code} 진행률`} aria-valuetext={`${all}항목 중 ${n}항목 완료, ${pct}%`}></progress>
            </li>
          );
        })}
      </ol>
    </section>
  );
}
