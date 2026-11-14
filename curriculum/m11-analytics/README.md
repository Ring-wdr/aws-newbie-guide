# M11. 데이터 분석

> 시나리오: 대표가 "지난주 강남점 매출이 왜 떨어졌지? 결제 수단별로는?"이라고 묻는다. 주문 이벤트를 레이크(S3)로 모으고, 카탈로그(Glue)에 표로 등록하고, SQL(Athena)로 답한다. 그리고 AI 서비스로 무엇을 더 할 수 있는지 훑는다.
> 도메인: D3 (고성능) · 예상 시간: 약 4시간

## 목표

- 수집 → 저장 → 카탈로그·변환 → 조회 파이프라인의 각 단계를 AWS 서비스(Firehose/KDS → S3 → Glue → Athena/Redshift/EMR → Amazon Quick)에 대응시킬 수 있다.
- Firehose 전송 스트림으로 주문 이벤트를 날짜 파티션 경로의 S3 객체로 적재할 수 있다.
- Glue 테이블·파티션을 정의하고, Glue ETL 작업이 서비스 역할로 실행된다는 것을 설명할 수 있다.
- Athena로 S3의 JSON에 SQL을 실행하고, 비용(스캔 바이트)을 줄이는 방법(파티션·열 지향·압축)을 설명할 수 있다.
- Athena vs Redshift vs EMR vs OpenSearch, 그리고 AI/ML 서비스 8종을 요구 사항에 맞게 고를 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [데이터 레이크와 Lake Formation](./01-data-lake.md) | 35분 | 🟢 (Lake Formation 🟡) |
| 2 | [수집: Kinesis Data Streams · Amazon Data Firehose · MSK](./02-ingestion.md) | 50분 | 🟢 |
| 3 | [카탈로그와 변환: AWS Glue](./03-glue-catalog-etl.md) | 55분 | 🟢 (크롤러 🔴) |
| 4 | [조회: Athena · Redshift · EMR · OpenSearch · Amazon Quick](./04-query-services.md) | 60분 | 🟢 |
| 5 | [AI/ML 서비스 한눈에](./05-ai-ml-services.md) | 25분 | 🔴 |

## 실습

하나의 파이프라인을 단계별로 만든다: **TodayOrder 주문 이벤트 → Firehose/boto3 → 파티션된 S3 → Glue 테이블 → Athena 매출 쿼리**. 각 lab은 단독으로 돈다(필요한 앞 단계 리소스를 스스로 만든다). lab05가 전체를 한 번에 잇는다.

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 레이크 버킷 뼈대: 퍼블릭 차단·암호화·버전 관리·수명 주기, 영역·파티션 경로, Lake Formation 설정 읽기 | [labs/lab01-lake-layout.sh](./labs/lab01-lake-layout.sh) | 1 | 🟢 (LF 🟡) |
| Data Firehose 전송 스트림 → S3 객체 생성 (날짜 파티션 접두사, KDS 소스) | [labs/lab02-firehose-to-s3.sh](./labs/lab02-firehose-to-s3.sh) | 2 | 🟢 |
| Glue 데이터베이스·테이블 직접 정의, `BatchCreatePartition`, 크롤러 501 | [labs/lab03-glue-catalog.sh](./labs/lab03-glue-catalog.sh) | 3 | 🟢 / 🔴 크롤러 |
| Glue ETL 작업(Python shell)으로 raw → curated, 역할 권한 거부 → 허용 | [labs/lab04-glue-python-etl.sh](./labs/lab04-glue-python-etl.sh) · [etl/daily_revenue.py](./labs/etl/daily_revenue.py) | 3 | 🟢 |
| 파이프라인 한 번에: 백필 + Firehose → Glue 테이블·파티션 → Athena 매출 쿼리(`GetQueryResults`) | [labs/lab05-athena-revenue.sh](./labs/lab05-athena-revenue.sh) | 4 | 🟢 |
| boto3: 주문 이벤트를 S3 파티션 경로로 적재 + 파티션 등록 | [sdk/order_events_loader.py](./sdk/order_events_loader.py) | 3, 4 | 🟢 |
| boto3: Athena 매출 리포트 (비동기 실행·폴링·paginator, Python 합산과 대조) | [sdk/athena_revenue_report.py](./sdk/athena_revenue_report.py) | 4 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m11-analytics/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성) sdk 예제를 실행한다. 마지막 줄이 `MODULE m11 OK`면 통과. lab 스크립트는 공용 도우미 [labs/_lib.sh](./labs/_lib.sh)(폴링, Athena 실행, 테이블 정의, 실습 데이터)를 쓴다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

<!-- widget: progress-tracker -->

## 에뮬레이터 제약

에뮬레이터 1.0.322, 포트 9310에서 직접 확인한 것.

| 오퍼레이션 / 동작 | 증상 | 대응 |
|---|---|---|
| Firehose 버퍼링 | `IntervalInSeconds=60`을 무시하고 수 초 안에 S3에 씀 | 객체가 생길 때까지 폴링. 타이밍을 AWS 특성으로 설명하지 않음 |
| Firehose 역할 권한 | 신뢰 정책은 검사(`Firehose is unable to assume role`)하지만, 역할에 S3 권한 정책이 없어도 배달함 | lab에는 실제에 필요한 권한을 모두 넣음 |
| Glue `GetPartitions`, `StartCrawler` | `501 NotImplemented` | 파티션은 `BatchCreatePartition`으로 등록하고 `GetPartition`(단건)으로 확인. 크롤러는 생성까지 + 개념(🔴) |
| Glue Spark 작업(`glueetl`) | `ModuleNotFoundError: No module named 'awsglue.context'`로 FAILED | ETL 실습은 Python shell 작업(🟢). 스크립트를 실제로 실행하고 작업 역할의 IAM 정책을 S3 호출에 적용함(권한 없으면 `AccessDenied`) |
| Athena 파티션 열 | 파티션 키 `dt`를 열로 노출하지 않음: `WHERE dt = ...` → `no such column: dt`. 등록한 파티션과 무관하게 테이블 `Location` 아래 파일을 **모두** 읽음(파티션 등록 전에도 같은 행 수). 파티션 위치가 테이블 위치 밖이면 읽지 않음 | 날짜 집계는 파일 안의 `ordered_at`으로. lab05가 이 차이를 보여 주고, 레슨 4가 실제 AWS의 파티션 프루닝을 설명 |
| Athena 결과 파일 | `OutputLocation`(`…/athena-results/<id>.csv`)을 보고하지만 S3에 쓰지 않음 | 결과는 `GetQueryResults`로만 |
| Athena SQL 방언 | `date_trunc`, `from_iso8601_timestamp`, `approx_distinct` 없음, 중첩 필드(`customer.tier`) 실패, `MSCK REPAIR TABLE`·`SHOW PARTITIONS` 구문 오류. 오류 메시지가 SQLite 계열(`no such column`, `near "MSCK": syntax error`) | 실습 SQL은 Athena(Trino)와 공통인 `count/sum/avg/round/substr/CAST/GROUP BY/ORDER BY/CTE`만 사용 |
| Athena 실행 시간 | 쿼리마다 약 3초 후 SUCCEEDED (`TotalExecutionTimeInMillis: 3000` 고정) | 폴링 |
| Athena `DeleteWorkGroup`, `ListWorkGroups`, `ListNamedQueries`, `ListDataCatalogs` | `501 NotImplemented` | 작업 그룹이 남아 있으면 `update-work-group`으로 갱신(멱등) |
| 줄바꿈 없는 JSON 레코드 | 에뮬레이터: `{…}{…}` 파일이 모든 열이 NULL인 행 하나로 읽힘. (실제 Athena: 한 줄의 **첫 레코드만** 읽혀 `count(*)`가 줄어듦 — 증상이 다름) | 생산자가 레코드 끝에 `\n`을 붙인다(실제 AWS에서도 필요) |
| Lake Formation | 설정 조회만 확인. 열·행 권한 집행은 확인하지 않음 | 🟡 설정 읽기 |
| QuickSight `ListDashboards`, SageMaker `ListNotebookInstances` | `501` (FIDELITY) | 레슨 4·5는 개념 |

## 설계 대비 대체 사유

- CURRICULUM.md의 M11 실습 4개(Firehose → S3, Glue 테이블 직접 정의 / 크롤러 🔴, Athena SQL + `BatchCreatePartition` + `GetQueryResults`, boto3 파티션 적재기)를 모두 구현했다.
- 추가(보강): lab01(레이크 버킷 뼈대·Lake Formation 설정 읽기, 레슨 1), **lab04(Glue Python shell ETL, 🟢)** — CURRICULUM에는 ETL 실습이 없지만 이 버전의 에뮬레이터가 Python shell 작업을 실제로 실행하고 역할 권한까지 평가함을 확인해 레슨 3에 넣었다. sdk 예제는 적재기와 Athena 리포트 두 개로 나눴다.
- Athena 매출 쿼리는 파티션 열 `dt` 대신 이벤트의 `ordered_at`으로 날짜를 계산한다(위 제약). 실제 AWS에서의 `WHERE dt = ...` 프루닝은 레슨 4에서 설명하고, lab05는 에뮬레이터의 오류를 그대로 보여 준다.
- 서비스명: Amazon Data Firehose(구 Kinesis Data Firehose). QuickSight는 SAA-C03 시험 가이드 범위 목록에서 **Amazon Quick**으로 표기되며, 현재 AWS 문서는 "AWS Quick"과 그 BI 기능 "Quick Sight"로 부른다(2026-11 확인). AWS Data Pipeline은 신규 고객에게 제공되지 않음을 명시했다.
