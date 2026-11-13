// 브라우저 검사 공용 도구: dist/ 를 127.0.0.1 에서만 여는 정적 서버 + 루프백 밖 요청을 모두 막고 기록하는 브라우저.
// Playwright 브라우저는 내려받지 않는다(이미 설치된 chromium 을 쓴다 — package.json 의 고정 버전과 짝).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

export const SITE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const DIST = path.resolve(process.env.GUIDE_DIST || path.join(SITE_DIR, 'dist'));

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

export function serve(port, root = DIST) {
  if (!fs.existsSync(path.join(root, 'index.html')) && !fs.existsSync(path.join(root, '404.html'))) {
    throw new Error(`빌드 산출물이 없다: ${root} — 먼저 pnpm --dir site build`);
  }
  const server = http.createServer((req, res) => {
    let p;
    try {
      p = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    let file = path.join(root, p);
    if (!file.startsWith(root)) {
      res.writeHead(403).end();
      return;
    }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) {
      const nf = path.join(root, '404.html');
      res.writeHead(404, { 'content-type': TYPES['.html'] });
      res.end(fs.existsSync(nf) ? fs.readFileSync(nf) : 'not found');
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

/**
 * 루프백 밖으로 가는 요청을 모두 막고 기록하는 브라우저 문맥.
 * @returns {{browser, context, blocked: string[]}}
 */
export async function offlineBrowser({ colorScheme = 'light', viewport = { width: 1280, height: 900 }, reducedMotion = 'no-preference', blockStorage = false } = {}) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ colorScheme, viewport, reducedMotion, serviceWorkers: 'block', acceptDownloads: true });
  const blocked = [];
  await context.route('**/*', (route) => {
    const url = route.request().url();
    let host = '';
    try {
      const u = new URL(url);
      if (u.protocol === 'data:' || u.protocol === 'blob:') return route.continue();
      host = u.hostname;
    } catch {
      /* 해석 못 하는 주소도 막는다 */
    }
    if (LOOPBACK.has(host)) return route.continue();
    if (!blocked.includes(url)) blocked.push(url);
    return route.abort('blockedbyclient');
  });
  // route 를 거치지 않는 요청(웹소켓 등)도 기록한다.
  context.on('request', (req) => {
    const u = req.url();
    try {
      const h = new URL(u).hostname;
      if (h && !LOOPBACK.has(h) && !blocked.includes(u)) blocked.push(u);
    } catch {
      /* 무시 */
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
  return { browser, context, blocked };
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
