# M05 치트시트 — 데이터베이스

## 무엇을 고를까 (요구 사항 → 서비스)

| 요구 사항에 나오는 말 | 답 |
|---|---|
| 관계형, JOIN, 기존 MySQL/PostgreSQL 앱, 관리 부담 줄이기 | **RDS** |
| OS·엔진 커스터마이즈 필요 (Oracle·SQL Server) | **RDS Custom** (또는 EC2 직접 설치) |
| 관계형 + 높은 성능·가용성, 복제본 15개, 복제 지연 최소 | **Aurora** |
| 여러 리전 1초 미만 복제, 리전 장애 빠른 복구 | **Aurora Global Database** |
| 관계형 + 예측 불가 부하, 용량 관리 싫음 | **Aurora Serverless v2** |
| Lambda가 DB 연결 폭증, 장애 조치 단축, 자격 증명 분리 | **RDS Proxy** |
| 키-값, 밀리초, 무제한 확장, 서버리스 | **DynamoDB** |
| DynamoDB 읽기를 마이크로초로, 코드 변경 최소 | **DAX** |
| DB 앞 범용 캐시, 세션 저장소 | **ElastiCache** (Valkey/Redis OSS, Memcached) |
| Redis 호환 + 영속 주 DB | **MemoryDB** |
| 데이터 웨어하우스, OLAP, BI 대시보드 | **Redshift** |
| MongoDB 호환 | **DocumentDB** |
| 그래프(추천·소셜·사기 탐지) | **Neptune** |
| Cassandra 호환, 서버리스 | **Keyspaces** |
| 시계열(IoT·지표) | **Timestream** (새 워크로드는 for InfluxDB, LiveAnalytics는 2025-06-20부터 신규 고객 불가) |
| 전문 검색, 로그 검색·시각화 | **OpenSearch Service** |

## Multi-AZ vs 읽기 전용 복제본 vs Aurora 복제본

| | RDS Multi-AZ (인스턴스) | RDS Multi-AZ DB 클러스터 | RDS 읽기 복제본 | Aurora 복제본 |
|---|---|---|---|---|
| 목적 | 가용성 | 가용성 + 읽기 | 읽기 확장, DR(교차 리전) | 읽기 확장 + 장애 조치 대상 |
| 복제 | 동기 | 반동기 | 비동기 | 공유 스토리지(지연 매우 작음) |
| 두 번째 노드 읽기 | ✗ | ✓ (대기 2개) | ✓ | ✓ (리더 엔드포인트) |
| 자동 장애 조치 | ✓ (보통 1~2분, DNS 이름 유지) | ✓ (더 빠름) | ✗ (수동 승격 → 새 엔드포인트) | ✓ (승격 티어 순) |
| 개수 | 대기 1 | 대기 2 | 원본당 최대 15 | 클러스터당 최대 15 |
| 다른 리전 | ✗ | ✗ | ✓ | Global Database |

## RDS 숫자·규칙

| 항목 | 값 |
|---|---|
| 자동 백업 보존 | 0(끔)~**35일** |
| PITR 가능 범위 | 보존 기간 안 ~ `LatestRestorableTime`(보통 현재보다 수 분 전) |
| 복원 결과 | **항상 새 인스턴스** (스냅샷·PITR 모두) |
| 읽기 복제본 전제 | 원본 자동 백업 켜짐 |
| 원본 삭제 시 | 같은 리전 복제본은 독립 인스턴스로 승격 |
| 암호화 | 생성 시에만. 기존 DB → 스냅샷 → 암호화 복사 → 복원 |
| 중지 | 최대 7일 뒤 자동 시작 |
| 파라미터 | `dynamic` 즉시 / `static` 재부팅 |

## Aurora 숫자

| 항목 | 값 |
|---|---|
| 데이터 사본 | 3 AZ × 2 = **6개** |
| 클러스터 볼륨 최대 | 128 TiB (최신 엔진 버전은 256 TiB) |
| 복제본 | 최대 15 (Global Database 보조 클러스터는 16) |
| Global Database | 보조 리전 최대 10, 복제 지연 보통 1초 미만 |
| Serverless v2 | 0(자동 일시 중지)~256 ACU, 1 ACU ≈ 2 GiB |
| 엔드포인트 | 클러스터(쓰기) · 리더 · 사용자 지정 · 인스턴스 |

## DynamoDB 숫자

| 항목 | 값 |
|---|---|
| 항목 최대 크기 | **400 KB** |
| RCU | 4 KB 강력 일관 1회/초 = 최종 일관 2회/초 |
| WCU | 1 KB 쓰기 1회/초 |
| 트랜잭션 | 읽기·쓰기 비용 **2배**, 최대 **100개 항목·4 MB**, 같은 항목 두 번 불가 |
| 멱등 토큰(`ClientRequestToken`) | **10분** 유효, 다른 내용이면 `IdempotentParameterMismatchException` |
| Query/Scan 응답 | 최대 **1 MB** / 페이지 (`LastEvaluatedKey`) |
| BatchWriteItem / BatchGetItem | 25개(16 MB) / 100개(16 MB) |
| GSI / LSI | 테이블당 20(기본, 증가 가능) / **5** |
| LSI 제약 | **테이블 생성 시에만**, 파티션 키 같음, 항목 컬렉션 10 GB |
| GSI 제약 | 언제든 추가·삭제, **최종 일관 읽기만** |
| 파티션 처리량 | 약 3,000 RCU · 1,000 WCU / 파티션 |
| 용량 모드 전환 | 프로비저닝→온디맨드 24시간에 4번, 반대는 언제든 |
| PITR | 복구 기간 1~35일 |
| Streams 보관 | 24시간 |
| TTL | Number 타입 epoch **초**. 만료 후 보통 **며칠 이내** 삭제, WCU 안 씀, Streams에 서비스 삭제로 기록 |

## 소비 용량 계산 (lab04에서 실제로 본 값, 항목 약 1 KB)

| 작업 | 계산 | RCU |
|---|---|---|
| GetItem (최종 / 강력) | 1 KB → 4 KB 1개 × 0.5 / × 1 | 0.5 / 1.0 |
| Query 20건 (최종) | 20 KB → 4 KB 5개 × 0.5 | 2.5 |
| Query 20건 (강력) | × 1 | 5.0 |
| Scan 200건 | 약 196 KB → 4 KB 49개 × 0.5 | 24.5 |
| Scan + Filter(결과 20건) | **필터 전에 읽은 양 기준** | 24.5 |

## 조건식 패턴

```text
중복 생성 금지      ConditionExpression: attribute_not_exists(pk)
재고 차감          UpdateExpression: SET stock = stock - :q   ConditionExpression: stock >= :q
상태 전이          ConditionExpression: #s = :expected
낙관적 잠금        ConditionExpression: version = :v   UpdateExpression: SET version = version + :one, ...
만료 항목 숨기기    FilterExpression: NOT (attribute_type(expires_at, :N) AND expires_at <= :now)
```

## 캐시

| | Valkey / Redis OSS | Memcached | DAX |
|---|---|---|---|
| 대상 | 무엇이든 | 무엇이든 | DynamoDB만 |
| 복제·자동 장애 조치·Multi-AZ | ✓ | ✗ | ✓ (기본 1 + 복제본 최대 10) |
| 백업 | ✓ | ✗ | — |
| 자료 구조 | 다양(정렬 셋 등) | 문자열 | DynamoDB API |
| 스레드 | 주로 단일 | 멀티 | — |

캐싱 전략: **지연 로딩**(miss 때 채움, 오래된 값 위험) · **쓰기 시 갱신**(항상 최신, 메모리 낭비) · **TTL**(둘 다와 함께).

## 에뮬레이터 실습에서 기억할 것

- DynamoDB·RDS 생성 직후 상태는 경쟁 상태 → **waiter/폴링**.
- RDS·ElastiCache 엔드포인트는 접속 불가 → 구성만.
- TTL이 수 초 안에 지워지는 것은 에뮬레이터 특성(실제는 며칠 이내).
- 멱등 토큰은 10분 동안 기억된다 → 실습을 다시 돌릴 때 토큰을 새로 만든다.
