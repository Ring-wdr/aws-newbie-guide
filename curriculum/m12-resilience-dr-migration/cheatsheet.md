# M12 치트시트 — 고가용성·DR·마이그레이션

## 가용성 숫자

| 가용성 | 연간 중단 | 월간(730h) |
|---|---|---|
| 99% | 87.6시간 | 438분 |
| 99.9% | 8.76시간 | 43.8분 |
| 99.99% | 52.6분 | 4.4분 |
| 99.999% | 5.3분 | 26초 |

직렬 = 곱(A1×A2…), 병렬(독립 n개) = 1 − (1−A)ⁿ. **같은 AZ 두 대는 독립이 아니다.**

## 장애 범위

| 범위 | 예 | 고가용성 책임 |
|---|---|---|
| AZ | EC2, EBS, NAT GW, 서브넷, 단일 AZ RDS, DMS 복제 인스턴스 | 내가 여러 AZ에 |
| 리전 | S3, DynamoDB, SQS, SNS, Lambda, ALB(여러 AZ 서브넷), EFS | AWS (서브넷만 여러 AZ로) |
| 글로벌 | Route 53, CloudFront, IAM | AWS |

## SPOF → 처방

| SPOF | 처방 |
|---|---|
| EC2 한 대 | ASG 최소 2 + 여러 AZ + ALB |
| NAT GW 하나 | AZ별 NAT + AZ별 프라이빗 라우팅 테이블 |
| RDS 단일 AZ | Multi-AZ(동기 대기, 자동 장애 조치 보통 60~120초) / Aurora |
| 캐시 단일 노드 | 복제본 + Multi-AZ 자동 장애 조치 |
| 서버의 cron·세션·파일 | EventBridge Scheduler, DynamoDB/ElastiCache, S3/EFS |
| 리전 | DR 전략 |

RDS Multi-AZ **DB 인스턴스** 배포의 대기는 읽을 수 없다(가용성 전용). **Multi-AZ DB 클러스터** 배포는 읽기 가능한 대기 2개. 읽기 확장은 읽기 전용 복제본.

## RTO / RPO

- **RPO** = 잃어도 되는 데이터의 시간 폭(백업·복제 주기). **RTO** = 멈춰 있어도 되는 시간.
- 둘 다 짧을수록 비싸다. 두 축을 따로 보라(데이터는 연속 복제, 컴퓨트는 나중에 띄우기 등).

## DR 4전략

| 전략 | 평소 DR 리전 | RPO | RTO | 비용 | 판별 질문 |
|---|---|---|---|---|---|
| 백업·복원 | 백업만 | 시간 | 시간 | 최저 | 인프라도 새로 만드나? |
| 파일럿 라이트 | 데이터 복제 + 꺼진 인프라 | 초~분 | 수십 분 | 낮음 | DR이 지금 요청을 못 받나? |
| 웜 스탠바이 | 축소된 전체 스택 동작 | 초~분 | 분 | 중간 | 작게라도 지금 받나? |
| 다중 사이트 액티브-액티브 | 전체 스택이 트래픽 처리 | ≈0 | ≈0 | 최고 | 두 리전 다 실제 트래픽? |

## DR 재료

| 필요 | 답 |
|---|---|
| 여러 서비스 백업을 중앙 정책으로, 교차 리전·계정 복사 | AWS Backup |
| 백업 삭제 불가(루트 포함), WORM | Backup Vault Lock 규정 준수 모드 (유예 ≥3일 후 고정) / 논리적 에어갭 볼트 |
| S3 다른 리전 복제, 시간 보장 | S3 CRR + RTC (99.9% 15분 이내 SLA) |
| 관계형 DB 리전 장애, 초 RPO·분 RTO | Aurora Global Database (보조 리전 최대 10개, 복제 지연 보통 <1초) |
| NoSQL 다중 리전 다중 쓰기 | DynamoDB 전역 테이블 (강한 일관성 MRSC 옵션도 있음) |
| DynamoDB 시점 복구 | PITR (1~35일) |
| 서버를 고치지 않는 DR, 초 RPO·분 RTO | Elastic Disaster Recovery (DRS) |
| 트래픽 전환 | Route 53 장애 조치 라우팅 + 상태 확인, ARC 라우팅 제어, Global Accelerator |
| AZ 문제 시 트래픽 빼기 | ARC 존 시프트 |
| 장애 주입 훈련 | AWS Fault Injection Service |
| 스냅샷 다른 리전으로 | EBS `copy-snapshot`, RDS `copy-db-snapshot` (대상 리전 KMS 키로 재암호화) |

## AWS Backup 부품

볼트(암호화, 접근 정책, Vault Lock) ← 계획(cron 기본 UTC, 시작·완료 창, 보관 기간, 복사 작업) ← 리소스 할당(ARN/태그 + 서비스 역할: 신뢰 `backup.amazonaws.com`, 정책 `AWSBackupServiceRolePolicyForBackup`) → 복구 지점 → 복원 = **새 리소스**.

## 7R

| R | 뜻 | 도구 |
|---|---|---|
| Retire | 폐기 | — |
| Retain | 유지 | — |
| Rehost | lift-and-shift | MGN |
| Relocate | 하이퍼바이저째 | VMware Cloud on AWS |
| Repurchase | SaaS로 | — |
| Replatform | 일부 관리형으로 (MySQL → RDS) | DMS |
| Refactor | 클라우드 네이티브 재설계 | 개발 + DMS |

## 마이그레이션 서비스

| 필요 | 답 |
|---|---|
| 서버 사용률·의존성 조사 | Application Discovery Service (2025-11-07부터 신규 고객 불가, 후속 AWS Transform) |
| 이전 진행 추적 | Migration Hub (동일) |
| 서버 그대로, 최소 다운타임 | MGN (Application Migration Service) |
| 운영 중인 DB를 최소 다운타임으로 | DMS full load + CDC (소스 binlog 등 준비) |
| 이종 엔진 스키마·코드 변환 | SCT / DMS Schema Conversion (+ DMS로 데이터) |
| 파일 공유 온라인 전송 | DataSync |
| 수십 TB+ 오프라인 | Snow (Snowball Edge는 2025-11-07부터 기존 고객만) |
| SFTP로 파일 받기 | Transfer Family |
| 지속적 하이브리드 접근 | Storage Gateway |

DMS 부품: 복제 인스턴스(VPC 서브넷 그룹, Multi-AZ 선택, 또는 DMS Serverless) · 소스/타깃 엔드포인트(TestConnection) · 복제 작업(`full-load` / `cdc` / `full-load-and-cdc`, 테이블 매핑 selection/transformation).

## 에뮬레이터에서

| 되는 것 | 안 되는 것 |
|---|---|
| Backup 볼트·계획·선택(신뢰 정책 검사)·온디맨드 백업·복사·Vault Lock | 복원 데이터, ListCopyJobs 등 목록 API(501) |
| DMS 복제 인스턴스(Multi-AZ)·엔드포인트·작업 ready | TestConnection·Stop·Delete 인스턴스/엔드포인트(501), 실제 복제 |
| NAT·ASG·RDS Multi-AZ 구성 | 트래픽, 장애 조치, ASG→대상 그룹 자동 등록 |
| 두 번째 에뮬레이터로 "DR 리전" | 실제 리전 분리·관리형 리전 간 복제 |
