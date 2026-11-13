# M07. 서버리스와 컨테이너

> 시나리오: TodayOrder 7단계 — 이벤트성 기능을 빠르게 붙여야 한다. 서버 없이(Lambda·API Gateway·Cognito), 그리고 컨테이너로(ECR·ECS).
> 도메인: D2, D3 · 예상 시간: 약 6시간

> **시작 전에 `scripts/emulator-reset.sh`부터 실행하자.** 이 모듈은 Lambda를 많이 호출하는데, 에뮬레이터는 호출마다 메모리를 조금씩 쌓아 두고 풀지 않는다. 앞 모듈에서 쓴 메모리를 안고 시작하지 않도록 깨끗한 에뮬레이터에서 시작한다(아래 "에뮬레이터 제약").

## 목표

- Lambda의 실행 모델(콜드 스타트, 동시성, 15분, 버전·별칭)과 호출 유형(동기·비동기·이벤트 소스 매핑)별 재시도·권한을 설명할 수 있다.
- API Gateway REST·HTTP·WebSocket을 요구 사항에 맞게 고르고, Lambda 프록시 API를 만들어 HTTPS로 호출할 수 있다.
- Cognito 사용자 풀과 자격 증명 풀을 구분하고, JWT로 API를 보호할 수 있다.
- ECS 작업 정의·서비스, EC2 vs Fargate, 두 역할(실행 역할·작업 역할)을 구분할 수 있다.
- API Gateway + Lambda + DynamoDB, S3 이벤트 처리 같은 서버리스 패턴을 최소 권한으로 구성할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [Lambda 실행 모델 — 콜드 스타트, 동시성, 타임아웃, 계층, 버전·별칭](./01-lambda-execution-model.md) | 60분 | 🟢 |
| 2 | [Lambda 트리거와 호출 유형, 대상(destination)](./02-lambda-triggers-invocation.md) | 50분 | 🟢 (비동기 대상 전달 🟡) |
| 3 | [API Gateway — REST vs HTTP vs WebSocket, 스테이지, 스로틀링, 캐싱, 권한 부여자](./03-api-gateway.md) | 55분 | 🟢 |
| 4 | [Cognito — 사용자 풀 vs 자격 증명 풀](./04-cognito.md) | 45분 | 🟢 |
| 5 | [컨테이너 — ECR, ECS, EC2 vs Fargate, EKS, App Runner, 하이브리드](./05-containers.md) | 55분 | 🟡 |
| 6 | [서버리스 아키텍처 패턴, 프런트엔드·모바일 한눈에](./06-serverless-patterns.md) | 60분 | 🟢 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| Lambda 생성·구성·버전·별칭(가중치)과 Invoke(동기/비동기/DryRun, 함수 오류, 타임아웃), 예약 동시성, logs 권한과 로그 그룹 | [labs/lab01-lambda-basics.sh](./labs/lab01-lambda-basics.sh) | 1 | 🟢 |
| 이벤트 소스 매핑(SQS→Lambda) 실제 소비, 가시성 타임아웃 규칙, 부분 배치 실패 + DLQ / 비동기 실패 대상(구성만) | [labs/lab02-lambda-sqs-esm.sh](./labs/lab02-lambda-sqs-esm.sh) | 2 | 🟢 (대상 전달 🟡) |
| API Gateway REST(MOCK, Lambda 프록시)·HTTP API→Lambda 프록시를 `https://127.0.0.1:$EMULATOR_PORT/_aws/execute-api/...`로 호출, `add-permission` | [labs/lab03-apigw-rest-http.sh](./labs/lab03-apigw-rest-http.sh) | 3 | 🟢 |
| 서버리스 주문 API (HTTP API + Lambda + DynamoDB, 실행 역할 최소 권한) | [labs/lab04-serverless-order-api.sh](./labs/lab04-serverless-order-api.sh) | 6 | 🟢 |
| S3 이벤트 → Lambda → DynamoDB (영수증 처리) | [labs/lab05-s3-event-lambda.sh](./labs/lab05-s3-event-lambda.sh) | 6 | 🟢 |
| ECR 저장소·ECS 클러스터·작업 정의·서비스 (태스크는 이미지 풀 실패로 STOPPED) | [labs/lab06-ecr-ecs.sh](./labs/lab06-ecr-ecs.sh) | 5 | 🟡 |
| Cognito 사용자 풀 가입·로그인 → JWT → HTTP API JWT 권한 부여자, 자격 증명 풀 임시 자격 증명 | [labs/lab07-cognito-jwt.sh](./labs/lab07-cognito-jwt.sh) | 4 | 🟢 |
| boto3: Lambda 배포와 호출 유형, 함수 오류 처리 | [sdk/lambda_invoke.py](./sdk/lambda_invoke.py) | 1 | 🟢 |
| boto3: Cognito 가입·로그인·토큰 클레임·갱신 | [sdk/cognito_login.py](./sdk/cognito_login.py) | 4 | 🟢 |

에뮬레이터에 배포되어 **에뮬레이터 안에서 실행되는** Lambda 함수 코드는 [functions/](./functions/)에 있다(`order_status.py`, `settlement_consumer.py`, `api_echo.py`, `order_api.py`, `receipt_processor.py`, `whoami.py`). sdk 예제가 아니므로 `emulator_guard`를 import하지 않는다.

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m07-serverless-containers/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치를 확인하고, 모든 lab을 **두 번씩**(멱등성 확인) 실행하고 sdk 예제를 실행한다. 마지막 줄이 `MODULE m07 OK`면 통과. lab들은 `curl`, `docker`(lab03이 에뮬레이터 로그를 읽는다), `uv`(JSON·zip 처리)를 쓴다 — 모두 M00 설치에 포함돼 있다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

저자가 포트 9306(에뮬레이터 1.0.322)에서 직접 확인한 내용이다.

| 오퍼레이션 / 동작 | 증상 | 실습에서의 처리 |
|---|---|---|
| **Lambda 함수 실행 환경** | CPython이 아니라 **RustPython**(`3.14.0.alpha … [RustPython 0.6.0]`). `boto3`는 에뮬레이터가 `/var/task/boto3`에 넣은 **대체 모듈**(`client`·`resource`·`Session`만). 네트워크는 에뮬레이터 서비스(sqs, events, dynamodb, logs, cloudwatch, apigateway, secretsmanager, opensearch, stepfunctions, sesv2, s3, xray, rds-data, appconfig)로만. `socket.gethostname()`, `os.listdir()`, `os.getcwd()`는 `OSError`. 함수 안에서 `sts`·`lambda` 클라이언트는 `UnknownServiceError` | 함수는 표준 라이브러리 + boto3 클라이언트 API만 쓴다 |
| **Lambda 호출마다 에뮬레이터 메모리 누적(OOM)** | 동기 호출 한 번마다 에뮬레이터 메모리가 수 MiB씩(M00 측정: 약 7 MiB) 늘고 줄지 않는다. 계속 쌓이면 메모리 상한(기본 2 GiB, `scripts/emulator-up.sh`의 `EMULATOR_MEMORY`)에서 컨테이너가 `OOMKilled`(종료 코드 137)되고, 학습자에게는 `Could not connect to the endpoint URL`만 보인다 | lab01의 호출 수를 줄였다(별칭 호출 20 → 10, 중복 오류 호출 제거). 편집자 측정(에뮬레이터 1.0.322, 상한 2 GiB): reset 직후 lab01~07을 한 번씩 + sdk 2개 = 174 → 446 MiB(약 22%). 그 뒤 lab01만 반복하면 회당 약 +111 MiB(547 → 659 → 770 MiB)라, 한 바퀴 뒤에도 lab01을 열 번 남짓 더 돌릴 여유가 있다. `verify.sh`는 시작할 때 에뮬레이터를 재시작하므로 통과한다. 그래도 반복 실습 뒤 증상이 보이면 `scripts/emulator-reset.sh`(상태 초기화), 반복이 아주 많으면 `EMULATOR_MEMORY=3g scripts/emulator-reset.sh`. 메모리 확인: `docker stats --no-stream aws-emulator-$EMULATOR_PORT` |
| 함수 안 자격 증명 | 환경 변수에 `AWS_ACCESS_KEY_ID` 등이 없다. 대신 실행 역할의 세션으로 서명된 것처럼 동작하고 **IAM 정책이 평가된다**(DynamoDB `PutItem`·`GetItem` 거부/허용 확인. `ListTables`는 권한 없이 통과) | lab04가 거부 → 최소 권한 허용을 보여 준다 |
| 비동기 호출의 실패 대상·성공 대상·함수 DLQ | 구성은 저장되지만 90초 넘게 기다려도 **전달되지 않았다**. 비동기 실패는 3번 실행됐고 `MaximumRetryAttempts=0`도 무시됐다 | lab02는 구성만(🟡) |
| API Gateway → Lambda 권한 | **REST API(`AWS_PROXY`)는 Lambda 리소스 정책을 검사**해 없으면 500(컨테이너 로그에 이유). **HTTP API는 검사하지 않고** 호출한다 | 두 API 모두 `add-permission`을 넣는다(실제 AWS는 둘 다 필요) |
| SNS → Lambda / S3 → Lambda 권한 | SNS는 `add-permission` 없으면 조용히 미실행, S3는 알림 구성 저장 시 `InvalidArgument`로 검증 | lab05가 S3 검증을 보여 준다 |
| Cognito 토큰의 `iss` | `https://127.0.0.1:<포트>/<풀 ID>` (실제 AWS: `https://cognito-idp.us-east-1.amazonaws.com/<풀 ID>`). JWT 권한 부여자의 Issuer를 AWS 형식으로 넣으면 유효 토큰도 401 | lab07은 토큰의 `iss`를 읽어 Issuer로 쓴다 |
| ECS 태스크 | `PROVISIONING → PENDING → STOPPED`, `CannotPullContainerError`. 에뮬레이터가 이미지를 **실제로 내려받으려** 하며, ECR 주소를 주면 실제 AWS 호스트(`000000000000.dkr.ecr.us-east-1.amazonaws.com:443`)로 연결을 시도했다 | lab06은 해석되지 않는 `.invalid` 레지스트리를 써서 외부 연결을 만들지 않는다(🟡) |
| API Gateway 목록 | `get-resources`·`get-rest-apis`를 `--query … --output text`로 받으면 페이지마다 `None` 줄이 섞인다 | `--no-paginate` 또는 `--output json` 가공 |
| 시간 관련 | 실행 시간(`Duration`), 별칭 가중치 비율, 매핑 상태 전이 시간은 측정만 하고 단언하지 않는다 | 상한 있는 폴링 |

## 설계 대비 대체 사유

- CURRICULUM.md의 M07 실습 6개를 모두 구현했다. 대체한 실습은 없다.
- **"서버리스 주문 API — Lambda 안의 DynamoDB 호출(저자 확인)"**: 된다. 함수 안 boto3가 에뮬레이터의 DynamoDB를 실행 역할 권한으로 호출하고, 권한이 없으면 실제로 `AccessDeniedException`이 난다. 설계대로 🟢로 확정했다. 상세는 [레슨 6의 "실제 AWS에서는"](./06-serverless-patterns.md#실제-aws에서는).
- 보강: lab05(S3 이벤트 → Lambda, 레슨 6 "S3 이벤트 처리"의 실습), lab02의 부분 배치 실패·DLQ, lab03의 REST Lambda 프록시와 권한 실패, lab07의 JWT 권한 부여자·자격 증명 풀.
- lab06은 실제 ECR 주소 대신 `.invalid` 이미지 주소를 쓴다(위 제약 참고). 태스크가 STOPPED가 되는 결과는 설계와 같다.
- WebSocket API, Lambda 계층, 함수 URL, 프로비저닝된 동시성은 개념으로 다룬다(탐침에서 API 호출은 동작함을 확인했지만 시험이 묻는 것은 "선택"이라 실습에서 뺐다).
