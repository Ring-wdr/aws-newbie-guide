// 확인 상자(공용). 시험 모드·진행 추적·시험 중 정답 링크 확인이 함께 쓴다.
import { ko } from '../i18n/ko.mjs';

/** 브라우저 기본 confirm() 대신 쓰는 확인 상자(<dialog>): 키보드로 조작되고 화면 낭독기가 읽는다. */
export function confirmDialog(message: string, opts: { yes?: string; no?: string; focus?: 'yes' | 'no' } = {}): Promise<boolean> {
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
    cancel.textContent = opts.no ?? ko.exam.confirmNo;
    const ok = document.createElement('button');
    ok.type = 'button';
    ok.className = 'exam-primary';
    ok.textContent = opts.yes ?? ko.exam.confirmYes;
    row.append(cancel, ok);
    dlg.append(p, row);
    document.body.append(dlg);
    const before = document.activeElement as HTMLElement | null;
    const done = (v: boolean) => {
      dlg.close();
      dlg.remove();
      // 취소하면 상자를 연 단추로 초점을 돌린다(확인 뒤의 초점은 부른 쪽이 정한다).
      if (!v && before?.isConnected) before.focus();
      resolve(v);
    };
    ok.addEventListener('click', () => done(true));
    cancel.addEventListener('click', () => done(false));
    dlg.addEventListener('cancel', (e) => {
      e.preventDefault();
      done(false);
    });
    dlg.showModal();
    (opts.focus === 'no' ? cancel : ok).focus();
  });
}
