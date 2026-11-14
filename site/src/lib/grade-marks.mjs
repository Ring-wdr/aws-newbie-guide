// 이미 그려진 HTML 조각(Starlight 의 목차·사이드바)의 등급 이모지 🟢/🟡/🔴 에 본문과 같은 라벨을 붙인다(원칙 6: 색만으로 전달 금지).
// 본문은 rehype-guide.mjs 의 gradeMarks 가 같은 구조를 만든다: 이모지 자리에 role=img + aria-label(접근 가능한 이름),
// 그 뒤에 보이는 라벨 칸(.grade-mark-label — 글자는 CSS 생성 콘텐츠, aria-hidden). 그래서 목차 글자·복사되는 글자는 원고 제목 그대로다.
// 글자 노드만 바꾼다: 태그·속성(href 의 앵커 등)과 script·style·template·title 안은 건드리지 않는다.
const GRADE_CLASS = { '🟢': 'g', '🟡': 'y', '🔴': 'r' };
const GRADE_SPLIT = /(🟢|🟡|🔴)/u;
const SKIP = new Set(['script', 'style', 'template', 'title', 'textarea', 'code', 'pre']);

const escAttr = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');

/**
 * @param {string} html 그려진 HTML
 * @param {Record<string, {label: string, meaning: string}>} legend 원고 README 등급 표(plugins/meta.mjs gradeLegend())
 */
export function gradeMarksInHtml(html, legend) {
  if (!GRADE_SPLIT.test(html)) return html;
  const tokens = html.split(/(<[^>]*>)/);
  let skip = 0; // SKIP 태그 안 깊이
  let inMark = 0; // 이미 라벨이 붙은 .grade-mark/.grade-badge 안 깊이(같은 태그 이름을 세지 않고 span 깊이로 센다)
  let spanDepth = 0;
  const markAt = [];
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.startsWith('<')) {
      const m = /^<(\/?)([a-zA-Z][\w-]*)/.exec(t);
      if (!m) continue;
      const name = m[2].toLowerCase();
      const closing = m[1] === '/';
      const selfClosing = /\/>$/.test(t);
      if (SKIP.has(name)) skip += closing ? -1 : selfClosing ? 0 : 1;
      if (name === 'span' && !selfClosing) {
        if (closing) {
          if (markAt.length && markAt[markAt.length - 1] === spanDepth) {
            markAt.pop();
            inMark--;
          }
          spanDepth--;
        } else {
          spanDepth++;
          if (/\bclass="[^"]*\bgrade-(mark|badge)\b/.test(t)) {
            markAt.push(spanDepth);
            inMark++;
          }
        }
      }
      continue;
    }
    if (skip > 0 || inMark > 0 || !GRADE_SPLIT.test(t)) continue;
    const parts = t.split(GRADE_SPLIT);
    tokens[i] = parts
      .map((part, k) => {
        if (!GRADE_CLASS[part]) return part;
        const { label, meaning } = legend[part];
        const after = parts.slice(k + 1).join('').trimStart();
        const title = escAttr(`${label}: ${meaning}`);
        const cls = `grade-mark grade-mark-${GRADE_CLASS[part]}`;
        // 바로 뒤에 같은 라벨 글자가 이미 있으면("🟢 재현") 이모지만 감싼다 — 본문 규칙과 같다.
        if (after.startsWith(label)) return `<span class="${cls}" title="${title}">${part}</span>`;
        const l = escAttr(label);
        return `<span class="${cls}" title="${title}"><span role="img" aria-label="${l}">${part}</span><span class="grade-mark-label" data-label="${l}" aria-hidden="true"></span></span>`;
      })
      .join('');
  }
  return tokens.join('');
}
