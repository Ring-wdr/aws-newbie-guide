# M14. 종합 — Well-Architected 리뷰, 캡스톤, 모의고사

> 시나리오: TodayOrder 14단계 — "전체를 다시 설계한다." 13개 모듈 동안 조각으로 만든 것을 Well-Architected 6대 원칙으로 리뷰하고, 요구 사항서 한 장에서 출발해 전체 아키텍처를 설계·구축·점검한 뒤, SAA-C03 형식의 모의고사로 마무리한다.
> 도메인: D1~D4 · 예상 시간: 약 12시간 (레슨 4시간 + 캡스톤 실습 2시간 + 모의고사 130분 + 오답 정리·마지막 1주 복습)

## 목표

- 지금까지 만든 TodayOrder를 6개 기둥으로 리뷰해 **구체적인 위험**(어느 모듈의 무엇)을 찾고 우선순위를 매길 수 있다.
- 기능·비기능 요구 사항서만 보고 참조 설계를 만들고, **각 결정의 이유와 버린 대안**을 설명할 수 있다.
- M02~M10의 재료를 조합해 전체 아키텍처를 **한 번에 짓고, 종단 간 시험하고, 지울 수 있다**.
- 65문항 모의고사를 130분 안에 풀고, 오답의 원인을 분류해 마지막 1주의 복습 계획으로 바꿀 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [Well-Architected 6대 원칙으로 TodayOrder 리뷰하기](./01-well-architected-review.md) | 60분 | 🟢 / 🟡 (위험 판정) |
| 2 | [캡스톤 ① 요구 사항서와 참조 설계](./02-capstone-requirements-and-design.md) | 90분 | — (설계) |
| 3 | [캡스톤 ② 한 번에 짓고, 시험하고, 지우기](./03-capstone-build.md) | 70분 | 🟢 (일부 🟡 — 아래 제약) |
| 4 | [시험 접수·당일 가이드, 문제 풀이 기술, 오답 노트, 마지막 1주](./04-exam-logistics-and-study-plan.md) | 40분 | — |

정리 자료: [통합 치트시트 — 요구 사항 → 서비스, 도메인별](./cheatsheet.md) · [모의고사 65문항](./mock-exam/questions.md) · [정답과 해설](./mock-exam/answer-key.md) · [캡스톤 자기 점검표](./capstone-self-check.md) · [퀴즈 안내](./quiz.md)

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 계층 1: 네트워크(CFN: VPC·서브넷 6·NAT 2·엔드포인트 2·SG 3) + 관리 웹(ACM·ALB·리스너 2·시작 템플릿·ASG) + 정산 DB(RDS Multi-AZ) | [labs/lab01-network-web-tier.sh](./labs/lab01-network-web-tier.sh) · [templates/network.yaml](./labs/templates/network.yaml) | 2, 3 | 🟢 구성 (트래픽·장애 조치 없음) |
| 계층 2: 데이터·보안(CFN: KMS·주문 테이블 GSI·PITR·비밀·설정) + 영수증 버킷(SSE-KMS·버전·수명 주기·HTTPS 강제) | [labs/lab02-data-security.sh](./labs/lab02-data-security.sh) · [templates/data.yaml](./labs/templates/data.yaml) | 2, 3 | 🟢 (수명 주기 전환 자체는 안 일어남) |
| 계층 3: 주문 파이프라인(EventBridge·CFN 메시징·Cognito·Lambda 2·ESM·HTTP API JWT) | [labs/lab03-order-pipeline.sh](./labs/lab03-order-pipeline.sh) · [templates/messaging.yaml](./labs/templates/messaging.yaml) · [functions/](./functions/) | 2, 3 | 🟢 |
| 계층 4: 관측·감사·거버넌스(알람 2·CloudTrail·Config 규칙 2·Budgets) | [labs/lab04-observability-governance.sh](./labs/lab04-observability-governance.sh) | 2, 3 | 🟢 알람·Config(S3) / 🟡 CloudTrail·Budgets·DLQ 알람 |
| 종단 간 스모크 테스트 — 빠진 계층은 먼저 지음(= 한 번에 구축) | [labs/lab05-smoke-test.sh](./labs/lab05-smoke-test.sh) | 3 | 🟢 |
| 정리(teardown) + 남은 것 단언 | [labs/lab06-teardown.sh](./labs/lab06-teardown.sh) | 3 | 🟢 |
| Well-Architected Tool: 워크로드·답변·마일스톤 비교 | [labs/lab07-well-architected-tool.sh](./labs/lab07-well-architected-tool.sh) | 1 | 🟢 / 🟡 위험 판정 |
| boto3: 6개 기둥 자동 점검(29항목) | [sdk/capstone_audit.py](./sdk/capstone_audit.py) | 3 | 🟢 |
| 모의고사 채점기(도메인별 점수, 틀린 문항, 형식 점검) | [mock-exam/grade.py](./mock-exam/grade.py) | 4 | — (로컬 도구) |

에뮬레이터 안에서 실행되는 Lambda 코드는 [functions/](./functions/)(`order_api.py`, `order_worker.py`)에 있다. sdk 예제가 아니므로 `emulator_guard`를 쓰지 않는다. lab 공용 도우미는 [labs/_lib.sh](./labs/_lib.sh)(이름, 폴링, CloudFormation 2초 폴링, 계층 존재 확인)이다.

**가장 빠른 길** — 깨끗한 에뮬레이터에서 한 번에 짓고 시험:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
scripts/emulator-reset.sh
bash curriculum/m14-capstone-exam/labs/lab05-smoke-test.sh     # lab01~04 를 먼저 실행하고 종단 간 시험 (5분 안팎)
uv run python curriculum/m14-capstone-exam/sdk/capstone_audit.py
bash curriculum/m14-capstone-exam/labs/lab06-teardown.sh
```

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m14-capstone-exam/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤 ① sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부) ② 모의고사 형식 점검(65문항, 도메인 20/17/15/13, 정답표·문제·해설 일치, 단일 응답 정답 글자 30% 이하, 정답이 가장 긴 보기인 문항 30% 이하)과 채점기 자가 시험(만점·부분 점수·빈 답안지·이상한 답안 줄 경고) ③ lab07 두 번 ④ 캡스톤 1회차: lab01\~05를 **두 번 연속**(두 번째는 이미 있는 환경에서 멱등) + 감사 → lab06 ⑤ 2회차: 정리된 에뮬레이터에서 **lab05 하나로 전체 구축** + 감사 → lab06 → 빈 상태에서 lab06 한 번 더를 실행한다. 마지막 줄이 `MODULE m14 OK`면 통과. 10\~14분 걸린다(1회차의 두 번째 lab05는 첫 번째 실행의 실패 데이터 포인트가 알람 평가 창에서 빠질 때까지 최대 3분 기다린다 — 아래 ★ 알람 줄). 끝나면 에뮬레이터 메모리는 약 500 MiB(Lambda 호출 누적, M00 제약 참고).

## 에뮬레이터 제약

에뮬레이터 1.0.322, 포트 9314에서 직접 확인했다. 앞 모듈에서 이미 기록된 제약(인스턴스가 부팅하지 않음, ALB·RDS 주소가 컨테이너 안, `PutScalingPolicy` 501, ASG가 대상 그룹에 자동 등록 안 함, CloudFormation `wait`로 NAT 경로 롤백, Lambda 호출마다 메모리 누적)은 그대로 적용된다. 이 모듈에서 **새로** 확인한 것은 ★.

| 오퍼레이션 / 동작 | 증상 | 이 모듈의 대응 |
|---|---|---|
| ★ CloudFormation `AWS::ElasticLoadBalancingV2::LoadBalancer`·`TargetGroup`·`Listener` | `CREATE_COMPLETE`로 보고되지만 `elbv2 describe-load-balancers`·`describe-target-groups`·`describe-listeners`에 **없다**(가짜 생성) | ALB·대상 그룹·리스너는 CLI로(lab01). 템플릿에는 넣지 않음 |
| ★ CloudFormation `AWS::AutoScaling::ScalingPolicy` | `CREATE_COMPLETE`, 그러나 `DescribePolicies`는 501 — 실재 확인 불가 | 조정 정책은 레슨 02에 JSON으로만 |
| ★ CloudFormation `AWS::Events::EventBus` | `CREATE_COMPLETE`인데 `list-event-buses`에 버스가 **없다**. 그 버스를 참조하는 `AWS::Events::Rule`은 `Event bus … does not exist`로 실패(`DependsOn`을 줘도 같음). 기본 버스의 규칙은 생성됨 | 버스는 CLI로 만들고 템플릿에 이름 파라미터로 넘김(lab03) |
| ★ CloudFormation `AWS::S3::Bucket`의 `BucketEncryption` | 무시됨 — 버킷이 기본 SSE-S3로 남음(`VersioningConfiguration`·`LifecycleConfiguration`·`PublicAccessBlockConfiguration`은 반영) | 영수증 버킷은 CLI로(lab02) |
| ★ CloudFormation `AWS::DynamoDB::Table`의 `StreamSpecification` | `Value null at 'streamSpecification.streamEnabled'`로 롤백(실제 CFN에는 `StreamEnabled` 속성이 없다) | 스트림을 쓰지 않는 설계(아웃박스는 레슨 02 "알려진 한계") |
| ★ EventBridge Pipes 대상 | DynamoDB 스트림 → SNS 토픽 파이프가 `RUNNING`이 되지만 전달하지 않는다. 컨테이너 로그: "only an Amazon SQS queue or a Lambda function target is delivered to by this emulator" | 아웃박스(Streams → Pipes)를 구축하지 않음 |
| ★ Lambda 함수 안 boto3 | `sns` 클라이언트가 `UnknownServiceError`(M07 README의 허용 목록에 SNS 없음). `events`·`cloudwatch`·`secretsmanager`·`s3`·`dynamodb`는 동작 | 주문 이벤트를 SNS 직접 게시 대신 EventBridge → SNS 규칙으로 |
| ★ EventBridge 규칙 → SNS 대상 | 실제로 전달됨(토픽 정책에 `events.amazonaws.com`) | 🟢로 사용 |
| ★ SNS 구독 필터 정책 `FilterPolicyScope: MessageBody`(숫자 비교) | 실제로 걸러짐(5만 원 이상만 도착) | 🟢로 사용, lab05가 단언 |
| ★ AWS Config 기록 범위 | `list-discovered-resources`에 S3 버킷만 나온다. DynamoDB 테이블·RDS 인스턴스 대상 관리형 규칙(`DYNAMODB_PITR_ENABLED`, `RDS_MULTI_AZ_SUPPORT`)은 평가 상태는 성공인데 결과가 비어 있다. S3 규칙 중에서도 `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED`·`S3_BUCKET_VERSIONING_ENABLED`는 평가되고 `S3_BUCKET_SSL_REQUESTS_ONLY`·`S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`는 결과가 없었다 | Config는 S3 규칙 2개(lab04). 테이블 PITR·RDS Multi-AZ·HTTPS 강제는 `sdk/capstone_audit.py`가 직접 점검 |
| ★ `AWS/SQS` 지표 | 에뮬레이터가 내지 않는다(`list-metrics --namespace AWS/SQS` 0개) | DLQ 깊이 알람은 구성만(`INSUFFICIENT_DATA`). 실제 알람 경로는 워커의 사용자 지정 지표로 |
| ★ CloudWatch 알람(60초 Period) | 사용자 지정 지표 1건 뒤 수십 초 안에 `ALARM` → SNS → SQS 도착. 상태 이유 문구도 실제와 같은 형식 | 상태를 폴링(상한 150초), 시간은 단언하지 않음 |
| ★ 알람 수동 OK 뒤 재평가 | `set-alarm-state OK` 뒤 몇 초 안에 1\~2분 전 데이터 포인트로 다시 `ALARM`이 되고 그 알림도 SNS로 나간다(평가가 1\~2분 늦은 창을 본다) | lab05는 수동 OK를 쓰지 않는다. 이전 실행의 마지막 실패 데이터 포인트 + 180초가 지나 알람이 스스로 ALARM이 아님을 확인한 뒤 장애 주문을 보내고, ALARM 전환 시각·운영 알림의 `StateChangeTime`·전환을 만든 데이터 포인트가 모두 그 뒤인지 단언한다(검증 A가 재현) |
| ★ Secrets Manager — CloudFormation이 지운 비밀 | 30일 삭제 대기로 남아 같은 이름으로 다시 만들 수 없다(실제 AWS와 같음). `--force-delete-without-recovery`로 즉시 삭제됨 | lab06이 즉시 삭제 |
| ★ Well-Architected Tool 위험 판정 | 질문의 **모든** 선택지를 고르면 `NONE`, 하나라도 빠지면 `MEDIUM`. `HIGH`는 관찰되지 않음(실제는 모범 사례별 위험 수준으로 판정) | lab07은 워크로드·답변·마일스톤 🟢, 위험 판정 🟡 |
| RDS `--manage-master-user-password` | 동작 — `MasterUserSecret`(Secrets Manager)이 생기고 `active`. DB 삭제 시 함께 지워짐 | 🟢로 사용 |
| Budgets | 저장·조회만, 지출은 항상 `0`(M13과 같음) | 🟡 구성 |
| CloudTrail `LookupEvents` | IAM 이벤트만 나옴(M09와 같음) | 캡스톤은 추적 구성·로깅 상태만 단언 |

## 설계 대비 대체 사유

CURRICULUM.md M14의 구성 5개를 모두 구현했다.

1. **Well-Architected 리뷰**: 레슨 01. 일반론이 아니라 M01~M13에서 실제로 만든 것(파일 링크)에 대한 발견 27개를 기둥별로 정리하고, 그것이 캡스톤 요구 사항이 되는 흐름으로 이었다. 보강: lab07(Well-Architected Tool API가 에뮬레이터에서 동작함을 확인해 마일스톤 비교 실습을 넣었다).
2. **캡스톤**: 요구 사항서 → 설계(Mermaid 4개, 결정 기록 24개와 버린 대안) → lab01~06 → 자기 점검표. 구축 범위는 "에뮬레이터가 실제로 동작시키는 것"으로 정했고, 엣지(CloudFront·WAF·Route 53), AWS Backup 계획, 리전 DR, 아웃박스, 조정 정책은 다이어그램·문서로 남겼다(레슨 02 6장에 이유). CloudFormation과 CLI의 분리 기준은 레슨 02 3장과 위 제약 표.
3. **서비스 선택 치트시트**: 전 모듈 치트시트의 비교표를 시험 도메인별 "요구 → 답(→ 아닌 것)"으로 통합하고, 모듈 간 불일치 4건을 근거와 함께 정리했다.
4. **모의고사 65문항 + 해설**: 자체 제작. 도메인 20/17/15/13, 단일 55·복수 10, 정답 글자 분포는 [정답표 통계](./mock-exam/answer-key.md#통계-gradepy---stats-로-다시-계산된다). 채점기가 형식·분포를 검사하고 `verify.sh`가 매번 실행한다. 검토는 두 번 받았다: 정답표를 보지 않은 독립 풀이 두 번이 모두 65/65 일치했고, 두 번째 검토의 지적(해설의 사실 오류 3건, 정답 길이 단서, 범위 편중)을 반영해 S3·SQS·KMS에 몰린 14문항을 컨테이너·API Gateway·NLB·CloudFormation·Control Tower·비용 도구·DMS·Storage Gateway·ElastiCache·Aurora Global Database·Security Hub CSPM·Shield Advanced·Firewall Manager 문항으로 바꾸고, "정답이 가장 긴 보기" 비율을 73% → 20%로 낮췄다(채점기가 30% 상한을 검사). 수정본도 정답표를 보지 않은 독립 풀이로 다시 65/65 일치를 확인했다. 재검증에서 교체가 지나쳐 빠진 S3 스토리지 클래스·수명 주기, S3 데이터 보호, SQS 가시성 타임아웃·DLQ를 4·37·41번으로 되살렸다(컴퓨트 구매 옵션·DR 서비스·메시징처럼 세 문항 이상 있던 영역에서 하나씩 교체).
5. **시험 접수·당일 가이드, 오답 노트 템플릿**: 레슨 04. 시험 형식·정책은 2026-11 AWS 공식 페이지에서 확인했다.

- quiz.md는 별도 10문항 대신 [모의고사](./mock-exam/questions.md)를 이 모듈의 퀴즈로 쓴다(안내와 통과 기준만 둔다). 모의고사 각 문항은 해당 모듈 레슨으로 돌아가는 "복습" 링크를 갖는다.
