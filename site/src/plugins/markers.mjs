// 원고 속 HTML 주석 표시 처리.
// - <!-- external-host-ok: … --> : 원고에는 남고 화면에는 내지 않는다(이 단계에서 산출물에서 뺀다).
// - <!-- widget: <이름> -->      : site/src/widgets/mNN/<이름>/index.astro 를 찾아 그 자리에 놓는다.
//                                  없으면 공용 위젯(src/lib/shared-widgets.mjs — 예: progress-tracker)인지 본다.
//                                  둘 다 아니면 빌드를 실패시킨다(등록 파일 없이 디렉터리로 찾는다).
// - 그 밖의 주석                 : 화면에 내지 않는다(셈만 한다).
import fs from 'node:fs';
import path from 'node:path';
import { WIDGETS_DIR, moduleOf } from '../lib/repo.mjs';
import { SHARED_WIDGETS } from '../lib/shared-widgets.mjs';
import { html, isComment, eachParent } from './util.mjs';

const WIDGET_RE = /^<!--\s*widget:\s*([^\s]+?)\s*-->$/;
const EXT_RE = /^<!--\s*external-host-ok:/;
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

export function widgetDir(mod, name) {
  return path.join(WIDGETS_DIR, mod, name);
}

export function transformMarkers(tree, ctx) {
  const { rep, rel, report } = ctx;
  rep.touch('markers');
  ctx.widgets = [];
  eachParent(tree, (parent) => {
    const kids = parent.children;
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i];
      if (!isComment(n)) continue;
      const v = n.value.trim();
      const w = WIDGET_RE.exec(v);
      if (w) {
        const name = w[1];
        const mod = (moduleOf(rel) || '').slice(0, 3); // "m06"
        if (!mod || !NAME_RE.test(name)) {
          const msg = `위젯 표시 "${v}"를 해석할 수 없다(모듈 원고 안에서, 이름은 소문자·숫자·하이픈)`;
          if (report) rep.unrecognised('markers', msg, n);
          else throw new Error(`${rel}:${n.position?.start?.line}: ${msg}`);
          continue;
        }
        const dir = widgetDir(mod, name);
        if (!fs.existsSync(path.join(dir, 'index.astro')) && !SHARED_WIDGETS.includes(name)) {
          const msg = `위젯 "${name}"이 없다: ${path.relative(process.cwd(), dir)}/index.astro 를 찾지 못했다`;
          if (report) rep.unrecognised('markers', msg, n);
          else throw new Error(`${rel}:${n.position?.start?.line}: ${msg}`);
          continue;
        }
        if (parent.type !== 'root') {
          const msg = `위젯 표시 "${name}"는 빈 줄로 둘러싼 독립된 줄이어야 한다(목록·인용 안에 있음)`;
          if (report) rep.unrecognised('markers', msg, n);
          else throw new Error(`${rel}:${n.position?.start?.line}: ${msg}`);
          continue;
        }
        kids[i] = html(`<div data-guide-widget="${mod}/${name}"></div>`);
        ctx.widgets.push(`${mod}/${name}`);
        rep.handled('markers');
        rep.note('markers', 'widget');
        continue;
      }
      if (EXT_RE.test(v)) rep.note('markers', 'external-host-ok');
      else rep.note('markers', 'other-comment');
      rep.handled('markers');
      kids.splice(i, 1);
      i--;
    }
  });
}
