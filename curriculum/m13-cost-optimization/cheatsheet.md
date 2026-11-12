# M13 치트시트 — 비용 최적화

## "가장 비용 효율적인" 풀이 4단계

1. **제약에 밑줄**: 가용성, 성능(지연·검색 시간), 보존 기간, 중단 허용 여부, 운영 부담.
2. **제약을 깨는 보기 삭제**: 가장 싼 보기가 제약을 깨는 경우가 많다.
3. **숨은 비용 확인**: 데이터 전송, 최소 보관 기간, 검색 요금, 안 써도 내는 약정, 직접 운영 비용.
4. **남은 것 중 최저가**. 비슷하면 관리형·서버리스·자동화.

## 요구 → 답

| 요구 | 답 |
|---|---|
| 꾸준한 사용, 패밀리·리전 바뀔 수 있음, Lambda·Fargate 포함 | Compute Savings Plans (최대 66%) |
| 꾸준한 사용, 패밀리 고정, 최대 할인 | EC2 Instance Savings Plans / RI (최대 72%) |
| 중단 가능한 배치·CI·렌더링 | 스팟 (최대 90%, 2분 전 알림) — 여러 유형·AZ로 분산 |
| 특정 AZ 용량 보장, 기간 약정 없이 | 온디맨드 용량 예약 |
| BYOL 소켓·코어 라이선스 | 전용 호스트 |
| 꾸준한 RDS | 예약 DB 인스턴스 (또는 Database Savings Plans, 2025-12~) |
| 간헐적·예측 불가 DB 부하 | Aurora Serverless v2 / DynamoDB 온디맨드 |
| 같은 성능 더 싸게 (인터프리터 언어·컨테이너) | Graviton (`*g` 인스턴스) |
| EBS gp2 | gp3 (GB당 약 20%↓, 기본 3,000 IOPS·125 MiB/s, 붙인 채 변경) |
| 접근 패턴 모름 | S3 Intelligent-Tiering |
| 드물게, 즉시 | Standard-IA (30일 최소, 128 KB 최소 과금) / 분기 1회면 Glacier IR (90일) |
| 다시 만들 수 있는 데이터, 최저가 즉시 | One Zone-IA |
| 몇 시간 기다려도 됨, 최저가 | Glacier Flexible (90일) / Deep Archive (180일, 표준 12시간 이내) |
| 프라이빗 → S3·DynamoDB 트래픽이 NAT 비용 | 게이트웨이 VPC 엔드포인트 (무료) |
| 온프레미스에서 사설로 S3, 또는 다른 AWS 서비스 | 인터페이스 엔드포인트 (AZ·시간 + GB) |
| 전 세계 정적 콘텐츠 + 전송 비용 | CloudFront (AWS 오리진 → CloudFront 무료) |
| 대량·꾸준한 온프레미스 트래픽 | Direct Connect |
| 한도 넘기 전 알림·예측 초과 알림 | AWS Budgets |
| 지난 비용 분석·예측 그래프 | Cost Explorer |
| 가장 상세한 리소스 단위 데이터 → Athena | CUR / Data Exports (CUR 2.0) |
| 비정상 지출 급증 감지 | Cost Anomaly Detection |
| 부서별 비용 배분 | 비용 할당 태그 (활성화 필요, 소급 안 됨) |
| 과다 프로비저닝 찾기 | Compute Optimizer, Trusted Advisor |
| 여러 계정 볼륨 할인·RI 공유 | Organizations 통합 결제 |
| 아직 안 만든 아키텍처 견적 | AWS Pricing Calculator |

## 데이터 전송 지도

| 경로 | 과금 |
|---|---|
| 인터넷 → AWS | 무료 |
| AWS → 인터넷 | 가장 비쌈 |
| 같은 AZ, 프라이빗 IP | 무료 |
| AZ 간 | 양방향 과금 (RDS Multi-AZ 복제는 무료) |
| EC2 → 같은 리전 S3/DynamoDB | 전송 무료 (NAT 경유면 NAT 처리 요금) |
| AWS 오리진 → CloudFront | 무료 |
| 리전 간 | 과금 |

## 이 모듈의 예시 단가 (⚠️ 실제 가격 아님 — AWS Pricing Calculator로 확인)

| 항목 | USD | 항목 | USD |
|---|---|---|---|
| 한 달 | 730시간 | 인터넷 아웃 | 0.09/GB |
| AZ 간 | 0.01/GB 방향마다 | 리전 간 | 0.02/GB |
| CloudFront → 사용자 | 0.08/GB | 퍼블릭 IPv4 | 0.005/시간 |
| NAT | 0.05/시간 + 0.05/GB | 인터페이스 엔드포인트 | 0.01/AZ·시간 + 0.01/GB |
| m7i.large / m7g.large / c7i.xlarge | 0.10 / 0.08 / 0.18 /시간 | SP / 스팟 할인(예시) | 30% / 70% |
| EBS gp2 / gp3 | 0.10 / 0.08 GB-월 | S3 Std / IA / GIR / Glacier / DA | 0.025 / 0.0125 / 0.005 / 0.004 / 0.001 |
| 전환 요청(1,000건) IA / GIR / Glacier / DA | 0.01 / 0.02 / 0.05 / 0.05 | | |

## 이 모듈의 워크시트 정답 (예시 단가 기준)

| 워크시트 | 정답 |
|---|---|
| 1. 데이터 전송 | 194.00 → CloudFront 적용 174.00 |
| 2. 구매 옵션 조합 | 전부 OD 642.00 / 바닥 SP+피크 OD+배치 스팟 443.40 / 피크까지 SP 642.00 |
| lab01 인벤토리 추정 | 721.35 → 391.78 (−45.7%) |
| 3. 영수증 5년 보관 | 전부 Standard 750.00 / 4단계 177.00 / 3단계 113.50 |
| lab03 NAT vs 엔드포인트 | 233.00 / 게이트웨이 83.00 / 인터페이스 127.60 |

## 에뮬레이터에서

| 되는 것 | 안 되는 것 |
|---|---|
| Budgets 예산·알림·구독자 저장 (지출은 항상 0) | Cost Explorer 조회·예측 (501) |
| 이상 탐지 모니터 생성 | 비용 할당 태그 활성화, SP·적정 크기 권장 (501) |
| 서비스별 태그 API (EC2 Tags, S3 `get_bucket_tagging`, DynamoDB `list_tags_of_resource`, SQS `list_queue_tags`, SNS) | Tagging API `GetResources`는 SQS만, EC2 `DescribeTags` 501 |
| 수명 주기 규칙·게이트웨이 엔드포인트 경로 구성 | 실제 전환, 실제 과금 |
