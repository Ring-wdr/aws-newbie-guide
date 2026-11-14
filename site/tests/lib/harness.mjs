// 브라우저 검사 공용 도구: dist/ 를 127.0.0.1 에서만 여는 정적 서버 + 루프백 밖 요청을 모두 막고 기록하는 브라우저.
// Playwright 브라우저는 내려받지 않는다(빌드가 쓰는 것과 같은 chromium-headless-shell 을 쓴다 — package.json 의 고정 버전과 짝.
// 없으면 scripts/guide-up.sh 가 빌드 전에 받는다).
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

export const SITE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const DIST = path.resolve(process.env.GUIDE_DIST || path.join(SITE_DIR, 'dist'));

/**
 * 산출물이 빌드된 base 경로(""=루트, "/aws-newbie-guide" 등 — src/lib/base.mjs 의 GUIDE_BASE). 산출물 자체에서 읽는다:
 * 홈(index.html)이 불러오는 /…/_astro/ 자산의 앞부분. 그래서 검사·로컬 서버는 따로 설정하지 않아도 빌드와 같은 주소에서 연다.
 * GUIDE_BASE 를 주면 그 값이 산출물과 같은지 확인한다(다르면 실패 — 다른 base 로 빌드한 산출물을 검사하지 않게).
 */
export function detectBase(root = DIST) {
  let html;
  try {
    html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  } catch {
    return '';
  }
  const m = /\s(?:href|src)="(\/(?:[A-Za-z0-9._-]+\/)*)_astro\//.exec(html);
  return m ? m[1].replace(/\/$/, '') : '';
}
/** 검사 대상 산출물(DIST)의 base 접두어. 페이지 경로("/curriculum/…/")는 base 를 뺀 사이트 경로로 다루고, 주소에만 붙인다. */
export const BASE = detectBase(DIST);
/** GUIDE_BASE 를 줬다면 산출물의 base 와 같은지(serve 가 DIST 를 열 때 확인한다 — 불러오기만 하는 --check 에서는 보지 않는다). */
function assertBaseMatches() {
  if (process.env.GUIDE_BASE === undefined) return;
  const s = process.env.GUIDE_BASE.trim().replace(/^\/+|\/+$/g, '');
  const want = s ? `/${s}` : '';
  if (want !== BASE) throw new Error(`GUIDE_BASE(${want || '/'})와 산출물의 base(${BASE || '/'})가 다르다: ${DIST} — 같은 GUIDE_BASE 로 다시 빌드한다`);
}
/** 사이트 경로 → 주소 경로(base 접두어를 붙인다). 링크의 href 를 비교할 때 쓴다. */
export const withBase = (route) => BASE + route;
/** 주소 경로 → 사이트 경로(base 를 뺀다). base 밖의 경로는 null. */
export function siteRoute(pathname) {
  if (!BASE) return pathname;
  if (pathname === BASE || pathname === `${BASE}/`) return '/';
  return pathname.startsWith(`${BASE}/`) ? pathname.slice(BASE.length) : null;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pf_meta': 'application/octet-stream',
  '.pf_index': 'application/octet-stream',
  '.pf_fragment': 'application/octet-stream',
  '.pagefind': 'application/octet-stream',
};

/** 포트는 반드시 받는다(에이전트마다 전용 포트 — GUIDE-SITE 6장). */
export function portFromArgs(def) {
  const i = process.argv.indexOf('--port');
  const p = i >= 0 ? Number(process.argv[i + 1]) : Number(process.env.GUIDE_PORT || def);
  if (!Number.isInteger(p) || p < 1024 || p > 65535) throw new Error('--port <1024~65535> 가 필요하다');
  return p;
}

/**
 * 포트를 이미 누가 쓰는가. 127.0.0.1 에 bind 해 보는 것만으로는 0.0.0.0·[::] 에서 듣는 프로그램을 못 본다(macOS 등은
 * 같은 포트의 와일드카드 주소와 127.0.0.1 bind 가 함께 성공한다). 그래서 127.0.0.1·::1 로 접속도 해 본다.
 */
export async function portBusy(port) {
  const connects = (host) =>
    new Promise((resolve) => {
      const sock = net.connect({ host, port });
      const done = (v) => {
        sock.destroy();
        resolve(v);
      };
      sock.setTimeout(500, () => done(false));
      sock.once('connect', () => done(true));
      sock.once('error', () => done(false));
    });
  const binds = () =>
    new Promise((resolve) => {
      const srv = net.createServer();
      srv.once('error', () => resolve(false));
      srv.listen(port, '127.0.0.1', () => srv.close(() => resolve(true)));
    });
  if ((await connects('127.0.0.1')) || (await connects('::1'))) return true;
  return !(await binds());
}

/**
 * root 를 127.0.0.1:port 에서 연다. base(기본: 검사 대상 산출물이면 BASE, 결함을 심은 임시 폴더면 "")가 있으면
 * 산출물을 그 경로 아래에서만 보여 준다(GitHub Pages 프로젝트 주소와 같다): /aws-newbie-guide/… → root/…,
 * /aws-newbie-guide → /aws-newbie-guide/ 로 이동, 그 밖의 경로는 404(base 를 빠뜨린 링크·자산이 검사에서 드러나게).
 */
export function serve(port, root = DIST, base = path.resolve(root) === DIST ? BASE : '') {
  if (!fs.existsSync(path.join(root, 'index.html')) && !fs.existsSync(path.join(root, '404.html'))) {
    throw new Error(`빌드 산출물이 없다: ${root} — 먼저 pnpm --dir site build`);
  }
  if (path.resolve(root) === DIST) assertBaseMatches();
  const notFound = (res) => {
    const nf = path.join(root, '404.html');
    res.writeHead(404, { 'content-type': TYPES['.html'] });
    res.end(fs.existsSync(nf) ? fs.readFileSync(nf) : 'not found');
  };
  const server = http.createServer((req, res) => {
    let p;
    try {
      p = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    if (base) {
      if (p === base) {
        res.writeHead(301, { location: `${base}/` }).end();
        return;
      }
      if (!p.startsWith(`${base}/`)) {
        notFound(res);
        return;
      }
      p = p.slice(base.length);
    }
    let file = path.join(root, p);
    // 경로를 실제 위치(심볼릭 링크를 따라간 뒤)로 바꿔, 실제 dist 폴더 밖이면 거절한다(형제 폴더·링크로 빠져나가기 방지).
    const realRoot = fs.realpathSync(root);
    let real;
    try {
      real = fs.realpathSync(file);
    } catch {
      real = path.resolve(realRoot, path.relative(root, file)); // 없는 파일: 아래에서 404
    }
    const inside = path.relative(realRoot, real);
    if (inside.startsWith('..') || path.isAbsolute(inside)) {
      res.writeHead(403).end();
      return;
    }
    file = real;
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) {
      file = path.join(file, 'index.html');
      const r2 = fs.existsSync(file) ? path.relative(realRoot, fs.realpathSync(file)) : '';
      if (r2.startsWith('..') || path.isAbsolute(r2)) {
        res.writeHead(403).end();
        return;
      }
    }
    if (!fs.existsSync(file)) {
      notFound(res);
      return;
    }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(fs.readFileSync(file));
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

export function isLoopbackUrl(url) {
  try {
    const u = new URL(url);
    if (u.protocol === 'data:' || u.protocol === 'blob:' || u.protocol === 'about:') return true;
    return LOOPBACK.has(u.hostname);
  } catch {
    return false; // 해석 못 하는 주소는 루프백이 아닌 것으로 본다(막는다)
  }
}

/**
 * 루프백 밖으로 나가려는 시도를 모두 막고 기록하는 브라우저 문맥.
 *
 * 기록하는 통로(각각 tests/offline-selftest.mjs 가 심어 둔 결함으로 잡히는지 확인한다):
 *  - HTTP(S) 요청 전부: 문서·스크립트·스타일·이미지·iframe·글꼴, fetch, XMLHttpRequest, EventSource, navigator.sendBeacon,
 *    전용 워커(Worker)의 스크립트와 그 워커 안의 fetch — 문맥(context) 단위 route 로 막고 기록한다.
 *  - WebSocket — context.routeWebSocket 으로 막고 기록하며, 페이지의 'websocket' 이벤트로도 기록한다.
 *  - 서비스 워커 — 문맥에서 차단(serviceWorkers: 'block')하고, navigator.serviceWorker.register 호출 자체를 기록한다.
 *  - navigator.sendBeacon — 함수를 감싸 루프백 밖이면 보내지 않고 기록한다. 페이지를 떠날 때(pagehide) 보내는 비컨은
 *    route·request 이벤트를 거치지 않고 실제로 나가므로 감싸기가 유일한 방어다. auditPage() 가 pagehide·visibilitychange 를
 *    일으켜 그런 코드를 드러낸다.
 *  - WebRTC — RTCPeerConnection 생성을 기록한다(ICE 서버 주소가 루프백 밖이면 그 주소, 아니면 생성 사실).
 *  - 페이지 이동(window.open, location 변경, form 제출, meta refresh 로 실제로 이동하는 경우) — 문서 요청이므로 route 가 막는다.
 *  - 문서 훑기(auditPage): <link rel=preconnect|dns-prefetch|prefetch|preload|modulepreload|prerender>, <meta http-equiv=refresh>,
 *    srcset 의 모든 후보, <object data>, <embed src>, <video poster>, 미디어 src — 이 환경에서 브라우저가 불러오지 않아
 *    요청으로 드러나지 않는 참조.
 * 다루지 않는 것: 브라우저 자체의 배경 통신(헤드리스 Chromium 기본 설정), 확장 프로그램, 사용자 조작으로만 일어나는 동작
 *  (누르기 전에는 요청이 없다 — 탐색 링크 <a href> 는 원고의 외부 링크로 허용). 이런 것과 스크립트 안의 주소 조립은
 *  정적 검사(tools/sitecheck static)가 뒷받침한다: site/src 는 외부 주소·네트워크 API 사용 자체를, 산출물은 리소스 속성·
 *  CSS 참조·스크립트의 네트워크 API·window.open/location 이동의 외부 주소를 본다.
 * @returns {{browser, context, blocked: string[], auditPage: (page) => Promise<void>}}
 */
export async function offlineBrowser({ colorScheme = 'light', viewport = { width: 1280, height: 900 }, reducedMotion = 'no-preference', blockStorage = false } = {}) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ colorScheme, viewport, reducedMotion, serviceWorkers: 'block', acceptDownloads: true });
  const blocked = [];
  const record = (kind, url) => {
    const item = `${kind} ${url}`;
    if (!blocked.includes(item)) blocked.push(item);
  };
  await context.route('**/*', (route) => {
    const req = route.request();
    if (isLoopbackUrl(req.url())) return route.continue();
    record(`http(${req.resourceType()})`, req.url());
    return route.abort('blockedbyclient');
  });
  await context.routeWebSocket(/.*/, (ws) => {
    if (isLoopbackUrl(ws.url().replace(/^ws/, 'http'))) return ws.connectToServer();
    record('websocket', ws.url());
    return ws.close();
  });
  const watchPage = (page) => {
    page.on('websocket', (ws) => {
      if (!isLoopbackUrl(ws.url().replace(/^ws/, 'http'))) record('websocket', ws.url());
    });
    page.on('worker', (w) => {
      if (!isLoopbackUrl(w.url())) record('worker', w.url());
    });
  };
  context.on('page', watchPage);
  // route 를 거치지 않고 나간 요청이 있으면(있어서는 안 된다) 기록한다.
  context.on('request', (req) => {
    if (!isLoopbackUrl(req.url())) record(`request(${req.resourceType()})`, req.url());
  });
  // 페이지 안 감싸기가 알려 주는 시도. 루프백 주소는 기록하지 않는다(서비스 워커 등록·WebRTC 생성은 주소와 상관없이 기록).
  await context.exposeBinding('__guideNetRecord', (_src, kind, url) => {
    if (kind === 'service-worker-register' || kind === 'webrtc' || !isLoopbackUrl(url)) record(kind, url);
  });
  await context.addInitScript(() => {
    const rec = (kind, url) => {
      try {
        window.__guideNetRecord(kind, String(url));
      } catch {
        /* 기록 함수가 아직 없으면 무시 */
      }
    };
    const abs = (u) => {
      try {
        return new URL(String(u), location.href).href;
      } catch {
        return String(u);
      }
    };
    // sendBeacon: 페이지를 떠날 때(pagehide) 보내는 비컨은 Playwright 의 route·request 이벤트를 거치지 않고 실제로 나간다.
    // 그래서 함수 자체를 감싸 루프백 밖이면 보내지 않고(false) 기록한다.
    if (navigator.sendBeacon) {
      const origBeacon = navigator.sendBeacon.bind(navigator);
      navigator.sendBeacon = (url, data) => {
        const u = abs(url);
        if (/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:|\/|$)/.test(u)) return origBeacon(url, data);
        rec('beacon', u);
        return false;
      };
    }
    if (navigator.serviceWorker) {
      const orig = navigator.serviceWorker.register.bind(navigator.serviceWorker);
      navigator.serviceWorker.register = (url, opts) => {
        rec('service-worker-register', abs(url));
        return orig(url, opts);
      };
    }
    if (window.RTCPeerConnection) {
      const Orig = window.RTCPeerConnection;
      window.RTCPeerConnection = function (cfg, ...rest) {
        const urls = (cfg?.iceServers || []).flatMap((s) => [].concat(s.urls || s.url || []));
        const ext = urls.filter((u) => !/^(stun|turns?):(127\.0\.0\.1|localhost)/.test(u));
        rec('webrtc', ext.length ? ext.join(' ') : '(RTCPeerConnection 생성)');
        return new Orig(cfg, ...rest);
      };
      window.RTCPeerConnection.prototype = Orig.prototype;
    }
  });
  if (blockStorage) {
    await context.addInitScript(() => {
      const deny = () => {
        throw new DOMException('blocked for test', 'SecurityError');
      };
      Object.defineProperty(window, 'localStorage', { get: deny, configurable: true });
      Object.defineProperty(window, 'sessionStorage', { get: deny, configurable: true });
    });
  }
  /**
   * 페이지를 연 뒤 부른다. ① 떠날 때 이벤트(pagehide·visibilitychange)를 일으켜 그때 나가는 시도를 드러내고,
   * ② 브라우저가 이 환경에서 불러오지 않는 참조를 문서에서 훑는다: 연결 예고 link, meta refresh,
   *    srcset 의 모든 후보(화면 배율 1에서는 2x 후보를 불러오지 않는다), <object data>·<embed src>(헤드리스는 불러오지 않는다),
   *    <video poster>·미디어 src.
   */
  const auditPage = async (page) => {
    await page
      .evaluate(() => {
        window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false }));
        Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
        document.dispatchEvent(new Event('visibilitychange'));
      })
      .catch(() => {});
    await page.waitForTimeout(50);
    const found = await page.evaluate(() => {
      const out = [];
      const absu = (u) => {
        try {
          return new URL(u, location.href).href;
        } catch {
          return u;
        }
      };
      for (const el of document.querySelectorAll('[srcset]')) {
        for (const cand of el.getAttribute('srcset').split(',')) {
          const u = cand.trim().split(/\s+/)[0];
          if (u) out.push([`srcset(${el.tagName.toLowerCase()})`, absu(u)]);
        }
      }
      for (const [sel, attr] of [['object[data]', 'data'], ['embed[src]', 'src'], ['video[poster]', 'poster'], ['video[src],audio[src],source[src],track[src]', 'src']]) {
        for (const el of document.querySelectorAll(sel)) out.push([`${el.tagName.toLowerCase()}[${attr}]`, absu(el.getAttribute(attr))]);
      }
      for (const l of document.querySelectorAll('link[rel][href]')) {
        const rel = l.rel.toLowerCase();
        if (/\b(preconnect|dns-prefetch|prefetch|preload|modulepreload|prerender)\b/.test(rel)) out.push([`link(${rel})`, l.href]);
      }
      for (const m of document.querySelectorAll('meta[http-equiv]')) {
        if (m.httpEquiv.toLowerCase() === 'refresh') {
          const u = /url=(.*)$/i.exec(m.content || '');
          if (u) out.push(['meta-refresh', new URL(u[1].trim().replace(/^['"]|['"]$/g, ''), location.href).href]);
        }
      }
      return out;
    });
    for (const [kind, url] of found) if (!isLoopbackUrl(url)) record(kind, url);
  };
  return { browser, context, blocked, auditPage };
}

/** 사이트맵 대신 dist 를 훑어 페이지 목록을 만든다. */
export function listPages(root = DIST) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (e.name === '_astro' || e.name === 'pagefind') continue;
        walk(p);
      } else if (e.name === 'index.html') out.push(`/${path.relative(root, d).split(path.sep).join('/')}${d === root ? '' : '/'}`);
    }
  };
  walk(root);
  return out.map((p) => p.replace(/^\/\/$/, '/')).sort();
}

/**
 * 검사 대상 페이지를 명령줄에서 고른다(sitecheck.py --pages 와 같은 값).
 *   --pages pilot(기본) | all | /a/,/b/   (예전 --all 은 --pages all 과 같다)
 * all 은 dist 의 모든 페이지다. withFiles=false 면 소스 보기(/files/…)를 뺀다.
 */
export function pagesFromArgs({ withFiles = true, def = 'pilot' } = {}) {
  const i = process.argv.indexOf('--pages');
  let v = i >= 0 ? process.argv[i + 1] : process.argv.includes('--all') ? 'all' : def;
  let pages;
  if (v === 'pilot') pages = PILOT_PAGES;
  else if (v === 'all') pages = listPages();
  else pages = v.split(',').map((p) => p.trim()).filter(Boolean).map((p) => (p.endsWith('/') ? p : `${p}/`));
  if (!withFiles) pages = pages.filter((p) => !p.startsWith('/files/'));
  return pages;
}

/**
 * 페이지 목록을 탭 여러 개(기본 6, GUIDE_TABS)로 나눠 연다. 전 페이지(--pages all, 약 350쪽) 검사 시간을 줄이려는 것이다.
 * 탭마다 페이지 하나를 재사용하고, fn(page, item) 은 차례로 불린다(같은 탭 안에서는 순서대로).
 */
export async function eachPage(context, items, fn, n = Number(process.env.GUIDE_TABS || 6)) {
  const queue = [...items];
  await Promise.all(
    Array.from({ length: Math.max(1, Math.min(n, queue.length)) }, async () => {
      const page = await context.newPage();
      try {
        while (queue.length) await fn(page, queue.shift());
      } finally {
        await page.close();
      }
    }),
  );
}

/** 고정 상호작용 단계가 쓰는 페이지(대상에 있을 때만 그 단계를 돈다). */
export const EXAM_PAGE = '/curriculum/m14-capstone-exam/mock-exam/questions/';
export const isQuizPage = (p) => /^\/curriculum\/m\d\d-[^/]+\/quiz\/$/.test(p);

/** 시범(P1) 확인 대상 페이지. */
export const PILOT_PAGES = [
  '/',
  '/curriculum/m06-integration-messaging/',
  '/curriculum/m06-integration-messaging/01-why-decoupling/',
  '/curriculum/m06-integration-messaging/02-sqs/',
  '/curriculum/m06-integration-messaging/03-sns-fanout/',
  '/curriculum/m06-integration-messaging/04-eventbridge/',
  '/curriculum/m06-integration-messaging/05-step-functions/',
  '/curriculum/m06-integration-messaging/06-streaming/',
  '/curriculum/m06-integration-messaging/cheatsheet/',
  '/curriculum/m06-integration-messaging/quiz/',
  '/curriculum/m00-orientation/03-environment-setup/',
  '/curriculum/m03-compute-scaling/06-auto-scaling/',
  '/curriculum/m14-capstone-exam/mock-exam/questions/',
  '/curriculum/m14-capstone-exam/mock-exam/answer-key/',
];

/** 이 검사 스크립트가 연 루프백 서버의 주소. 위젯 keyboard.check.mjs 는 이것을 쓴다(static 관문은 루프백 주소도 허용한다). */
// 산출물이 하위 경로(BASE)로 빌드됐으면 그 경로까지 붙는다 — 검사는 `${baseUrl(port)}${사이트 경로}` 로 연다.
export const baseUrl = (port) => `http://127.0.0.1:${port}${BASE}`;

/**
 * 위젯 하나의 좁은 화면 가로 넘침 검사 — 위젯 keyboard.check.mjs 가 --shots 없이도 늘 부른다(GUIDE-SITE 원칙 6: 360px에서 가로 스크롤 없음).
 * 라이트·다크 × widths 로 위젯이 놓인 페이지를 열고, 처음 상태와 위젯의 미리 채우기 단추(button[data-preset])를 하나씩 누른 상태마다
 * ① 문서 전체의 가로 넘침 ② 위젯 안에서 화면 오른쪽 밖으로 나간 요소(자체 가로 스크롤 상자 안은 제외)를 본다.
 * 조작은 마우스 누르기다(키보드 조작은 각 검사의 본문이 따로 본다).
 * @returns {Promise<string[]>} 문제 목록(없으면 빈 배열)
 */
export async function widgetOverflow({ port, path: pagePath, widget, widths = [360] }) {
  const problems = [];
  const root = `.guide-widget[data-widget="${widget}"]`;
  for (const colorScheme of ['light', 'dark']) {
    for (const width of widths) {
      const { browser, context, blocked } = await offlineBrowser({ colorScheme, viewport: { width, height: 800 }, reducedMotion: 'reduce' });
      try {
        const page = await context.newPage();
        await page.goto(`${baseUrl(port)}${pagePath}`, { waitUntil: 'networkidle' });
        await page.locator(root).scrollIntoViewIfNeeded();
        await page.waitForFunction((sel) => document.querySelector(`${sel} astro-island:not([ssr])`) !== null, root);
        const check = async (label) => {
          const r = await page.evaluate(
            ({ sel, w }) => {
              const doc = document.documentElement.scrollWidth - document.documentElement.clientWidth;
              const inScroller = (e, top) => {
                for (let a = e.parentElement; a && a !== top; a = a.parentElement) {
                  if (/(auto|scroll)/.test(getComputedStyle(a).overflowX)) return true;
                }
                return false;
              };
              const top = document.querySelector(sel);
              const out = [...top.querySelectorAll('*')]
                .filter((e) => e.getClientRects().length && e.getBoundingClientRect().right > w + 0.5 && !inScroller(e, top))
                .map((e) => `${e.tagName.toLowerCase()}${e.className && typeof e.className === 'string' ? '.' + e.className.trim().split(/\s+/)[0] : ''}`);
              return { doc, out: [...new Set(out)].slice(0, 5) };
            },
            { sel: root, w: width },
          );
          if (r.doc > 0) problems.push(`${colorScheme} ${width}px ${label}: 문서 가로 넘침 ${r.doc}px`);
          if (r.out.length) problems.push(`${colorScheme} ${width}px ${label}: 화면 밖으로 나간 요소 ${r.out.join(', ')}`);
        };
        await check('처음 상태');
        const presets = await page.$$eval(`${root} button[data-preset]:not([disabled])`, (bs) => bs.map((b) => b.dataset.preset));
        for (const id of presets) {
          await page.locator(`${root} button[data-preset="${id}"]`).first().click();
          await check(`미리 채우기 ${id}`);
        }
        if (blocked.length) problems.push(`${colorScheme} ${width}px: 외부 요청 ${blocked.join(', ')}`);
      } finally {
        await browser.close();
      }
    }
  }
  return problems;
}

/**
 * 위젯 상자만 찍는다. 찍기 전에 붙박이(fixed·sticky) 요소 — Starlight 머리글 등 — 를 숨겨 상자 위에 겹쳐 찍히지 않게 하고,
 * 찍은 뒤 되돌린다(요소 스크린샷은 상자를 화면 안으로 스크롤하므로 머리글이 상자 윗부분을 덮을 수 있다).
 */
export async function shootElement(page, selector, file) {
  const hidden = await page.evaluate((sel) => {
    const target = document.querySelector(sel);
    let n = 0;
    for (const el of document.querySelectorAll('body *')) {
      const pos = getComputedStyle(el).position;
      if ((pos === 'fixed' || pos === 'sticky') && !el.contains(target) && !target.contains(el)) {
        el.dataset.shotHidden = el.style.visibility;
        el.style.visibility = 'hidden';
        n++;
      }
    }
    return n;
  }, selector);
  try {
    await page.locator(selector).first().screenshot({ path: file });
  } finally {
    if (hidden)
      await page.evaluate(() => {
        for (const el of document.querySelectorAll('[data-shot-hidden]')) {
          el.style.visibility = el.dataset.shotHidden;
          delete el.dataset.shotHidden;
        }
      });
  }
}
