# M11 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(12문항 중 10문항) 맞히면 다음 모듈로.

---

**1.** TodayOrder 주문 API가 초당 수백 건의 주문 이벤트를 만든다. 이 이벤트를 S3에 적재해 다음 날 분석에 쓰고 싶다. 서버 관리나 소비자 코드 없이, 몇 분 정도의 지연은 괜찮다. 가장 적합한 것은?

- A. Kinesis Data Streams + EC2에서 도는 KCL 소비자 앱이 S3에 쓴다
- B. Amazon Data Firehose 전송 스트림(목적지 S3)
- C. 주문마다 API 서버가 S3 `PutObject`를 직접 호출한다
- D. SQS 큐에 넣고 Lambda가 메시지마다 S3 객체를 하나씩 만든다

<details><summary>정답과 해설</summary>

**B.** Firehose는 받은 레코드를 버퍼링해 큰 객체로 묶어 S3에 배달하는 완전 관리형 서비스다("거의 실시간", 코드·용량 관리 없음). A: 동작하지만 소비자 앱과 샤드 용량을 직접 관리해야 한다. C·D: 주문마다 작은 객체가 생겨 "작은 파일 문제"로 분석이 느려지고 S3 요청 요금이 늘어난다.
</details>

---

**2.** 주문 이벤트를 실시간으로 사기 탐지 Lambda와 매출 집계 Flink 앱이 **각자** 읽어야 하고, 버그를 고친 뒤 지난 3일치를 **다시 처리**할 수 있어야 한다. 무엇을 쓰는가?

- A. Amazon SQS 표준 큐
- B. Amazon Data Firehose
- C. Kinesis Data Streams (보존 기간 7일)
- D. Amazon SNS

<details><summary>정답과 해설</summary>

**C.** KDS는 여러 소비자가 같은 데이터를 독립적으로 읽고, 보존 기간 동안 원하는 위치부터 다시 읽을 수 있다. A: 소비자가 메시지를 지우면 사라지고, 한 메시지는 한 소비자 그룹이 처리한다. B: 목적지로 배달만 하고 재처리용으로 보관하지 않는다. D: 푸시 팬아웃은 되지만 보관·재처리가 없다.
</details>

---

**3.** 분석팀이 S3에 쌓인 2년치 주문 JSON(수 TB)을 가끔(주 몇 번) SQL로 조회한다. 인프라 운영 인력이 없다. 가장 비용 효율적인 조합은?

- A. Redshift 프로비저닝 클러스터에 전부 적재
- B. Glue Data Catalog에 테이블을 정의하고 Athena로 조회
- C. EMR 클러스터를 상시 띄워 Hive로 조회
- D. RDS for PostgreSQL에 적재

<details><summary>정답과 해설</summary>

**B.** Athena는 서버리스이고 스캔한 데이터만큼 과금되어 간헐적 쿼리에 맞다. 데이터는 S3에 그대로 둔다. A·C: 상시 클러스터 비용이 쿼리가 없을 때도 나온다. D: 수 TB 분석용 OLAP에 맞지 않고 적재·운영 부담이 크다.
</details>

---

**4.** Athena 쿼리 요금이 너무 많이 나온다. 테이블은 `s3://…/orders/` 아래 압축 안 된 JSON이고, 쿼리는 거의 항상 최근 7일의 `store`, `amount` 두 열만 쓴다. 효과가 **가장 적은** 것은?

- A. `dt=YYYY-MM-DD` 파티션으로 나누고 `WHERE dt >= …`를 쓴다
- B. Parquet로 변환하고 Snappy로 압축한다
- C. `SELECT *` 대신 `SELECT store, amount`
- D. 같은 쿼리를 다른 작업 그룹에서 실행한다

<details><summary>정답과 해설</summary>

**D.** 작업 그룹을 바꿔도 스캔량은 같다(작업 그룹은 비용 **통제**·결과 위치·권한 분리 수단이지 스캔량을 줄이지 않는다). A: 7일치 폴더만 읽는다(파티션 프루닝). B: 열 지향 + 압축으로 필요한 열만, 더 적은 바이트를 읽는다. C: 열 지향 형식에서는 읽는 열이 줄어 스캔량이 준다(JSON에서는 효과가 작지만 B와 함께 쓰면 크다).
</details>

---

**5.** S3에 `dt=2026-11-12/` 폴더가 새로 생겼는데 Athena에서 그 날짜 데이터가 안 보인다. 테이블은 `dt`로 파티션되어 있다. 원인과 해결로 맞는 것은?

- A. S3 일관성 문제 — 몇 시간 기다린다
- B. 카탈로그에 새 파티션이 등록되지 않았다 — `ALTER TABLE ADD PARTITION`/`MSCK REPAIR TABLE`/크롤러/`BatchCreatePartition` 또는 파티션 프로젝션
- C. Athena 작업 그룹의 결과 위치가 잘못됐다
- D. 버킷 버전 관리가 꺼져 있다

<details><summary>정답과 해설</summary>

**B.** 파티션 테이블은 카탈로그에 등록된 파티션만 읽는다. 새 폴더는 누군가 등록해야 하고, 파티션 프로젝션을 쓰면 규칙으로 계산되어 등록이 필요 없다. A: S3는 강한 읽기 후 쓰기 일관성을 제공한다. C: 결과 저장 위치는 조회 대상과 무관하다. D: 버전 관리는 관계없다.
</details>

---

**6.** Glue ETL 작업이 `AccessDenied ... assumed-role/todayorder-glue-etl/... is not authorized to perform: s3:ListBucket`으로 실패했다. 작업을 시작한 개발자는 `AdministratorAccess`를 가지고 있다. 무엇을 고쳐야 하는가?

- A. 개발자의 IAM 정책에 `s3:ListBucket`을 추가한다
- B. 작업에 지정한 Glue 서비스 역할(`todayorder-glue-etl`)의 권한 정책에 필요한 S3 권한을 추가한다
- C. 버킷을 퍼블릭으로 바꾼다
- D. 역할의 신뢰 정책에 개발자를 추가한다

<details><summary>정답과 해설</summary>

**B.** 작업 스크립트는 시작한 사람이 아니라 **작업 역할의 세션**으로 S3를 호출한다(lab04에서 재현: 정책 추가 전 FAILED, 후 SUCCEEDED). A: 개발자 권한은 작업 실행 권한과 무관하다. C: 보안 사고다. D: 신뢰 정책은 "누가 역할을 맡을 수 있나"이고 Glue 서비스(`glue.amazonaws.com`)가 맡아야 한다 — 권한 부족과 관계없다.
</details>

---

**7.** 마케팅팀에는 `orders` 테이블에서 `store`, `amount` 열만, 그리고 자기 지역 매장 행만 보여 주고 싶다. 같은 테이블을 Athena와 Redshift Spectrum이 쓴다. 가장 적합한 방법은?

- A. 열마다 별도의 S3 버킷으로 데이터를 복사한다
- B. AWS Lake Formation으로 열 수준 권한과 행 필터를 부여한다
- C. S3 버킷 정책에 열 이름 조건을 쓴다
- D. Athena 작업 그룹을 팀별로 만든다

<details><summary>정답과 해설</summary>

**B.** Lake Formation은 카탈로그 테이블의 열·행·셀 단위 권한을 중앙에서 주고, Athena·Redshift Spectrum·EMR이 그 권한을 따른다. A: 데이터가 중복되고 관리가 어렵다. C: S3 정책은 객체 단위라 파일 안의 열·행을 구분할 수 없다. D: 작업 그룹은 비용·결과 분리이지 데이터 권한이 아니다.
</details>

---

**8.** 매일 아침 경영진 200명이 여는 매출 대시보드가 여러 대형 테이블을 조인하는 복잡한 쿼리로 만들어지며, 수 초 안에 떠야 한다. 데이터는 수십 TB로 늘고 있다. 저장·조회 계층으로 가장 적합한 것은?

- A. Athena
- B. Amazon Redshift (대시보드는 Amazon Quick)
- C. Amazon OpenSearch Service
- D. DynamoDB

<details><summary>정답과 해설</summary>

**B.** 반복적이고 동시성이 높은 복잡한 분석 쿼리는 데이터 웨어하우스(열 지향 MPP)인 Redshift가 맞다. A: 즉석·간헐적 쿼리에 강하고, 고동시성 반복 BI에는 Redshift가 일반적인 답이다. C: 검색·로그 분석용이다. D: 키 기반 OLTP용이라 조인·집계 분석에 맞지 않다.
</details>

---

**9.** 회사가 온프레미스 Hadoop 클러스터에서 Spark·Hive 작업 수백 개를 돌린다. 코드를 거의 바꾸지 않고 AWS로 옮기고, 작업은 밤에만 돌기 때문에 비용을 줄이고 싶다. 무엇을 쓰는가?

- A. Amazon EMR(작업 노드에 스팟 인스턴스, 작업 후 클러스터 종료 또는 EMR Serverless)
- B. Amazon Athena
- C. AWS Glue DataBrew
- D. Amazon Redshift

<details><summary>정답과 해설</summary>

**A.** EMR은 관리형 Hadoop/Spark라 기존 작업을 그대로 옮기기 쉽고, 일시적 클러스터·스팟·Serverless로 비용을 줄인다. B: SQL 조회 서비스라 Spark 작업을 실행하지 않는다. C: 노코드 데이터 정제 도구다. D: 웨어하우스이지 Hadoop 작업 실행 환경이 아니다.
</details>

---

**10.** 고객센터 통화 녹음을 텍스트로 바꾼 뒤, 화가 난 고객의 통화만 골라 점장에게 보내고 싶다. 서비스 조합으로 맞는 것은?

- A. Amazon Textract → Amazon Translate
- B. Amazon Transcribe → Amazon Comprehend
- C. Amazon Polly → Amazon Rekognition
- D. Amazon Lex → Amazon Textract

<details><summary>정답과 해설</summary>

**B.** Transcribe가 음성을 텍스트로, Comprehend가 텍스트의 감정을 분석한다. A: Textract는 문서 이미지에서 텍스트를 뽑고, Translate는 번역이다. C: Polly는 텍스트→음성, Rekognition은 이미지·영상 분석이다. D: Lex는 챗봇, Textract는 문서용이다.
</details>

---

**11.** 점주가 올리는 사업자 등록증 스캔 이미지에서 상호·대표자·등록번호를 필드별로 뽑아 DB에 저장하고 싶다. ML 전문가는 없다. 무엇을 쓰는가?

- A. Amazon Rekognition
- B. Amazon Textract (양식의 키-값 추출)
- C. Amazon SageMaker AI로 OCR 모델을 직접 학습
- D. Amazon Comprehend

<details><summary>정답과 해설</summary>

**B.** Textract는 문서·양식에서 텍스트뿐 아니라 키-값 쌍과 표 구조를 추출하는 사전 학습 서비스다. A: 이미지 속 문자 검출은 하지만 양식 구조를 이해하지 못한다. C: 가능하지만 ML 전문성과 운영이 필요해 요구(전문가 없음)에 맞지 않다. D: 이미 텍스트가 된 것의 의미를 분석한다.
</details>

---

**12.** Firehose로 S3에 적재한 주문 JSON을 Athena로 조회했더니, 일부 파일에서 행이 하나만 나오고 값이 비어 있다. 생산자는 `PutRecordBatch`로 `{"order_id":"A1",...}` 형태의 레코드를 보낸다. 가장 가능성 높은 원인은?

- A. Firehose 버퍼 크기가 너무 작다
- B. 레코드 끝에 줄바꿈(`\n`)이 없어 여러 JSON이 한 줄로 이어 붙었다
- C. Glue 테이블의 `Location`이 버킷 루트다
- D. S3 기본 암호화가 켜져 있다

<details><summary>정답과 해설</summary>

**B.** Firehose는 레코드를 구분자 없이 이어 붙인다. 줄 단위 JSON SerDe는 `{…}{…}` 한 줄을 제대로 해석하지 못한다. 생산자가 `\n`을 붙이거나 Firehose 처리 기능으로 구분자를 추가한다. A: 파일 크기·개수에 영향을 줄 뿐 형식을 깨지 않는다. C: 다른 파일까지 읽게 될 수는 있지만 "한 행·빈 값" 증상의 원인이 아니다. D: SSE-S3는 읽을 때 투명하게 복호화된다.
</details>
