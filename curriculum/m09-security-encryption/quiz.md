# M09 퀴즈 — 보안 서비스와 암호화

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 12문항 중 10문항(80%) 이상 맞히면 다음 모듈로.

---

**1.** 영수증 버킷의 객체를 암호화해야 한다. 감사인이 "누가 언제 어떤 키로 복호화했는지 기록이 남아야 하고, 필요하면 키를 꺼서 모든 영수증 접근을 즉시 막을 수 있어야 한다"고 요구한다.

- A. SSE-KMS(고객 관리형 키)
- B. SSE-S3
- C. SSE-C
- D. 버킷 버전 관리

<details><summary>정답과 해설</summary>

**A.** KMS 키 사용은 CloudTrail에 기록되고, 고객 관리형 키는 키 정책·비활성화로 접근을 통제할 수 있다. B는 키 사용 감사·통제가 없다. C는 고객이 키를 요청마다 보내므로 AWS 쪽 감사·중앙 비활성화가 없다. D는 암호화가 아니다.
</details>

---

**2.** 주문 서비스가 50 MB짜리 일별 정산 파일을 KMS 키로 보호하려 한다. 개발자가 `kms.encrypt()`로 파일을 통째로 보냈더니 실패했다. 올바른 방법은?

- A. KMS 요청 한도를 늘린다
- B. 파일을 4 KB 조각으로 나눠 각각 `Encrypt`한다
- C. `GenerateDataKey`로 데이터 키를 받아 로컬에서 암호화하고, 암호화된 데이터 키를 파일과 함께 저장한다
- D. CloudHSM으로 옮긴다

<details><summary>정답과 해설</summary>

**C.** 봉투 암호화다. `Encrypt`는 4,096바이트까지만 받는다(lab01 5단계). B는 요청이 수만 건이 되어 느리고 비싸며 의도된 사용법이 아니다. A는 크기 한도와 무관하다. D는 요구와 무관하게 비용·운영 부담만 늘린다.
</details>

---

**3.** 금융 규제 때문에 "암호 키는 단일 테넌트 전용 하드웨어에 두고, AWS 직원을 포함해 고객 외에는 아무도 키에 접근할 수 없어야 한다"는 요구가 있다.

- A. KMS 고객 관리형 키
- B. AWS CloudHSM
- C. KMS AWS 관리형 키
- D. Secrets Manager

<details><summary>정답과 해설</summary>

**B.** 전용·단일 테넌트 HSM과 고객 단독 키 통제는 CloudHSM이다(필요하면 KMS 사용자 지정 키 저장소로 KMS와 연결). A·C는 다중 테넌트 관리형 서비스다. D는 비밀 저장소이지 HSM이 아니다.
</details>

---

**4.** 운영자가 실수로 주문 DB 스냅샷을 암호화한 KMS 키에 `ScheduleKeyDeletion`(30일)을 실행했다. 이틀 뒤 발견했다. 어떻게 하나?

- A. 복구 불가 — 새 키로 다시 암호화한다
- B. 키 교체(`RotateKeyOnDemand`)를 실행한다
- C. AWS Support에 키 재료 복구를 요청한다
- D. `CancelKeyDeletion` 후 `EnableKey`

<details><summary>정답과 해설</summary>

**D.** 대기 기간 안에는 취소할 수 있고, 취소된 키는 `Disabled` 상태이므로 다시 켠다(lab01 7단계). A는 대기 기간이 지난 뒤의 이야기다. C는 삭제 후에는 AWS도 복구할 수 없다. B는 `PendingDeletion` 상태의 키에 쓸 수 없고(`KMSInvalidStateException`) 문제를 풀지 못한다.
</details>

---

**5.** 운영 RDS의 마스터 비밀번호를 30일마다 자동으로 바꾸고, 애플리케이션은 코드 변경 없이 항상 최신 비밀번호를 읽어야 한다.

- A. Parameter Store SecureString + 30일마다 사람이 갱신
- B. Secrets Manager + 자동 교체, 앱은 `AWSCURRENT` 조회
- C. 비밀번호를 Lambda 환경 변수에 넣고 KMS로 암호화
- D. IAM 정책으로 비밀번호를 강제 변경

<details><summary>정답과 해설</summary>

**B.** 자동 교체는 Secrets Manager의 핵심 기능이며 RDS와 연동된다. 앱은 `AWSCURRENT`를 읽는다. A는 교체가 수동이다. C는 교체 기능이 없고 배포마다 바꿔야 한다. D는 IAM 사용자 비밀번호 정책이지 DB 비밀번호가 아니다.
</details>

---

**6.** 개발·스테이징·운영 환경의 설정값 수백 개를 `/todayorder/<환경>/…` 구조로 관리하고, 서비스는 시작할 때 자기 환경의 값만 한 번에 읽는다. 일부 값은 API 키다. 비용은 최소로.

- A. Secrets Manager 비밀 수백 개
- B. S3 버킷에 JSON 파일
- C. Parameter Store(Standard) 계층 + API 키는 SecureString, `GetParametersByPath --recursive`
- D. DynamoDB 테이블

<details><summary>정답과 해설</summary>

**C.** 계층 조회와 무료 Standard 티어, SecureString이 요구와 맞는다(lab05). A는 비밀당 월 요금이 들고 계층 조회가 핵심 기능이 아니다. B·D는 접근 제어·암호화·버전 관리를 직접 만들어야 한다.
</details>

---

**7.** 보안 그룹에 0.0.0.0/0으로 22번 포트가 열린 것을 찾았다. 보안팀은 "**누가** 열었는지"와 "**앞으로 이런 설정이 생기면 자동으로 닫히게**"를 원한다.

- A. 누가: CloudTrail / 자동: Config 규칙 + 자동 수정(SSM Automation)
- B. 누가: Config / 자동: CloudTrail
- C. 누가: GuardDuty / 자동: Inspector
- D. 누가: VPC Flow Logs / 자동: WAF

<details><summary>정답과 해설</summary>

**A.** API 호출의 주체는 CloudTrail(`AuthorizeSecurityGroupIngress` 이벤트), 구성 규칙 위반의 지속 감시와 자동 수정은 Config(lab08에서 자동 수정이 실제로 실행됨). B는 역할이 뒤바뀌었다. C의 GuardDuty는 위협 탐지, Inspector는 취약점 스캔이다. D의 Flow Logs는 트래픽 기록이지 설정 변경자가 아니고, WAF는 HTTP 필터다.
</details>

---

**8.** 조직의 모든 계정·리전에서 발생하는 API 활동을 7년간 보관하고, 로그가 삭제·변조되지 않았음을 증명해야 한다.

- A. 각 계정의 CloudTrail 이벤트 기록
- B. CloudWatch Logs 보존 기간 무제한
- C. Config 집계자
- D. 조직 추적(멀티 리전) → 별도 로그 계정의 S3 버킷, 로그 파일 무결성 검증 켜기, S3 객체 잠금

<details><summary>정답과 해설</summary>

**D.** 조직 추적이 모든 계정·리전을 모으고, 무결성 검증 다이제스트로 변조를 증명하며, 객체 잠금으로 삭제를 막는다. A는 90일이고 계정별이다. C는 구성 항목이지 API 활동 로그가 아니다. B는 무결성 증명이 없고 조직 단위 수집을 따로 만들어야 한다.
</details>

---

**9.** TodayOrder EC2 인스턴스가 암호 화폐 채굴 풀 도메인을 조회하기 시작했다. 이를 **에이전트 설치 없이** 자동으로 탐지하려면?

- A. Amazon Inspector
- B. Amazon GuardDuty
- C. Amazon Macie
- D. AWS Config

<details><summary>정답과 해설</summary>

**B.** GuardDuty는 DNS 로그·VPC Flow Logs·CloudTrail을 분석해 `CryptoCurrency:EC2/BitcoinTool.B!DNS` 같은 결과를 낸다(lab09 샘플). A는 취약점 스캔, C는 S3 민감 데이터, D는 구성 규정 평가다.
</details>

---

**10.** 영수증 CSV가 쌓이는 S3 버킷 수백 개 중 어디에 고객 카드 번호가 평문으로 들어 있는지 찾아야 한다.

- A. Macie
- B. GuardDuty S3 보호
- C. Inspector
- D. Security Hub

<details><summary>정답과 해설</summary>

**A.** S3 객체 내용에서 민감 데이터(PII·금융 정보)를 찾는 서비스가 Macie다. B는 S3에 대한 의심스러운 **접근 행동**을 탐지한다. C는 취약점 스캔이다. D는 결과를 모을 뿐 스스로 내용을 검사하지 않는다.
</details>

---

**11.** CloudFront 배포에 `shop.todayorder.example` 도메인으로 HTTPS를 붙이려 한다. 서울 리전에서 ACM 인증서를 발급받았는데 CloudFront 설정 화면에 보이지 않는다.

- A. 인증서를 ACM에서 내보내 CloudFront에 업로드한다
- B. 인증서를 IAM에 업로드한다
- C. us-east-1 리전에서 ACM 인증서를 다시 요청한다
- D. ALB를 앞에 두고 서울 인증서를 쓴다

<details><summary>정답과 해설</summary>

**C.** CloudFront는 us-east-1의 ACM 인증서만 쓴다. A는 ACM 발급 인증서 내보내기가 기본 기능이 아니고(내보내기 가능 옵션은 별도) 필요도 없다. B는 레거시 방식으로 ACM 자동 갱신을 잃는다. D는 문제를 우회할 뿐 CloudFront 도메인 HTTPS를 해결하지 못한다.
</details>

---

**12.** 해킹된 EC2가 공격자 서버로 데이터를 빼돌리는 것을 막기 위해, VPC에서 나가는 HTTPS를 결제 대행사와 AWS API 도메인으로만 제한하고 싶다.

- A. 보안 그룹 아웃바운드에 도메인 이름을 넣는다
- B. NACL 아웃바운드 거부 규칙
- C. WAF Web ACL을 EC2에 연결한다
- D. AWS Network Firewall 상태 저장 도메인 허용 목록(SNI)

<details><summary>정답과 해설</summary>

**D.** Network Firewall은 TLS SNI·HTTP Host로 도메인을 판별해 허용 목록 밖을 막는다(lab10). A·B의 보안 그룹·NACL은 IP·포트만 다루고 도메인을 모른다. C의 WAF는 들어오는 HTTP 요청을 걸러내는 L7 필터이고 EC2에 직접 붙일 수도 없다.
</details>
