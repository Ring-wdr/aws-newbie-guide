// Mermaid 다이어그램을 빌드할 때 SVG로 그린다(라이트·다크 두 벌). 브라우저에는 Mermaid 스크립트를 보내지 않는다.
// 그리기는 mermaid-isomorphic이 Playwright 헤드리스 Chromium 안에서 한다(로컬 파일만 읽는다).
// 같은 원문은 디스크 캐시(node_modules/.cache/guide-mermaid)에서 재사용한다.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { SITE_DIR } from '../lib/repo.mjs';

const require = createRequire(import.meta.url);
const CACHE_DIR = path.join(SITE_DIR, 'node_modules/.cache/guide-mermaid');

// 페이지와 같은 시스템 글꼴 스택. 빌드 때 글자 폭을 이 글꼴로 재므로 화면과 어긋남이 작다.
export const FONT_STACK =
  '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans KR", "Segoe UI", sans-serif';

const THEMES = {
  light: { theme: 'default' },
  // Mermaid 'dark' 테마의 간선 라벨(회색 바탕 + 회색 글자)은 명암비가 WCAG AA(4.5:1)에 못 미쳐 바탕만 어둡게 바꾼다.
  dark: { theme: 'dark', themeVariables: { edgeLabelBackground: '#1b1e24', labelBackground: '#1b1e24' } },
};

let versionTag;
function cacheVersion() {
  if (!versionTag) {
    const v = (name) => {
      try {
        return JSON.parse(fs.readFileSync(require.resolve(`${name}/package.json`), 'utf8')).version;
      } catch {
        return '?';
      }
    };
    versionTag = `mi${v('mermaid-isomorphic')}-pw${v('playwright')}-v3`;
  }
  return versionTag;
}

let renderer;
async function getRenderer() {
  if (!renderer) {
    const { createMermaidRenderer } = await import('mermaid-isomorphic');
    renderer = createMermaidRenderer();
  }
  return renderer;
}

function keyFor(source, theme) {
  return crypto.createHash('sha256').update(`${cacheVersion()}\0${JSON.stringify(THEMES[theme])}\0${source}`).digest('hex').slice(0, 24);
}

// 다이어그램마다 고유한 id 접두어. SVG 안의 <style>이 id로 범위를 잡으므로 한 페이지 안에서 겹치면 안 된다.
function prefixFor(source, theme) {
  return `mmd-${crypto.createHash('sha256').update(source).digest('hex').slice(0, 10)}-${theme}`;
}

/**
 * @param {string[]} sources Mermaid 원문 목록
 * @returns {Promise<Array<{light: {svg:string,width:number,height:number}, dark: {...}} | {error: string}>>}
 */
export async function renderMermaid(sources) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const out = sources.map(() => ({}));
  for (const theme of Object.keys(THEMES)) {
    const todo = [];
    sources.forEach((src, i) => {
      if (out[i].error) return;
      const file = path.join(CACHE_DIR, `${keyFor(src, theme)}.json`);
      if (fs.existsSync(file)) {
        out[i][theme] = JSON.parse(fs.readFileSync(file, 'utf8'));
      } else {
        todo.push(i);
      }
    });
    // 한 번에 하나씩 그린다: 접두어가 원문마다 달라야 하므로(같은 페이지의 두 그림이 같은 id를 쓰지 않게).
    for (const i of todo) {
      const render = await getRenderer();
      const [res] = await render([sources[i]], {
        prefix: prefixFor(sources[i], theme),
        mermaidConfig: {
          ...THEMES[theme],
          fontFamily: FONT_STACK,
          securityLevel: 'strict',
          flowchart: { htmlLabels: true },
        },
      });
      if (res.status === 'fulfilled') {
        const value = { svg: res.value.svg, width: res.value.width, height: res.value.height };
        out[i][theme] = value;
        fs.writeFileSync(path.join(CACHE_DIR, `${keyFor(sources[i], theme)}.json`), JSON.stringify(value));
      } else {
        out[i] = { error: String(res.reason?.message || res.reason) };
      }
    }
  }
  return out;
}
