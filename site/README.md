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

## 공개 배포 (GitHub Pages)

공개 주소는 `https://ring-wdr.github.io/aws-newbie-guide/`(프로젝트 Pages — 하위 경로)이다. `.github/workflows/pages.yml`이 `main`에 푸시될 때(와 수동 실행) 빌드·검사·배포한다.

- **하위 경로 빌드**: `GUIDE_BASE=/aws-newbie-guide/ pnpm build`. 주지 않으면 지금처럼 루트(`/`)로 빌드한다(`guide-up.sh`·검사 기본값). 값은 `src/lib/base.mjs`가 받는다(경로 조각은 영문·숫자·`-_.`만). base를 붙이는 곳: 원고의 상대 링크를 바꾸는 변환기(`plugins/links.mjs` — 다른 원고·소스 보기 `/files/…`), Mermaid "원래 크기로 보기"(`plugins/code.mjs`, `/diagrams/…svg`), 소스 보기 페이지의 링크, 진행 추적·홈 요약·"이 레슨 완료"의 링크(`progress/catalog.mjs`), 모의고사 데이터. Starlight가 만드는 것(사이드바·이전/다음·검색 색인·자산·404 페이지)은 Astro `base`로 맞춰진다.
- **저장 키는 경로와 무관하다**: 퀴즈·체크리스트 키는 base를 뺀 사이트 경로(`quiz:/curriculum/…/quiz`)로 만든다(`scripts/base.ts`의 `siteRoute`). 로컬과 배포본의 키가 같아서, 한쪽에서 내보낸 진행 상태를 다른 쪽에서 가져오면 그대로 맞는다(저장소 자체는 출처마다 따로다). 시험 중 정답 링크 가리기도 같은 함수로 경로를 비교한다.
- **배포 주소(`site`)를 정하지 않는다**: Astro `site`를 정하면 Starlight가 sitemap·`<link rel=canonical>`·`og:url`에 절대 주소를 넣는다. 오프라인·무추적 원칙과 부딪히지는 않지만(같은 사이트 주소이고 불러오는 리소스가 아니다) 쓸 데가 없고, `static` 관문에 자기 주소 허용 목록을 더해야 한다. 그래서 만들지 않는다 — 빌드 로그의 `[@astrojs/sitemap] … requires the site … Skipping`은 그 결과다. 이 폴더(`site/src`)에는 배포 주소를 적지 않는다(`static` 관문은 `site/src`의 외부 주소를 실패로 본다).
- **하위 경로 산출물의 검사**: 검사기는 산출물이 어느 base로 빌드됐는지 산출물에서 읽는다(홈이 불러오는 `/…/_astro/` 자산 경로 — `tests/lib/harness.mjs`의 `detectBase`, `sitecheck.py`의 `detect_base`). 브라우저 검사의 로컬 서버는 그 base 아래에서만 산출물을 보여 주고(`/aws-newbie-guide/…`, 그 밖은 404 — 배포본과 같다), `links` 관문은 `/`로 시작하는 주소가 모두 base 아래인지 본다. `GUIDE_BASE`를 주고 검사하면 산출물의 base와 같은지 먼저 확인한다.

  ```bash
  GUIDE_BASE=/aws-newbie-guide/ pnpm --dir site build
  uv run python tools/sitecheck/sitecheck.py all --port 4331       # 같은 관문이 /aws-newbie-guide/ 아래에서 돈다
  GUIDE_BASE=/aws-newbie-guide/ scripts/guide-up.sh 4331            # http://127.0.0.1:4331/aws-newbie-guide/
  ```

- 배포본도 외부 요청이 0건이다(같은 `offline`·`static` 관문). GitHub Pages가 방문 기록(접속 로그)을 남기는 것은 이 사이트가 정할 수 없는 호스팅의 성질이다.

## 개발

```bash
cd site
pnpm install --frozen-lockfile
pnpm dev --port 4331          # 127.0.0.1 에만 연다. UI 저자는 자기 전용 포트(4331~)를 쓴다
pnpm build                    # 전체(약 350쪽, 30초 안팎). GUIDE_SCOPE=pilot 이면 시범 페이지만: pnpm build:pilot
pnpm report                   # 변환기 보고 모드: 원고 133개에 변환기를 돌려 해석 못 한 구조를 센다
pnpm test:widgets             # 단위 시험 전부: src/widgets/**/*.test.mjs, src/progress, src/lib (node --test 에 파일 glob 을 넘긴다)
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
| `src/progress/` | 진행 추적(전 모듈 공용 위젯 `progress-tracker`), 홈의 전체 진행 요약, 레슨 끝의 "이 레슨 완료" |
| `src/lib/shared-widgets.mjs` | 공용 위젯 이름 목록(모듈 폴더 없이 어느 모듈 원고에서나 부르는 위젯) |
| `tests/` | 브라우저 검사(오프라인·접근성·키보드), 스크린샷, 위젯 찾기 시험 |
| `scripts/` | 변환기 보고, 모의고사 채점(검사용), 로컬 서버 |

원고 요소와 화면의 대응은 GUIDE-SITE 4장 표 그대로다. 몇 가지 규칙:

- `bash` 블록 바로 뒤(주석 표시만 끼어 있을 수 있음)의 라벨 없는 블록이 "기록된 실제 출력"이 된다. 출력 블록이 없으면 명령만 보인다. 앞에 `bash`가 없는 라벨 없는 블록은 그대로 둔다.
- 다른 원고로 가는 링크는 페이지로, lab·sdk 등 그 밖의 파일은 `/files/<저장소 경로>/` 소스 보기로 간다.
- 소스 보기의 "실행 명령"은 근거가 있을 때만 보인다: ① 원고의 ```` ```bash ```` 블록이 그 파일을 실제로 부르는 줄(줄 끝 주석 제외), 없으면 ② 실행 진입점의 정해진 형태(셸은 실행 비트 또는 `labs/labNN-*.sh`·`labs/verify.sh` 이름 — `_`로 시작하면 도우미, Python은 `if __name__ == "__main__":`). 그 밖의 파일(`source` 해서 쓰는 도우미, import 해서 쓰는 모듈)은 명령 없이 그렇다고만 적는다. `run-commands` 관문이 같은 규칙으로 산출물을 검사한다.
- GFM의 물결표 하나짜리 취소선은 끈다. 원고는 `D1~D4`, `2~3시간`처럼 물결표를 범위로 쓴다(13곳).

## 진행 추적 (전 모듈 공용)

- 모듈 `README.md`의 표시 줄 `<!-- widget: progress-tracker -->` 하나로 켠다. 구현은 `src/progress/` 한 곳이며(공용 위젯 — `src/lib/shared-widgets.mjs`), 모듈 폴더(`src/widgets/mNN/`)에 같은 이름이 있으면 그쪽이 먼저다.
- 목록은 빌드 때 원고에서 읽는다(`src/progress/catalog.mjs`): README의 `## 레슨` 표(둘째 칸 링크), `## 실습` 표(둘째 칸 첫 링크 — 링크가 없는 "(레슨 문서 안)" 워크시트 행은 레슨 칸의 첫 번호가 가리키는 레슨 페이지), README의 `quiz.md` 링크. 퀴즈에 문항이 없으면(M14) 대신 README가 링크한 모의고사와 캡스톤 자기 점검표를 "모의고사·캡스톤"으로 둔다. 표시 줄이 있는데 목록을 읽지 못하면 빌드가 실패한다.
- 저장: `localStorage`의 `guide:progress:mNN`(`{ v: 1, done: { <id>: true } }`). id는 `lesson:<파일 이름>`, `lab:<상대 경로>`, `lab:in-lesson:<실습 이름>`, `quiz`, `exam:mock-exam`, `exam:capstone-self-check`. P1의 M06 값은 그대로 읽힌다.
- 같은 저장값을 홈의 "전체 진행"(첫 H2 앞)과, 표시 줄이 있는 모듈의 레슨 페이지 끝 "이 레슨 완료"가 함께 쓴다(원고에는 표시가 없다).
- 저장값이 바뀌면 같은 창 안에서도 알린다(`storage.ts`의 `onStorageChange`): 진행 상태를 **가져오면** 진행 추적·홈 요약·퀴즈·체크리스트·시험 모드가 새로 고치지 않고 바로 다시 읽는다. "완료 표시 모두 지우기"는 확인 상자(초점은 "취소")를 거친다.

## 위젯 계약 (UI 저자)

1. 위젯은 `site/src/widgets/mNN/<이름>/index.astro` 하나가 진입점이다. 등록 파일은 없다 — 빌드가 디렉터리를 찾는다. `<이름>`은 소문자·숫자·하이픈.
2. 그 모듈 원고에 표시 줄을 넣는다: 빈 줄로 둘러싼 독립된 줄 `<!-- widget: <이름> -->`. `bash` 블록과 그 출력 블록 사이, 목록·인용 안에 넣으면 빌드가 실패한다(표 안에는 HTML 주석 줄을 둘 수 없다). 원고의 다른 부분은 고치지 않는다.
3. 표시가 가리키는 디렉터리가 없어도 빌드가 실패한다. `node tests/widget-fixture.mjs`가 세 경우(찾음·없음·명령과 출력 사이)를 시험한다.
4. 상호작용은 Preact로 만들고 `index.astro`에서 `client:visible`로 붙인다. 계산 로직은 화면과 분리한 순수 함수로 두고 같은 디렉터리에 단위 시험(`*.test.mjs`)을 둔다. 하나만 돌릴 때는 `site/`에서 `node --test src/widgets/mNN/<이름>/*.test.mjs`(Node 24는 `node --test <폴더>/`를 파일로 보고 실패한다), 전부는 `pnpm test:widgets` — `sitecheck`의 `widgets` 관문이 같은 것을 돌린다.
5. 수치는 원고(레슨·치트시트의 표)에서 빌드 때 읽거나, 그럴 수 없으면 출처 줄을 주석으로 단다. 실제 실행이 아닌 설명용 동작이면 화면에 "모형"이라고 적는다.
6. 저장은 `src/scripts/storage.ts`의 `load`/`save`(try/catch, 저장소가 막혀도 동작)를 쓰고, 키 앞에 `guide:`가 자동으로 붙는다. 진행 상태 내보내기/가져오기에 함께 담긴다.
7. 외부 리소스(글꼴·CDN·이미지)를 쓰지 않는다. `site/src` 안에 외부 주소가 있으면 검사가 실패한다.
8. 새 패키지가 필요하면 PR 본문에 요청한다(`package.json`·lockfile은 환경 구축 담당).
9. 키보드 검사는 위젯 폴더에 `keyboard.check.mjs`로 둔다: 독립 실행(스스로 `tests/lib/harness.mjs`의 `serve`로 서버를 연다), `--port <포트>` 인자, 실패면 0이 아닌 종료 코드. `keyboard` 관문이 `src/widgets/**/keyboard.check.mjs`를 찾아, 그 위젯의 표시가 있는 페이지가 대상(`--pages`)일 때 자기 서버를 닫은 뒤 같은 포트로 하나씩 돌린다(`tests/lib/widget-checks.mjs`, 자체 시험 `tests/widget-checks-selftest.mjs`). 표시가 원고 어디에도 없는 위젯의 검사 파일은 관문 실패로 보고한다. `tests/keyboard.mjs`는 고치지 않아도 된다. 서버 주소는 `harness.mjs`의 `baseUrl(port)`를 쓰고, 360px 가로 넘침은 `widgetOverflow({ port, path, widget })`로 `--shots` 없이도 늘 단언한다(처음 상태와 `button[data-preset]`마다). 위젯 상자 스크린샷은 붙박이 머리글을 숨기고 찍는 `shootElement(page, selector, file)`을 쓴다. 맞춤 위젯이 붙기 전(`astro-island[ssr]`)에는 `guide-client.ts`가 위젯 안 입력을 받지 않으므로(Tab 이동만 된다), 검사는 붙은 뒤(`astro-island:not([ssr])`)에 조작한다. 붙기 전 상태를 `aria-busy`로 표시하지 않는다 — `client:visible` 위젯은 화면에 들어오지 않으면 끝까지 붙지 않아 busy가 남고, 화면 낭독기가 서버가 그린 내용까지 건너뛸 수 있다. `a11y` 관문의 `tests/widget-busy.mjs`가 위젯 페이지마다 끝까지 스크롤·Tab만 이동한 뒤 `aria-busy="true"` 남은 위젯이 0인지 본다(결함을 심은 자체 시험 포함).

## 검사 (PR 관문, GUIDE-SITE 5장)

저장소 루트에서, 빌드한 뒤:

```bash
uv run python tools/sitecheck/sitecheck.py all --port 4331                    # 전 페이지 전체 관문(기본 --pages all, 약 9분)
uv run python tools/sitecheck/sitecheck.py all --pages pilot --port 4331      # 시범 14쪽만(빠른 확인)
uv run python tools/sitecheck/sitecheck.py parity --pages all                 # 내용 동등성(전 페이지)
uv run python tools/sitecheck/sitecheck.py parity --pages /curriculum/m06-integration-messaging/02-sqs/
uv run python tools/sitecheck/sitecheck.py a11y --port 4331                   # 하나만: parity·grades·quiz·exam·links·static·offline·a11y·keyboard·diagrams·tables
uv run python tools/sitecheck/sitecheck.py tables --pages /curriculum/m01-iam-identity/ --port 4331
node site/tests/screenshots.mjs --port 4331 --out <폴더> [--full]            # 라이트/다크 × 1280/360px (맞춤 위젯은 폴더·표시 줄에서 자동으로 찾아 widget-mNN-<이름>으로 찍는다)
```

관문: `parity`(제목·코드 블록 바이트·표·메타 줄, 원고의 백슬래시 이스케이프는 CommonMark대로 풀어 비교), `grades`(본문·표 칸, 그리고 페이지 안 목차·사이드바의 등급 이모지 🟢🟡🔴에 글자 라벨이나 접근 가능한 이름이 있는지 — 색만으로 전달 금지. 빈 라벨(`data-label` 없음·빈 값), 빈 `aria-label`, 보이는 라벨 없이 화면 낭독기 이름만 있는 것도 실패), `quiz`, `exam`(= grade.py), `links`, `run-commands`(소스 보기 실행 명령의 근거), `static`(외부 주소·네트워크 API, `site/src`와 산출물. 위젯의 `*.check.mjs`·`*.test.mjs`에서는 루프백 주소 — 127.0.0.0/8·`localhost`·`[::1]` — 를 허용한다), `scanner`(`tools/probe/no_external_hosts.py`를 돌려 0건이 아니면 실패, 그리고 `site/tests`·`tools/sitecheck`에 심은 결함 주소가 `.invalid` 호스트나 루프백뿐인지), `selftest`(정적·실행 명령·등급 관문에 결함을 심어 잡는지), `widgets`(`pnpm test:widgets` — 위젯 단위 시험·진행 추적·`src/lib` 시험, 시험 파일 없는 위젯도 실패), `offline`(먼저 `tests/offline-selftest.mjs`로 통로 30가지에 결함을 심어 잡는지 확인), `a11y`(axe-core, 그리고 `tests/widget-busy.mjs` — 위젯 상자에 `aria-busy="true"`가 남지 않는지, 결함을 심은 자체 시험 먼저), `keyboard`, `diagrams`(Mermaid 라벨 잘림, 서브그래프·노드·간선 라벨 겹침, 노드 글자 명암비, 넓은 그림의 첫 화면에서 잘린 흐름의 시작. 원고 구조 때문에 배치로 못 고치는 것만 이유와 함께 `tests/diagrams-known.json`에 둔다 — 재현되지 않는 항목은 낡은 예외로 실패), `tables`(표 칸 내용이 칸 경계를 넘어 옆 칸과 겹치면 실패(1280·360px), 1280px에서 상자보다 넓은 표는 `tests/tables-known.json`의 목록과 같아야 하고, 넘치는 표에는 키보드 스크롤과 스크롤 표시가 있어야 한다). `diagrams`·`tables`·`offline`은 결함을 심은 페이지로 자체 시험을 먼저 한다.

**`--pages`와 브라우저 관문**: `--pages`(기본 `all`)는 브라우저 관문(`offline`·`a11y`·`keyboard`·`diagrams`·`tables`)에도 그대로 넘어간다. 상호작용 단계는 그 페이지가 대상에 있을 때만 돈다 — 퀴즈는 대상의 퀴즈 페이지마다(전 페이지면 문항이 있는 14개 모듈 전부) 키보드로 풀고, M06 위젯은 그 페이지가, 모의고사는 `mock-exam/questions/`가 대상일 때만 조작한다. 경로 목록만 주면 그 페이지들만 연다.

**기본 범위를 전 페이지로 둔 이유**: P2로 전 페이지가 만들어졌고, 시범 범위만 보는 `all`은 범위 밖 페이지의 문제를 놓쳤다(전 페이지로 처음 돌렸을 때 `docs/` 작업 목록 체크 상자의 이름 없음, 표 칸 겹침 215칸이 그렇게 드러났다). 측정(이 저장소, 빌드 뒤): `all`(전 페이지 약 350쪽 — 브라우저 관문은 소스 보기 포함 offline·a11y 354쪽 × 4가지 화면) 540초, 그중 offline·a11y가 대부분이다. 고치는 중 빨리 볼 때만 `--pages pilot`이나 경로 목록을 쓴다. 브라우저 탭 수는 `GUIDE_TABS`(기본 6)로 바꾼다.

결함을 심는 시험(새로 만드는 것 포함)의 주소는 모두 `.invalid` 호스트나 루프백이어야 한다. 그렇지 않으면 `scanner` 관문이 실패한다.

오프라인 관문이 기록하는 통로: HTTP(S) 요청 전부(문서·스크립트·스타일·이미지·iframe, fetch, XMLHttpRequest, EventSource, sendBeacon, 전용 워커와 그 안의 요청), WebSocket(페이지와 워커), 서비스 워커 등록(차단하고 기록), WebRTC(`RTCPeerConnection` 생성), `<link rel=preconnect|dns-prefetch|prefetch|preload|modulepreload|prerender>`, `<meta http-equiv=refresh>`, pagehide·visibilitychange 때의 sendBeacon, `<object data>`·`<embed>`·모든 `srcset` 후보·`<video poster>`, `window.open`·`location` 이동. 각 통로를 어느 층이 맡는지는 `tests/lib/harness.mjs` 머리 주석에 있고, 정적 검사(`static`)가 뒤를 받친다. 브라우저 자체의 배경 통신은 다루지 않는다.

브라우저 검사(`offline`·`a11y`·`keyboard`·`diagrams`)는 `site/tests/`의 Node 스크립트이며, 이미 설치된 Playwright Chromium을 쓰고 아무것도 내려받지 않는다. 키보드 검사 스크립트는 `site/tests/keyboard.mjs`다.

## 알아 둘 성질

- **모의고사 정답은 페이지 소스에 들어 있다.** 시험 모드는 서버 없이 브라우저에서 채점하므로, 정답표(`#exam-data` JSON)와 65문항 해설(`<template>`)이 제출 전부터 HTML에 있다. 화면에는 제출 뒤에만 나온다. 혼자 공부하는 가이드라서 이렇게 두었다(소스를 열면 볼 수 있다는 점은 원고의 `answer-key.md`와 같다).
- 시험 타이머는 페이지가 열려 있는 동안만 줄어든다. 0이 되면 자동 제출한다.
- **시험 중(시작 뒤 제출 전)에는 정답·해설 페이지로 가는 길을 가린다**(`src/scripts/exam-guard.ts`): 사이드바와 이전/다음 페이지의 정답·해설 링크는 숨고, 본문 등의 다른 링크는 누르면 "그래도 열기/열지 않기" 확인이 뜬다. 시험 상태는 저장값(`guide:exam:m14-mock-exam`)으로 판단하므로 다른 페이지에서도 같다. **주소를 직접 입력해 여는 것은 막지 않는다**(그 페이지 위에 시험 중이라는 알림만 둔다) — 정답이 페이지 소스에 있는 것과 같은 이유다. 사이트 검색 결과의 정답·해설 링크도 같은 확인을 거친다. 시작만 하고 떠난 시험이 정답 링크를 끝없이 가리지 않도록, 마지막 저장 시각 + 남은 시간(종료 예정 시각)에서 24시간이 더 지난 진행 상태는 가리지 않는다(`src/lib/exam-live.mjs`, 단위 시험 `exam-live.test.mjs`). 시험 페이지를 다시 열면 그대로 이어서 풀 수 있다.
- **지난 응시 기록**: 제출할 때마다(시간 종료 자동 제출 포함) 날짜·총점·판정·도메인별 점수·소요 시간을 `guide:exam:m14-mock-exam:history`에 최근 20회까지 쌓고, 시작 화면과 결과 화면에 표로 보인다. 점수는 화면 채점과 같은 `exam-core.gradeExam`(= `grade.py`) 결과를 그대로 담는다. 소요 시간은 타이머가 실제로 줄어든 시간(일시 정지 제외)이다. "응시 기록 지우기"는 확인을 거치고, 진행 상태 내보내기/가져오기에 함께 담긴다(`src/lib/exam-history.mjs`, 단위 시험 `exam-history.test.mjs`).
- Mermaid 그림은 기본 배치에서 서브그래프·노드가 겹치면, 내용은 그대로 두고 간격을 넓힌 배치로 다시 그린다(`src/plugins/mermaid-render.mjs`).
- 폭 2400px 이상·높이 600px 이상인 왼→오(LR·RL) 흐름도는 같은 원문을 위→아래(TB)로 한 벌 더 그려, 40rem 이하 화면에서는 그것을 대신 보인다(그 아래에 "다시 배치했다"는 안내, 원래 배치는 "원래 크기로 보기" 링크). 좁은 화면에서 80%로만 줄인 넓은 그림이 빈 곳만 보이는 띠가 되는 것을 막는다(지금은 M14 레슨 2의 전체 그림 하나). `diagrams` 관문은 이 배치도 같은 기준(라벨 잘림·겹침·명암비, 360px 첫 화면)으로 보고 순번을 `n1`처럼 적는다.
- 폭이 640px를 넘는 그림은 가로 스크롤 상자 안에서 흐름의 시작(들어오는 간선이 없는 노드 중 가장 위·왼쪽)이 보이게 열린다 — 왼쪽 끝에서 그 노드가 다 보이면 왼쪽 끝부터, 아니면 그 노드를 가운데에. 아래에 같은 사이트의 원래 크기 SVG(`/diagrams/<id>.svg`)를 새 탭으로 여는 링크가 붙는다.
- 원고가 `classDef`/`style`로 밝은 바탕(fill)만 주고 글자색(`color`)을 주지 않은 노드는 다크 테마로 그릴 때만 어두운 글자색을 더한다(원고는 그대로).
- 표: 한국어 낱말은 중간에서 끊지 않고(keep-all), 칸 안의 인라인 코드는 구분 기호 뒤·낱말 경계(`<wbr>`)에서, 공백 없는 16자 이상 영문 토큰(API 이름·JSON·주소)은 아무 데서나 끊는다. 그래도 상자보다 넓은 표는 위에 "가로로 스크롤" 안내와 가장자리 그림자·점선 테두리가 붙고, Tab으로 고른 뒤 ←/→로 스크롤한다.
- 본문·표 칸의 등급 이모지 🟢/🟡/🔴 옆에는 원고 README 등급 표의 라벨(재현/부분/개념)이 작은 배지로 붙는다(원고 글자는 그대로. 제목 안에서도 같다 — 라벨 칸은 글자 없는 빈 요소라 제목 글자·앵커가 바뀌지 않는다). 접근 가능한 이름은 이모지 자리에 직접 둔다(`<span role="img" aria-label="재현">🟢</span>`) — 스타일시트를 꺼도 등급이 남는다. 눈에 보이는 라벨 글자는 CSS 생성 콘텐츠(`::after { content: attr(data-label) }`, `user-select: none`, `aria-hidden="true"`)라서 화면에는 보이고 화면 낭독기에는 두 번 읽히지 않으며, 문단을 복사하면 원고 글자만 복사된다("🟢재현"처럼 섞이지 않는다). 메타 칩의 배지·범례, 진행 추적 항목 이름의 이모지도 같다. 페이지 안 목차(넓은 화면·좁은 화면)와 사이드바에 같은 제목이 실릴 때도 같은 구조를 붙인다 — Starlight 기본 컴포넌트를 감싼 `src/components/GradeMarks.astro`가 그려진 HTML의 글자 노드만 바꾸므로(`src/lib/grade-marks.mjs`) 목차 글자·앵커는 원고 제목 그대로다. 좁은 화면 목차의 "지금 읽는 곳" 표시는 `guide-client.ts`가 현재 링크의 내용을 옮겨 라벨을 유지한다. JavaScript가 꺼지면 위젯 상자마다 공용 틀(`MarkdownContent.astro`)의 `<noscript>` 안내 한 줄(문구는 `i18n/ko.mjs`의 `widget.noscript`)이 보인다.
- 로컬 서버(`scripts/serve.mjs`, 검사 스크립트)는 경로를 실제 경로(realpath)로 풀어 `dist` 안인지 확인한다. `dist` 안의 심볼릭 링크가 밖을 가리키면 403을 돌려준다.
