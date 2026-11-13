# M06. 애플리케이션 통합과 디커플링

> 시나리오: TodayOrder 6단계 — 주문 후 알림·정산이 느려지고, 알림 서버 장애가 주문 실패로 번진다. 동기 호출을 큐·토픽·이벤트 버스·워크플로로 끊어 낸다.
> 도메인: D2 · 예상 시간: 약 6시간

## 목표

- 동기 호출 사슬을 SQS·SNS·EventBridge·Step Functions·Kinesis로 바꾸는 설계를 하고, 각 서비스를 **언제** 고르는지 설명할 수 있다.
- SQS의 가시성 타임아웃·롱 폴링·DLQ·FIFO가 어떤 문제를 푸는지 직접 관찰하고 설명할 수 있다.
- SNS→SQS 팬아웃에서 **큐 정책이 없으면 조용히 전달되지 않는다**는 것을 알고 고칠 수 있다.
- Step Functions의 Retry/Catch로 일시 오류와 업무 오류를 나눠 처리할 수 있다.
- 각 서비스의 전달 보장(최소 한 번, 정확히 한 번, 순서)을 구분할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [왜 디커플링인가](./01-why-decoupling.md) | 30분 | 🟢 |
| 2 | [SQS — 표준 vs FIFO, 가시성 타임아웃, 롱 폴링, DLQ, 지연 큐](./02-sqs.md) | 60분 | 🟢 |
| 3 | [SNS — 토픽, 구독, 필터 정책, FIFO 토픽과 팬아웃](./03-sns-fanout.md) | 50분 | 🟢 |
| 4 | [EventBridge — 버스, 규칙, 패턴, Scheduler, Pipes](./04-eventbridge.md) | 45분 | 🟢 |
| 5 | [Step Functions — 표준 vs 익스프레스, 상태 유형, 오류 처리](./05-step-functions.md) | 60분 | 🟢 |
| 6 | [스트리밍 — Kinesis vs Firehose vs SQS, MSK, Amazon MQ, AppFlow](./06-streaming.md) | 50분 | 🟢 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| SQS 송수신·가시성 타임아웃·롱 폴링·지연 전송 | [labs/lab01-sqs-basics.sh](./labs/lab01-sqs-basics.sh) | 1, 2 | 🟢 |
| DLQ와 재처리(redrive) | [labs/lab02-sqs-dlq-redrive.sh](./labs/lab02-sqs-dlq-redrive.sh) | 2 | 🟢 |
| FIFO 순서·중복 제거·그룹 단위 처리 | [labs/lab03-sqs-fifo.sh](./labs/lab03-sqs-fifo.sh) | 2 | 🟢 |
| SNS→SQS 팬아웃과 필터 정책 (큐 정책 없는 조용한 실패 → 수정) | [labs/lab04-sns-fanout-filter.sh](./labs/lab04-sns-fanout-filter.sh) | 3 | 🟢 |
| EventBridge 규칙·패턴·SQS 대상 + Scheduler 일정 구성 | [labs/lab05-eventbridge-rules.sh](./labs/lab05-eventbridge-rules.sh) | 4 | 🟢 (Scheduler 발화 시각은 🟡 — 아래 제약) |
| Step Functions 주문 워크플로 (Choice/Fail, Retry/Catch, SQS 서비스 통합, 실행 역할 권한, EXPRESS 동기 실행) | [labs/lab06-stepfunctions-order.sh](./labs/lab06-stepfunctions-order.sh) | 5 | 🟢 |
| Kinesis 스트림 put/get, 파티션 키→샤드(MD5 계산으로 확인), 재독 | [labs/lab07-kinesis-shards.sh](./labs/lab07-kinesis-shards.sh) | 6 | 🟢 |
| boto3: 주문 워커(컨슈머) — 롱 폴링·배치 삭제·멱등·DLQ | [sdk/order_worker.py](./sdk/order_worker.py) | 2 | 🟢 |

lab06이 배포하는 결제 Lambda의 코드는 [functions/payment.py](./functions/payment.py)다(에뮬레이터 안에서 실행되는 함수 코드라 sdk 예제가 아니다).

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m06-integration-messaging/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성 확인) sdk 예제를 실행한다. 마지막 줄이 `MODULE m06 OK`면 통과. 가시성 타임아웃·지연 전송·재시도를 실제로 기다리므로 수 분 걸린다.

lab 스크립트는 [labs/_lib.sh](./labs/_lib.sh)의 작은 도우미(폴링, 큐 재생성, 큐 정책 설정, Lambda 배포)를 함께 쓴다. JSON 정리에는 `jq` 대신 저장소의 Python(`uv run`)을 쓰므로 추가 설치가 필요 없다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

이 모듈의 실습은 모두 🟢로 확정했다. 서비스 간 전달(SNS→SQS, EventBridge→SQS, Step Functions→Lambda·SQS)이 실제로 일어나고, 정책·권한도 검사한다. 저자가 포트 9306(에뮬레이터 1.0.322)에서 관찰한 AWS와의 차이:

| 오퍼레이션 / 동작 | 증상 | 실습에서의 처리 |
|---|---|---|
| EventBridge Scheduler `at()` 일회성 일정 | 지정 시각(10분 뒤)을 기다리지 않고 약 10초 만에 대상 SQS에 전달됐다. `cron(0 3 * * ? *)` 일정은 20초 넘게 지켜봐도 발화하지 않았다 | lab05는 일정 **구성**만 확인하고 발화는 단언하지 않는다 |
| SQS `CreateQueue` 직후 같은 이름 재생성 | `QueueDeletedRecently`(60초 규칙)가 날 때도 있고 안 날 때도 있었다 | `_lib.sh`의 `fresh_queue`가 재시도한다 |
| SQS `PurgeQueue` | 60초 안 두 번째 호출은 `PurgeQueueInProgress` (AWS와 같음) | 실습은 큐를 새로 만들어 비운다 |
| 시간 관련 동작 | 가시성 타임아웃 재등장·지연 전송·이동 작업 완료까지 걸린 시간은 측정만 하고 단언하지 않는다 | 모든 대기는 상한 있는 폴링 |
| Step Functions 오류 이름 | SQS 권한 부족은 `SQS.AmazonSQSException`, Lambda 권한 부족은 `Lambda.AWSLambdaException`으로 나왔다 | 단언은 상태(`FAILED`)로만 |

확인한 것(설계 문서의 "저자 확인" 항목): **Step Functions Retry/Catch는 AWS 규칙대로 동작한다.** `MaxAttempts: 2`면 Task가 총 3번 실행되고(`TaskFailed` 3건), `ErrorEquals`에 맞지 않는 오류는 재시도 없이 Catch로 가며, Catch는 위에서부터 첫 일치 항목을 쓰고 `States.ALL`이 나머지를 받는다. Lambda 예외 클래스 이름이 그대로 오류 이름이 된다. 실행 역할의 `sqs:SendMessage`·`lambda:InvokeFunction` 권한도 검사한다.

## 설계 대비 대체 사유

- CURRICULUM.md의 M06 실습 8개를 모두 구현했다. 대체한 실습은 없다.
- 보강: lab05에 EventBridge Scheduler 일정 구성, lab06에 실행 역할 권한 실패 → 수정 흐름과 EXPRESS `StartSyncExecution`, lab07에 MD5로 샤드를 직접 계산해 대조하는 단계를 넣었다.
- lab06의 Retry/Catch 시연에는 실패하는 Task가 필요해서 작은 결제 Lambda를 쓴다. Lambda 자체의 설명은 M07에서 한다.
- Firehose는 레슨 6에서 개념만 다루고 실습은 M11(Firehose → S3)에 맡긴다. MSK·Amazon MQ·AppFlow는 개념 비교만 한다(시험이 묻는 것은 "선택").
