// 원고를 제자리에서 읽는 로더 — docs/GUIDE-SITE.md 3장.
// Starlight의 docs 컬렉션을 저장소 루트의 README.md·docs/*.md·curriculum/**/*.md 로 채운다(복사하지 않는다).
// 원고에는 frontmatter가 없으므로 페이지 제목은 첫 줄의 H1에서 읽어 넣는다(본문의 H1은 변환기가 뺀다).
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import type { Loader } from 'astro/loaders';
import { REPO_ROOT, builtContentFiles, idForRepoPath, kindOf, readTitle, repoRel, shortLabel } from './lib/repo.mjs';
import { ko } from './i18n/ko.mjs';

function curriculumLoader(): Loader {
  const inner = glob({
    base: REPO_ROOT,
    pattern: builtContentFiles(),
    generateId: ({ entry }) => idForRepoPath(entry),
  });
  return {
    name: 'guide-curriculum-loader',
    load: (ctx) =>
      inner.load({
        ...ctx,
        parseData: (props) => {
          const rel = repoRel(props.filePath!);
          const kind = kindOf(rel);
          return ctx.parseData({
            ...props,
            data: {
              ...props.data,
              title: readTitle(rel),
              sidebar: { label: shortLabel(rel) },
              // 홈(저장소 README)과 참고 문서는 목차를 보이고, 모의고사 시험 페이지는 시험 화면을 넓게 쓰도록 목차를 숨긴다.
              ...(kind === 'exam-questions' ? { tableOfContents: false } : {}),
            },
          });
        },
      }),
  };
}

// Starlight 내장 UI 문자열 중 사전(src/i18n/ko.mjs)에서 덮어쓰는 것.
function i18nLoader(): Loader {
  return {
    name: 'guide-i18n-loader',
    load: async ({ store, parseData }) => {
      store.clear();
      const data = await parseData({ id: 'ko', data: ko.starlight });
      store.set({ id: 'ko', data });
    },
  };
}

export const collections = {
  docs: defineCollection({ loader: curriculumLoader(), schema: docsSchema() }),
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
