# M05 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(13문항 중 11문항) 맞히면 다음 모듈로.

---

**1.** TodayOrder의 주문 DB(RDS PostgreSQL)가 있는 AZ에 장애가 나도 몇 분 안에 자동으로 서비스가 이어져야 하고, 커밋된 주문은 잃으면 안 된다. 앱 코드 변경은 최소로 하고 싶다. 무엇을 해야 하나?

- A. 다른 AZ에 읽기 전용 복제본을 만들고, 장애 시 앱이 복제본 엔드포인트로 바꾸게 한다
- B. Multi-AZ 배포를 켠다
- C. 자동 백업 보존 기간을 35일로 늘린다
- D. ElastiCache를 앞에 두어 DB가 죽어도 캐시로 응답한다

<details><summary>정답과 해설</summary>

**B.** Multi-AZ는 다른 AZ의 대기 인스턴스에 **동기** 복제하고, 장애 시 **같은 DNS 이름**이 대기 쪽을 가리키도록 자동 장애 조치한다. 앱은 재연결만 하면 된다.
- A: 복제본은 **비동기**라 최근 커밋이 유실될 수 있고, 승격은 자동이 아니며 엔드포인트가 바뀌어 코드/설정 변경이 필요하다.
- C: 백업은 복구 수단이지 자동 장애 조치가 아니다. 복원은 새 인스턴스를 만들고 시간이 걸린다.
- D: 캐시는 읽기 일부만 대신할 뿐 주문 쓰기를 처리할 수 없다.
</details>

---

**2.** 매일 오전 정산팀의 무거운 집계 쿼리가 운영 MySQL(RDS)의 CPU를 90%까지 올려 주문 API가 느려진다. 정산은 몇 분 지난 데이터여도 괜찮다. 가장 알맞은 해결책은?

- A. Multi-AZ를 켜고 정산 쿼리를 대기 인스턴스로 보낸다
- B. 읽기 전용 복제본을 만들고 정산 쿼리를 복제본 엔드포인트로 보낸다
- C. 인스턴스를 중지했다가 정산이 끝나면 다시 시작한다
- D. 정산 테이블을 DynamoDB로 옮기고 Scan으로 집계한다

<details><summary>정답과 해설</summary>

**B.** 읽기 부하 분리는 읽기 전용 복제본의 대표 용도다. 몇 분 지연(비동기)도 허용된다.
- A: Multi-AZ(인스턴스 배포)의 대기 인스턴스는 **읽기 트래픽을 받지 않는다**.
- C: 운영 중인 주문 DB를 멈출 수는 없다.
- D: Scan 집계는 테이블 전체를 읽어 비싸고 느리다. 집계·분석에는 DynamoDB가 맞지 않는다.
</details>

---

**3.** 개발자가 실수로 운영 RDS에서 `orders` 테이블을 `DROP` 했다. 사고 시각은 14:07이고 자동 백업 보존 기간은 7일이다. 데이터를 되살리는 올바른 방법은?

- A. 자동 백업에서 기존 인스턴스를 14:06으로 되돌린다
- B. 14:06으로 시점 복원(PITR)해 새 인스턴스를 만들고, 거기서 데이터를 확인해 옮기거나 앱을 전환한다
- C. 읽기 전용 복제본을 승격한다
- D. Multi-AZ 강제 장애 조치로 대기 인스턴스의 데이터를 쓴다

<details><summary>정답과 해설</summary>

**B.** PITR(과 스냅샷 복원)은 **항상 새 인스턴스**를 만든다. 기존 인스턴스를 그 자리에서 되돌리는 기능은 없다(A 오답).
- C: 복제본에도 DROP이 이미 복제됐다(비동기라도 몇 초 안에).
- D: Multi-AZ는 동기 복제라 대기 쪽에도 DROP이 반영돼 있다. 가용성 기능이지 백업이 아니다.
</details>

---

**4.** 전 세계 사용자를 둔 주문 서비스가 관계형 DB를 쓴다. 쓰기는 한 리전에서 하되, 다른 대륙 사용자는 가까운 리전에서 1초 미만 지연으로 읽어야 하고, 주 리전 전체가 장애 나면 1분 안팎으로 다른 리전을 주 리전으로 바꿔야 한다. 무엇을 고르나?

- A. RDS MySQL + 교차 리전 읽기 복제본
- B. Aurora Global Database
- C. DynamoDB 글로벌 테이블
- D. RDS Multi-AZ DB 클러스터

<details><summary>정답과 해설</summary>

**B.** Aurora Global Database는 스토리지 계층에서 보조 리전(최대 10개)으로 보통 1초 미만에 복제하고, 리전 장애 시 보조 클러스터로 빠르게 failover한다.
- A: 가능은 하지만 엔진 수준 비동기 복제라 지연과 승격 시간(RPO/RTO)이 더 크다. "가장 빠른"을 묻는다면 B.
- C: 관계형 DB 요구에 맞지 않는다(키-값 모델로 다시 설계해야 한다).
- D: 한 리전 안의 AZ들에 걸친 구성이다. 다른 리전은 다루지 않는다.
</details>

---

**5.** 이벤트 기간에 Lambda 함수가 수백 개 동시에 실행되면서 Aurora PostgreSQL이 `too many connections` 오류를 낸다. 쿼리 자체는 가볍다. DB 비밀번호도 코드에서 없애고 싶다. 가장 알맞은 것은?

- A. Aurora 인스턴스 클래스를 가장 큰 것으로 올린다
- B. Lambda 예약 동시성을 1로 줄인다
- C. RDS Proxy를 두고 Secrets Manager의 자격 증명과 IAM 인증을 쓴다
- D. Aurora 리더를 15개로 늘린다

<details><summary>정답과 해설</summary>

**C.** RDS Proxy는 연결을 풀링해 DB 쪽 연결 수를 줄이고, 자격 증명은 Secrets Manager에서 꺼내며 앱은 IAM 인증으로 붙을 수 있다.
- A: `max_connections`가 조금 늘 뿐 연결 폭증 구조는 그대로이고 비싸다.
- B: 이벤트 트래픽을 처리하지 못한다.
- D: 쓰기 연결 문제와 무관하고, 리더도 각각 연결 한도가 있다.
</details>

---

**6.** DynamoDB 주문 테이블의 키는 PK `customer_id`, SK `order_ts`다. 고객센터가 "특정 고객의 주문"을 찾을 때 개발자가 `Scan` + `FilterExpression: customer_id = :c`를 쓰고 있다. 테이블은 500 GB다. 무엇이 문제이고 어떻게 고치나?

- A. 문제없다. FilterExpression이 서버에서 걸러 주므로 그 고객 주문 크기만큼만 과금된다
- B. Scan이 테이블 전체를 읽어 그만큼 RCU를 쓴다. `Query`(KeyCondition `customer_id = :c`)로 바꾼다
- C. Scan을 강력 일관 읽기로 바꾸면 빨라진다
- D. `customer_id`에 GSI를 만들어야 한다

<details><summary>정답과 해설</summary>

**B.** FilterExpression은 **읽은 뒤에** 거른다. lab04에서 결과 20건이라도 200건을 읽어 24.5 RCU(Query는 2.5)를 썼다. `customer_id`는 이미 파티션 키이므로 그냥 Query하면 된다.
- A: 위 이유로 틀림.
- C: 강력 일관은 비용이 2배가 될 뿐이다.
- D: 이미 테이블의 파티션 키라 인덱스가 필요 없다.
</details>

---

**7.** 한정판 상품(재고 100개)에 초당 수천 건의 구매 요청이 몰린다. 재고가 음수가 되거나 초과 판매되면 안 된다. DynamoDB에서 가장 알맞은 구현은?

- A. `GetItem`으로 재고를 읽고, 1 이상이면 `PutItem`으로 `stock - 1`을 쓴다
- B. `UpdateItem`에 `SET stock = stock - :one`과 `ConditionExpression: stock >= :one`을 준다
- C. 강력 일관 읽기로 재고를 읽은 뒤 `UpdateItem`으로 덮어쓴다
- D. 재고를 ElastiCache에 두고 DynamoDB는 나중에 맞춘다

<details><summary>정답과 해설</summary>

**B.** 조건 검사와 감소가 항목 단위로 원자적으로 처리된다. sdk/stock_concurrency.py에서 40명 동시 요청 중 정확히 10명만 성공했다.
- A·C: 읽기와 쓰기 사이에 다른 요청이 끼어들어 lost update가 생긴다(실습: 40명 성공, 재고 9). 강력 일관 읽기는 "읽는 순간"만 최신일 뿐 쓰기 시점을 보호하지 않는다.
- D: 두 저장소 사이의 일관성 문제를 새로 만든다.
</details>

---

**8.** 주문 생성(`orders`에 Put)과 재고 차감(`products`에 Update)을 함께 처리해야 한다. 재고가 부족하면 주문도 생기면 안 된다. 결제 서비스는 타임아웃 시 재시도한다. 무엇을 써야 하나?

- A. `BatchWriteItem`
- B. `TransactWriteItems` + `ClientRequestToken`
- C. Put과 Update를 순서대로 호출하고, Update가 실패하면 주문을 Delete한다
- D. DynamoDB Streams로 주문 INSERT를 받아 Lambda가 재고를 줄인다

<details><summary>정답과 해설</summary>

**B.** 트랜잭션은 조건 하나라도 실패하면 전부 취소한다(`TransactionCanceledException`). 토큰을 주면 10분 안의 재시도가 한 번만 반영된다.
- A: BatchWriteItem은 원자적이지 않고 조건식도 지원하지 않는다.
- C: 두 호출 사이에 실패하면 불일치가 남는다(보상 로직도 실패할 수 있다).
- D: 비동기라 이미 주문이 만들어진 뒤에 재고 부족을 알게 된다.
</details>

---

**9.** 운영 중인 DynamoDB 주문 테이블(PK `customer_id`)에 "배송 상태별·날짜순 조회"를 추가해야 한다. 테이블을 다시 만들 수는 없다. 무엇을 하나?

- A. LSI를 추가한다
- B. GSI(PK `status`, SK `order_ts`)를 추가한다
- C. 테이블의 파티션 키를 `status`로 바꾼다
- D. Scan + FilterExpression을 쓴다

<details><summary>정답과 해설</summary>

**B.** GSI는 운영 중에도 추가할 수 있고 기존 데이터를 백필한다(lab05). 단 최종 일관 읽기만 된다.
- A: LSI는 **테이블 생성 시에만** 만들 수 있고 파티션 키도 테이블과 같아야 한다.
- C: 기본 키는 바꿀 수 없다. 바꾼다 해도 가장 잦은 "고객별 주문" 패턴이 깨진다.
- D: 비싸고 느리다(문항 6).
</details>

---

**10.** 장바구니 항목을 마지막 활동 24시간 뒤에 자동으로 지우고 싶다. 삭제에 쓰기 비용을 쓰고 싶지 않고, 만료 직후 정확히 지워질 필요는 없다. 다만 화면에는 만료된 장바구니가 보이면 안 된다. 올바른 설계는?

- A. TTL을 켜고 `expires_at`(Number, epoch 초)을 저장한다. 읽을 때 만료 시각이 지난 항목은 걸러 낸다
- B. TTL을 켜면 만료 즉시 지워지므로 따로 할 일이 없다
- C. 매시간 Lambda가 Scan해서 만료 항목을 DeleteItem 한다
- D. `expires_at`을 ISO 8601 문자열로 저장하고 TTL을 켠다

<details><summary>정답과 해설</summary>

**A.** TTL 삭제는 WCU를 쓰지 않지만 **만료 후 보통 며칠 이내**에 일어난다. 그동안 보일 수 있으므로 읽기 쪽 필터가 필요하다.
- B: 즉시가 아니다(에뮬레이터는 수 초 만에 지우지만 실제 AWS는 다르다).
- C: Scan과 삭제 모두 용량을 쓴다. 요구 사항(쓰기 비용 없이)에 어긋난다.
- D: TTL 속성은 Number 타입이어야 한다. 문자열은 무시된다(lab07의 `cart-string-ttl`).
</details>

---

**11.** 상품 상세 조회가 초당 수만 건이고 대부분 같은 인기 상품이다. 데이터는 DynamoDB에 있고, 응답 시간을 마이크로초 단위로 줄이되 애플리케이션 코드는 거의 바꾸고 싶지 않다. 무엇을 고르나?

- A. ElastiCache for Memcached를 두고 지연 로딩 코드를 작성한다
- B. DynamoDB Accelerator(DAX)
- C. 읽기 전용 복제본
- D. 테이블을 프로비저닝 모드로 바꾸고 RCU를 크게 올린다

<details><summary>정답과 해설</summary>

**B.** DAX는 DynamoDB API와 호환되는 인메모리 캐시라 클라이언트만 바꾸면 되고, 마이크로초 응답을 준다.
- A: 가능하지만 캐시 읽기·쓰기·무효화 코드를 직접 작성해야 한다("코드 변경 최소"에 어긋남).
- C: DynamoDB에는 RDS식 읽기 복제본이 없다.
- D: 처리량은 늘지만 응답은 여전히 밀리초이고, 같은 키에 몰리면 핫 파티션 문제도 남는다.
</details>

---

**12.** 다음 중 요구 사항과 서비스의 짝이 **틀린** 것은?

- A. 5년치 주문 데이터로 BI 대시보드용 대규모 집계 → Amazon Redshift
- B. "이 상품을 산 사람이 함께 산 상품" 관계 탐색 → Amazon Neptune
- C. 기존 Cassandra 앱을 서버 관리 없이 → Amazon DocumentDB
- D. 상품 전문 검색(오타 허용, 형태소 분석) → Amazon OpenSearch Service

<details><summary>정답과 해설</summary>

**C**가 틀린 짝이다. Cassandra(CQL) 호환은 **Amazon Keyspaces**이고, DocumentDB는 **MongoDB** 호환 문서 DB다.
- A: 열 기반 데이터 웨어하우스(OLAP) → Redshift. 맞다.
- B: 그래프 탐색 → Neptune. 맞다.
- D: 전문 검색 → OpenSearch. 맞다.
</details>

---

**13.** 세션 데이터를 API 서버 메모리에 두었더니 Auto Scaling으로 서버가 줄 때마다 사용자가 로그아웃된다. 세션은 고가용성이 필요하고, 노드 하나가 죽어도 세션이 남아 있기를 원한다. 무엇을 고르나?

- A. ALB 스티키 세션
- B. ElastiCache for Memcached 클러스터(노드 3개)
- C. ElastiCache for Valkey 복제 그룹(복제본 + 자동 장애 조치 + Multi-AZ)
- D. 각 서버의 EBS 볼륨에 세션 파일 저장

<details><summary>정답과 해설</summary>

**C.** Valkey/Redis OSS 복제 그룹은 복제본으로 데이터를 복제하고 기본 노드가 죽으면 자동 장애 조치한다(lab09의 `test-failover`).
- A: 서버가 사라지면 그 서버에 붙어 있던 세션도 사라진다.
- B: Memcached는 복제가 없어 노드가 죽으면 그 노드의 세션이 사라진다(lab09: Memcached 복제 그룹은 생성 자체가 거부됨).
- D: 서버마다 따로 저장돼 서버가 바뀌면 세션을 못 찾는다.
</details>
