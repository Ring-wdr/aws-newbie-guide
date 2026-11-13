// 모의고사 시험 모드(브라우저). 타이머·표시해 두기·복수 응답·도메인별 점수·검토.
// 채점은 grade.py 를 옮긴 exam-core 로 한다. 답안은 answer-sheet.txt 형식으로 내보내 grade.py 로도 채점할 수 있다.
import { ko } from '../i18n/ko.mjs';
import { formatAnswerSheet, gradeExam, parseAnswerSheet } from '../lib/exam-core.mjs';
import { download, load, pickFile, remove, save } from './storage';

type Key = Record<string, { number: number; answer: string[]; domain: string; task: string; kind: string; topic: string }>;
type Data = {
  total: number;
  passPct: number;
  domains: Record<string, string>;
  minutes: number;
  key: Key;
  questions: Record<string, { choose: number; options: string[] }>;
};
type Phase = 'idle' | 'running' | 'submitted';
type State = {
  phase: Phase;
  current: number;
  answers: Record<string, string[]>;
  flags: number[];
  remainingMs: number;
  paused: boolean;
  filter: 'all' | 'wrong' | 'flagged';
};

const STORE = 'exam:m14-mock-exam';

/** 브라우저 기본 confirm() 대신 쓰는 확인 상자(<dialog>): 키보드로 조작되고 화면 낭독기가 읽는다. */
function confirmDialog(message: string): Promise<boolean> {
  return new Promise((resolve) => {
    const dlg = document.createElement('dialog');
    dlg.className = 'guide-dialog';
    const p = document.createElement('p');
    p.id = 'guide-dialog-msg';
    p.textContent = message;
    dlg.setAttribute('aria-labelledby', p.id);
    const row = document.createElement('div');
    row.className = 'guide-dialog-actions';
    const cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.textContent = ko.exam.confirmNo;
    const ok = document.createElement('button');
    ok.type = 'button';
    ok.className = 'exam-primary';
    ok.textContent = ko.exam.confirmYes;
    row.append(cancel, ok);
    dlg.append(p, row);
    document.body.append(dlg);
    const done = (v: boolean) => {
      dlg.close();
      dlg.remove();
      resolve(v);
    };
    ok.addEventListener('click', () => done(true));
    cancel.addEventListener('click', () => done(false));
    dlg.addEventListener('cancel', (e) => {
      e.preventDefault();
      done(false);
    });
    dlg.showModal();
    ok.focus();
  });
}
const app = document.querySelector<HTMLElement>('[data-exam]');
if (app) init(app);

function init(app: HTMLElement) {
  const data: Data = JSON.parse(document.getElementById('exam-data')!.textContent!);
  const nums = Array.from({ length: data.total }, (_, i) => i + 1);
  const fresh = (): State => ({ phase: 'idle', current: 1, answers: {}, flags: [], remainingMs: data.minutes * 60_000, paused: false, filter: 'all' });
  let state: State = { ...fresh(), ...load<Partial<State>>(STORE, {}) };

  const $ = <T extends HTMLElement>(sel: string) => app.querySelector<T>(sel)!;
  const start = $('.exam-start');
  const bar = $('.exam-bar');
  const nav = $('.exam-nav');
  const grid = $('.exam-nav-grid');
  const result = $('.exam-result');
  const controls = $('.exam-controls');
  const clock = $('.exam-clock');
  const counts = $('.exam-counts');
  const chooseStatus = $('.exam-choose-status');
  const explainSlot = $('.exam-explain-slot');
  const msg = $('.exam-msg');
  // 문항 아래로 옮겨 다니는 조작 단추 묶음은 app 밖으로 나가므로 처음에 붙잡아 둔다.
  const btnPrev = controls.querySelector<HTMLButtonElement>('[data-act=prev]')!;
  const btnNext = controls.querySelector<HTMLButtonElement>('[data-act=next]')!;
  const btnFlag = controls.querySelector<HTMLButtonElement>('[data-act=flag]')!;
  const btnBack = controls.querySelector<HTMLButtonElement>('[data-act=back-to-result]')!;
  const sections = new Map<number, HTMLElement>();
  for (const s of document.querySelectorAll<HTMLElement>('section.exam-q')) sections.set(Number(s.dataset.q), s);

  app.querySelector('.exam-noscript')?.remove();
  document.documentElement.classList.add('exam-js');
  const live = document.createElement('p');
  live.className = 'sr-only';
  live.setAttribute('role', 'status');
  live.setAttribute('aria-live', 'polite');
  app.append(live);
  const say = (t: string) => {
    live.textContent = '';
    requestAnimationFrame(() => (live.textContent = t));
  };

  const persist = () => save(STORE, state);
  const answered = (n: number) => (state.answers[n]?.length ?? 0) > 0;
  const flagged = (n: number) => state.flags.includes(n);

  // 문항 이동 단추
  for (const n of nums) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.dataset.goto = String(n);
    b.textContent = String(n);
    b.addEventListener('click', () => go(n, true));
    li.append(b);
    grid.append(li);
  }

  // 보기 입력 → 답 저장
  for (const [n, sec] of sections) {
    const choose = data.questions[n]?.choose ?? 1;
    for (const inp of sec.querySelectorAll<HTMLInputElement>('input')) {
      inp.addEventListener('change', () => {
        if (state.phase !== 'running') return;
        const picked = [...sec.querySelectorAll<HTMLInputElement>('input:checked')].map((i) => i.value).sort();
        if (picked.length) state.answers[n] = picked;
        else delete state.answers[n];
        persist();
        syncQuestion(n);
        syncCounts();
        if (choose > 1) say(ko.exam.chosen(picked.length, choose));
      });
    }
  }

  function fmt(ms: number) {
    const s = Math.max(0, Math.ceil(ms / 1000));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
  }

  function syncCounts() {
    const a = nums.filter(answered).length;
    counts.textContent = `${ko.exam.answeredCount(a, data.total)} · ${ko.exam.flaggedCount(state.flags.length)}`;
    for (const b of grid.querySelectorAll<HTMLButtonElement>('button')) {
      const n = Number(b.dataset.goto);
      b.dataset.answered = String(answered(n));
      b.dataset.flagged = String(flagged(n));
      if (state.phase === 'submitted') b.dataset.result = isRight(n) ? 'correct' : 'wrong';
      else delete b.dataset.result;
      const bits = [ko.exam.question(n), answered(n) ? '답함' : '안 함'];
      if (flagged(n)) bits.push(ko.exam.flagged);
      if (state.phase === 'submitted') bits.push(isRight(n) ? ko.quiz.correct : ko.quiz.wrong);
      b.setAttribute('aria-label', bits.join(', '));
      if (n === state.current && state.phase !== 'idle') b.setAttribute('aria-current', 'step');
      else b.removeAttribute('aria-current');
    }
  }

  const isRight = (n: number) => {
    const mine = (state.answers[n] ?? []).slice().sort().join('');
    return mine !== '' && mine === data.key[n].answer.join('');
  };

  function syncQuestion(n: number) {
    const sec = sections.get(n);
    if (!sec) return;
    const choose = data.questions[n]?.choose ?? 1;
    const mine = state.answers[n] ?? [];
    const inputs = [...sec.querySelectorAll<HTMLInputElement>('input')];
    for (const inp of inputs) {
      inp.checked = mine.includes(inp.value);
      const label = inp.closest('label')!;
      if (state.phase === 'submitted') {
        inp.disabled = true;
        label.classList.toggle('is-answer', data.key[n].answer.includes(inp.value));
        label.classList.toggle('is-wrong', inp.checked && !data.key[n].answer.includes(inp.value));
      } else {
        // 복수 응답은 정해진 개수까지만 고를 수 있다.
        inp.disabled = choose > 1 && !inp.checked && mine.length >= choose;
        label.classList.remove('is-answer', 'is-wrong');
      }
    }
    chooseStatus.textContent = choose > 1 ? `${ko.exam.chooseN(choose)} — ${ko.exam.chosen(mine.length, choose)}` : '';
    const flagBtn = btnFlag;
    flagBtn.setAttribute('aria-pressed', String(flagged(n)));
    flagBtn.textContent = flagged(n) ? `⚑ ${ko.exam.flagged}` : ko.exam.flag;
  }

  function visibleList(): number[] {
    if (state.phase !== 'submitted' || state.filter === 'all') return nums;
    if (state.filter === 'wrong') return nums.filter((n) => !isRight(n));
    return nums.filter(flagged);
  }

  function go(n: number, focus = false) {
    state.current = n;
    persist();
    render();
    if (focus) {
      const sec = sections.get(n);
      const h = sec?.querySelector<HTMLElement>('h2');
      if (h) {
        h.tabIndex = -1;
        h.focus();
      }
    }
  }

  let timer: number | undefined;
  let lastTick = 0;
  function tick() {
    const now = performance.now();
    if (state.phase === 'running' && !state.paused) {
      const before = state.remainingMs;
      state.remainingMs -= now - lastTick;
      for (const mark of [30, 10, 5, 1]) {
        if (before > mark * 60_000 && state.remainingMs <= mark * 60_000) say(`${ko.exam.timeLeft} ${mark}분`);
      }
      if (state.remainingMs <= 0) {
        state.remainingMs = 0;
        say(ko.exam.timeUp);
        submit(true);
      }
      persist();
    }
    lastTick = now;
    clock.textContent = fmt(state.remainingMs);
  }
  function startTimer() {
    stopTimer();
    lastTick = performance.now();
    timer = window.setInterval(tick, 1000);
    tick();
  }
  function stopTimer() {
    if (timer !== undefined) window.clearInterval(timer);
    timer = undefined;
  }

  async function submit(auto = false) {
    if (state.phase !== 'running') return;
    if (!auto) {
      const blank = nums.filter((n) => !answered(n)).length;
      if (!(await confirmDialog(ko.exam.submitConfirm(blank)))) return;
    }
    state.phase = 'submitted';
    state.filter = 'all';
    stopTimer();
    persist();
    render();
    result.focus();
  }

  function renderResult() {
    const answers: Record<number, string[]> = {};
    for (const [n, a] of Object.entries(state.answers)) answers[Number(n)] = a;
    const r = gradeExam(data.key, answers, state.flags, { domains: data.domains, passPct: data.passPct, total: data.total });
    $('.exam-total').textContent = `${ko.exam.total(r.totalOk, r.totalQ, r.pctText)} · ${ko.exam.blank(r.blank)}`;
    const verdict = $('.exam-verdict');
    verdict.textContent = r.pass ? ko.exam.pass(data.passPct) : ko.exam.fail(data.passPct, r.more);
    verdict.dataset.pass = String(r.pass);
    const tbody = $('.exam-domains tbody');
    tbody.replaceChildren(
      ...r.domains.map((d) => {
        const tr = document.createElement('tr');
        const pct = d.pct.toFixed(1);
        tr.innerHTML = `<th scope="row"></th><td></td><td><span class="exam-meter"><span style="width:${pct}%"></span></span> <span class="exam-pct"></span></td>`;
        tr.querySelector('th')!.textContent = `${d.domain} ${d.name}`;
        tr.querySelector('td')!.textContent = `${d.ok}/${d.total}`;
        tr.querySelector('.exam-pct')!.textContent = `${pct}%`;
        return tr;
      }),
    );
    $('.exam-weak').textContent = r.weak.length ? `${ko.exam.weak}: ${r.weak.map((d) => `${d} ${data.domains[d]}`).join(', ')}` : '';
    $('.exam-lucky').textContent = r.lucky.length ? `${ko.exam.lucky}: ${r.lucky.join(', ')}` : '';
    for (const b of app.querySelectorAll<HTMLButtonElement>('[data-filter]')) b.setAttribute('aria-pressed', String(b.dataset.filter === state.filter));
    const list = $('.exam-review-list');
    list.replaceChildren(
      ...visibleList().map((n) => {
        const li = document.createElement('li');
        const b = document.createElement('button');
        b.type = 'button';
        const k = data.key[n];
        const mine = (state.answers[n] ?? []).join('') || ko.exam.none;
        b.textContent = `${n}번 ${isRight(n) ? '○' : '✕'} ${ko.exam.mine} ${mine} · ${ko.exam.key} ${k.answer.join('')} — ${k.domain} ${k.task} ${k.topic}${flagged(n) ? ' ⚑' : ''}`;
        b.dataset.result = isRight(n) ? 'correct' : 'wrong';
        b.addEventListener('click', () => go(n, true));
        li.append(b);
        return li;
      }),
    );
  }

  function render() {
    const phase = state.phase;
    start.hidden = phase !== 'idle';
    $<HTMLButtonElement>('[data-act=start]').textContent = state.remainingMs < data.minutes * 60_000 || Object.keys(state.answers).length ? ko.exam.resume : ko.exam.start;
    $<HTMLButtonElement>('.exam-start [data-act=restart]').hidden = !(Object.keys(state.answers).length || state.flags.length);
    bar.hidden = phase !== 'running';
    nav.hidden = phase === 'idle';
    result.hidden = phase !== 'submitted';
    controls.hidden = phase === 'idle';
    $<HTMLButtonElement>('[data-act=pause]').textContent = state.paused ? ko.exam.resumeTimer : ko.exam.pause;
    app.dataset.phase = phase;
    app.dataset.paused = String(state.paused);
    // 한 번에 한 문항만 보인다. 시작 전에는 문항을 감춘다(미리 보지 않도록).
    const list = visibleList();
    if (phase !== 'idle' && !list.includes(state.current)) state.current = list[0] ?? 1;
    for (const [n, sec] of sections) sec.hidden = phase === 'idle' || n !== state.current || (state.paused && phase === 'running');
    if (phase !== 'idle') {
      const sec = sections.get(state.current);
      sec?.after(controls);
      syncQuestion(state.current);
      const idx = list.indexOf(state.current);
      btnPrev.disabled = idx <= 0;
      btnNext.disabled = idx < 0 || idx >= list.length - 1;
      btnFlag.hidden = phase !== 'running';
      btnBack.hidden = phase !== 'submitted';
      if (phase === 'submitted') {
        const tpl = document.getElementById(`exam-explain-${state.current}`) as HTMLTemplateElement | null;
        explainSlot.replaceChildren();
        if (tpl) {
          const h = document.createElement('h3');
          h.textContent = `${ko.exam.explanation} — ${ko.exam.question(state.current)}`;
          explainSlot.append(h, tpl.content.cloneNode(true));
        }
        explainSlot.hidden = false;
        renderResult();
      } else {
        explainSlot.hidden = true;
      }
    }
    syncCounts();
    clock.textContent = fmt(state.remainingMs);
  }

  const onClick = async (ev: MouseEvent) => {
    const t = (ev.target as HTMLElement).closest<HTMLButtonElement>('button[data-act], button[data-filter]');
    if (!t) return;
    if (ev.currentTarget === app && controls.contains(t)) return; // 조작 단추 묶음이 app 안에 있을 때 두 번 처리하지 않는다
    if (t.dataset.filter) {
      state.filter = t.dataset.filter as State['filter'];
      persist();
      render();
      return;
    }
    switch (t.dataset.act) {
      case 'start':
        state.phase = 'running';
        state.paused = false;
        persist();
        render();
        startTimer();
        go(state.current, true);
        break;
      case 'restart':
        if (!(await confirmDialog(ko.exam.restartConfirm))) return;
        stopTimer();
        state = fresh();
        remove(STORE);
        render();
        $<HTMLButtonElement>('[data-act=start]').focus();
        break;
      case 'pause':
        state.paused = !state.paused;
        persist();
        render();
        say(state.paused ? ko.exam.paused : ko.exam.resumeTimer);
        t.focus();
        break;
      case 'submit':
        await submit();
        break;
      case 'prev':
      case 'next': {
        const list = visibleList();
        const i = list.indexOf(state.current) + (t.dataset.act === 'next' ? 1 : -1);
        if (list[i]) go(list[i], true);
        break;
      }
      case 'flag': {
        const n = state.current;
        state.flags = flagged(n) ? state.flags.filter((x) => x !== n) : [...state.flags, n].sort((a, b) => a - b);
        persist();
        syncQuestion(n);
        syncCounts();
        say(flagged(n) ? ko.exam.flagged : ko.exam.flag);
        break;
      }
      case 'back-to-result':
        result.focus();
        result.scrollIntoView({ block: 'start' });
        break;
      case 'export-sheet':
        download('my-answers.txt', formatAnswerSheet(state.answers, state.flags, data.total), 'text/plain');
        break;
      case 'import-sheet': {
        const text = await pickFile('.txt,text/plain');
        if (text === null) return;
        const parsed = parseAnswerSheet(text, data.total);
        if (parsed.error) {
          msg.textContent = ko.exam.importSheetFailed;
          return;
        }
        state.answers = Object.fromEntries(Object.entries(parsed.answers).map(([n, a]) => [n, a]));
        state.flags = parsed.unsure.filter((n) => n >= 1 && n <= data.total);
        persist();
        render();
        msg.textContent = ko.exam.importSheetDone(Object.keys(parsed.answers).length);
        break;
      }
    }
  };
  app.addEventListener('click', onClick);
  controls.addEventListener('click', onClick);

  // 시험용 시험 훅: 자동화 검사(tools/sitecheck)가 키 입력만으로 끝까지 풀었는지 상태를 읽는다(쓰기는 하지 않는다).
  (window as any).__guideExamState = () => JSON.parse(JSON.stringify(state));

  render();
  if (state.phase === 'running') startTimer();
}
