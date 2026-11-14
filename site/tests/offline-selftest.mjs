// 오프라인 관문 자체 시험: 통로마다 외부로 나가려는 결함을 하나씩 심은 페이지를 만들어,
// offlineBrowser(오프라인 관문과 같은 기록기)가 모두 잡고, 결함 없는 페이지는 0건인지 확인한다.
// 외부 주소는 예약 도메인(.invalid/.example)만 쓰며, 모든 요청은 브라우저 안에서 막혀 실제로 나가지 않는다.
// 사용: node tests/offline-selftest.mjs --port <포트>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { offlineBrowser, portFromArgs, serve } from './lib/harness.mjs';

const port = portFromArgs(4321);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'guide-offline-selftest-'));
// 주소를 실행 중에 조립해 정적 검사로는 보이지 않게 한다(브라우저 관문만으로 잡혀야 한다).
const EXT = `'ht' + 'tps://net-selftest.' + 'invalid'`;
const WSX = `'w' + 'ss://net-selftest.' + 'invalid/socket'`;
const page = (body, head = '') => `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>t</title>${head}</head><body>${body}</body></html>`;
const js = (code) => `<script>setTimeout(() => { try { ${code} } catch (e) {} }, 0);</script>`;

const CASES = {
  clean: page('<p>결함 없음</p><img src="/ok.svg" alt=""><script>fetch("/ok.svg")</script>'),
  fetch: page(js(`fetch(${EXT} + '/f')`)),
  xhr: page(js(`const x = new XMLHttpRequest(); x.open('GET', ${EXT} + '/x'); x.send();`)),
  eventsource: page(js(`new EventSource(${EXT} + '/es')`)),
  beacon: page(js(`navigator.sendBeacon(${EXT} + '/b', 'x')`)),
  websocket: page(js(`new WebSocket(${WSX})`)),
  'worker-fetch': page(js(`new Worker('/worker.js')`)),
  'worker-websocket': page(js(`new Worker('/worker-ws.js')`)),
  'service-worker': page(js(`navigator.serviceWorker && navigator.serviceWorker.register('/sw.js')`)),
  preconnect: page('', '<link rel="preconnect" href="https://net-selftest.invalid">'),
  'dns-prefetch': page('', '<link rel="dns-prefetch" href="//net-selftest.invalid">'),
  prefetch: page('', '<link rel="prefetch" href="https://net-selftest.invalid/next.html">'),
  img: page('<img alt="" src="https://net-selftest.invalid/i.png">'),
  'css-import': page('', '<style>@import url("https://net-selftest.invalid/s.css");</style>'),
  'css-url': page('<div style="background:url(https://net-selftest.invalid/bg.png);width:9px;height:9px"></div>'),
  iframe: page('<iframe title="t" src="https://net-selftest.invalid/frame"></iframe>'),
  'script-src': page('<script src="https://net-selftest.invalid/a.js"></script>'),
  'dynamic-import': page(js(`import(${EXT} + '/m.js')`)),
  webrtc: page(js(`new RTCPeerConnection({ iceServers: [{ urls: 'stun:net-selftest.invalid:3478' }] })`)),
  'meta-refresh': page('', '<meta http-equiv="refresh" content="30; url=https://net-selftest.invalid/">'),
  'beacon-pagehide': page(`<script>addEventListener('pagehide', () => navigator.sendBeacon(${EXT} + '/bye', 'x'));</script>`),
  'beacon-visibility': page(`<script>document.addEventListener('visibilitychange', () => navigator.sendBeacon(${EXT} + '/hidden', 'x'));</script>`),
  'srcset-2x': page('<img alt="" src="/ok.svg" srcset="/ok.svg 1x, https://net-selftest.invalid/i@2x.png 2x">'),
  'picture-source': page('<picture><source srcset="https://net-selftest.invalid/p.webp" type="image/webp"><img alt="" src="/ok.svg"></picture>'),
  'object-data': page('<object data="https://net-selftest.invalid/o.svg" type="image/svg+xml"></object>'),
  'embed-src': page('<embed src="https://net-selftest.invalid/e.svg" type="image/svg+xml">'),
  'video-poster': page('<video poster="https://net-selftest.invalid/poster.png"></video>'),
  'window-open': page(js(`window.open(${EXT} + '/popup')`)),
  'location-href': page(js(`location.href = ${EXT} + '/away'`)),
  'location-assign': page(js(`location.assign(${EXT} + '/away2')`)),
  'form-autosubmit': page('<form id="f" action="https://net-selftest.invalid/post" method="post"></form>' + js(`document.getElementById('f').submit()`)),
};
for (const [name, html] of Object.entries(CASES)) {
  fs.mkdirSync(path.join(root, name), { recursive: true });
  fs.writeFileSync(path.join(root, name, 'index.html'), html);
}
fs.writeFileSync(path.join(root, 'ok.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>');
fs.writeFileSync(path.join(root, 'worker.js'), `fetch('ht' + 'tps://net-selftest.' + 'invalid/from-worker').catch(() => {});`);
fs.writeFileSync(path.join(root, 'worker-ws.js'), `try { new WebSocket('w' + 'ss://net-selftest.' + 'invalid/from-worker'); } catch (e) {}`);
fs.writeFileSync(path.join(root, 'sw.js'), `self.addEventListener('install', () => {});`);
fs.writeFileSync(path.join(root, 'index.html'), page('<p>root</p>'));

const server = await serve(port, root);
const failures = [];
try {
  for (const name of Object.keys(CASES)) {
    const { browser, context, blocked, auditPage } = await offlineBrowser();
    const p = await context.newPage();
    await p.goto(`http://127.0.0.1:${port}/${name}/`, { waitUntil: 'load' });
    await p.waitForTimeout(800);
    await auditPage(p);
    await browser.close();
    const ok = name === 'clean' ? blocked.length === 0 : blocked.length > 0;
    console.log(`${ok ? 'ok  ' : 'MISS'} ${name.padEnd(16)} → ${blocked.length ? blocked.join(' | ') : '(기록 없음)'}`);
    if (!ok) failures.push(name);
  }
} finally {
  server.close();
  fs.rmSync(root, { recursive: true, force: true });
}
if (failures.length) {
  console.log(`FAIL offline-selftest: 잡지 못한 통로 ${failures.join(', ')}`);
  process.exit(1);
}
console.log(`PASS offline-selftest: 심은 결함 ${Object.keys(CASES).length - 1}가지를 모두 잡고, 결함 없는 페이지는 0건`);
