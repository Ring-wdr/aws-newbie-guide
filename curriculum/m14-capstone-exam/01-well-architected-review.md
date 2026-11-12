# M14-01. Well-Architected 6대 원칙으로 TodayOrder 리뷰하기
> 도메인: D1~D4 · 예상 시간: 60분 · 실습 등급: 🟢 워크로드·답변·마일스톤 / 🟡 위험 판정 규칙

## 왜 필요한가

13개 모듈 동안 TodayOrder는 서버 한 대에서 VPC·ASG·DynamoDB·큐·Lambda·KMS·CloudTrail까지 자랐다. 하지만 각 모듈은 "그 주제"만 보고 만들었기 때문에, **모듈 사이의 틈**에 위험이 남아 있다 — M07의 주문 API는 인증이 없고, M10의 VPC 템플릿은 NAT가 하나이며, 로그는 기본값(무기한 보관)으로 쌓인다. AWS Well-Architected Framework는 이런 틈을 체계적으로 찾는 질문 목록이다. 이 레슨은 지금까지 **직접 만든 것**을 여섯 기둥으로 리뷰하고, 그 결과가 다음 레슨의 캡스톤 요구 사항이 된다.

## 핵심 개념

### Well-Architected Framework와 Tool

- **Framework**: 6개 기둥(pillar)마다 설계 원칙과 질문(예: "워크로드의 상태를 어떻게 파악하는가?")과 모범 사례를 정리한 문서. SAA-C03 시험 가이드 첫 문장이 "Well-Architected Framework에 기반한 설계 능력을 검증한다"이다.
- **Well-Architected Tool**: 워크로드를 등록하고 질문에 답하면 **고위험(HRI)·중위험(MRI) 이슈**를 집계하고, 마일스톤으로 개선을 추적하는 무료 콘솔 도구. 렌즈(Serverless Lens, SaaS Lens 등)로 질문을 보탠다.
- 리뷰는 감사가 아니다. "지금 이 위험을 알고 받아들였는가, 아니면 몰랐는가"를 드러내는 대화다. 받아들인 위험은 결정 기록에 이유를 남긴다.

| 기둥 | 한 줄 | 대표 질문 | 시험 도메인 |
|---|---|---|---|
| 운영 우수성 (Operational Excellence) | 변경을 작게·자주·되돌릴 수 있게, 운영을 코드로 | 장애를 어떻게 알고 대응하나? | D2 일부 |
| 보안 (Security) | 모든 계층에 최소 권한·추적성·암호화 | 자격 증명과 권한을 어떻게 관리하나? | **D1** |
| 안정성 (Reliability) | 장애를 가정하고 자동 복구, 수평 확장 | 구성 요소 장애를 어떻게 견디나? | **D2** |
| 성능 효율성 (Performance Efficiency) | 요구에 맞는 리소스 유형, 서버리스, 실험 | 데이터베이스를 어떻게 고르나? | **D3** |
| 비용 최적화 (Cost Optimization) | 쓴 만큼, 측정·배분, 관리형으로 운영비 절감 | 사용량과 비용을 어떻게 관리하나? | **D4** |
| 지속 가능성 (Sustainability) | 같은 일을 더 적은 자원으로 | 사용 패턴에 맞춰 자원을 어떻게 줄이나? | (D3·D4와 겹침) |

### TodayOrder 리뷰 결과

각 행은 **이 커리큘럼에서 실제로 만든 것**에 대한 발견이다. 위험도는 TodayOrder가 운영에 들어간다고 가정한 판단이다. 마지막 열은 [레슨 02](./02-capstone-requirements-and-design.md)의 캡스톤이 그것을 어떻게 다뤘는지다.

#### 1) 보안

| # | 발견 | 어디서 만든 것 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|---|
| S1 | 사람(개발자)용 IAM 사용자와 **장기 액세스 키** | [M01 lab01](../m01-iam-identity/labs/lab01-users-groups-policies.sh) | 높음 | 직원은 IAM Identity Center + 외부 IdP, CI는 OIDC 역할([M01 lab07](../m01-iam-identity/labs/lab07-oidc-federation.sh)) | 캡스톤에 IAM 사용자 0개. 서비스는 역할만 |
| S2 | M07 주문 API에 **인증이 없고**, 고객 ID를 요청 본문에서 그대로 믿는다 | [M07 lab04](../m07-serverless-containers/labs/lab04-serverless-order-api.sh) | 높음 | Cognito 사용자 풀 + JWT 권한 부여자, 고객 ID는 토큰 `sub`에서 | 결정 2. 스모크 테스트가 401을 단언 |
| S3 | 결제 키·DB 암호 같은 비밀의 자리가 정해지지 않음(실습마다 평문 변수) | M05·M07 | 높음 | Secrets Manager(교체 가능) + 실행 환경 캐시, RDS는 "Secrets Manager로 마스터 암호 관리" | 결정 8·14 |
| S4 | 데이터마다 암호화 방식이 제각각(SSE-S3 기본값, DynamoDB AWS 소유 키) | M04·M05 | 중간 | 감사·비상 차단이 필요한 데이터는 고객 관리형 KMS 키 + 키 교체 | 결정 9 |
| S5 | 영수증 버킷의 HTTPS 강제·퍼블릭 차단이 실습마다 다름 | [M04 lab05](../m04-storage/labs/lab05-bucket-security.sh) | 중간 | 버킷 정책 `aws:SecureTransport=false` Deny + BPA 4개 | lab02 |
| S6 | CloudTrail·Config가 **실습용으로만** 켜졌다 꺼짐 | [M09 lab07·08](../m09-security-encryption/labs/lab07-cloudtrail.sh) | 높음 | 멀티 리전 추적 + 무결성 검증 상시, Config 규칙 상시 | lab04 |
| S7 | 관리 서버 접속 방법이 SSH(키 페어) 전제 | [M03 lab01](../m03-compute-scaling/labs/lab01-instance-lifecycle.sh) | 중간 | 22번 포트 없이 Session Manager, IMDSv2 필수 | 시작 템플릿 IMDSv2, SG에 22번 없음 |

#### 2) 안정성

| # | 발견 | 어디서 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|---|
| R1 | M10의 VPC 템플릿은 **NAT 게이트웨이가 AZ a에 하나**, 앱 라우팅 테이블도 하나 — AZ a 장애 시 AZ b의 앱도 외부 통신 불가 | [M10 vpc-3tier.yaml](../m10-monitoring-iac/labs/templates/vpc-3tier.yaml) | 중간 | AZ마다 NAT + AZ별 라우팅 테이블([M02](../m02-vpc-networking/README.md)의 설계). 비용과의 절충을 결정 기록으로 | 결정 15 (network.yaml) |
| R2 | 첫 RDS 인스턴스가 단일 AZ | [M05 lab01](../m05-databases/labs/lab01-rds-instance-backup.sh) | 높음 | Multi-AZ(동기 대기, 자동 장애 조치) | 결정 14 |
| R3 | ASG에 **조정 정책이 없다**(에뮬레이터 501) — 실제로 올리면 고정 용량 | [M03 lab09](../m03-compute-scaling/labs/lab09-scaling-policies-and-healing.sh) | 중간 | 대상 추적(`ALBRequestCountPerTarget`) 정책, 헬스 체크 ELB | 레슨 02의 정책 JSON, ELB 헬스 체크 |
| R4 | 주문 API가 DynamoDB에 쓴 뒤 하위 처리를 **동기로** 하던 구조 | M06 레슨 1의 v1 | 높음 | 접수와 처리를 큐로 분리, DLQ, 부분 배치 실패 | 결정 5·6 |
| R5 | 소비자의 멱등성은 M06 워커에만 있고, 주문 확정 단계에는 없음 | [M06 sdk](../m06-integration-messaging/sdk/order_worker.py) | 중간 | 상태 전이를 조건부 쓰기로(PENDING→CONFIRMED) | order_worker.py |
| R6 | 백업이 "실습한 날"에만 있음 | [M12 lab03](../m12-resilience-dr-migration/labs/lab03-aws-backup.sh) | 중간 | DynamoDB PITR 상시 + AWS Backup 계획(교차 리전 복사) | PITR 켬, Backup 계획은 설계(6장) |
| R7 | 리전 DR은 두 에뮬레이터로 흉내만 냄 | [M12 lab02](../m12-resilience-dr-migration/labs/lab02-multi-region-dr.sh) | 낮음(요구 RTO 4h) | 백업·복원 + IaC로 재배포 | 설계만(6장 그림) |

#### 3) 성능 효율성

| # | 발견 | 어디서 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|---|
| P1 | "고객의 주문 목록"을 Scan으로 하던 첫 설계 | [M05 lab04](../m05-databases/labs/lab04-ddb-orders-query-scan.sh) | 높음 | GSI `customerId + createdAt`로 Query(소비 용량이 결과 크기에 비례) | 결정 3 |
| P2 | Athena가 파티션 없이 전체 스캔(에뮬레이터 한계 포함) | [M11 lab05](../m11-analytics/labs/lab05-athena-revenue.sh) | 중간 | `dt=` 파티션 + Parquet | 범위 밖(분석 계층) — 모의고사 20번 |
| P3 | 정적 자산·API 앞에 엣지 계층이 없음 | M08은 따로 실습 | 중간 | CloudFront(정적 자산 캐시) + WAF | 설계만(6장) |

#### 4) 비용 최적화

| # | 발견 | 어디서 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|---|
| C1 | 프라이빗 서브넷의 S3·DynamoDB 트래픽이 NAT를 지남(처리 요금) | [M13 lab03](../m13-cost-optimization/labs/lab03-nat-vs-endpoint.sh) | 중간 | 게이트웨이 엔드포인트(무료) | 결정 16 |
| C2 | Lambda가 만든 로그 그룹의 보존 기간이 **기본값(무기한)** — M10 lab03은 직접 만든 그룹에만 14일을 걸었다 | [M07 lab01](../m07-serverless-containers/labs/lab01-lambda-basics.sh)·[M10 lab03](../m10-monitoring-iac/labs/lab03-logs-metric-filter-insights.sh) | 중간 | 함수 로그 그룹마다 보존 기간(30일 등)을 배포 스크립트·템플릿에서 | 결정 18 |
| C3 | 태그가 실습마다 달라 비용 배분 불가 | [M13 lab05](../m13-cost-optimization/labs/lab05-tag-audit.sh) | 중간 | `Project` 태그 표준 + 비용 할당 태그 활성화 | 모든 리소스 `Project=todayorder` |
| C4 | 예산·알림 없음 | [M13 lab04](../m13-cost-optimization/labs/lab04-budgets.sh) | 중간 | Budgets 예측 알림 → 운영 채널 | lab04 |
| C5 | x86 인스턴스·함수 | M03·M07 | 낮음 | Graviton(arm64) | t4g, Lambda arm64 |

#### 5) 운영 우수성

| # | 발견 | 어디서 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|---|
| O1 | 대부분이 CLI 스크립트, IaC는 M10 일부 | 전 모듈 | 중간 | 템플릿 + 재현 가능한 정리 스크립트 | 스택 3개 + lab06 |
| O2 | 알람이 실습 지표에만 있고 "업무 실패"를 보지 않음 | [M10 lab02](../m10-monitoring-iac/labs/lab02-alarm-sns-sqs.sh) | 높음 | 결제 실패 지표 → 알람 → 운영 채널, OK 알림 | 결정 19 |
| O3 | 실패한 메시지의 재처리 절차가 문서에 없음 | M06 lab02 | 중간 | DLQ + `start-message-move-task` 런북 | lab05 마지막 안내, 레슨 03 |

#### 6) 지속 가능성

| # | 발견 | 위험 | 개선 | 캡스톤 |
|---|---|---|---|---|
| U1 | 하루 대부분 노는 상시 서버(M03의 API 서버) | 중간 | 이벤트 기반 서버리스로 유휴 자원 0 | 주문 경로는 Lambda |
| U2 | 오래된 데이터가 Standard에 계속 | 낮음 | 수명 주기로 아카이브 계층 → 만료 | 결정 11 |

### 리뷰가 캡스톤 요구 사항이 된다

위 표의 "높음"은 [레슨 02의 요구 사항서](./02-capstone-requirements-and-design.md#1-요구-사항서--todayorder-20)에서 NFR로 바뀐다: S1→NFR-S1, S2→FR-2·NFR-S1, R2→NFR-A2, R4→FR-3, P1→NFR-P2, O2→NFR-O2. 리뷰 → 요구 → 설계 → 구축 → 점검(`sdk/capstone_audit.py`)이 한 바퀴다.

## 직접 해 보기

에뮬레이터는 Well-Architected Tool API에 응답한다. [labs/lab07-well-architected-tool.sh](./labs/lab07-well-architected-tool.sh)가 캡스톤을 워크로드로 등록하고, 위 리뷰의 일부를 Tool의 질문에 답해 고위험 이슈 수가 어떻게 집계되는지 본다.

```bash
bash curriculum/m14-capstone-exam/labs/lab07-well-architected-tool.sh
```

```text
== 0. 이전 실행의 워크로드 삭제
== 1. 워크로드 등록 (렌즈: AWS Well-Architected Framework)
워크로드 ID: 8f4e88a20ba147b4f8e8e8c96ae7a8b1
operationalExcellence  질문 11개
security               질문 11개
reliability            질문 13개
performance            질문 5개
costOptimization       질문 11개
sustainability         질문 6개
== 2. 모듈 시절(M01~M13)의 TodayOrder 로 답한다 — 레슨 01 리뷰 표 기준
security	identities	MEDIUM
security	protect-data-at-rest	MEDIUM
reliability	withstand-component-failures	MEDIUM
operationalExcellence	workload-observability	MEDIUM
performance	data-management	MEDIUM
costOptimization	data-transfer	MEDIUM
sustainability	hardware-patterns	MEDIUM
== 3. 캡스톤으로 다시 답한다 — 레슨 02 결정 기록 기준
security	identities	MEDIUM
security	protect-data-at-rest	NONE
reliability	withstand-component-failures	MEDIUM
operationalExcellence	workload-observability	MEDIUM
performance	data-management	MEDIUM
costOptimization	data-transfer	NONE
sustainability	hardware-patterns	MEDIUM
== 4. 마일스톤 비교 (답한 질문 7개의 위험 합계, 나머지 50개는 UNANSWERED)
1	v1-modules-m01-m13
2	v2-capstone
마일스톤 1  HIGH 0  MEDIUM 7  NONE 0  UNANSWERED 50
마일스톤 2  HIGH 0  MEDIUM 5  NONE 2  UNANSWERED 50
LAB07 OK
```

**방금 본 것**

- 프레임워크 렌즈의 질문은 57개다(운영 11 · 보안 11 · 안정성 13 · 성능 5 · 비용 11 · 지속 가능성 6). 실제 리뷰는 전부 답하지만, 여기서는 위 리뷰 표에서 기둥마다 대표 질문 하나씩 7개만 답했다.
- 같은 질문에 "모듈 시절"과 "캡스톤" 두 번 답하고 각각 **마일스톤**으로 저장했다. 마일스톤은 그 시점의 답과 위험을 고정해 두는 스냅숏이라, 다음 리뷰 때 무엇이 나아졌는지 비교할 수 있다.
- 캡스톤에서 `protect-data-at-rest`(키 관리·암호화·자동 보호·접근 제어·사람을 데이터에서 떼어 놓기)와 `data-transfer`는 위험이 `NONE`이 되었다. 나머지 5개는 아직 `MEDIUM` — 예를 들어 `identities`는 "자격 증명을 주기적으로 감사·교체"를 고르지 않았고(결제 비밀 자동 교체 미설정), `withstand-component-failures`는 "복구할 때 컨트롤 플레인(리소스 생성 API)이 아니라 데이터 플레인에 기대기"를 고르지 않았다(ASG가 장애 시 새 인스턴스를 **만들어야** 하는 구조). 이것이 캡스톤의 **남은 위험 목록**이다.
- ⚠️ 에뮬레이터는 "모든 선택지를 고르면 NONE, 아니면 MEDIUM"처럼 단순하게 판정하는 것으로 보인다(HIGH가 한 번도 나오지 않았다). 실제 Tool은 모범 사례마다 정해진 위험 수준이 있어, 고위험 모범 사례를 빠뜨리면 HIGH가 된다. 그래서 위험 **판정**은 🟡로 표시했다.

## 실제 AWS에서는

- Well-Architected Tool은 **무료**다. 콘솔에서 워크로드를 정의하고 질문에 답하면 개선 계획(Improvement plan)과 모범 사례 링크가 나온다. 마일스톤을 저장해 리뷰 사이의 개선을 비교한다.
- 실제 AWS에서 해 보려면: 콘솔 → AWS Well-Architected Tool → Define workload. 리소스를 만들지 않으므로 비용이 들지 않는다. 끝나면 워크로드를 삭제한다(`aws wellarchitected delete-workload`).
- 리뷰는 아키텍처가 바뀔 때마다(분기마다 등) 반복한다. Trusted Advisor·Compute Optimizer·Security Hub의 자동 점검 결과를 근거로 함께 본다([M10-05](../m10-monitoring-iac/05-operations-support.md)).

## 시험 포인트

- 시험 문제의 "가장 잘 만족하는"은 대개 **한 기둥의 요구**(가장 안전한/가장 가용성 높은/가장 비용 효율적인/운영 부담이 가장 적은)를 고정하고 나머지는 "만족만 하면 됨"으로 둔다. 어떤 기둥을 묻는지부터 찾는다.
- 운영 부담 최소 → 관리형·서버리스·자동화. 비용 최소 → 요구를 깨지 않는 가장 싼 것. 가용성 최고 → 다중 AZ·다중 리전·자동 장애 조치.
- Well-Architected Tool = 워크로드 리뷰(질문·HRI·마일스톤). Trusted Advisor = 계정의 자동 점검. Config = 리소스 규칙 준수. 셋을 헷갈리지 말 것.
- 지속 가능성 기둥의 정답 신호: 사용률을 높여라(유휴 자원 제거·서버리스), Graviton, 데이터 수명 주기, 필요한 만큼만 복제.

## 스스로 확인

1. R1(NAT 하나)을 "받아들인 위험"으로 둘 수 있는 상황은 어떤 때인가?
2. S2를 고치는 방법으로 JWT 권한 부여자 대신 "함수 안에서 토큰을 검증"하면 무엇이 나빠지는가?
3. 리뷰 표에서 보안 "높음"이 아닌 비용 "중간"을 먼저 고쳐야 하는 경우가 있을까?

<details><summary>답</summary>

1. 개발·테스트 환경처럼 AZ 장애 때 외부 통신이 끊겨도 업무 영향이 없고, NAT 하나(시간당 요금 + EIP)를 아끼는 것이 더 중요할 때. 운영 환경이라면 "AZ 장애 시 반대편 앱까지 고립"은 요구(NFR-A2) 위반이다. 받아들였다면 결정 기록에 이유를 남긴다.
2. 모든 함수가 검증 코드(서명 키 조회·캐시·만료·발급자·대상 확인)를 직접 갖게 되고, 실수 한 번이 우회로가 된다. 인증 실패 요청도 함수를 호출해 비용·동시성을 쓴다. 권한 부여자는 함수 앞에서 거부하고 검증된 클레임만 넘긴다.
3. 있다. 위험도는 "발생 가능성 × 영향"이고 조직의 상황이 순서를 정한다. 예: 예산이 이번 달 안에 바닥날 상황이면 C4(예산 알림)·C1(NAT 처리 요금)이 먼저다. 다만 보안 "높음"은 사고 한 번의 영향이 크므로 미룰 때는 반드시 명시적으로 받아들인 위험으로 기록한다.
</details>
