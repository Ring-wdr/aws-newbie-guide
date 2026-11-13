// 본문 장치의 브라우저 쪽 동작: 명령 복사, 퀴즈 채점, 체크리스트 저장, 진행 상태 백업.
// 스크립트가 없어도 원고 내용은 모두 읽힌다(단추만 숨겨진 채 남는다).
import { ko } from '../i18n/ko.mjs';
import { load, save, remove, mountStoragePanels } from './storage';

const pageKey = location.pathname.replace(/\/+$/, '') || '/';

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

function init() {
  document.documentElement.classList.add('guide-js');
  initCopy();
  initQuiz();
  initChecklist();
  initReveal();
  mountStoragePanels();
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
else init();
