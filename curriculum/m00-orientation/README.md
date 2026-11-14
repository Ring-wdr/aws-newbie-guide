# M00. 오리엔테이션과 실습 환경

> 시나리오: TodayOrder 입사 첫날. 서버 한 대짜리 주문 서비스를 AWS로 옮기기 전에, 내 노트북에 "AWS처럼 대답하는 서버"를 띄우고 도구 사용법을 익힌다.
> 예상 시간: 약 3시간 (설치 포함)

## 목표

- 에뮬레이터를 띄우고, CLI·boto3가 실제 AWS가 아니라 **에뮬레이터를 향하는지 확인**할 수 있다.
- 리전·가용 영역·엣지 로케이션·Local Zones·Wavelength와 공동 책임 모델을 설명할 수 있다.
- 에뮬레이터가 무엇을 재현하고 무엇을 재현하지 않는지 알고, 충실도 등급(🟢/🟡/🔴)을 읽을 수 있다.
- AWS CLI의 `--query`·`--output`·페이지네이션·`wait`, boto3의 client·paginator·waiter를 쓸 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [클라우드와 AWS 글로벌 인프라](./01-cloud-and-global-infrastructure.md) | 35분 | 🟢 |
| 2 | [aws-emulator란 무엇이고 무엇이 아닌가](./02-what-is-aws-emulator.md) | 30분 | 🟢 |
| 3 | [환경 설치](./03-environment-setup.md) | 40분 | 🟢 |
| 4 | [첫 요청 해부: sts get-caller-identity, SigV4, --debug](./04-first-request-anatomy.md) | 35분 | 🟢 |
| 5 | [AWS CLI 생존 기술과 boto3 기본기](./05-cli-and-boto3-survival.md) | 45분 | 🟢 |

**레슨 3부터 시작해도 된다.** 환경을 먼저 만들어 두면 레슨 1·2의 "직접 해 보기"도 바로 따라 할 수 있다.

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 에뮬레이터 기동·헬스 체크 | [labs/lab01-emulator-health.sh](./labs/lab01-emulator-health.sh) | 3 | 🟢 |
| S3 버킷 왕복 | [labs/lab02-s3-roundtrip.sh](./labs/lab02-s3-roundtrip.sh) | 3, 5 | 🟢 |
| 검증 오류 관찰 (DynamoDB 테이블명 2글자) | [labs/lab03-validation-error.sh](./labs/lab03-validation-error.sh) | 4 | 🟢 |
| CLI 생존 기술 (`--query`, `--output`, 페이지네이션, `wait`) | [labs/lab04-cli-survival.sh](./labs/lab04-cli-survival.sh) | 5 | 🟢 |
| 에뮬레이터가 AWS와 다른 곳 (501, IAM 부분 평가) | [labs/lab05-emulator-limits.sh](./labs/lab05-emulator-limits.sh) | 2 | 🟢 |
| 같은 작업을 boto3로 (S3 왕복) | [sdk/s3_roundtrip.py](./sdk/s3_roundtrip.py) | 5 | 🟢 |
| boto3 client·resource·paginator·waiter | [sdk/client_resource_paginator_waiter.py](./sdk/client_resource_paginator_waiter.py) | 5 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m00-orientation/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성 확인) sdk 예제를 실행한다. 마지막 줄이 `MODULE m00 OK`면 통과.

**포트 규칙**: `EMULATOR_PORT`가 있으면 그 포트를 쓴다. 없으면 터미널에서 직접 실행할 때(표준 입력이 터미널)만 9297을 쓴다. AI 에이전트·CI·`nohup` 같은 비대화형 실행에서는 `env.sh`, lab 스크립트, `verify.sh`, `emulator-reset.sh`, `emulator-down.sh`가 모두 "EMULATOR_PORT 가 설정되지 않았습니다"로 거부한다. 학습자는 그냥 `bash curriculum/m00-orientation/labs/lab01-emulator-health.sh`처럼 실행하면 된다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

<!-- widget: progress-tracker -->

## 이 모듈이 만든 공용 환경

| 경로 | 내용 |
|---|---|
| [`scripts/install.sh`](../../scripts/install.sh) | 필수 프로그램 확인·설치, Colima 시작, 이미지 빌드, `uv sync` |
| [`scripts/emulator-up.sh`](../../scripts/emulator-up.sh) `[포트]` | 포트별 에뮬레이터 컨테이너(`aws-emulator-<포트>`) 시작 |
| [`scripts/emulator-down.sh`](../../scripts/emulator-down.sh) `[포트\|--all]` · [`emulator-reset.sh`](../../scripts/emulator-reset.sh) `[포트]` · [`emulator-status.sh`](../../scripts/emulator-status.sh) | 끄기 · 재시작(초기화) · 상태 |
| [`scripts/env.sh`](../../scripts/env.sh) | `source` 해서 쓰는 환경 설정 + 안전 장치(계정 `000000000000` 확인) |
| [`tools/probe/`](../../tools/probe/) · [`docs/FIDELITY.md`](../../docs/FIDELITY.md) | 충실도 탐침과 그 결과 보고서 |

## 에뮬레이터 제약

이 모듈의 실습은 모두 🟢이다. 다만 이 모듈에서 관찰한 다음 차이는 다른 모듈에도 영향을 준다(상세는 [FIDELITY.md](../../docs/FIDELITY.md)).

| 오퍼레이션 / 동작 | 증상 |
|---|---|
| `organizations:CreatePolicy` | `501 NotImplemented` (SCP 생성 불가) |
| IAM 정책 평가 | IAM·EC2·KMS는 사용자 정책을 평가한다. S3·SQS·DynamoDB는 객체·메시지·항목 요청은 평가하지만 버킷·큐·테이블의 생성·삭제·나열(계정 수준 요청)은 평가하지 않아, 정책 없는 사용자가 S3 버킷을 만들 수 있다. 전역 조건 키(`aws:SecureTransport` 등)도 서비스·키마다 다르게 평가된다. 상세는 [FIDELITY.md "M01 IAM과 계정 관리"](../../docs/FIDELITY.md#m01-iam과-계정-관리) |
| `DescribeAvailabilityZones`, `DescribeRegions` | 고정 목록(리전 17개, 리전당 AZ 3개). 실제 AWS의 숫자와 다르다 |
| Lambda 동기 `Invoke` | 호출마다 에뮬레이터 메모리가 약 7 MiB씩 늘고 줄지 않는다. 1 GiB 상한에서 약 120회, 기본 2 GiB에서 약 270회 뒤 OOM(137) — 레슨 3 문제 해결 |
| SDK가 호스트명을 직접 만드는 기능 (S3 MRAP ARN, Kinesis `--stream-id` 등) | 엔드포인트 설정(`AWS_ENDPOINT_URL`)을 무시하고 실제 AWS 호스트(`*.s3-global.amazonaws.com`, `*.control-kinesis.<리전>.amazonaws.com`)로 간다. `env.sh`는 MRAP를 꺼서 로컬에서 거부되게 하고, Kinesis `--stream-id`는 연결 시도는 하지만 TLS 단계에서 끊긴다(연결 상태: 에뮬레이터 인증서만 믿음, 끊긴 상태: 믿는 인증서 없음 — HTTP 요청은 전달되지 않음). 실습에서 쓰지 않는다 — 레슨 3 "거부하면 셸을 AWS에서 끊는다" |
| DynamoDB `CreateTable` | 생성 응답은 (CLI·boto3 모두) `CREATING`. 에뮬레이터는 1초 안에 `ACTIVE`가 되는 경우가 많아, 직후 `DescribeTable` 결과는 실행마다 다르다(경쟁 상태). waiter로 기다릴 것 |

## 설계 대비 대체 사유

- CURRICULUM.md의 M00 실습 4개(기동·헬스 체크, S3 왕복, boto3, 검증 오류)를 모두 그대로 구현했다.
- 추가: lab04(CLI 생존 기술, 레슨 5의 실습)와 lab05(에뮬레이터 한계 관찰, 레슨 2의 실습). 레슨 내용을 직접 실행해 보게 하려는 것으로, 대체가 아니라 보강이다.
