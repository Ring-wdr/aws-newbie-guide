// 가이드 사이트 빌드 설정 — docs/GUIDE-SITE.md 3장.
// 원고는 저장소의 curriculum/·docs/·README.md 를 제자리에서 읽는다(src/content.config.ts).
// 산출물은 외부 리소스를 하나도 불러오지 않는다: 시스템 글꼴, 빌드 시점 Mermaid SVG, 로컬 검색 색인.
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import preact from '@astrojs/preact';
import { unified } from '@astrojs/markdown-remark';
import remarkGfm from 'remark-gfm';
import { remarkGuide, GFM_OPTIONS } from './src/plugins/remark-guide.mjs';
import { rehypeGuide } from './src/plugins/rehype-guide.mjs';
import { buildSidebar } from './src/lib/sidebar.mjs';
import { REPO_ROOT } from './src/lib/repo.mjs';
import { ko } from './src/i18n/ko.mjs';

// 원격 측정·업데이트 확인을 끈다(package.json 스크립트와 scripts/guide-up.sh 도 같은 환경 변수를 준다).
process.env.ASTRO_TELEMETRY_DISABLED = '1';
process.env.GUIDE_SITE_DIR ??= new URL('.', import.meta.url).pathname; // src/lib/repo.mjs 참고
process.env.ASTRO_DISABLE_UPDATE_CHECK = 'true';

export default defineConfig({
  // 로컬 전용. 공개 배포는 GUIDE-SITE 1장에 따라 소유자 승인 뒤에 정한다.
  server: { host: '127.0.0.1', port: 4321 },
  devToolbar: { enabled: false },
  prefetch: false,
  trailingSlash: 'always',
  build: { format: 'directory' },
  markdown: {
    processor: unified({
      // GFM은 아래 플러그인으로 직접 켠다(물결표 한 개 취소선을 끄기 위해 — remark-guide.mjs 참고).
      gfm: false,
      smartypants: false, // 원고의 따옴표·대시를 바꾸지 않는다
      remarkPlugins: [[remarkGfm, GFM_OPTIONS], remarkGuide],
      rehypePlugins: [rehypeGuide],
    }),
    syntaxHighlight: 'shiki',
    shikiConfig: {
      themes: { light: 'github-light-default', dark: 'github-dark-default' },
      defaultColor: false,
      wrap: false,
    },
  },
  vite: {
    server: { fs: { allow: [REPO_ROOT] } },
    resolve: {
      alias: {
        // 맞춤 위젯 디렉터리. 시험용 빌드(GUIDE_WIDGETS_DIR)만 다른 곳을 가리킨다.
        '@guide-widgets': process.env.GUIDE_WIDGETS_DIR || new URL('./src/widgets', import.meta.url).pathname,
      },
    },
  },
  integrations: [
    starlight({
      title: ko.site.title,
      description: ko.site.description,
      defaultLocale: 'root',
      locales: { root: { label: '한국어', lang: 'ko' } },
      sidebar: buildSidebar(),
      customCss: ['./src/styles/guide.css'],
      components: {
        MarkdownContent: './src/components/MarkdownContent.astro',
        ThemeProvider: './src/components/ThemeProvider.astro',
        ThemeSelect: './src/components/ThemeSelect.astro',
      },
      expressiveCode: false,
      pagefind: true,
      lastUpdated: false,
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
      favicon: '/favicon.svg',
    }),
    preact(),
  ],
});
