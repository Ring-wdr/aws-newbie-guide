# 에이전트 역할과 브랜치

커리큘럼은 역할이 나뉜 에이전트들이 만든다. **브랜치명이 곧 역할**이다. 모든 작업은 PR로 올라오고, 검증 에이전트가 `VERDICT: PASS`를 남긴 뒤에만 `main`에 병합된다.

## 역할 표

| 단계 | 역할 | 브랜치 | 담당 범위 | 에뮬레이터 포트 |
|---|---|---|---|---|
| 0 | 커리큘럼 설계자 (메인 세션) | `architect/curriculum-master-design`, 이후 개정은 `architect/<개정 내용>` (예: `architect/curriculum-fidelity-regrade`, `architect/curriculum-as-built-revision`) | `README.md`, `docs/CURRICULUM.md`, `docs/AUTHORING.md`, `docs/AGENTS.md` | – |
| 1 | 환경 구축 엔지니어 | `setup/emulator-runtime-and-tooling` | 필수 프로그램 설치, `scripts/`, `tools/probe/`, `src/emulator_guard/`, `pyproject.toml`, `docs/FIDELITY.md`, `curriculum/m00-orientation/` | 9297 |
| 2 | IAM·계정 모듈 저자 | `author/m01-iam-identity` | `curriculum/m01-iam-identity/` | 9301 |
| 2 | VPC 네트워킹 모듈 저자 | `author/m02-vpc-networking` | `curriculum/m02-vpc-networking/` | 9302 |
| 2 | 컴퓨트·확장 모듈 저자 | `author/m03-compute-scaling` | `curriculum/m03-compute-scaling/` | 9303 |
| 2 | 스토리지 모듈 저자 | `author/m04-storage` | `curriculum/m04-storage/` | 9304 |
| 2 | 데이터베이스 모듈 저자 | `author/m05-databases` | `curriculum/m05-databases/` | 9305 |
| 2 | 통합·서버리스·컨테이너 모듈 저자 | `author/m06-m07-integration-serverless` | `curriculum/m06-integration-messaging/`, `curriculum/m07-serverless-containers/` | 9306 |
| 2 | 엣지·보안 모듈 저자 | `author/m08-m09-edge-security` | `curriculum/m08-dns-edge/`, `curriculum/m09-security-encryption/` | 9308 |
| 2 | 운영·분석 모듈 저자 | `author/m10-m11-ops-analytics` | `curriculum/m10-monitoring-iac/`, `curriculum/m11-analytics/` | 9310 |
| 2 | 복원력·비용 모듈 저자 | `author/m12-m13-resilience-cost` | `curriculum/m12-resilience-dr-migration/`, `curriculum/m13-cost-optimization/` | 9312 (+9313: 두 번째 "리전") |
| 3 | 캡스톤·모의고사 저자 | `author/m14-capstone-mock-exam` | `curriculum/m14-capstone-exam/`, 루트 `README.md` 최종 목차 | 9314 |
| 4 | 교차 모듈 편집자 | `editor/cross-module-review-followups`, `editor/stale-fact-corrections`, `editor/final-consistency-cleanup`, `editor/verify-reverse-order-pass`, `editor/cli-wait-polling-all-modules`, `editor/clock-hook-and-readiness-settle` | `curriculum/` 모듈 간 불일치와 검증에서 미뤄 둔 제안, 실습 공용 도우미 `scripts/lab-wait.sh` | 9316 (+9317) |
| 수시 | 환경 구축 엔지니어 (후속) | `setup/guard-hardening-and-shared-tooling`, `setup/fidelity-report-corrections`, `setup/dns-isolation-default-and-host-scan`, `setup/environment-verification-followups`, `setup/guard-refusal-followups`, `setup/guard-disconnect-hardening`, `setup/vm-clock-stability-detection`, `setup/clock-check-interrupt-cleanup` | 가드·공용 스크립트 보강, 탐침과 `docs/FIDELITY.md` 정정 | 9297 (+9298) |
| 수시 | 모듈 저자 (후속) | `author/<모듈>-review-followup` (예: `author/m04-storage-review-followup`, `author/m05-verify-runtime-followup`) | 병합 뒤 발견된 자기 모듈의 결함 수정 | 원래 배정 포트 |
| 5 | 가이드 사이트 환경 구축 | `setup/guide-site-toolchain` (이후 `setup/guide-*`) | `site/` 공용부, `tools/sitecheck/`, `scripts/guide-up.sh` — [GUIDE-SITE.md](./GUIDE-SITE.md) | 에뮬레이터 9297, 개발 서버 4321 |
| 5 | UI 저자 | `ui/m06-pilot-integration-messaging`, 이후 `ui/<모듈 범위>-pages`(예: `ui/m00-m03-pages`, `ui/m14-capstone-mock-exam`), `ui/widgets-<모듈·주제>` | 브랜치명에 적힌 모듈 범위의 `site/src/widgets/mNN/`과 그 모듈 원고의 위젯 표시 줄 | 개발 서버 4331~ (에이전트마다 하나) |
| 각 PR | PR 검증자 | (브랜치 없음 — 해당 PR 브랜치를 체크아웃해 검증) | [AUTHORING.md 6장](./AUTHORING.md) 체크리스트, 사이트 PR은 [GUIDE-SITE.md 5장](./GUIDE-SITE.md)도 | 에뮬레이터 9320~, 개발 서버·브라우저 검사 4390~ |

## 진행 순서

```mermaid
flowchart LR
  A[0. 설계<br/>architect/*] --> B[1. 환경 구축<br/>setup/*]
  B --> C[2. 모듈 저자 9명<br/>author/m01 ~ m13<br/>병렬, 각자 worktree·포트]
  C --> D[3. 캡스톤·모의고사<br/>author/m14-*]
  A -. PR .-> V{{PR 검증자}}
  B -. PR .-> V
  C -. PR .-> V
  D -. PR .-> V
  V -- PASS --> M[(main)]
  V -- CHANGES_REQUESTED --> W[해당 PR 작성자가 수정 후 재검증]
  W -.-> V
```

## 병렬 작업 규칙

- 에뮬레이터는 계정·리전을 분리하지 않으므로, **에이전트마다 전용 포트의 에뮬레이터**를 띄운다 (`export EMULATOR_PORT=<port>` 후 `scripts/emulator-up.sh`, 깨끗한 상태가 필요하면 `scripts/emulator-reset.sh`). 다른 에이전트의 포트를 건드리지 않는다.
- 각 저자는 자신의 git worktree에서 작업하고, 자기 담당 디렉터리만 수정한다.
- 작업을 마치면 자기 포트의 에뮬레이터를 반드시 내린다 (`scripts/emulator-down.sh <port>`).
- 두 번째 에뮬레이터를 쓰는 에이전트는 `DR_EMULATOR_PORT`를 반드시 명시한다(역할 표에 `+포트`가 적힌 역할만 그 포트를 쓴다). 포트가 연속 번호라, 추측한 포트는 다른 에이전트의 에뮬레이터일 수 있다.
- `emulator-down.sh --all`, Colima 재시작, VM 시계 변경은 다른 에이전트의 작업을 깨뜨리므로 금지한다(스크립트는 `--all`에 경고만 한다 — 지키는 것은 에이전트의 몫이다). VM 시계는 손으로 바꿔도 Lima 게스트 에이전트와 timesyncd가 몇 초 안에 되돌리므로, 어긋남을 시험하려면 둘을 멈춰야 하고 그동안 다른 에이전트의 서명 요청이 모두 실패한다. 이런 시험은 다른 에뮬레이터가 하나도 없을 때만 한다.
- `emulator-up.sh`는 포트를 주지 않으면 비대화형에서도 9297을 쓴다. 에이전트는 항상 `EMULATOR_PORT`를 export하거나 포트를 인자로 넘긴다.
- 임시 파일은 에이전트마다 고유한 이름의 폴더에 둔다. 공용 임시 폴더에 흔한 파일명(`verify.log`, `out.txt`)으로 쓰면 서로 덮어쓴다.
- 기본 메모리 상한은 2g다. 동시에 많은 에뮬레이터를 띄울 때만 `EMULATOR_MEMORY`로 낮춘다.

## 운영하며 배운 것

- **검증자는 작성자와 다른 에이전트여야 한다.** 저자의 `verify.sh` 통과 보고만으로는 사실 오류, 순서 의존, 정답이 한 글자에 쏠린 퀴즈, 깨진 다이어그램을 걸러내지 못했다.
- **검증자도 틀린다.** 검증자의 제안이 낡은 수치였던 경우가 있었다. 사실 관계가 엇갈리면 1차 자료(AWS 문서·발표)를 인용해 판정한다.
- **"외부에 닿지 않는다"는 주장도 검증 대상이다.** 첫 탐침은 ECS 검사에 실제 공개 레지스트리 이미지를 써서, 실행할 때마다 에뮬레이터가 익명 이미지 풀을 시도했다. 여러 차례의 검증을 거친 뒤에야 발견됐다. 지금은 정적 검사(`tools/probe/no_external_hosts.py`)가 M00 `verify.sh`에서 `tools`·`scripts`·`src`와 `curriculum/` 전체(M00~M14)를 막고(탐침 시작 때는 `tools/probe`만 검사한다), 에뮬레이터 컨테이너는 기본으로 이름 해석이 막힌 채(`--dns 127.0.0.1`, 해제는 `EMULATOR_DNS=host`) 뜬다.
- **실제 AWS에 맞는 도구가 에뮬레이터에서는 느릴 수 있다.** AWS CLI의 `wait`는 RDS·DocumentDB를 30초, ElastiCache를 15초 간격으로 확인한다. 에뮬레이터는 1초 안에 상태를 바꾸지만, 생성 직후 첫 확인이 `creating`을 보면 한 간격을 통째로 기다린다. M05 `verify.sh`가 같은 조건에서 8분에서 13분까지 흔들린 원인이었고, M08은 12분 중 10분이 `wait`였다(교체 뒤 3분). 전체 회귀에서 한 번 나온 M05의 30분은 재현하지 못했다 — 수정 전 코드를 다시 돌린 실행은 525초였고 `wait` 68번 중 5번만 한 간격을 기다렸으므로, 같은 원인이라는 추정은 뒷받침되지 않은 채 남아 있다. 레슨의 명령은 `wait`를 그대로 가르치고, 실습 스크립트는 `scripts/lab-wait.sh`로 1초 간격 폴링한다. 이미 빠른 Lambda, ELB `load-balancer-available`, S3 `bucket-exists`(M00)는 CLI `wait`로 남겼다(DynamoDB `table-exists`는 아래 시계 문제 때문에 나중에 `lab-wait.sh`로 옮겼다. M00 lab03만 남아 있다).
- **엔드포인트 설정을 무시하는 SDK 기능이 있다.** S3 다중 리전 액세스 포인트 ARN, Kinesis `StreamId`, sign-in 제어 작업은 `AWS_ENDPOINT_URL`과 상관없이 AWS 호스트 이름을 직접 만든다. 요청이 이 컴퓨터 밖으로 나가지 않는다는 취지의 안내 문구는 검증자가 이 기능들로 반례를 보인 뒤에야 거짓으로 드러났다(이후 로컬 botocore 엔드포인트 규칙을 매개변수 하나씩 바꿔 가며 훑어 위 세 가지를 확인했다. 여러 매개변수의 조합은 보지 않았다). 지금은 첫째를 스위치로 끄고, 나머지는 TLS 검증으로 끊는다(연결된 셸은 에뮬레이터 CA만 신뢰하고, 분리된 셸은 인증서 묶음이 아예 없다). 안전 장치의 문구는 보장되는 것만 약속하게 쓴다.
- **가끔 나는 실패의 원인이 VM 시계였다.** 전체 회귀에서 M05·M06·M08이 가끔 실패했다. M05·M06의 실패는 이렇게 설명됐다: 맥 시계가 약 2초 틀어진 동안 Lima 게스트 에이전트(10초마다 맥 시각으로)와 VM 안의 `systemd-timesyncd`(NTP 시각으로)가 VM 시계를 서로 되돌렸고, 에뮬레이터는 DynamoDB 테이블과 Kinesis 스트림의 준비 여부를 벽시계로 정하므로 막 `ACTIVE`가 된 리소스가 잠깐 "준비 안 됨"으로 돌아갔다. 지금은 `scripts/clock-check.sh --stability`가 VM 저널에서 이 상태를 알아내고, 모듈 `verify.sh`가 실패할 때 함께 알리며, `lab-wait.sh`가 준비 직후 한 번 더 확인한다. 남은 것: 준비 재확인은 시계를 한 번 2초 되돌리는 시험과 추론으로 확인했을 뿐 10초마다 되풀이되는 실제 상황에서 돌려 보지는 못했고, M08 lab06의 실패는 이 원인으로 재현되지 않아 원인을 모르며, 맥이 틀린 NTP 표본을 받아들인 이유도 모른다. 재현하지 못한 실패에 원인을 붙여 적지 않는다.
- **에이전트에게 범위와 시간 한도를 준다.** 한도 없이 맡긴 검증과 수정은 멈추지 않고도 끝나지 않을 수 있다 — 요청 밖의 실험과 검사를 계속 늘린다. 지시에 확인할 항목, 시간 한도, "한도 안에 못 본 것은 미확인으로 적는다"를 넣는다. 검증자가 결함을 심어 볼 때 쓰는 가짜 주소는 `.invalid`나 루프백만 쓴다(예약되지 않은 이름은 실제로 나갈 수 있다).
- **병합 뒤에도 깨질 수 있다.** 부하가 달라지면 타이밍 경합이 드러난다. 공용 파일을 바꾸는 PR은 이미 병합된 모듈의 `verify.sh`를 회귀로 돌린다.
