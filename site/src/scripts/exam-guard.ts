// 시험 중(시작 뒤 제출 전)에는 모의고사 정답·해설 페이지로 가는 길을 가린다.
// - 사이드바와 이전/다음 페이지 링크의 정답·해설 링크는 숨긴다.
// - 본문 등 그 밖의 링크는 누르면 "시험 중에는 열지 않기" 확인을 띄운다(확인하면 연다).
// 주소를 직접 입력해 여는 것까지 막지는 않는다(혼자 공부하는 가이드 — site/README "알아 둘 성질").
// 시험 상태는 exam.ts가 저장하는 "exam:m14-mock-exam"의 phase로 판단하므로 어느 페이지에서나 같다.
// 시작만 하고 떠난 시험(마지막 저장 + 남은 시간 + 24시간이 지남)은 가리지 않는다(lib/exam-live.mjs).
// 사이트 검색(Pagefind) 결과의 정답·해설 링크도 본문 링크와 같이 누를 때 확인을 거친다(문서 전체에 건 클릭 처리).
import { ko } from '../i18n/ko.mjs';
import { load, onStorageChange } from './storage';
import { confirmDialog } from './dialog';
import { examLiveState } from '../lib/exam-live.mjs';
import { siteRoute } from './base';

export const EXAM_STORE = 'exam:m14-mock-exam';
export const ANSWER_KEY_PATH = '/curriculum/m14-capstone-exam/mock-exam/answer-key/'; // base 를 뺀 사이트 경로(base.ts)

const NAV_SELECTOR = 'nav.sidebar, .pagination-links';

/** 진행 중인 시험이 있는가. 시작만 하고 떠나 종료 예정 시각 + 24시간이 지난 진행 상태는 버려진 것으로 보고 가리지 않는다(lib/exam-live.mjs). */
export function examRunning(): boolean {
  return examLiveState(load<unknown>(EXAM_STORE, null), Date.now()) === 'running';
}

function isKeyLink(a: HTMLAnchorElement): boolean {
  try {
    const u = new URL(a.href, location.href);
    return u.origin === location.origin && siteRoute(u.pathname).replace(/\/?$/, '/') === ANSWER_KEY_PATH;
  } catch {
    return false;
  }
}

let running = false;
/** 화면을 시험 상태에 맞춘다. running을 주지 않으면 저장값에서 읽는다. */
export function syncExamGuard(next: boolean = examRunning()): void {
  running = next;
  document.documentElement.toggleAttribute('data-exam-running', running);
  for (const a of document.querySelectorAll<HTMLAnchorElement>('a[href]')) {
    if (!isKeyLink(a)) continue;
    if (a.closest(NAV_SELECTOR)) {
      // 사이드바는 목록 항목째, 이전/다음 링크는 링크만 숨긴다.
      const target = (a.closest('nav.sidebar') ? a.closest('li') : null) ?? a;
      target.classList.toggle('exam-key-hidden', running);
    } else {
      a.dataset.examKeyLink = '';
    }
  }
}

let installed = false;
export function installExamGuard(): void {
  if (installed) return;
  installed = true;
  syncExamGuard();
  onStorageChange((key) => {
    if (key === null || key === EXAM_STORE) {
      const now = examRunning();
      if (now !== running) syncExamGuard(now);
    }
  });
  document.addEventListener(
    'click',
    async (ev) => {
      if (!running || ev.defaultPrevented || ev.button !== 0) return;
      const a = (ev.target as HTMLElement | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!a || !isKeyLink(a)) return;
      ev.preventDefault();
      const go = await confirmDialog(ko.exam.keyLinkConfirm, { yes: ko.exam.keyLinkOpen, no: ko.exam.keyLinkStay, focus: 'no' });
      if (go) location.href = a.href;
    },
    true,
  );
  // 정답·해설 페이지를 시험 중에 (주소로) 열었으면 위에 알림만 둔다.
  if (running && siteRoute(location.pathname).replace(/\/?$/, '/') === ANSWER_KEY_PATH) {
    const main = document.querySelector('.sl-markdown-content');
    if (main) {
      const p = document.createElement('p');
      p.className = 'exam-key-warning';
      p.setAttribute('role', 'note');
      p.textContent = ko.exam.keyPageWarning;
      main.prepend(p);
    }
  }
}
