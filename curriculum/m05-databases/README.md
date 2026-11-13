# M05. 데이터베이스

> 시나리오: TodayOrder 5단계 — 주문 데이터를 저장한다. EC2 한 대 안의 PostgreSQL을 관리형 RDS·Aurora로 옮기고, 폭증하는 주문 조회·생성은 DynamoDB로, 반복 조회는 캐시로 떼어 낸다. "RDB냐 NoSQL이냐, 읽기 부하·장애 대응"을 요구 사항으로 판단하는 법을 익힌다.
> 도메인: D2(복원력), D3(고성능) · 예상 시간: 약 7시간

## 목표

- 요구 사항(일관성·확장·접근 패턴·운영 부담)을 읽고 RDS / Aurora / DynamoDB / 캐시 / 목적별 DB 중 하나를 고를 수 있다.
- RDS의 서브넷·파라미터 그룹, 자동 백업·스냅샷·PITR을 구성하고, **Multi-AZ(가용성)와 읽기 전용 복제본(확장)** 의 차이를 설명할 수 있다.
- Aurora의 스토리지 구조·엔드포인트·Global Database·Serverless v2와 RDS Proxy의 용도를 설명할 수 있다.
- TodayOrder의 접근 패턴에서 출발해 DynamoDB 키·GSI·LSI를 설계하고, Query와 Scan의 비용 차이를 **소비 용량으로 직접 확인**할 수 있다.
- 조건부 쓰기·트랜잭션으로 동시 주문의 재고 초과 판매를 막고, TTL·Streams·백업·글로벌 테이블을 구성할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [RDS 기본 — 엔진, 서브넷·파라미터 그룹, 백업·스냅샷·PITR](./01-rds-basics.md) | 50분 | 🟡 |
| 2 | [Multi-AZ vs 읽기 전용 복제본](./02-multi-az-vs-read-replica.md) | 45분 | 🟡 |
| 3 | [Aurora(스토리지, 엔드포인트, Global Database, Serverless v2)와 RDS Proxy](./03-aurora-and-rds-proxy.md) | 55분 | 🟡 |
| 4 | [DynamoDB 기본 — 키 설계, 용량 모드, 일관성, 조건부 쓰기, Query vs Scan](./04-dynamodb-basics.md) | 60분 | 🟢 |
| 5 | [DynamoDB 심화 — GSI/LSI, 트랜잭션, Streams, TTL, DAX, 글로벌 테이블](./05-dynamodb-advanced.md) | 60분 | 🟢 |
| 6 | [캐시 — ElastiCache(Valkey/Redis OSS vs Memcached), DAX, 캐싱 전략](./06-caching-elasticache.md) | 45분 | 🟡 |
| 7 | [목적별 DB 한눈에](./07-purpose-built-databases.md) | 35분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| RDS 서브넷·파라미터 그룹, 인스턴스, 스냅샷·복원, 삭제 방지 / PITR(501) | [labs/lab01-rds-instance-backup.sh](./labs/lab01-rds-instance-backup.sh) | 1 | 🟡 |
| Multi-AZ·강제 장애 조치(AZ 안 바뀜)·읽기 복제본·수직 확장 / 승격(501) | [labs/lab02-rds-multiaz-replica.sh](./labs/lab02-rds-multiaz-replica.sh) | 2 | 🟡 |
| Aurora 클러스터·엔드포인트·장애 조치(역할 전환)·Global Database·RDS Proxy / 사용자 지정 엔드포인트(501) | [labs/lab03-aurora-cluster-proxy.sh](./labs/lab03-aurora-cluster-proxy.sh) | 3 | 🟡 |
| DynamoDB 주문 테이블 설계와 Query/Scan 소비 용량 비교 | [labs/lab04-ddb-orders-query-scan.sh](./labs/lab04-ddb-orders-query-scan.sh) | 4 | 🟢 |
| GSI 추가(백필)와 접근 패턴, LSI, 인덱스 쓰기 비용 | [labs/lab05-ddb-gsi-lsi.sh](./labs/lab05-ddb-gsi-lsi.sh) | 5 | 🟢 |
| 조건부 쓰기로 재고 차감·중복 주문 방지, 트랜잭션(멱등 토큰 포함) | [labs/lab06-ddb-conditional-transactions.sh](./labs/lab06-ddb-conditional-transactions.sh) | 4, 5 | 🟢 |
| TTL(장바구니 만료)·Streams(INSERT/MODIFY/REMOVE) | [labs/lab07-ddb-ttl-streams.sh](./labs/lab07-ddb-ttl-streams.sh) | 5 | 🟢 |
| 용량 모드 전환·온디맨드 백업·PITR / 글로벌 테이블 복제본 | [labs/lab08-ddb-capacity-backup-global.sh](./labs/lab08-ddb-capacity-backup-global.sh) | 4, 5 | 🟢 / 🟡(PITR 시점·글로벌 테이블) |
| ElastiCache Valkey 복제 그룹·장애 조치 테스트, Memcached, 서버리스, DAX | [labs/lab09-elasticache-dax.sh](./labs/lab09-elasticache-dax.sh) | 6 (5) | 🟡 |
| 목적별 DB 구성 맛보기: DocumentDB·Keyspaces·Neptune | [labs/lab10-purpose-built-tour.sh](./labs/lab10-purpose-built-tour.sh) | 7 | 🟡 |
| boto3: 동시 구매 40건 — 읽고-덮어쓰기 vs 조건부 감소 | [sdk/stock_concurrency.py](./sdk/stock_concurrency.py) | 5 | 🟢 |
| boto3: 주문 저장소(repository) 구현 | [sdk/order_repository.py](./sdk/order_repository.py) | 4, 5 | 🟢 |

`labs/_common.sh`는 lab들이 함께 쓰는 함수(실습용 VPC·서브넷 준비, 폴링, 오류 기대, 주문 200건 적재)다. 단독 실행하지 않는다.

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m05-databases/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인하고, 모든 lab을 번호 순으로 한 번·**역순으로 한 번 더**(멱등성·순서 무관성) 실행하고 sdk 예제를 실행한다. 마지막 줄이 `MODULE m05 OK`면 통과. 전체 10분 남짓(RDS·캐시 생성이 많다).

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

이 모듈에서 직접 확인한 차이(에뮬레이터 1.0.322). 레슨의 "실제 AWS에서는"에도 같은 내용을 적었다.

| 오퍼레이션 / 동작 | 증상 | 영향받는 실습 |
|---|---|---|
| RDS·Aurora 엔드포인트 | `Endpoint.Address`가 `127.0.0.1`, 포트는 임의. 컨테이너 안에서만 열려 호스트에서 접속 불가 | lab01~03 (SQL 접속 실습 없음) |
| `rds:RestoreDBInstanceToPointInTime` | `501 NotImplemented` | lab01 |
| `rds:DescribeDBInstanceAutomatedBackups` | `501 NotImplemented`. `describe-db-snapshots --snapshot-type automated`는 빈 목록 | 레슨 1 |
| RDS Multi-AZ | `MultiAZ: true`는 저장되지만 `SecondaryAvailabilityZone`이 `null`, `reboot --force-failover` 후에도 AZ 그대로(장애 조치 재현 안 됨) | lab02 |
| `rds:PromoteReadReplica` | `501 NotImplemented` (원본 삭제 시 복제본이 독립 인스턴스가 되는 동작은 재현됨) | lab02 |
| Multi-AZ **DB 클러스터**(`create-db-cluster --engine postgres`) | 응답은 오지만 멤버 인스턴스가 생기지 않음 → 실습하지 않음 | 레슨 2 |
| `rds:CreateDBClusterEndpoint`, `DescribeDBClusterEndpoints` | `501 NotImplemented` (Aurora 사용자 지정 엔드포인트) | lab03 |
| Aurora `MultiAZ` 표시 | 다른 AZ에 리더가 있어도 `false` (실제 AWS는 `true`) | lab03 |
| DynamoDB `CreateTable` 직후 상태 | 응답은 `CREATING`, 1초 안에 `ACTIVE`가 되는 경우가 많아 직후 `DescribeTable`은 경쟁 상태 → 항상 waiter | lab04~08 |
| DynamoDB TTL | 만료 항목이 **수 초 안에** 삭제됨(실제 AWS: 보통 만료 후 며칠 이내). 문자열 타입 TTL은 무시(AWS와 같음) | lab07 |
| DynamoDB Streams의 TTL 삭제 레코드 | `REMOVE` 레코드에 `userIdentity`(`Service`/`dynamodb.amazonaws.com`)가 없음 | lab07 |
| DynamoDB PITR | `LatestRestorableDateTime`이 PITR을 켠 시각에 멈춰 있고, `--use-latest-restorable-time` 복원 결과는 "복원 요청 시점의 현재 데이터". 구간 밖 시각은 `InvalidRestoreTimeException`으로 거부(AWS와 같음) | lab08 |
| DynamoDB 글로벌 테이블 | 복제본 추가·`ACTIVE`까지 보이지만 리전을 분리하지 않아 `--region us-west-2`로도 같은 테이블이 보임. 리전 간 복제·충돌 해결은 관찰 불가 | lab08 |
| `elasticache:DeleteReplicationGroup` | `501 NotImplemented` → 복제 그룹이 남는다. lab09는 재실행 시 재사용, 에뮬레이터 재시작으로 사라짐 | lab09 |
| ElastiCache 엔드포인트 | 실제 AWS 형식 이름(`*.cache.amazonaws.com`)이라 어디서도 해석되지 않는다(접속 불가). 접속을 시도하면 그 이름이 바깥 DNS에 질의되므로 시도하지 않는다(FIDELITY 환경 메모) | lab09는 주소를 읽기만 한다 |
| `dax:CreateSubnetGroup` | 기본 VPC·사용자 VPC 어떤 서브넷을 줘도 `InvalidParameterValueException` → 서브넷 그룹 없이 클러스터 생성 | lab09 |
| `timestream-write` CLI | `AmbiguousService`(내부 서비스 이름 충돌)로 호출 불가 | 레슨 7 (설명만) |
| DocumentDB·Neptune·Keyspaces | 구성·상태만. 데이터 질의 불가 | lab10 |

반대로 **AWS와 똑같이 재현되어 실습의 중심이 된 것**: DynamoDB 소비 용량 계산(항목 크기·일관성·인덱스·트랜잭션 2배), GSI 백필과 투영 검사, 조건부 쓰기의 원자성(스레드 40개 동시 요청), 트랜잭션 취소 사유와 멱등 토큰(10분 창, 재시도 시 RCU 보고, 다른 내용이면 `IdempotentParameterMismatchException`), RDS 검증 오류(자동 백업 없는 원본의 복제본 거부, 삭제 방지, 최종 스냅샷 필수), Aurora `failover-db-cluster`의 쓰기 역할 전환, ElastiCache `test-failover`의 역할 전환과 잘못된 구성 거부.

## 설계 대비 대체 사유

- CURRICULUM.md M05의 레슨 7개와 실습 7종을 모두 구현했다. 등급은 설계와 같다(RDS·ElastiCache 🟡, DynamoDB 🟢).
- **RDS 실습(설계상 하나)을 lab01~03 세 개로 나눴다**: 레슨 1·2·3에 각각 대응하도록. Aurora 클러스터 실습에 RDS Proxy·Global Database 구성을 추가했다(레슨 3 범위).
- **DynamoDB "TTL/Streams"와 별도로 lab08을 추가**: 용량 모드 전환·온디맨드 백업·PITR·글로벌 테이블(레슨 4·5 범위). PITR 시점 복원과 글로벌 테이블 복제는 에뮬레이터 한계로 🟡 부분이 있다(위 표).
- **ElastiCache 실습에 DAX를 함께 넣었다**: 시험 포인트 "DAX vs ElastiCache"를 같은 화면에서 비교하기 위해.
- **lab10 추가(레슨 7)**: 설계에는 레슨 7의 실습이 없지만, DocumentDB·Keyspaces·Neptune API가 응답해 "구성 모양"을 보는 🟡 실습을 붙였다.
- **조건부 쓰기 동시성 시연은 boto3(sdk/stock_concurrency.py)로**: 셸로는 동시 요청을 결정적으로 재현하기 어렵다. `threading.Barrier`로 "모두 읽은 뒤 동시에 쓰기"를 매번 같게 만들어 lost update(40건 성공·재고 9)와 조건부 감소(10건 성공·30건 거절·재고 0)를 단언한다.
- **SQL 클라이언트로 RDS에 접속하는 실습은 없다**: 엔드포인트가 컨테이너 안에만 있다(AUTHORING 3장 9번).
- **Timestream**: 웹 문서로 확인한 결과 Timestream for LiveAnalytics는 2025-06-20부터 신규 고객을 받지 않는다. 레슨 7은 Timestream for InfluxDB를 새 워크로드의 선택지로 설명한다. QLDB는 다루지 않는다(지원 종료).
