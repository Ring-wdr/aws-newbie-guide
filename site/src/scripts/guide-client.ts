// 본문 장치의 브라우저 쪽 동작: 명령 복사, 퀴즈 채점, 체크리스트 저장, 진행 상태 백업.
// 스크립트가 없어도 원고 내용은 모두 읽힌다(단추만 숨겨진 채 남는다).
import { ko } from '../i18n/ko.mjs';
import { load, save, remove, mountStoragePanels, onStorageChange } from './storage';
import { installExamGuard } from './exam-guard';
import { siteRoute } from './base';

// 저장 키는 base 를 뺀 사이트 경로로 만든다(하위 경로 배포에서도 로컬과 같은 키 — progress.mjs QUIZ_STATE_KEY 와 같은 규칙).
const pageKey = siteRoute(location.pathname).replace(/\/+$/, '') || '/';

/* ---------- 명령 복사 ---------- */
let live: HTMLElement | null = null;
function announce(msg: string) {
  if (!live) {
    live = document.createElement('div');
    live.className = 'sr-only';
    live.setAttribute('role', 'status');
    live.setAttribute('aria-live', 'polite');
    document.body.append(live);
  }
  live.textContent = '';
  requestAnimationFrame(() => {
    if (live) live.textContent = msg;
  });
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // 클립보드 API가 막힌 경우(비보안 문맥 등) 선택 후 복사를 시도한다.
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.append(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch {
      ok = false;
    }
    ta.remove();
    return ok;
  }
}

function initCopy() {
  for (const btn of document.querySelectorAll<HTMLButtonElement>('button[data-copy]')) {
    const block = btn.closest('.cmd-block, .source-run');
    const pre = block?.querySelector('pre');
    if (!pre) continue;
    btn.hidden = false;
    btn.addEventListener('click', async () => {
      const ok = await copyText(pre.textContent ?? '');
      const msg = ok ? ko.cmd.copied : ko.cmd.copyFailed;
      btn.dataset.state = ok ? 'done' : 'failed';
      btn.textContent = ok ? ko.cmd.copied : ko.cmd.copy;
      announce(msg);
      setTimeout(() => {
        btn.textContent = ko.cmd.copy;
        delete btn.dataset.state;
      }, 2000);
    });
  }
}

/* ---------- 퀴즈 ---------- */
type QuizState = { picked: Record<string, string>; graded: Record<string, boolean> };

function initQuiz() {
  const summary = document.querySelector<HTMLElement>('.quiz-summary');
  const cards = [...document.querySelectorAll<HTMLElement>('section.quiz-q')];
  if (!summary || !cards.length) return;
  const key = `quiz:${pageKey}`;
  let state = load<QuizState>(key, { picked: {}, graded: {} });
  const total = Number(summary.dataset.total);
  const need = Number(summary.dataset.need);
  const progress = summary.querySelector<HTMLElement>('.quiz-progress')!;
  const scoreEl = summary.querySelector<HTMLElement>('.quiz-score')!;
  summary.querySelector('.quiz-noscript')?.remove();
  progress.hidden = false;
  summary.classList.add('is-live');

  const render = () => {
    let graded = 0;
    let ok = 0;
    for (const card of cards) {
      const n = card.dataset.q!;
      const answer = card.dataset.answer!;
      const picked = state.picked[n];
      const isGraded = Boolean(state.graded[n] && picked);
      const inputs = [...card.querySelectorAll<HTMLInputElement>('input[type=radio]')];
      for (const inp of inputs) {
        inp.checked = inp.value === picked;
        inp.disabled = isGraded;
        const label = inp.closest('label')!;
        label.classList.toggle('is-answer', isGraded && inp.value === answer);
        label.classList.toggle('is-wrong', isGraded && inp.value === picked && picked !== answer);
      }
      const btn = card.querySelector<HTMLButtonElement>('.quiz-check')!;
      btn.disabled = !picked || isGraded;
      const verdict = card.querySelector<HTMLElement>('.quiz-verdict')!;
      const details = card.querySelector<HTMLDetailsElement>('details.quiz-explain');
      if (isGraded) {
        graded++;
        const right = picked === answer;
        if (right) ok++;
        card.dataset.result = right ? 'correct' : 'wrong';
        verdict.textContent = right
          ? `${ko.quiz.correct} — ${ko.quiz.yourAnswer} ${picked}`
          : `${ko.quiz.wrong} — ${ko.quiz.yourAnswer} ${picked}, ${ko.quiz.answerIs} ${answer}`;
        if (details) details.hidden = false;
      } else {
        delete card.dataset.result;
        verdict.textContent = '';
        if (details) {
          details.hidden = true;
          details.open = false;
        }
      }
    }
    const parts = [ko.quiz.answered(graded, total), ko.quiz.score(ok, total)];
    if (graded === total) parts.push(ok >= need ? ko.quiz.pass : ko.quiz.notYet);
    scoreEl.textContent = parts.join(' · ');
    summary.dataset.state = graded === total ? (ok >= need ? 'pass' : 'fail') : 'progress';
  };

  for (const card of cards) {
    const n = card.dataset.q!;
    card.querySelector<HTMLElement>('.quiz-actions')!.hidden = false;
    for (const inp of card.querySelectorAll<HTMLInputElement>('input[type=radio]')) {
      inp.addEventListener('change', () => {
        state.picked[n] = inp.value;
        save(key, state);
        render();
      });
    }
    card.querySelector<HTMLButtonElement>('.quiz-check')!.addEventListener('click', () => {
      if (!state.picked[n]) return;
      state.graded[n] = true;
      save(key, state);
      render();
      const details = card.querySelector<HTMLDetailsElement>('details.quiz-explain');
      if (details) details.open = true;
      card.querySelector<HTMLElement>('.quiz-verdict')?.focus();
    });
  }
  summary.querySelector<HTMLButtonElement>('.quiz-reset')!.addEventListener('click', () => {
    state = { picked: {}, graded: {} };
    remove(key);
    render();
    cards[0]?.querySelector<HTMLInputElement>('input')?.focus();
  });
  // 백업을 가져왔거나 다른 창에서 바꾸면 다시 읽는다.
  onStorageChange((k) => {
    if (k !== null && k !== key) return;
    const next = load<QuizState>(key, { picked: {}, graded: {} });
    if (JSON.stringify(next) === JSON.stringify(state)) return;
    state = next;
    render();
  });
  render();
}

/* ---------- 체크리스트 ---------- */
function initChecklist() {
  const summary = document.querySelector<HTMLElement>('.checklist-summary');
  const boxes = [...document.querySelectorAll<HTMLInputElement>('input[data-check-id]')];
  if (!summary || !boxes.length) return;
  const key = `checklist:${pageKey}`;
  let state = load<Record<string, boolean>>(key, {});
  const progress = summary.querySelector<HTMLElement>('.checklist-progress')!;
  summary.hidden = false;
  document.documentElement.classList.add('has-checklist-js');
  const render = () => {
    let done = 0;
    for (const b of boxes) {
      const id = b.dataset.checkId!;
      b.checked = id in state ? state[id] : b.hasAttribute('data-check-default');
      if (b.checked) done++;
    }
    progress.textContent = ko.checklist.progress(done, boxes.length);
  };
  for (const b of boxes) {
    b.addEventListener('change', () => {
      state[b.dataset.checkId!] = b.checked;
      save(key, state);
      render();
    });
  }
  summary.querySelector<HTMLButtonElement>('.checklist-reset')!.addEventListener('click', () => {
    state = {};
    remove(key);
    render();
  });
  onStorageChange((k) => {
    if (k !== null && k !== key) return;
    const next = load<Record<string, boolean>>(key, {});
    if (JSON.stringify(next) === JSON.stringify(state)) return;
    state = next;
    render();
  });
  render();
}

/* ---------- 답 가리기(스스로 확인) ---------- */
function initReveal() {
  for (const d of document.querySelectorAll<HTMLDetailsElement>('details.self-check, details.reveal')) {
    const s = d.querySelector('summary');
    if (!s || s.querySelector('.reveal-state')) continue;
    const hint = document.createElement('span');
    hint.className = 'reveal-state';
    const sync = () => (hint.textContent = d.open ? ko.reveal.hide : ko.reveal.show);
    sync();
    d.addEventListener('toggle', sync);
    s.append(hint);
  }
}

/* ---------- 넓은 다이어그램: 흐름의 시작이 보이게 처음 스크롤 위치를 정한다 ---------- */
// 시작 = 들어오는 간선이 없는 노드(여럿이면 가장 위, 같은 높이면 가장 왼쪽). 그림의 왼쪽 끝에서 시작 노드가
// 다 보이면 왼쪽 끝(앞 여백만 건너뛴다)에, 아니면 시작 노드를 상자 가운데에 둔다(위→아래 트리의 뿌리가 가운데·오른쪽일 때).
function startNode(svg: SVGSVGElement): Element | null {
  const nodes = [...svg.querySelectorAll('g.node')];
  const idOf = (n: Element) => /flowchart-(.+)-\d+$/.exec(n.id)?.[1];
  const ids = new Map(nodes.map((n) => [idOf(n), n] as const));
  const targets = new Set<string>();
  for (const e of svg.querySelectorAll('path[data-edge="true"][data-id]')) {
    const m = /^L_(.+)_\d+$/.exec(e.getAttribute('data-id') || '');
    if (!m) continue;
    // "L_<시작>_<끝>_<n>": 이름에 _ 가 있을 수 있어 두 쪽이 모두 노드 이름인 자르기를 찾는다
    const parts = m[1].split('_');
    for (let k = 1; k < parts.length; k++) {
      const from = parts.slice(0, k).join('_');
      const to = parts.slice(k).join('_');
      if (ids.has(from) && ids.has(to)) {
        targets.add(to);
        break;
      }
    }
  }
  const starts = nodes.filter((n) => !targets.has(idOf(n) || '')).map((n) => ({ n, r: n.getBoundingClientRect() })).filter((x) => x.r.width > 0);
  if (!starts.length) return null;
  starts.sort((a, b) => (Math.abs(a.r.top - b.r.top) > 2 ? a.r.top - b.r.top : a.r.left - b.r.left));
  return starts[0].n;
}

function initDiagrams() {
  const dark = document.documentElement.dataset.theme === 'dark';
  for (const box of document.querySelectorAll<HTMLElement>('.diagram-scroll')) {
    if (box.scrollWidth <= box.clientWidth + 1) continue;
    const t = dark ? 'dark' : 'light';
    const svg = box.querySelector<SVGSVGElement>(`.diagram-${t} svg, .diagram-n-${t} svg`);
    if (!svg) continue;
    // 노드·간선 라벨·서브그래프 중 가장 왼쪽 것의 바로 앞(그림 앞 여백을 건너뛴다)
    const rects = [...svg.querySelectorAll('g.node, g.edgeLabel, g.cluster')].map((n) => n.getBoundingClientRect()).filter((r) => r.width > 0);
    if (!rects.length) continue;
    const boxLeft = box.getBoundingClientRect().left - box.scrollLeft;
    const max = box.scrollWidth - box.clientWidth;
    let want = Math.min(...rects.map((r) => r.left)) - boxLeft - 8;
    const start = startNode(svg)?.getBoundingClientRect();
    if (start) {
      const sLeft = start.left - boxLeft;
      const sRight = start.right - boxLeft;
      if (sRight > want + box.clientWidth || sLeft < want) want = sLeft - (box.clientWidth - start.width) / 2;
    }
    box.scrollLeft = Math.max(0, Math.min(max, want));
    box.dataset.startScroll = String(Math.round(box.scrollLeft));
  }
}

/* ---------- 넓은 표: 넘칠 때만 스크롤 표시(안내 글 + 가장자리 그림자 + 점선 테두리)와 키보드 초점 ---------- */
// 넘치지 않으면 안내를 숨기고 aria-describedby·tabindex 도 뗀다(창 폭이 바뀌면 ResizeObserver 로 다시 정한다).
// 스크립트가 없으면 빌드 때의 tabindex=0 이 그대로 남아 언제나 키보드로 스크롤할 수 있다.
function initTables() {
  const boxes = [...document.querySelectorAll<HTMLElement>('.table-scroll')];
  if (!boxes.length) return;
  let seq = 0;
  const update = (box: HTMLElement) => {
    const over = box.scrollWidth > box.clientWidth + 1;
    box.classList.toggle('is-scrollable', over);
    let hint = box.previousElementSibling as HTMLElement | null;
    if (!hint?.classList.contains('table-scroll-hint')) hint = null;
    if (over) {
      if (!hint) {
        hint = document.createElement('p');
        hint.className = 'table-scroll-hint';
        hint.id = `table-scroll-hint-${++seq}`;
        hint.textContent = ko.table.scrollHint;
        box.before(hint);
      }
      hint.hidden = false;
      box.setAttribute('aria-describedby', hint.id);
      box.tabIndex = 0;
    } else {
      if (hint) hint.hidden = true;
      box.removeAttribute('aria-describedby');
      box.removeAttribute('tabindex');
    }
  };
  for (const b of boxes) update(b);
  if ('ResizeObserver' in window) {
    // 상자와 그 안의 표를 함께 본다: 창 폭이 바뀐 첫 프레임에 표가 아직 예전 폭이면 상자만 봐서는 다시 판단할 기회가 없다
    const ro = new ResizeObserver((entries) => {
      for (const e of entries) update((e.target as HTMLElement).closest<HTMLElement>('.table-scroll')!);
    });
    for (const b of boxes) {
      ro.observe(b);
      const t = b.querySelector('table');
      if (t) ro.observe(t);
    }
  }
  // 닫힌 <details>(스스로 확인의 답 등) 안의 표는 ResizeObserver 알림을 받지 못한다 — 창 폭이 바뀌거나 펼칠 때 다시 판단한다
  let pending = 0;
  window.addEventListener('resize', () => {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(() => boxes.forEach(update));
  });
  document.addEventListener(
    'toggle',
    (e) => {
      const d = e.target as HTMLElement;
      if (d.tagName === 'DETAILS') d.querySelectorAll<HTMLElement>('.table-scroll').forEach(update);
    },
    true,
  );
}

/* ---------- 맞춤 위젯이 붙기 전의 입력을 붙은 뒤에 넘겨주기 ---------- */
// 위젯(Preact 아일랜드)은 화면에 보일 때 스크립트가 붙는다(client:visible). Tab 으로 들어가면 그제야 화면에 들어와 붙기 시작하므로,
// 초점 직후 수십 ms(느린 기기·느린 네트워크에서는 더 길게) 동안은 서버가 그린 상태(astro-island[ssr])다. 그 사이의 입력은
// 브라우저가 화면 요소에는 반영하지만(숫자 칸의 값, 체크 상자·라디오) 위젯 상태에는 들어가지 않고, 단추 누르기는 처리할 곳이 없다.
// 예전에는 그 입력을 막았는데(조용히 버려짐) 지금은 받아 두었다가, 위젯이 붙는 순간(astro:hydrate — Preact 는 붙을 때 화면 요소의
// 값·체크를 덮어쓰지 않는다) 순서대로 넘겨준다:
//   - 값이 바뀐 입력 요소(숫자·글자·범위 칸, select, 체크 상자, 선택된 라디오): input/change 이벤트를 다시 보내 위젯이 화면 값을 읽게 한다.
//     지금 값이 처음(서버가 그린) 값과 같으면 보내지 않는다(두 번 바꿔 제자리면 그대로).
//   - 단추(button, [role=button])를 누른 것: 붙은 뒤 click() 을 다시 한다.
// 페이지가 열리자마자 건다(DOMContentLoaded 전). 검사: tests/widget-early-input.mjs(keyboard 관문, 스크립트를 일부러 늦춰 확인).
const HYDRATION_PENDING = '.guide-widget astro-island[ssr]';
const EARLY_VALUE = 'input, select, textarea';
const EARLY_BUTTON = 'button, [role=button]';
function initEarlyInput() {
  const queues = new Map<Element, Element[]>();
  const islandOf = (t: EventTarget | null) => (t instanceof Element ? t.closest(HYDRATION_PENDING) : null);
  const note = (island: Element, el: Element) => {
    const q = queues.get(island) ?? [];
    const at = q.indexOf(el);
    if (at >= 0 && !el.matches(EARLY_BUTTON)) q.splice(at, 1); // 값은 마지막 상태만, 단추는 누른 횟수만큼
    q.push(el);
    queues.set(island, q);
  };
  document.addEventListener(
    'click',
    (ev) => {
      const island = islandOf(ev.target);
      const btn = island && (ev.target as Element).closest(EARLY_BUTTON);
      if (island && btn && island.contains(btn) && !(btn as HTMLButtonElement).disabled) note(island, btn);
    },
    true,
  );
  for (const type of ['input', 'change']) {
    document.addEventListener(
      type,
      (ev) => {
        const island = islandOf(ev.target);
        if (island && (ev.target as Element).matches(EARLY_VALUE)) note(island, ev.target as Element);
      },
      true,
    );
  }
  const changed = (el: Element): boolean => {
    if (el instanceof HTMLInputElement) {
      if (el.type === 'radio') return el.checked && !el.defaultChecked;
      if (el.type === 'checkbox') return el.checked !== el.defaultChecked;
      return el.value !== el.defaultValue;
    }
    if (el instanceof HTMLSelectElement) return [...el.options].some((o) => o.selected !== o.defaultSelected);
    if (el instanceof HTMLTextAreaElement) return el.value !== el.defaultValue;
    return false;
  };
  // astro:hydrate 는 버블링하지 않으므로 캡처 단계에서 받는다(Astro 가 ssr 속성을 지운 직후에 보낸다).
  document.addEventListener(
    'astro:hydrate',
    (ev) => {
      const island = ev.target as Element;
      const q = queues.get(island);
      if (!q) return;
      queues.delete(island);
      for (const el of q) {
        if (!el.isConnected) continue;
        if (el.matches(EARLY_BUTTON)) {
          if (!(el as HTMLButtonElement).disabled) (el as HTMLElement).click();
        } else if (changed(el)) {
          const toggle = el instanceof HTMLInputElement && (el.type === 'checkbox' || el.type === 'radio');
          if (!toggle && !(el instanceof HTMLSelectElement)) el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
      }
    },
    true,
  );
}
initEarlyInput();

// 붙기 전 상태를 aria-busy 로 표시하지 않는다. client:visible 위젯은 화면에 들어올 때까지 붙지 않으므로, 빠르게 지나치거나
// (맨 끝으로 바로 이동) 화면에 머물지 않은 위젯은 busy 가 끝까지 남았고(전 위젯 페이지 101쪽 중 29곳), 화면 낭독기는 busy 영역을
// 건너뛸 수 있어 서버가 그린 내용(진행 목록·처음 계산 결과)까지 가려졌다. 서버가 그린 내용은 그대로 읽을 수 있는 정상 내용이고,
// 붙기 전 입력은 위의 받아 두기가 붙은 뒤에 넘겨주므로 busy 표시 없이 둔다. 검사: tests/widget-busy.mjs(sitecheck a11y 관문).

/* ---------- 좁은 화면 목차의 "지금 읽는 곳" 표시에도 등급 라벨 ---------- */
// Starlight 는 현재 절 링크의 textContent 를 .display-current 에 그대로 넣어 등급 라벨(생성 콘텐츠·role=img)이 빠진다.
// 링크 안(GradeMarks.astro 가 라벨을 붙인 것)을 그대로 옮겨 이모지만 남지 않게 한다.
function initMobileTocGrades() {
  const toc = document.querySelector('mobile-starlight-toc');
  const display = toc?.querySelector<HTMLElement>('.display-current');
  if (!toc || !display) return;
  const fix = () => {
    if (!/🟢|🟡|🔴/u.test(display.textContent || '') || display.querySelector('.grade-mark')) return;
    const span = toc.querySelector('a[aria-current="true"] > span');
    if (span?.querySelector('.grade-mark')) display.innerHTML = span.innerHTML;
  };
  new MutationObserver(fix).observe(display, { childList: true, characterData: true, subtree: true });
  fix();
}

function init() {
  document.documentElement.classList.add('guide-js');
  initMobileTocGrades();
  initCopy();
  initQuiz();
  initChecklist();
  initReveal();
  initTables();
  initDiagrams();
  mountStoragePanels();
  installExamGuard();
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
else init();
