# M07 치트시트 — 서버리스와 컨테이너

## 컴퓨트 고르기

| 요구 | 정답 |
|---|---|
| 짧은(≤ 15분) 이벤트 처리, 유휴 비용 0, 자동 확장 | **Lambda** |
| 15분 초과, 상시 실행, 큰 런타임, 장시간 연결 | **ECS/EKS on Fargate** (또는 EC2) |
| 서버 관리 없는 컨테이너 | **Fargate** |
| GPU·특수 인스턴스·호스트 제어·대규모 상시(RI/SP) | **ECS/EKS on EC2** |
| 쿠버네티스 표준·이식성 | **EKS** |
| 코드/이미지만으로 가장 빠른 웹 서비스 | **App Runner** (시험 답. 단 2026-04-30부터 신규 고객 불가 — AWS 권장 대안은 **ECS Express Mode**) |
| 온프레미스에서 관리형 컨테이너 | **ECS Anywhere / EKS Anywhere** |
| 대량 배치 작업(큐·스케줄링) | **AWS Batch** |

## Lambda 한계값 (공식 할당량 기준)

| 항목 | 값 |
|---|---|
| 타임아웃 | 기본 3초, 최대 **900초(15분)** |
| 메모리 | 128 ~ 10,240 MB (CPU 비례, 1,769 MB ≈ 1 vCPU) |
| `/tmp` | 512 ~ 10,240 MB |
| 페이로드 | 동기 6 MB(요청·응답 각각), **비동기 1 MB** |
| 패키지 | zip 50 MB(직접) / 압축 해제 250 MB(계층 포함) / 컨테이너 이미지 10 GB |
| 계층 | 5개 · 환경 변수 합계 4 KB |
| 동시성 | 계정·리전 기본 1,000 (증설 가능) |

## 동시성 3종

| | 뜻 | 언제 |
|---|---|---|
| 예약 동시성 | 함수 몫을 떼어 두고 **상한**으로도 작동 | 다른 함수 보호, 하위 DB 보호, 0으로 두면 함수 정지 |
| 프로비저닝된 동시성 | 실행 환경을 미리 데움(유료) | 콜드 스타트 제거, 일정한 저지연 |
| 계정 동시성 | 리전 전체 한도 | 넘으면 스로틀(429) |

## 호출 유형

| | 동기 | 비동기 | 이벤트 소스 매핑 |
|---|---|---|---|
| 소스 | API GW, ALB, SDK, Cognito 트리거 | S3, SNS, EventBridge | SQS, Kinesis, DynamoDB Streams, MSK, MQ |
| 재시도 | 호출자 | Lambda 기본 2번 더 → 대상/DLQ | SQS: 큐 가시성·DLQ / 스트림: 샤드 막힘(분할·실패 대상) |
| 권한 | 리소스 정책 | 리소스 정책(`add-permission`) | **실행 역할**에 소스 읽기 |
| 핵심 설정 | – | `PutFunctionEventInvokeConfig`(재시도 0~2, 최대 나이, OnSuccess/OnFailure) | 배치 크기, **ReportBatchItemFailures**, 가시성 타임아웃 ≥ 함수 타임아웃(권장 6배) |

## API Gateway 유형

| 필요 | REST | HTTP | WebSocket |
|---|---|---|---|
| API 키·사용량 계획 | ✓ | | |
| 캐싱 | ✓ | | |
| WAF 직접 연결 | ✓ | | |
| 프라이빗 엔드포인트 / 엣지 최적화 | ✓ | | |
| 요청 검증·MOCK | ✓ | | |
| Cognito 연동 인증 | **Cognito 사용자 풀 권한 부여자** | **JWT 권한 부여자** | (Lambda 권한 부여자) |
| 가장 싸고 단순 | | ✓ | |
| 양방향 실시간 | | | ✓ |

- HTTP·WebSocket API에 WAF가 필요하면 → 앞에 **CloudFront + WAF**.
- 계정·리전 기본 스로틀: 초당 10,000, 버스트 5,000 → 넘으면 429.
- 통합 타임아웃: REST 기본 최대 29초(리전·프라이빗은 증설 가능), HTTP 30초.
- REST 캐시 TTL 기본 300초, 최대 3,600초.
- Lambda 프록시 응답: `{"statusCode", "headers", "body": "<문자열>"}`.

## Cognito

| | 사용자 풀(User Pool) | 자격 증명 풀(Identity Pool) |
|---|---|---|
| 답하는 질문 | "**누구인가**" (인증) | "**AWS 리소스에 무엇을 할 수 있나**" (AWS 자격 증명) |
| 결과 | JWT: ID 토큰·액세스 토큰·갱신 토큰 | **임시 AWS 자격 증명**(STS, IAM 역할) |
| 쓰임 | 가입·로그인·MFA·소셜/SAML 로그인, API Gateway 권한 부여 | 앱이 S3·DynamoDB에 **직접** 접근, 비인증(게스트) 접근 |

- ID 토큰: 사용자 정보(`email`, `aud`=앱 클라이언트 ID). 액세스 토큰: 권한 범위(`scope`, `client_id`). 갱신 토큰: 새 토큰 발급.
- JWT payload는 서명됐을 뿐 **암호화되지 않음** — 비밀을 넣지 않는다.

## ECS 용어

| 용어 | 한 줄 |
|---|---|
| 작업 정의 | 이미지·CPU·메모리·포트·역할 명세(리비전) |
| 태스크 | 실행 단위 |
| 서비스 | desired count 유지 + ALB 연결 + 롤링 배포 |
| **작업 실행 역할** | ECS 에이전트: 이미지 풀·로그·비밀 주입 |
| **작업 역할** | 앱 코드: AWS API 호출 |
| awsvpc | 태스크마다 ENI·보안 그룹 (Fargate 필수) |

## 권한 체크리스트

| 연결 | 필요한 것 |
|---|---|
| API GW / S3 / SNS / EventBridge → Lambda | `aws lambda add-permission --principal <서비스> --source-arn <소스>` |
| Lambda → DynamoDB/S3/SQS | 실행 역할(신뢰 `lambda.amazonaws.com`) + 최소 권한 |
| Lambda 로그 | 실행 역할에 `AWSLambdaBasicExecutionRole` |
| SQS → Lambda(ESM) | 실행 역할에 `sqs:ReceiveMessage`·`DeleteMessage`·`GetQueueAttributes` |
| ECS 이미지 풀 | 작업 실행 역할 `AmazonECSTaskExecutionRolePolicy` + 네트워크 경로(NAT 또는 ECR·S3 엔드포인트) |

## 자주 쓰는 CLI

```bash
aws lambda invoke --function-name F --cli-binary-format raw-in-base64-out --payload '{"k":"v"}' out.json
aws lambda invoke --function-name F --invocation-type Event|DryRun ...
aws lambda publish-version --function-name F
aws lambda create-alias --function-name F --name live --function-version 1 --routing-config '{"AdditionalVersionWeights":{"2":0.1}}'
aws lambda create-event-source-mapping --function-name F --event-source-arn <큐 ARN> --function-response-types ReportBatchItemFailures
curl --cacert "$AWS_CA_BUNDLE" https://127.0.0.1:$EMULATOR_PORT/_aws/execute-api/<apiId>/<stage>/<path>   # 에뮬레이터 전용 주소
aws cognito-idp initiate-auth --client-id C --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME=u,PASSWORD=p
aws ecs describe-tasks --cluster C --tasks T --query 'tasks[0].[lastStatus, stoppedReason]'
```
