// 코드 블록 변환.
// 1) ```bash 블록 + 바로 뒤의 라벨 없는 블록 → 복사 버튼이 달린 명령 + "기록된 실제 출력" 패널.
//    둘 사이에는 HTML 주석(<!-- external-host-ok: … --> 표시)만 끼어 있을 수 있다. 출력 블록이 없으면 명령만.
//    출력은 원고에 실린 것만 보여 준다(지어내지 않는다).
// 2) ```mermaid 블록 → 빌드 시점 SVG(라이트·다크) + 원문 텍스트. 다른 코드 블록 안에 실린 Mermaid 텍스트는
//    그 블록의 일부(출력)일 뿐이므로 건드리지 않는다(마크다운 파서가 바깥 블록 하나로 읽는다).
import { ko } from '../i18n/ko.mjs';
import { box, html, esc, isComment, eachParent } from './util.mjs';

const SHELL_LIKE = new Set(['sh', 'shell', 'zsh', 'console', 'shell-session']);

function head(cls, label, withCopy) {
  const btn = withCopy
    ? `<button type="button" class="copy-btn" data-copy hidden aria-label="${esc(`${label} ${ko.cmd.copy}`)}">${esc(ko.cmd.copy)}</button>`
    : '';
  return html(`<div class="${cls}"><span class="block-label">${esc(label)}</span>${btn}</div>`);
}

export function commandBlock(codeNode) {
  return box('div', { className: ['cmd-block'] }, [head('cmd-head', ko.cmd.command, true), codeNode]);
}

export function transformCode(tree, ctx) {
  const { rep } = ctx;
  rep.touch('cmd');
  rep.touch('mermaid');
  ctx.mermaid = [];
  eachParent(tree, (parent) => {
    if (parent.type === 'guideBox') return; // 이미 만든 명령·출력 상자 안은 다시 보지 않는다
    const kids = parent.children;
    for (let i = 0; i < kids.length; i++) {
      const node = kids[i];
      if (node.type !== 'code') continue;
      const lang = (node.lang || '').toLowerCase();
      rep.note('cmd', `lang:${lang || '(none)'}`);
      if (lang === 'mermaid') {
        const ph = { type: 'guideMermaid', source: node.value, position: node.position, data: { hName: 'div' } };
        kids[i] = ph;
        ctx.mermaid.push(ph);
        rep.handled('mermaid');
        continue;
      }
      if (lang !== 'bash') {
        if (SHELL_LIKE.has(lang)) rep.unrecognised('cmd', `bash가 아닌 셸 라벨 \`${lang}\` — 명령으로 취급하지 않음`, node);
        continue;
      }
      // 바로 뒤(주석만 건너뜀)의 라벨 없는 코드 블록을 찾는다.
      let j = i + 1;
      const skipped = [];
      while (j < kids.length && isComment(kids[j])) skipped.push(kids[j++]);
      const next = kids[j];
      if (next && next.type === 'code' && !next.lang) {
        // 명령과 그 출력 사이에는 위젯 표시를 둘 수 없다(GUIDE-SITE 4장). 주석 표시(external-host-ok)만 허용한다.
        const misplaced = skipped.find((c) => /^<!--\s*widget:/.test(c.value.trim()));
        if (misplaced) {
          const msg = `위젯 표시 "${misplaced.value.trim()}"가 bash 명령과 그 출력 블록 사이에 있다 — 출력 블록 뒤(빈 줄로 둘러싼 독립된 줄)로 옮긴다`;
          if (ctx.report) rep.unrecognised('markers', msg, misplaced);
          else throw new Error(`${ctx.rel}:${misplaced.position?.start?.line}: ${msg}`);
        }
        rep.handled('cmd');
        rep.note('cmd', 'bash+output');
        if (skipped.length) rep.note('cmd', 'paired-across-comment');
        const pair = box('div', { className: ['cmd-pair'] }, [
          commandBlock(node),
          box('div', { className: ['out-block'] }, [head('out-head', ko.cmd.output, false), next]),
        ]);
        // 건너뛴 주석은 짝 앞에 둔다(표시 처리 단계가 화면에서 지운다).
        kids.splice(i, j - i + 1, ...skipped, pair);
        i += skipped.length;
      } else {
        rep.handled('cmd');
        rep.note('cmd', 'bash-only');
        kids[i] = box('div', { className: ['cmd-pair', 'cmd-only'] }, [commandBlock(node)]);
      }
    }
  });
  // 라벨 없는 코드 블록 중 짝이 되지 않은 것(앞에 bash가 없음)은 그대로 둔다 — 셈만 한다.
  eachParent(tree, (parent) => {
    if (parent.type === 'guideBox') return;
    for (const n of parent.children) if (n.type === 'code' && !n.lang) rep.note('cmd', 'unlabeled-standalone');
  });
}

export function mermaidHtml(source, rendered, ids) {
  const svgBox = (theme) => {
    const r = rendered[theme];
    // SVG의 가로 크기를 원래 크기로 유지해, 좁은 화면에서는 줄이지 않고 상자 안에서 가로로 스크롤한다.
    return `<div class="diagram-${theme}" style="--diagram-w:${Math.ceil(r.width)}px">${r.svg}</div>`;
  };
  // 넓은 그림은 같은 사이트 안의 SVG 파일(/diagrams/<id>.svg)로 원래 크기 그대로 볼 수 있게 한다.
  const open =
    Math.ceil(rendered.light.width) > 640
      ? `<p class="diagram-open">` +
        `<a class="diagram-open-light" href="/diagrams/${ids.light}.svg" target="_blank" rel="noopener">${esc(ko.diagram.openFull)}</a>` +
        `<a class="diagram-open-dark" href="/diagrams/${ids.dark}.svg" target="_blank" rel="noopener">${esc(ko.diagram.openFull)}</a>` +
        `</p>`
      : '';
  return (
    `<figure class="diagram">` +
    `<div class="diagram-scroll" tabindex="0" role="group" aria-label="${esc(ko.diagram.label)}">${svgBox('light')}${svgBox('dark')}</div>` +
    open +
    `<details class="diagram-src"><summary>${esc(ko.diagram.source)}</summary><pre class="mermaid-src"><code>${esc(source)}</code></pre></details>` +
    `</figure>`
  );
}
