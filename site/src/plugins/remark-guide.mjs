// 원고 Markdown → 사이트 화면 요소 변환의 진입점(remark 플러그인).
// 원고 파일은 고치지 않는다. 빌드 때 mdast를 바꿀 뿐이다.
// report 모드(scripts/converter-report.mjs)에서는 같은 변환을 돌리되 그리기(Mermaid)는 하지 않고,
// 해석하지 못한 구조를 실패 대신 보고서에 모은다.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { toString } from 'mdast-util-to-string';
import { kindOf, repoRel, REPO_ROOT } from '../lib/repo.mjs';
import { reporter, html } from './util.mjs';
import { transformMeta } from './meta.mjs';
import { transformCode, mermaidHtml } from './code.mjs';
import { transformQuiz } from './quiz.mjs';
import { transformLinks } from './links.mjs';
import { transformMarkers } from './markers.mjs';
import { transformExamQuestions, transformExamKey } from './exam.mjs';
import { transformChecklist } from './checklist.mjs';
import { checkLessonSections, transformSelfCheck } from './sections.mjs';
import { renderMermaid, prefixFor, narrowSource } from './mermaid-render.mjs';
import { fontFaceCss } from './diagram-font.mjs';
import { withBase } from '../lib/base.mjs';

function relOf(file) {
  const p = file.path ? (String(file.path).startsWith('file:') ? fileURLToPath(file.path) : String(file.path)) : null;
  if (!p) return null;
  const abs = path.resolve(p);
  return repoRel(abs);
}

function checkTables(tree, rep) {
  rep.touch('tables');
  const walk = (n) => {
    if (n.type === 'table') {
      const cols = n.children[0]?.children.length ?? 0;
      const bad = n.children.filter((r) => r.children.length !== cols).length;
      if (bad) rep.unrecognised('tables', `표의 ${bad}개 줄이 머리글(${cols}칸)과 칸 수가 다름 — GFM은 칸을 채우거나 버린다`, n);
      else rep.handled('tables');
      return;
    }
    n.children?.forEach(walk);
  };
  walk(tree);
}

export function remarkGuide(options = {}) {
  const report = Boolean(options.report);
  return async function transformer(tree, file) {
    const rel = relOf(file);
    if (!rel || rel.startsWith('..')) return; // 저장소 밖 파일(이 사이트의 다른 Markdown)은 건드리지 않는다
    const rep = reporter(file);
    const kind = kindOf(rel);
    const ctx = { rel, kind, rep, report };

    // 1) H1: Starlight가 페이지 제목으로 따로 그리므로 본문에서는 뺀다(제목 문자열은 로더가 같은 줄에서 읽는다).
    const h1 = tree.children.findIndex((n) => n.type === 'heading' && n.depth === 1);
    rep.touch('title');
    if (h1 === 0 || (h1 > 0 && tree.children.slice(0, h1).every((n) => n.type === 'html'))) {
      ctx.title = toString(tree.children[h1]);
      tree.children.splice(h1, 1);
      rep.handled('title');
    } else {
      rep.unrecognised('title', '첫 블록이 H1 제목이 아님', tree.children[0]);
    }

    // 2) 종류별 구조 변환
    if (kind === 'lesson') {
      transformMeta(tree, ctx);
      checkLessonSections(tree, ctx);
      transformSelfCheck(tree, ctx);
    }
    transformCode(tree, ctx);
    if (kind === 'quiz') transformQuiz(tree, ctx);
    if (kind === 'exam-questions') transformExamQuestions(tree, ctx);
    if (kind === 'exam-key') transformExamKey(tree, ctx);
    if (kind === 'self-checklist') transformChecklist(tree, ctx);
    checkTables(tree, rep);
    transformLinks(tree, ctx);
    transformMarkers(tree, ctx);

    // 3) Mermaid → SVG (보고 모드에서는 그리지 않는다)
    if (!report && ctx.mermaid.length) {
      const results = await renderMermaid(ctx.mermaid.map((m) => m.source));
      // 아주 넓은 LR 그림은 좁은 화면용 TB 배치를 한 벌 더 그린다(mermaid-render.mjs narrowSource).
      const narrowSrc = ctx.mermaid.map((m, i) => (results[i].light ? narrowSource(m.source, results[i].light) : null));
      const narrowOut = narrowSrc.some(Boolean) ? await renderMermaid(narrowSrc.filter(Boolean)) : [];
      let ni = 0;
      const narrow = narrowSrc.map((src) => {
        if (!src) return null;
        const r = narrowOut[ni++];
        return r && r.light && r.dark ? { ...r, ids: { light: prefixFor(src, 'light'), dark: prefixFor(src, 'dark') } } : null;
      });
      // 다이어그램 글꼴(같은 사이트의 /fonts/diagram-*.woff2 — base 포함). 페이지의 첫 그림 앞에 한 번만 둔다.
      const fontCss = await fontFaceCss((file) => withBase(`/fonts/${file}`));
      ctx.mermaid.forEach((ph, i) => {
        const r = results[i];
        if (r.error || !r.light || !r.dark) {
          const line = ph.position?.start?.line;
          throw new Error(`${rel}:${line}: Mermaid 다이어그램을 그리지 못했다 — ${r.error || '알 수 없는 오류'}`);
        }
        Object.assign(ph, html(mermaidHtml(ph.source, r, { light: prefixFor(ph.source, 'light'), dark: prefixFor(ph.source, 'dark') }, narrow[i], i === 0 ? fontCss : '')));
        delete ph.data;
        delete ph.source;
      });
    } else {
      for (const ph of ctx.mermaid) {
        const src = ph.source;
        Object.assign(ph, { type: 'code', lang: 'mermaid', value: src });
        delete ph.data;
        delete ph.source;
      }
    }

    file.data.astro ??= {};
    file.data.astro.frontmatter ??= {};
    file.data.astro.frontmatter.guide = {
      rel,
      kind,
      widgets: ctx.widgets || [],
      quiz: ctx.quiz || null,
      meta: ctx.meta || null,
      linkedFiles: [...(ctx.linkedFiles || [])],
    };
  };
}

/**
 * GFM 설정. 원고에는 "D1~D4", "2~3시간"처럼 물결표를 범위 표시로 쓴 곳이 있는데(13곳), GFM은 물결표 한 개로도
 * 취소선을 만든다. 원고에 의도한 취소선(물결표 두 개)은 하나도 없으므로, 사이트는 한 개짜리 취소선을 끈다.
 */
export const GFM_OPTIONS = { singleTilde: false };

export default remarkGuide;
export { REPO_ROOT };
