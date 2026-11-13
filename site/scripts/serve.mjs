// 빌드된 사이트(dist/)를 127.0.0.1 에서만 연다. 포트가 이미 쓰이면 다른 포트로 옮기지 않고 실패한다.
// scripts/guide-up.sh 가 부른다. 사용: node scripts/serve.mjs --port <포트>
import { DIST, portFromArgs, serve } from '../tests/lib/harness.mjs';

const port = portFromArgs(4321);
try {
  const server = await serve(port);
  console.log(`가이드 사이트: http://127.0.0.1:${port}/  (이 컴퓨터에서만 열린다. 멈추려면 Ctrl+C)`);
  console.log(`보여 주는 폴더: ${DIST}`);
  const stop = () => server.close(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
} catch (e) {
  if (e.code === 'EADDRINUSE') {
    console.error(`포트 ${port} 를 이미 다른 프로그램이 쓰고 있다. 다른 포트를 주거나(scripts/guide-up.sh <포트>) 그 프로그램을 멈춘다.`);
  } else {
    console.error(String(e.message || e));
  }
  process.exit(1);
}
