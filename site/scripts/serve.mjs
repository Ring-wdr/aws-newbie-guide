// 빌드된 사이트(dist/)를 127.0.0.1 에서만 연다(하위 경로로 빌드했으면 그 경로 아래에서 — tests/lib/harness.mjs 의 BASE). 포트가 이미 쓰이면 다른 포트로 옮기지 않고 실패한다.
// scripts/guide-up.sh 가 부른다. 사용: node scripts/serve.mjs --port <포트> [--check]
import { BASE, DIST, portBusy, portFromArgs, serve } from '../tests/lib/harness.mjs';

const port = portFromArgs(4321);
const busyMsg = `포트 ${port} 를 이미 다른 프로그램이 쓰고 있다(127.0.0.1·0.0.0.0·[::] 어느 쪽이든). 다른 포트를 주거나 그 프로그램을 멈춘다.`;
if (await portBusy(port)) {
  console.error(busyMsg);
  process.exit(1);
}
if (process.argv.includes('--check')) process.exit(0); // guide-up.sh 가 빌드 전에 포트만 확인할 때
try {
  const server = await serve(port);
  console.log(`가이드 사이트: http://127.0.0.1:${port}${BASE}/  (이 컴퓨터에서만 열린다. 멈추려면 Ctrl+C)`);
  console.log(`보여 주는 폴더: ${DIST}`);
  const stop = () => server.close(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
} catch (e) {
  if (e.code === 'EADDRINUSE') {
    console.error(busyMsg);
  } else {
    console.error(String(e.message || e));
  }
  process.exit(1);
}
