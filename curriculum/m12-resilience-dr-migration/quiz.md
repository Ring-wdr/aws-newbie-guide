# M12 퀴즈 — 고가용성·DR·마이그레이션

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 12문항 중 10문항 이상 맞히면 통과.

---

**1.** TodayOrder의 프라이빗 서브넷은 AZ-a와 AZ-b에 있고, 두 서브넷 모두 AZ-a의 NAT 게이트웨이 하나로 외부 결제 API를 호출한다. AZ-a 장애에도 AZ-b의 서버가 결제 API를 계속 호출하게 하려면?

- A. NAT 게이트웨이의 인스턴스 크기를 키운다
- B. AZ-b의 퍼블릭 서브넷에 NAT 게이트웨이를 하나 더 만들고, AZ-b 프라이빗 서브넷의 라우팅 테이블이 그 NAT를 가리키게 한다
- C. AZ-b의 서버에 탄력적 IP를 붙인다 (서브넷은 프라이빗 그대로)
- D. 인터넷 게이트웨이를 하나 더 붙인다

<details><summary>정답과 해설</summary>

**B.** NAT 게이트웨이는 AZ 단위 리소스다. AZ마다 하나씩 두고 각 AZ의 프라이빗 라우팅 테이블이 자기 AZ의 NAT를 쓰게 해야 AZ 장애가 다른 AZ로 번지지 않는다. A: NAT 게이트웨이에는 크기 선택이 없고 가용성과도 무관하다. C: 프라이빗 서브넷에는 인터넷 게이트웨이로 가는 경로가 없으므로 공인 IP를 붙여도 밖으로 나가지 못한다. D: VPC에는 인터넷 게이트웨이를 하나만 붙일 수 있고, IGW는 원래 고가용성이다.
</details>

---

**2.** 주문 DB(RDS MySQL)의 AZ 장애 시 수동 개입 없이 1~2분 안에 쓰기가 재개돼야 한다. 읽기 성능 문제는 없다. 무엇을 하는가?

- A. 같은 AZ에 읽기 전용 복제본을 만든다
- B. Multi-AZ 배포로 바꾼다
- C. 매시간 스냅샷을 찍는다
- D. 다른 리전에 읽기 전용 복제본을 만든다

<details><summary>정답과 해설</summary>

**B.** Multi-AZ는 다른 AZ에 동기 복제 대기를 두고, 장애 시 DNS를 대기로 자동 전환한다(보통 60~120초). A: 같은 AZ에 두면 AZ 장애를 견디지 못하고, 읽기 복제본은 자동 장애 조치가 아니다(수동 승격). C는 복원에 시간이 걸리고 마지막 스냅샷 이후 데이터를 잃는다. D는 리전 DR용이며 승격이 수동이라 요구에 비해 과하다.
</details>

---

**3.** 사내 문서 시스템의 요구: RTO 24시간, RPO 24시간, 비용은 최소. 리전 장애 대비책으로 가장 적절한 것은?

- A. 다른 리전에 웜 스탠바이
- B. 매일 백업을 다른 리전으로 복사하고, 장애 시 IaC로 인프라를 만들어 복원
- C. 두 리전 액티브-액티브
- D. 다른 리전에 Aurora Global Database 보조 클러스터

<details><summary>정답과 해설</summary>

**B.** 백업·복원 전략은 RTO·RPO가 시간 단위일 때 가장 싸다. A·C·D는 모두 요구를 만족하지만 평소 DR 리전에 리소스를 계속 켜 두거나 연속 복제 비용을 내므로 "비용 최소"에 어긋난다.
</details>

---

**4.** 주문 API의 요구: RPO 1분 이하, RTO 30분, DR 리전의 평소 비용은 최소. 데이터는 Aurora MySQL에 있다. 가장 비용 효율적인 설계는?

- A. Aurora Global Database로 DR 리전에 보조 클러스터를 두고, 앱 서버용 시작 템플릿·ASG는 용량 0으로 준비해 둔다(파일럿 라이트)
- B. DR 리전에 앱 서버 20대를 항상 켜 둔다
- C. 하루 한 번 스냅샷을 DR 리전으로 복사한다
- D. 같은 리전 Multi-AZ만 쓴다

<details><summary>정답과 해설</summary>

**A.** 데이터는 Aurora Global Database로 연속 복제(복제 지연 보통 1초 미만)해 RPO를 만족하고, 앱 서버는 평소 꺼 두었다가 장애 때 ASG 용량을 올려 30분 안에 복구한다. B는 액티브-액티브 수준의 비용이다. C는 RPO 24시간이라 요구를 깬다. D는 리전 장애를 대비하지 못한다.
</details>

---

**5.** 결제 승인 서비스는 리전 장애 시 **몇 분 안에, 줄어든 용량으로라도 즉시** 요청을 처리해야 한다. 파일럿 라이트와 웜 스탠바이 중 무엇이고, 왜인가?

- A. 파일럿 라이트 — 데이터가 복제되어 있으므로
- B. 웜 스탠바이 — DR 리전에 작은 규모의 전체 스택이 항상 동작해 바로 트래픽을 받을 수 있으므로
- C. 백업·복원 — 가장 싸므로
- D. 어느 것이든 같다

<details><summary>정답과 해설</summary>

**B.** 판별 질문은 "DR 쪽이 지금 바로 요청을 받을 수 있나"다. 파일럿 라이트(A)는 데이터는 있지만 앱 서버를 켜고 늘리는 시간이 필요해 "즉시"를 만족하기 어렵다. C는 RTO가 시간 단위다. D는 틀렸다.
</details>

---

**6.** 규제 때문에 모든 RDS·DynamoDB·EBS 백업을 매일 만들어 **다른 계정·다른 리전**에 7년 보관하고, 어떤 관리자(루트 포함)도 기간 안에 삭제할 수 없어야 한다. 가장 적은 운영 노력으로 충족하는 방법은?

- A. 서비스마다 Lambda로 스냅샷을 찍어 S3에 복사한다
- B. AWS Backup 계획(일일 규칙 + 교차 계정·교차 리전 복사)과 대상 볼트에 규정 준수 모드 Vault Lock
- C. 각 서비스의 자동 백업 보존 기간을 최대로 늘린다
- D. AWS Backup 계획 + 거버넌스 모드 Vault Lock

<details><summary>정답과 해설</summary>

**B.** AWS Backup은 여러 서비스의 백업을 하나의 계획으로 일정·보관·복사까지 관리하고, 규정 준수 모드 Vault Lock은 유예 기간이 지나면 루트 사용자도 해제할 수 없다. A는 직접 만들고 운영할 것이 많다. C는 서비스별 최대 보존 기간(예: RDS 자동 백업 35일)이 7년에 못 미치고 교차 계정 요구도 없다. D의 거버넌스 모드는 권한 있는 사용자가 잠금을 풀 수 있다.
</details>

---

**7.** AWS Backup 계획에 태그 기반 리소스 할당을 추가하는데 `IAM Role cannot be assumed by AWS Backup` 오류가 났다. 원인은?

- A. 대상 리소스에 태그가 없다
- B. 지정한 IAM 역할의 신뢰 정책에 `backup.amazonaws.com` 서비스 주체가 없다
- C. 백업 볼트가 암호화되지 않았다
- D. 백업 계획의 cron 식이 잘못되었다

<details><summary>정답과 해설</summary>

**B.** AWS Backup은 지정한 역할을 맡아(AssumeRole) 작업하므로, 역할의 신뢰 정책이 `backup.amazonaws.com`을 허용해야 한다(lab03에서 재현). A는 오류가 아니라 대상이 0개가 될 뿐이다. C: 볼트는 항상 KMS로 암호화된다. D는 계획 생성 단계의 다른 검증 오류다.
</details>

---

**8.** 사무실 서버실의 MySQL(1 TB, 24시간 주문 쓰기)을 Amazon Aurora MySQL로 옮긴다. 다운타임은 몇 분 이내여야 한다. 가장 적절한 방법은?

- A. mysqldump로 내보내 S3에 올리고 Aurora로 가져온다
- B. AWS DMS로 full load + CDC 작업을 구성하고, 지연이 거의 0이 되면 앱의 연결 대상을 바꾼다
- C. AWS SCT로 스키마를 변환한 뒤 DMS full load만 한다
- D. MGN으로 DB 서버를 통째로 옮긴다

<details><summary>정답과 해설</summary>

**B.** CDC가 전체 로드 중·후의 변경을 계속 적용하므로 원본을 운영하면서 따라잡고 짧은 전환만 하면 된다. A는 덤프·복원 동안 쓰기를 멈춰야 하거나 그동안의 변경을 잃는다. C: 같은 MySQL 계열이라 SCT가 필요 없고, full load만으로는 변경을 따라잡지 못한다. D는 EC2 위의 MySQL로 옮길 뿐 관리형 Aurora가 아니다(Rehost, Replatform이 아님).
</details>

---

**9.** Oracle 데이터베이스를 Aurora PostgreSQL로 옮기려 한다. 저장 프로시저가 많다. 어떤 조합이 맞나?

- A. DMS만 사용
- B. AWS SCT(또는 DMS Schema Conversion)로 스키마·코드를 변환하고, DMS로 데이터를 옮긴다
- C. MGN으로 Oracle 서버를 옮긴다
- D. DataSync로 데이터 파일을 복사한다

<details><summary>정답과 해설</summary>

**B.** 이종 엔진 이전은 "구조는 SCT, 데이터는 DMS"가 기본 공식이다. A: DMS는 프로시저 등 코드 객체를 변환하지 않는다. C는 엔진을 바꾸지 않는 Rehost다. D는 파일 전송 서비스로 DB 엔진 변환과 무관하다.
</details>

---

**10.** 코드를 수정할 수 없는 레거시 Windows 애플리케이션 서버 40대를 최소한의 다운타임으로 AWS로 옮겨야 한다. 무엇을 쓰나?

- A. AWS Application Migration Service(MGN)
- B. AWS DMS
- C. Elastic Beanstalk로 다시 배포
- D. AWS DataSync

<details><summary>정답과 해설</summary>

**A.** MGN은 서버 디스크를 블록 단위로 연속 복제한 뒤 짧은 전환으로 EC2에서 띄우는 Rehost 도구다. B는 데이터베이스용이다. C는 코드를 다시 배포해야 하므로 "수정 불가"와 맞지 않는다. D는 파일 전송용이다.
</details>

---

**11.** 이전 계획을 세우려고, 온프레미스 서버 300대의 CPU·메모리 사용률과 **서버 간 네트워크 의존성**을 파악하려 한다. 어떤 서비스의 용도에 해당하나?

- A. AWS Application Discovery Service
- B. AWS Migration Hub만으로 충분
- C. AWS Config
- D. Amazon Inspector

<details><summary>정답과 해설</summary>

**A.** Application Discovery Service가 서버 사양·사용률과 프로세스·네트워크 연결을 수집한다(시험이 묻는 용도). 단, AWS는 2025-11-07부터 이 서비스를 신규 고객에게 열지 않고 AWS Transform을 후속으로 안내한다. B: Migration Hub는 진행 상황 추적이지 수집 도구가 아니다. C는 AWS 리소스 구성 기록, D는 취약점 스캔이다.
</details>

---

**12.** 이 모듈의 다중 리전 DR 실습(lab02)에서 마지막 동기화 이후 서울에만 쓰인 주문 2건이 장애 조치 후 도쿄에 없었다. 실제 AWS에서 이 손실(RPO)을 초 단위로 줄이는 방법으로 가장 적절한 것은?

- A. 동기화 스크립트를 1시간마다 실행한다
- B. DynamoDB 전역 테이블과 S3 교차 리전 복제(필요하면 RTC)를 써서 쓰기 직후 복제되게 한다
- C. 서울 리전에 Multi-AZ를 켠다
- D. 도쿄 리전에 앱 서버를 더 많이 켜 둔다

<details><summary>정답과 해설</summary>

**B.** RPO는 복제 주기가 정한다. 관리형 연속 복제(DynamoDB 전역 테이블은 보통 1초 안쪽으로 복제, S3 CRR은 비동기 복제이며 RTC는 99.9%를 15분 안에 보장)를 쓰면 주기적 배치 복사보다 손실 폭이 훨씬 작다. A는 RPO를 1시간으로 만들 뿐이다. C는 같은 리전 안의 AZ 장애 대비다. D는 RTO(복구 속도)에 영향을 줄 뿐 데이터 손실(RPO)은 줄이지 못한다.
</details>
