# M11 치트시트

## 파이프라인 단계 → 서비스

| 단계 | 서비스 |
|---|---|
| 실시간 수집(여러 소비자·재처리) | Kinesis Data Streams |
| 거의 실시간 적재(S3·Redshift·OpenSearch·Splunk·HTTP) | **Amazon Data Firehose** |
| Kafka 호환 | Amazon MSK |
| 영상 스트림 | Kinesis Video Streams |
| 제3자 데이터 구독 | AWS Data Exchange |
| DB 이전·지속 복제 | AWS DMS (M12) |
| SaaS ↔ AWS | Amazon AppFlow |
| (예전) 배치 데이터 이동 스케줄러 | AWS Data Pipeline — **신규 고객 불가**, Glue·Step Functions·MWAA로 |
| 저장 | **S3 데이터 레이크** (raw / curated 영역, `dt=` 파티션) |
| 메타데이터 | **Glue Data Catalog** (DB·테이블·파티션) |
| 스키마 자동 발견 | Glue 크롤러 |
| 서버리스 ETL | Glue ETL 작업 (Spark / Python shell), DataBrew(노코드) |
| 세밀 권한(열·행) | **Lake Formation** |
| 서버리스 SQL on S3 | **Athena** |
| 데이터 웨어하우스 | **Redshift** (+ Spectrum: S3 외부 테이블, Serverless) |
| Hadoop/Spark 클러스터 | **EMR** (+ Serverless) |
| 검색·로그 분석 | **OpenSearch Service** |
| BI 대시보드 | **Amazon Quick** (구 QuickSight, 기능명 Quick Sight) |

## Athena vs Redshift vs EMR

| | Athena | Redshift | EMR |
|---|---|---|---|
| 형태 | 서버리스 쿼리 | 웨어하우스(클러스터/서버리스) | 빅데이터 클러스터(Spark·Hive·Presto·HBase) |
| 데이터 | S3 그대로 | 적재(COPY) 또는 Spectrum | S3·HDFS |
| 과금 | 스캔 TB | 노드·RPU 시간 | 인스턴스 시간 |
| 고르는 신호 | 즉석·간헐적·최소 운영 | 반복 BI·복잡 조인·고동시성 | 대규모 변환·커스텀 프레임워크·Hadoop 이전 |

## Firehose 핵심 숫자 (AWS 문서 기준)

| 항목 | 값 |
|---|---|
| S3 버퍼 크기 | 1~128 MiB, 기본 5 MiB |
| S3 버퍼 시간 | 최대 900초, 기본 300초 (0초 = 버퍼링 없음 가능) |
| 레코드 최대 크기 | 1,000 KiB (base64 인코딩 전) |
| `PutRecordBatch` | 호출당 500건 또는 4 MiB |
| 배달 실패 시 보관 | Direct PUT 소스는 최대 24시간 재시도 |
| 접두사 식 | `!{timestamp:yyyy-MM-dd}`(UTC), `!{firehose:error-output-type}` — 식을 쓰면 `ErrorOutputPrefix` 필수 |
| 레코드 구분자 | 넣지 않는다 → 생산자가 `\n` |

## Kinesis Data Streams 핵심

- 샤드당 쓰기 1 MB/s 또는 1,000 레코드/s · 프로비저닝 모드 또는 온디맨드 모드
- 보존 기본 24시간, 최대 365일 → **재처리 가능** (Firehose·SQS와 다른 점)
- 같은 파티션 키 → 같은 샤드 → 샤드 안 순서 보장

## Glue

| 개념 | 한 줄 |
|---|---|
| 데이터베이스 | 카탈로그 안 이름공간 (지우면 테이블·파티션도 삭제) |
| 테이블 | 열·타입·S3 위치·SerDe·파티션 키 |
| 파티션 등록 | 크롤러 / `MSCK REPAIR TABLE` / `ALTER TABLE ADD PARTITION` / `BatchCreatePartition` / **파티션 프로젝션** |
| `Batch*` API | 호출 성공 + 항목별 `Errors` (꼭 확인) |
| ETL 작업 | 서비스 역할로 실행 → 역할의 IAM 정책이 S3 접근을 결정 |
| 작업 북마크 | 새 데이터만 처리 |

## Athena 비용·성능 체크리스트

1. `dt=` 파티션 + 쿼리에 `WHERE dt ...`
2. Parquet/ORC (열 지향) + 압축
3. 필요한 열만 `SELECT`
4. 작은 파일 합치기(compaction)
5. 작업 그룹 `BytesScannedCutoffPerQuery`, 결과 위치 강제
6. 자주 쓰는 집계는 미리 만들어 두기(CTAS / Glue ETL)

## AI/ML 한 줄 매칭

| 키워드 | 서비스 |
|---|---|
| 감정·개체·PII·핵심 구문 (텍스트 의미) | Comprehend |
| 챗봇·대화형 | Lex |
| 텍스트 → 음성 | Polly |
| 이미지·영상 분석, 얼굴, 부적절 콘텐츠 | Rekognition |
| 문서·양식·표에서 텍스트 추출 | Textract |
| 음성 → 텍스트 | Transcribe |
| 번역 | Translate |
| 맞춤 모델 학습·배포 | SageMaker AI |

## 에뮬레이터에서 기억할 것

- Firehose는 버퍼 시간 무시(수 초). 역할 신뢰는 검사, 권한 정책은 안 봄.
- Glue: `GetPartitions`·`StartCrawler` 501, Python shell 작업은 실제 실행 + 역할 권한 평가, Spark 작업은 실패.
- Athena: 실제 SQL 실행, 결과는 `GetQueryResults`로만(S3 파일 없음). 파티션 열 `dt` 없음·파티션 무시하고 전체 읽음. `DeleteWorkGroup` 501.
