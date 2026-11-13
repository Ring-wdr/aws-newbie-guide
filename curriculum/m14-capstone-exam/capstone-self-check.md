# 캡스톤 자기 점검표

> 이 표를 채우면 [CURRICULUM §7](../../docs/CURRICULUM.md#7-완료-기준)의 "캡스톤 자기 점검표 완료"다. 복사해서 자기 노트에 두고 체크한다.
> 세 부분으로 나뉜다: **A. 돌려 보기**(스크립트가 판정) · **B. 요구 사항 추적**(근거를 직접 찾아 적기) · **C. 설명하기**(말로 답해 보기).

## A. 돌려 보기

| ✔ | 항목 | 확인 방법 | 기대 결과 |
|---|---|---|---|
| ☐ | 깨끗한 에뮬레이터에서 한 번에 짓고 시험한다 | `scripts/emulator-reset.sh` 후 `bash curriculum/m14-capstone-exam/labs/lab05-smoke-test.sh` | 마지막 줄 `LAB05 OK` |
| ☐ | 같은 환경에서 다시 돌려도 깨지지 않는다(멱등) | lab01~05를 한 번 더 | 모두 `LABxx OK` |
| ☐ | 6개 기둥 자동 점검 | `uv run python curriculum/m14-capstone-exam/sdk/capstone_audit.py` | `점검 29개 · 통과 29 · 실패 0` |
| ☐ | 하나를 일부러 망가뜨리고 점검이 잡는지 본다 | 예: `aws s3api delete-bucket-policy --bucket todayorder-cap-receipts` 후 감사 | `FAIL 영수증 버킷 HTTPS 강제` → lab02로 복구 |
| ☐ | 정리 후 아무것도 남지 않는다 | `bash .../labs/lab06-teardown.sh` | `스택:[] 버킷:[] …` + `LAB06 OK` |
| ☐ | 모듈 전체 검증 | `curriculum/m14-capstone-exam/labs/verify.sh` | `MODULE m14 OK` |

## B. 요구 사항 추적 — 근거를 직접 찾아 적는다

[요구 사항서](./02-capstone-requirements-and-design.md#1-요구-사항서--todayorder-20)의 각 줄에 대해, **에뮬레이터에서 확인한 근거**(명령과 출력 한 줄) 또는 **설계 문서의 위치**를 적는다. 첫 줄은 예시다.

| ✔ | 요구 | 만족시킨 구성 | 내가 찾은 근거 |
|---|---|---|---|
| ☑ | FR-1 재시도해도 주문 하나 | `attribute_not_exists(orderId)` 조건부 쓰기 | lab05 2단계: 두 번째 POST가 `[HTTP 409]`, 테이블 항목 1개 |
| ☐ | FR-2 내 주문만 / 내 주문 목록 | | |
| ☐ | FR-3 접수와 처리 분리 | | |
| ☐ | FR-4 고액 주문만 알림 채널 | | |
| ☐ | FR-5 관리 웹 HTTPS | | |
| ☐ | FR-6 실패 알림 + 재처리 | | |
| ☐ | NFR-A1 AZ 장애에도 접수 | | |
| ☐ | NFR-A2 관리 웹·DB AZ 장애 | | |
| ☐ | NFR-A3 35일 안 임의 시점 복구 | | |
| ☐ | NFR-A4 리전 장애 RTO 4h·RPO 1h | (설계만) | |
| ☐ | NFR-P1 피크 300건/초 | | |
| ☐ | NFR-P2 "내 주문" Scan 금지 | | |
| ☐ | NFR-S1 장기 키 없음·최소 권한 | | |
| ☐ | NFR-S2 고객 관리형 키 | | |
| ☐ | NFR-S3 TLS 1.2 이상 | | |
| ☐ | NFR-S4 DB 격리 | | |
| ☐ | NFR-S5 결제 키를 코드에 두지 않음 | | |
| ☐ | NFR-S6 API 기록·설정 위반 판정 | | |
| ☐ | NFR-S7 영수증 5년·복구 가능 | | |
| ☐ | NFR-O1 코드로 재생성·정리 | | |
| ☐ | NFR-O2 실패 알림·해제 알림 | | |
| ☐ | NFR-C1 예산 알림·태그 | | |
| ☐ | NFR-C2 유휴 비용 최소 | | |
| ☐ | NFR-C3 NAT 처리 요금 없음 | | |

## C. 설명하기 — 소리 내어 답해 본다 (답은 레슨 01·02에 있다)

| ✔ | 질문 |
|---|---|
| ☐ | 주문 한 건이 앱에서 영수증 파일이 되기까지 거치는 서비스를 순서대로, 각 단계의 권한(누가 누구를 부를 수 있게 허용했나)과 함께 설명한다 |
| ☐ | 결제 대행사 장애 주문이 DLQ에 가기까지 몇 번, 몇 초 간격으로 처리되는가? 가시성 타임아웃을 5초로 줄이면 무슨 일이 생기는가? |
| ☐ | 큐를 고객 관리형 KMS 키로 바꾸면 무엇을 추가해야 하고, 빠뜨리면 증상은 무엇인가? |
| ☐ | 이 설계에서 SNS를 빼고 EventBridge 규칙에 SQS 대상 두 개를 직접 달면 무엇이 달라지는가? |
| ☐ | order-api가 DynamoDB 쓰기 직후 죽으면 어떤 주문이 생기는가? 아웃박스 패턴으로 어떻게 막는가? |
| ☐ | NAT를 하나로 줄이면 월 비용과 가용성이 각각 어떻게 바뀌는가? 어떤 환경이라면 받아들이겠는가? |
| ☐ | 관리 웹에 붙일 조정 정책을 고르고(대상 추적/단계/예약/예측), 지표와 목표값의 이유를 말한다 |
| ☐ | NFR-A4가 "RTO 15분·RPO 1분"으로 바뀌면 DR 그림의 무엇을 바꾸는가? |
| ☐ | 에뮬레이터에서 확인하지 **못한** 동작 세 가지와, 실제 AWS에서 그것을 확인하는 방법을 말한다 |
| ☐ | Well-Architected 6개 기둥 각각에서 이 캡스톤의 가장 큰 남은 위험 하나를 꼽는다 |

## 확장 과제 (선택)

1. **아웃박스**: 주문 테이블에 스트림을 켜고(`aws dynamodb update-table --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE`), 스트림 → Lambda(이벤트 소스 매핑) → `PutEvents`로 바꿔 order-api의 `put_events`를 없앤다. 스모크 테스트가 그대로 통과하는지 본다.
2. **재처리 런북**: DLQ의 장애 주문을 `aws sqs start-message-move-task --source-arn <DLQ ARN>`으로 원래 큐에 되돌리되, 그 전에 order_worker.py의 모의 장애 조건을 바꿔 성공하게 만든다. 주문이 `CONFIRMED`가 되는지 확인한다.
3. **엣지**: HTTP API 앞에 CloudFront 배포와 WAF 웹 ACL(속도 기반 규칙)을 붙이는 설계를 그리고, M08 lab04·lab06의 명령으로 어디까지 에뮬레이터에서 구성되는지 확인한다.
