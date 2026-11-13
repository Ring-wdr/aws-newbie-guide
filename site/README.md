# 가이드 사이트 (`site/`)

`curriculum/`의 Markdown 원고를 **빌드할 때** 읽어 정적 인터랙티브 사이트로 보여 준다. 설계는 [docs/GUIDE-SITE.md](../docs/GUIDE-SITE.md). 원고가 단일 원본이며, 이 폴더에는 원고의 사본이 없다.

## 열어 보기

```bash
scripts/guide-up.sh          # 필요하면 설치·빌드하고 http://127.0.0.1:4321/ 에서 연다 (대화형 기본 포트 4321)
scripts/guide-up.sh 4331     # 포트 지정 — 비대화형 실행(에이전트)에서는 반드시 지정
```

- `127.0.0.1`에만 열린다. 포트가 이미 쓰이면 다른 포트로 옮기지 않고 실패한다.
- 에뮬레이터와 무관하다. 페이지는 명령을 **복사**만 하고 실행하지 않는다.
- 처음 한 번 `pnpm install --frozen-lockfile`이 npm 레지스트리에 접속한다(빌드하는 쪽에만 필요). 빌드된 사이트는 외부 요청을 하나도 하지 않는다.
- 필요한 것: Node 24 이상, pnpm. Mermaid 그림은 빌드 때 Playwright의 Chromium으로 그린다 — `playwright` 1.64.1은 Chromium 1248을 쓴다(`~/Library/Caches/ms-playwright/chromium_headless_shell-1248`). 없으면 빌드가 브라우저를 찾지 못했다고 실패한다.

## 개발

```bash
cd site
pnpm install --frozen-lockfile
pnpm dev --port 4331          # 127.0.0.1 에만 연다. UI 저자는 자기 전용 포트(4331~)를 쓴다
pnpm build                    # 전체(약 350쪽, 30초 안팎). GUIDE_SCOPE=pilot 이면 시범 페이지만: pnpm build:pilot
pnpm report                   # 변환기 보고 모드: 원고 133개에 변환기를 돌려 해석 못 한 구조를 센다
```

원격 측정·업데이트 확인은 꺼져 있다(`ASTRO_TELEMETRY_DISABLED=1`, `ASTRO_DISABLE_UPDATE_CHECK=true` — `package.json` 스크립트와 `astro.config.mjs`).

## 구조

| 경로 | 내용 |
|---|---|
| `src/content.config.ts` | 저장소의 `README.md`·`docs/*.md`·`curriculum/**/*.md`를 제자리에서 읽는 로더. 제목은 원고 첫 줄 H1 |
| `src/plugins/` | 원고 요소 → 화면 요소 변환(remark). 메타 칩·등급 배지, 명령·출력 짝, Mermaid SVG, 퀴즈, 스스로 확인, 시험 모드, 체크리스트, 링크 재작성, 주석 표시 |
| `src/components/` | 본문 상자(위젯 자리 바꾸기), 시험 모드, 저장소가 막혀도 동작하는 테마 전환 |
| `src/scripts/` | 브라우저 쪽 동작(복사, 퀴즈 채점, 체크리스트, 시험 모드, `localStorage` 저장·JSON 내보내기/가져오기) |
| `src/lib/` | 경로↔페이지 대응, 링크 규칙, 모의고사 채점(`exam-core.mjs` — `grade.py`를 옮긴 것) |
| `src/i18n/ko.mjs` | UI 문자열 사전(한 파일) |
| `src/widgets/mNN/<이름>/` | 모듈별 맞춤 위젯(UI 저자) |
| `tests/` | 브라우저 검사(오프라인·접근성·키보드), 스크린샷, 위젯 찾기 시험 |
| `scripts/` | 변환기 보고, 모의고사 채점(검사용), 로컬 서버 |

원고 요소와 화면의 대응은 GUIDE-SITE 4장 표 그대로다. 몇 가지 규칙:

- `bash` 블록 바로 뒤(주석 표시만 끼어 있을 수 있음)의 라벨 없는 블록이 "기록된 실제 출력"이 된다. 출력 블록이 없으면 명령만 보인다. 앞에 `bash`가 없는 라벨 없는 블록은 그대로 둔다.
- 다른 원고로 가는 링크는 페이지로, lab·sdk 등 그 밖의 파일은 `/files/<저장소 경로>/` 소스 보기로 간다.
- 소스 보기의 "실행 명령"은 근거가 있을 때만 보인다: ① 원고의 ```` ```bash ```` 블록이 그 파일을 실제로 부르는 줄(줄 끝 주석 제외), 없으면 ② 실행 진입점의 정해진 형태(셸은 실행 비트 또는 `labs/labNN-*.sh`·`labs/verify.sh` 이름 — `_`로 시작하면 도우미, Python은 `if __name__ == "__main__":`). 그 밖의 파일(`source` 해서 쓰는 도우미, import 해서 쓰는 모듈)은 명령 없이 그렇다고만 적는다. `run-commands` 관문이 같은 규칙으로 산출물을 검사한다.
- GFM의 물결표 하나짜리 취소선은 끈다. 원고는 `D1~D4`, `2~3시간`처럼 물결표를 범위로 쓴다(13곳).

## 위젯 계약 (UI 저자)

1. 위젯은 `site/src/widgets/mNN/<이름>/index.astro` 하나가 진입점이다. 등록 파일은 없다 — 빌드가 디렉터리를 찾는다. `<이름>`은 소문자·숫자·하이픈.
2. 그 모듈 원고에 표시 줄을 넣는다: 빈 줄로 둘러싼 독립된 줄 `<!-- widget: <이름> -->`. `bash` 블록과 그 출력 블록 사이, 목록·인용 안에 넣으면 빌드가 실패한다(표 안에는 HTML 주석 줄을 둘 수 없다). 원고의 다른 부분은 고치지 않는다.
3. 표시가 가리키는 디렉터리가 없어도 빌드가 실패한다. `node tests/widget-fixture.mjs`가 세 경우(찾음·없음·명령과 출력 사이)를 시험한다.
4. 상호작용은 Preact로 만들고 `index.astro`에서 `client:visible`로 붙인다. 계산 로직은 화면과 분리한 순수 함수로 두고 같은 디렉터리에 단위 시험(`*.test.mjs`, `node --test`)을 둔다.
5. 수치는 원고(레슨·치트시트의 표)에서 빌드 때 읽거나, 그럴 수 없으면 출처 줄을 주석으로 단다. 실제 실행이 아닌 설명용 동작이면 화면에 "모형"이라고 적는다.
6. 저장은 `src/scripts/storage.ts`의 `load`/`save`(try/catch, 저장소가 막혀도 동작)를 쓰고, 키 앞에 `guide:`가 자동으로 붙는다. 진행 상태 내보내기/가져오기에 함께 담긴다.
7. 외부 리소스(글꼴·CDN·이미지)를 쓰지 않는다. `site/src` 안에 외부 주소가 있으면 검사가 실패한다.
8. 새 패키지가 필요하면 PR 본문에 요청한다(`package.json`·lockfile은 환경 구축 담당).

## 검사 (PR 관문, GUIDE-SITE 5장)

저장소 루트에서, 빌드한 뒤:

```bash
uv run python tools/sitecheck/sitecheck.py all --port 4331                    # 시범 페이지 전체 관문
uv run python tools/sitecheck/sitecheck.py parity --pages all                 # 내용 동등성(전 페이지)
uv run python tools/sitecheck/sitecheck.py parity --pages /curriculum/m06-integration-messaging/02-sqs/
uv run python tools/sitecheck/sitecheck.py a11y --port 4331                   # 하나만: parity·quiz·exam·links·static·offline·a11y·keyboard
node site/tests/screenshots.mjs --port 4331 --out <폴더> [--full]            # 라이트/다크 × 1280/360px
```

관문: `parity`(제목·코드 블록 바이트·표·메타 줄), `quiz`, `exam`(= grade.py), `links`, `run-commands`(소스 보기 실행 명령의 근거), `static`(외부 주소·네트워크 API, `site/src`와 산출물), `selftest`(정적·실행 명령 관문에 결함을 심어 잡는지), `offline`(먼저 `tests/offline-selftest.mjs`로 통로 19가지에 결함을 심어 잡는지 확인), `a11y`, `keyboard`, `diagrams`(Mermaid 라벨 잘림·서브그래프/노드 겹침).

오프라인 관문이 기록하는 통로: HTTP(S) 요청 전부(문서·스크립트·스타일·이미지·iframe, fetch, XMLHttpRequest, EventSource, sendBeacon, 전용 워커와 그 안의 요청), WebSocket(페이지와 워커), 서비스 워커 등록(차단하고 기록), WebRTC(`RTCPeerConnection` 생성), `<link rel=preconnect|dns-prefetch|prefetch|preload|modulepreload|prerender>`, `<meta http-equiv=refresh>`. 브라우저 자체의 배경 통신은 다루지 않는다.

브라우저 검사(`offline`·`a11y`·`keyboard`·`diagrams`)는 `site/tests/`의 Node 스크립트이며, 이미 설치된 Playwright Chromium을 쓰고 아무것도 내려받지 않는다. 키보드 검사 스크립트는 `site/tests/keyboard.mjs`다.

## 알아 둘 성질

- **모의고사 정답은 페이지 소스에 들어 있다.** 시험 모드는 서버 없이 브라우저에서 채점하므로, 정답표(`#exam-data` JSON)와 65문항 해설(`<template>`)이 제출 전부터 HTML에 있다. 화면에는 제출 뒤에만 나온다. 혼자 공부하는 가이드라서 이렇게 두었다(소스를 열면 볼 수 있다는 점은 원고의 `answer-key.md`와 같다).
- 시험 타이머는 페이지가 열려 있는 동안만 줄어든다. 0이 되면 자동 제출한다.
- Mermaid 그림은 기본 배치에서 서브그래프·노드가 겹치면, 내용은 그대로 두고 간격을 넓힌 배치로 다시 그린다(`src/plugins/mermaid-render.mjs`).
