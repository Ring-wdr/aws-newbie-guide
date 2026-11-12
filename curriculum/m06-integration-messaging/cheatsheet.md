# M06 치트시트 — 애플리케이션 통합

## 무엇을 고를까 (한 장 요약)

| 요구 | 정답 | 아닌 것 |
|---|---|---|
| 생산자·소비자 분리, 작업 분배, 트래픽 버퍼 | **SQS** | SNS(보관 안 함) |
| 순서 + 중복 없음(그룹 단위) | **SQS FIFO** | 표준 큐 |
| 한 이벤트 → 여러 소비자 | **SNS → 여러 SQS(팬아웃)** | 큐 하나를 여러 워커가 공유(그건 분배) |
| 내용 기반 라우팅, AWS 서비스/SaaS 이벤트, 아카이브·재생 | **EventBridge** | SNS |
| cron·일회성 일정 | **EventBridge Scheduler** | EC2의 cron |
| 소스 하나 → 대상 하나를 코드 없이(필터·보강) | **EventBridge Pipes** | Lambda 접착 코드 |
| 여러 단계·분기·재시도·사람 승인 | **Step Functions** (승인은 `.waitForTaskToken`) | Lambda 안의 sleep/try |
| 실시간 스트림, 여러 소비자, 재생 | **Kinesis Data Streams** | SQS |
| 스트림을 S3/Redshift/OpenSearch에 적재만 | **Amazon Data Firehose** | KDS + 직접 짠 소비자 |
| 기존 Kafka | **MSK** | KDS로 재작성 |
| 기존 JMS/AMQP/MQTT/STOMP 브로커 이전 | **Amazon MQ** | SQS(코드 수정 필요) |
| SaaS ↔ S3/Redshift 데이터 이동 | **AppFlow** | 직접 짠 배치 |

## SQS 한계값·기본값

| 항목 | 값 |
|---|---|
| 메시지 크기 | 최대 1 MiB (2025-08부터. 더 크면 S3 + 확장 클라이언트) |
| 보존 기간 | 기본 4일, 60초 ~ 14일 |
| 가시성 타임아웃 | 기본 30초, 0초 ~ 12시간 |
| 롱 폴링 대기 | 0 ~ 20초 |
| 지연(DelaySeconds) | 0 ~ 15분 |
| 배치 | 최대 10건 (Send/Receive/Delete) |
| FIFO 처리량 | 파티션당 API별 300 TPS, 배치 시 3,000 msg/s. 높은 처리량 모드는 리전별로 그 이상 |
| FIFO 중복 제거 기간 | 5분 |
| DLQ | 같은 종류(표준↔표준, FIFO↔FIFO), `maxReceiveCount` 초과 시 이동. 수정 후 `StartMessageMoveTask` |

## 전달 보장

| 서비스 | 보장 |
|---|---|
| SQS 표준 / SNS 표준 | 최소 한 번, 순서 최선 노력 → **멱등 소비자** |
| SQS FIFO / SNS FIFO | 그룹 안 순서 + 중복 제거 |
| Kinesis Data Streams | 샤드 안 순서, 재생 가능, 소비자 재시도 시 중복 가능 |
| Step Functions 표준 | 정확히 한 번(최대 1년) |
| Step Functions 익스프레스 | 비동기 최소 한 번 / 동기 최대 한 번 (최대 5분) |

## 정책 체크리스트 (없으면 조용히 실패)

| 연결 | 필요한 것 |
|---|---|
| SNS → SQS | 큐 정책: `sns.amazonaws.com`, `sqs:SendMessage`, `aws:SourceArn`=토픽 |
| EventBridge 규칙 → SQS | 큐 정책: `events.amazonaws.com`, `aws:SourceArn`=규칙 |
| 암호화된 큐(SSE-KMS) | KMS 키 정책에서 위 서비스 주체 허용 |
| Step Functions / Scheduler / Pipes | **실행 역할**(신뢰: `states`/`scheduler`/`pipes.amazonaws.com`) + 대상 호출 권한 |

## Step Functions 오류 처리

```json
"Retry": [{"ErrorEquals": ["GatewayTimeout"], "IntervalSeconds": 1, "MaxAttempts": 2, "BackoffRate": 2.0}],
"Catch": [{"ErrorEquals": ["PaymentDeclined"], "Next": "MarkDeclined"},
          {"ErrorEquals": ["States.ALL"], "Next": "PaymentUnavailable"}]
```

- `MaxAttempts: 2` = 재시도 2번(총 3번). Catch는 **위에서부터 첫 일치**, `States.ALL`은 마지막.
- Lambda 예외 클래스 이름 = 오류 이름. 일시 오류는 Retry, 업무 오류는 Catch.

## Kinesis Data Streams

- 샤드: 쓰기 1 MB/s 또는 1,000 rec/s, 읽기 2 MB/s(공유). 향상된 팬아웃: 소비자별 샤드당 2 MB/s.
- 샤드 = MD5(파티션 키)의 해시 범위. 키 다양성이 낮으면 hot shard.
- 보존: 기본 24시간 ~ 최대 365일. 레코드: 기본 1 MiB, 설정으로 최대 10 MiB(2025-10).
- 모드: 프로비저닝(샤드 수 관리) / 온디맨드(자동).

## 자주 쓰는 CLI

```bash
aws sqs receive-message --queue-url $U --wait-time-seconds 20 --max-number-of-messages 10 --attribute-names ApproximateReceiveCount
aws sqs change-message-visibility --queue-url $U --receipt-handle $H --visibility-timeout 0
aws sqs start-message-move-task --source-arn <DLQ ARN> --destination-arn <원본 ARN>
aws sns subscribe --topic-arn $T --protocol sqs --notification-endpoint <큐 ARN> \
  --attributes '{"RawMessageDelivery":"true","FilterPolicy":"{\"eventType\":[\"order_paid\"]}"}'
aws events test-event-pattern --event-pattern file://pattern.json --event '<이벤트 JSON>'
aws stepfunctions get-execution-history --execution-arn $E --query 'events[].type'
aws kinesis get-shard-iterator --stream-name $S --shard-id shardId-000000000000 --shard-iterator-type TRIM_HORIZON
```

## 에뮬레이터 메모

- 전달·필터·DLQ·FIFO·Retry/Catch·권한 검사 모두 실제처럼 동작.
- Scheduler `at()`은 시각을 기다리지 않고 곧 발화(관찰). 타이밍을 AWS 특성으로 믿지 말 것.
