# M13. 비용 최적화

> 시나리오: TodayOrder 13단계 — 첫 분기 청구서가 날아왔다. EC2보다 NAT 처리 요금이 더 무섭고, 어느 팀이 무엇을 썼는지 아무도 모른다. 같은 요구를 더 싸게 만족하는 방법을 찾는다.
> 도메인: D4 (시험 비중 20%) · 예상 시간: 약 4시간

## 목표

- AWS 요금의 세 축(컴퓨트·스토리지·데이터 전송)과 데이터 전송 요금 지도를 그리고, 아키텍처에서 비용 요인을 찾아낼 수 있다.
- 워크로드에 맞게 온디맨드·Savings Plans·스팟을 섞고, 적정 크기·Graviton·gp3·스토리지 클래스·VPC 엔드포인트로 같은 요구를 더 싸게 만들 수 있다.
- Cost Explorer·Budgets·CUR·비용 할당 태그·Compute Optimizer·통합 결제의 용도를 구분할 수 있다.
- 시험의 **"가장 비용 효율적인(MOST cost-effective)"** 문제를 4단계로 풀 수 있다 ([레슨 1](./01-billing-and-data-transfer.md#가장-비용-효율적인-문제를-푸는-4단계)).

## 먼저 읽을 것: 예시 단가

이 모듈의 모든 비용 계산은 **계산 연습용 예시 단가**를 쓴다(레슨 1의 표, [cheatsheet](./cheatsheet.md)). 반올림한 숫자이며 **실제 AWS 가격이 아니다**. 가격은 리전·사용량 구간·시기마다 다르므로 실제 숫자는 각 서비스 요금 페이지와 [AWS Pricing Calculator](https://calculator.aws/)로 확인한다. 시험은 단가를 외우게 하지 않는다. "어느 쪽이 싸지는가"의 **구조**를 묻는다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [AWS 과금 구조와 데이터 전송 요금 지도](./01-billing-and-data-transfer.md) — "가장 비용 효율적인" 풀이 4단계 | 45분 | 🔴 워크시트 |
| 2 | [컴퓨트 비용: 구매 옵션 조합, 적정 크기, 스팟, Graviton](./02-compute-cost.md) | 50분 | 🟢 / 🔴 |
| 3 | [스토리지·DB 비용: 클래스 전환, gp2→gp3, 예약 용량, 서버리스](./03-storage-db-cost.md) | 50분 | 🟢 |
| 4 | [네트워크 비용: NAT 게이트웨이 vs VPC 엔드포인트, CloudFront, 같은 AZ](./04-network-cost.md) | 40분 | 🟢 |
| 5 | [비용 도구: Cost Explorer, Budgets, CUR, 비용 할당 태그, Compute Optimizer, 통합 결제](./05-cost-tools.md) | 55분 | 🟡 / 🔴 / 🟢 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 워크시트 1: 데이터 전송 요금 | (레슨 문서 안, 손 계산) | 1 | 🔴 |
| 워크시트 2: 구매 옵션 조합 + 인벤토리로 월 비용 추정 | [labs/lab01-compute-cost-estimate.sh](./labs/lab01-compute-cost-estimate.sh) | 2 | 🟢 인벤토리 읽기 / 🔴 실제 청구 금액 |
| 워크시트 3: 수명 주기 규칙으로 스토리지 비용 계산 | [labs/lab02-storage-lifecycle-cost.sh](./labs/lab02-storage-lifecycle-cost.sh) | 3 | 🟢 규칙 구성 (전환은 안 일어남) |
| NAT 게이트웨이 vs S3 게이트웨이 엔드포인트 경로·비용 | [labs/lab03-nat-vs-endpoint.sh](./labs/lab03-nat-vs-endpoint.sh) | 4 | 🟢 경로 구성 |
| Budgets 예산·알림 / Cost Explorer / 이상 탐지 모니터 | [labs/lab04-budgets.sh](./labs/lab04-budgets.sh) | 5 | 🟡 Budgets · 🔴 Cost Explorer |
| 비용 할당 태그 정책과 태그 누락 감사 | [labs/lab05-tag-audit.sh](./labs/lab05-tag-audit.sh) | 5 | 🟢 (Organizations 태그 정책 강제는 🔴) |
| boto3: 인벤토리 비용 추정기 | [sdk/cost_estimator.py](./sdk/cost_estimator.py) | 2 | 🟢 |
| boto3: 수명 주기 비용 계산기 | [sdk/lifecycle_cost.py](./sdk/lifecycle_cost.py) | 3 | 🟢 |
| boto3: 서비스별 태그 API로 태그 감사 | [sdk/tag_audit.py](./sdk/tag_audit.py) | 5 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m13-cost-optimization/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인하고, 모든 lab을 **두 번씩** 실행하고 sdk 예제를 실행한다. 마지막 줄이 `MODULE m13 OK`면 통과. 각 lab은 레슨 워크시트의 정답 숫자를 단언하므로, 계산기나 예시 단가를 바꾸면 lab이 실패한다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

| 오퍼레이션 / 동작 | 증상 | 이 모듈의 대응 |
|---|---|---|
| Budgets `CreateBudget`·`DescribeBudget`·알림·구독자 | 저장·조회는 된다. `CalculatedSpend.ActualSpend`는 항상 `0`, 알림 상태는 항상 `OK` | 구성까지 실습(🟡), 알림 동작은 문서로 |
| Cost Explorer `GetCostAndUsage`, `GetCostForecast` | `501 NotImplemented` | 🔴. 인벤토리 기반 추정기(lab01)로 대체 |
| Cost Explorer `ListCostAllocationTags`, `UpdateCostAllocationTagsStatus`, `GetSavingsPlansPurchaseRecommendation`, `GetRightsizingRecommendation` | `501 NotImplemented` | 비용 할당 태그 "활성화"는 문서로. 감사는 태그 자체로(lab05) |
| Cost Explorer `CreateAnomalyMonitor`·`GetAnomalyMonitors` | 동작한다(탐지할 지출은 없음) | lab04에서 모니터 생성만 |
| Compute Optimizer `GetEC2InstanceRecommendations` | `OptInRequiredException`(실제 AWS와 같은 응답) | 문서로 |
| Organizations `CreatePolicy`(`TAG_POLICY`) | `501 NotImplemented` | 태그 정책 JSON을 파일로 두고 감사 스크립트가 판정(lab05) |
| Resource Groups Tagging API `GetResources` | SQS만 찾고 S3·DynamoDB·EC2·EBS·SNS는 못 찾음 | 서비스별 태그 API로 감사(lab05, `sdk/tag_audit.py`) |
| EC2 `DescribeTags` | `501 NotImplemented` | `describe_instances`·`describe_volumes`의 `Tags` 사용 |
| DynamoDB 태그 | `CreateTable`의 태그가 ACTIVE 전에는 `ListTagsOfResource`에 안 보이고, `TagResource`·`UntagResource` 결과도 몇 초 뒤 반영 | 보일 때까지 폴링(실제 DynamoDB도 최종 일관성) |
| S3 수명 주기 전환 | 규칙은 저장되지만 시간이 지나도 객체는 `STANDARD`에 머문다. 규칙 검증은 현재 AWS 규칙과 같다 — 30일 미만 IA 전환은 받아 주고(2026-07부터 AWS도 허용, 최소 보관 30일 요금은 그대로), 역방향 전환 등은 `InvalidArgument`로 거부한다(M04 README) | 규칙을 읽어 계산(lab02) |
| 과금 전반 | 에뮬레이터는 어떤 요금도 매기지 않는다 | 모든 금액은 예시 단가로 계산 |

## 설계 대비 대체 사유

- CURRICULUM의 실습 4개를 모두 구현했다: 🟡 Budgets 예산·알림 / 🔴 Cost Explorer(lab04), 🟢 태그 정책·태그 감사(lab05), 🟢 수명 주기 비용 워크시트(lab02), 🔴 시나리오별 월 비용 추정 워크시트(레슨 1·2 워크시트 + lab01).
- "🔴 시나리오별 월 비용 추정 워크시트"는 손 계산 워크시트(레슨 1·2)에 더해, 에뮬레이터의 **인벤토리를 읽어 예시 단가로 추정하는** lab01로 보강했다. 실제 청구 금액은 여전히 🔴이고, 인벤토리 읽기는 🟢이다.
- 추가: lab03(NAT vs 게이트웨이 엔드포인트). 레슨 4의 "NAT GW vs 엔드포인트"를 라우팅 테이블에서 직접 확인하게 하려는 보강이다.
- "비용 할당 태그 정책"은 Organizations 태그 정책 API가 501이라, 같은 문법의 JSON 파일([labs/tag-policy.json](./labs/tag-policy.json))을 감사 스크립트가 읽어 판정하는 방식으로 대체했다.
