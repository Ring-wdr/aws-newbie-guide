# M04 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(14문항 중 12문항) 맞히면 다음 모듈로.

---

**1.** TodayOrder의 상품 이미지는 등록 후 첫 2주 동안 많이 조회되고, 이후 조회 빈도가 상품마다 제각각이다(어떤 상품은 1년 뒤 갑자기 인기를 끈다). 운영팀은 규칙을 관리하고 싶지 않고, 조회될 때 지연이 생기면 안 된다. 가장 비용 효율적인 선택은?

- A. 수명 주기로 30일 뒤 Standard-IA로 전환
- B. S3 Intelligent-Tiering (선택형 아카이브 계층은 켜지 않음)
- C. 수명 주기로 30일 뒤 Glacier Flexible Retrieval로 전환
- D. 처음부터 One Zone-IA에 저장

<details><summary>정답과 해설</summary>

**B.** 접근 패턴을 예측할 수 없고 규칙 관리를 원하지 않으면 Intelligent-Tiering이다. 다시 인기를 끌면 자동으로 Frequent 계층으로 돌아오고 검색 요금도 없다. 기본 계층은 모두 밀리초 응답이다. A는 다시 인기를 끈 상품을 IA에서 많이 읽게 되어 검색 요금이 나오고, 상품별 패턴 차이를 반영하지 못한다. C는 복원이 필요해 "지연이 생기면 안 된다"를 위반한다. D는 AZ 하나에만 저장해 원본 이미지를 잃을 위험이 있고, 첫 2주의 잦은 조회에 검색 요금이 붙는다.
</details>

---

**2.** 회계 감사용 거래 로그를 10년 보관해야 한다. 감사는 1년에 한 번이고 자료 요청 후 3일 안에만 제출하면 된다. 가장 저렴한 저장 방법은?

- A. S3 Glacier Instant Retrieval
- B. S3 Glacier Flexible Retrieval
- C. S3 Glacier Deep Archive
- D. S3 Standard-IA + 수명 주기로 10년 뒤 삭제

<details><summary>정답과 해설</summary>

**C.** Deep Archive는 가장 싼 클래스이고, 표준 검색 12시간 이내·대량 검색 48시간 이내라 "3일 안"을 만족한다. 1년에 한 번이므로 검색 요금보다 저장 요금이 중요하다. A·B도 요건은 만족하지만 저장 단가가 더 비싸다. D는 훨씬 비싸다.
</details>

---

**3.** 개발자가 수명 주기 규칙 "업로드 7일 후 `STANDARD_IA`로 전환"을 로컬 에뮬레이터에서 테스트해 통과시킨 뒤 실제 계정에 배포했다. 무슨 일이 일어나는가?

- A. 7일 뒤 정상적으로 전환된다
- B. `PutBucketLifecycleConfiguration`이 `InvalidArgument`로 실패한다
- C. 규칙은 저장되지만 30일이 되어야 전환된다
- D. 규칙은 저장되지만 128 KB 미만 객체만 전환된다

<details><summary>정답과 해설</summary>

**B.** S3는 Standard-IA·One Zone-IA 전환을 생성 후 30일 이상으로만 허용하고, 그보다 짧으면 설정 자체를 거부한다. 에뮬레이터 1.0.322는 이 검증을 하지 않는다(lab02). A·C는 "저장된다"는 전제가 틀렸다. D는 거꾸로다. 기본값은 128 KB **미만** 객체를 전환하지 **않는다**.
</details>

---

**4.** 1,000만 개의 4 KB 이벤트 파일을 "자주 안 읽으니까" Standard에서 Standard-IA로 옮기자는 제안이 나왔다. 가장 적절한 판단은?

- A. 저장 단가가 낮아지므로 옮긴다
- B. 128 KB 최소 과금 크기 때문에 저장 요금이 오히려 크게 늘어난다. Standard에 두거나 큰 객체로 묶는다
- C. One Zone-IA로 옮기면 최소 과금 크기가 없으므로 더 싸다
- D. Glacier Deep Archive로 옮기면 메타데이터 오버헤드가 없으므로 가장 싸다

<details><summary>정답과 해설</summary>

**B.** IA는 객체를 최소 128 KB로 과금한다. 4 KB 객체는 32배 크기로 과금되어 단가 차이(약 절반)를 크게 넘는다(워크시트 W3). C: One Zone-IA도 128 KB 최소 과금이 있다. D: Glacier Flexible·Deep Archive는 객체당 40 KB 메타데이터 과금이 붙어 작은 객체에 오히려 불리하다(워크시트 W4).
</details>

---

**5.** 신입이 영수증 버킷에서 `aws s3 rm s3://todayorder-receipts/2026/ --recursive`를 잘못 실행했다. 버킷은 버전 관리가 켜져 있다. 영수증을 되살리는 가장 빠른 방법은?

- A. AWS Support에 복구 요청
- B. 각 키의 최신 버전인 **삭제 마커를 삭제**한다
- C. 수명 주기 규칙으로 이전 버전을 현재 버전으로 승격
- D. 복제 대상 버킷에서 되가져와야만 한다

<details><summary>정답과 해설</summary>

**B.** 버전 관리 버킷에서 버전 ID 없이 삭제하면 데이터는 그대로 두고 삭제 마커만 쌓인다. 삭제 마커를 버전 지정 삭제하면 바로 아래 버전이 다시 최신이 된다(lab03 7단계). A: AWS는 고객 데이터를 대신 복구해 주지 않는다. C: 그런 수명 주기 동작은 없다. D: 가능은 하지만 가장 빠른 방법이 아니고, 삭제 마커 복제를 켰다면 대상에도 마커가 생겼을 수 있다.
</details>

---

**6.** 금융 규정상 거래 증빙은 5년 동안 **어떤 사용자도, 루트 사용자도** 수정·삭제할 수 없어야 한다. 무엇을 써야 하는가?

- A. 버전 관리 + MFA Delete
- B. 버킷 정책으로 `s3:DeleteObject` 명시적 Deny
- C. S3 객체 잠금 거버넌스 모드, 보존 5년
- D. S3 객체 잠금 규정 준수 모드, 보존 5년

<details><summary>정답과 해설</summary>

**D.** 규정 준수(Compliance) 모드는 보존 기간 동안 루트 포함 누구도 객체 버전을 지우거나 보존 기간을 줄일 수 없다(lab03 13단계). C: 거버넌스 모드는 `s3:BypassGovernanceRetention` 권한이 있으면 우회할 수 있다(lab03 12단계). A: MFA를 가진 루트는 지울 수 있다. B: 정책을 바꿀 권한이 있는 사람이 Deny를 지우면 끝이다.
</details>

---

**7.** 서울 리전 버킷의 상품 이미지를 버지니아 리전 버킷으로 DR용 복제를 설정했다. 그런데 설정 전부터 있던 이미지 50만 개가 대상 버킷에 없다. 원인과 해결책은?

- A. 대상 버킷의 버전 관리가 꺼져 있다. 켜면 자동으로 복제된다
- B. 복제 규칙은 설정 이후 새로 쓰인 객체만 복제한다. **S3 Batch Replication**으로 기존 객체를 복제한다
- C. 복제 역할에 권한이 없다. 권한을 주면 기존 객체도 곧 복제된다
- D. CRR은 이미지 파일을 복제하지 않는다

<details><summary>정답과 해설</summary>

**B.** 라이브 복제는 규칙을 건 뒤의 새 객체만 대상이다(lab04 6단계에서 `old.jpg`가 넘어가지 않았다). 기존 객체는 Batch Replication으로 옮긴다. A: 버전 관리는 복제 설정의 전제 조건이지만, 켠다고 기존 객체가 복제되지는 않는다. C: 권한 문제라면 새 객체도 복제되지 않았을 것이다. D: 사실이 아니다.
</details>

---

**8.** 보안팀 요구: "영수증 버킷의 모든 객체는 우리가 관리하는 키로 암호화되어야 하고, 누가 언제 어떤 키로 복호화했는지 감사할 수 있어야 한다. KMS 요청 비용도 최소화하라." 가장 알맞은 조합은?

- A. SSE-S3 + CloudTrail
- B. SSE-KMS(고객 관리형 키) + S3 버킷 키
- C. SSE-C + 버킷 정책
- D. 클라이언트 측 암호화 + S3 Transfer Acceleration

<details><summary>정답과 해설</summary>

**B.** 고객 관리형 KMS 키는 키 정책으로 접근을 통제하고, 키 사용이 CloudTrail에 남는다. 버킷 키는 KMS 호출 수를 줄여 비용을 낮춘다(lab05 6단계). A: SSE-S3의 키는 S3가 관리해 키 단위 감사·통제가 없다. C: SSE-C는 고객이 키를 요청마다 보내야 하고, KMS 감사와 무관하다. D: Transfer Acceleration은 암호화와 무관하다.
</details>

---

**9.** 모바일 앱 사용자가 프로필 사진(최대 20 MB)을 올린다. 지금은 앱 → API 서버 → S3로 올려서 API 서버의 네트워크와 메모리가 버거워한다. 보안을 유지하면서 서버 부담을 없애는 방법은?

- A. 버킷을 퍼블릭 쓰기로 열고 앱이 직접 올린다
- B. 앱에 IAM 사용자 액세스 키를 넣어 배포한다
- C. API 서버가 **미리 서명된 PUT URL**을 발급하고 앱이 S3에 직접 올린다
- D. S3 Transfer Acceleration을 켠다

<details><summary>정답과 해설</summary>

**C.** API는 짧은 유효 기간의 서명 URL만 발급하고 파일은 S3로 바로 간다. 서명에 키·Content-Type이 묶여 다른 객체나 형식으로 바꿀 수 없다(lab06·receipt_upload_service.py). A: 누구나 아무 파일이나 올릴 수 있어 위험하다(BPA가 막기도 한다). B: 앱에 장기 자격 증명을 넣으면 유출된다. D: 업로드 속도 개선책일 뿐, 서버 경유 문제는 그대로다.
</details>

---

**10.** 상품 이미지가 S3에 올라오면 썸네일 작업 큐(SQS)에 메시지가 가도록 이벤트 알림을 설정하려 했는데 `InvalidArgument: Unable to validate the following destination configurations` 오류가 났다. 무엇을 고쳐야 하는가?

- A. 큐를 FIFO로 바꾼다
- B. 큐 정책에 `s3.amazonaws.com`의 `sqs:SendMessage`를 허용한다(`aws:SourceArn`으로 버킷 한정)
- C. 버킷의 버전 관리를 켠다
- D. 버킷 정책에 `sqs:SendMessage`를 허용한다

<details><summary>정답과 해설</summary>

**B.** S3는 설정 시점에 대상 큐로 보낼 권한이 있는지 검증한다. 권한은 **큐 쪽 리소스 정책**에 있어야 한다(lab09 1~3단계). A: FIFO 큐는 S3 알림의 직접 대상이 될 수 없다. C: 이벤트 알림과 무관하다. D: 버킷 정책은 S3 버킷에 대한 접근을 정할 뿐, S3가 SQS에 보낼 권한을 주지 않는다.
</details>

---

**11.** 리눅스 EC2 웹 서버 6대(2개 AZ)가 사용자가 올린 파일을 같은 디렉터리에서 읽고 써야 한다. 기존 앱은 POSIX 파일 경로를 쓰고 코드 수정이 어렵다. 용량은 예측할 수 없다. 무엇을 쓰는가?

- A. EBS gp3 볼륨 하나를 6대에 연결
- B. Amazon EFS (리전형), AZ마다 마운트 타깃
- C. FSx for Windows File Server
- D. 각 서버의 인스턴스 스토어

<details><summary>정답과 해설</summary>

**B.** EFS는 NFS로 여러 AZ의 리눅스 인스턴스가 동시에 마운트하고, 용량이 자동으로 늘어난다. AZ마다 마운트 타깃을 둔다(lab10). A: EBS는 기본적으로 한 인스턴스에, 같은 AZ에서만 붙는다(Multi-Attach는 io1/io2·같은 AZ·클러스터 인식 파일 시스템이 필요). C: SMB·Windows용이다. D: 서버마다 따로이고 인스턴스가 멈추면 사라진다.
</details>

---

**12.** 연구팀이 S3에 있는 수백 TB의 학습 데이터를 GPU 클러스터에서 고속 병렬 파일 시스템으로 읽고, 결과를 다시 S3에 쓰려 한다. 가장 알맞은 것은?

- A. Amazon EFS Max I/O
- B. FSx for Lustre (S3 데이터 저장소 연결)
- C. FSx for NetApp ONTAP
- D. S3 File Gateway

<details><summary>정답과 해설</summary>

**B.** FSx for Lustre는 HPC·ML용 고성능 병렬 파일 시스템이고, S3 버킷과 연결해 객체를 파일로 보여 주고 결과를 S3로 내보낼 수 있다. A: EFS는 범용 NFS로 이런 대규모 병렬 처리량에 맞춰져 있지 않고, Max I/O는 이전 세대 모드다. C: 멀티 프로토콜·NetApp 기능이 필요할 때 쓴다. D: 사내(온프레미스) 앱을 위한 하이브리드 통로다.
</details>

---

**13.** 매장 POS 서버들의 백업 소프트웨어는 테이프 라이브러리에만 백업할 수 있다. 물리 테이프를 없애고 백업을 AWS에 장기 보관하고 싶다. 소프트웨어는 바꿀 수 없다. 무엇을 쓰는가?

- A. DataSync
- B. Storage Gateway — Tape Gateway
- C. Storage Gateway — Volume Gateway(저장 모드)
- D. S3 File Gateway

<details><summary>정답과 해설</summary>

**B.** Tape Gateway는 iSCSI 가상 테이프 라이브러리를 제공해 기존 백업 소프트웨어가 그대로 쓰고, 보관된 테이프는 Glacier 계열에 저장된다. A: DataSync는 파일 이전 도구로 테이프 인터페이스가 없다. C: 블록 볼륨용이다. D: 파일(NFS/SMB)용이다.
</details>

---

**14.** 회사 데이터 센터의 NAS 60 TB를 S3로 옮겨야 한다. 회선은 1 Gbps이고 다른 업무와 함께 쓰므로 절반 정도만 쓸 수 있다. 3주 안에 끝내고, 이전 중 바뀐 파일도 반영하고, 전송 무결성을 검증해야 한다. 가장 알맞은 방법은?

- A. `aws s3 sync`를 사내 서버 한 대에서 실행
- B. DataSync 에이전트를 설치하고 대역폭 제한·스케줄을 건 DataSync 작업
- C. Transfer Family SFTP 서버로 업로드
- D. S3 Transfer Acceleration을 켜고 콘솔에서 업로드

<details><summary>정답과 해설</summary>

**B.** 500 Mbps로 60 TB는 60 × 8 × 10^12 ÷ (5 × 10^8) = 9.6 × 10^5 초 ≈ 11일이라 3주 안에 온라인 이전이 가능하다. DataSync는 증분 동기화, 대역폭 제한, 무결성 검증, 재시도를 관리형으로 제공한다. A: 가능은 하지만 검증·재시도·병렬화·모니터링을 직접 해야 한다. C: 파트너 파일 교환용이지 대량 이전 도구가 아니다. D: 콘솔로 60 TB는 현실적이지 않고 가속은 원격지 업로드용이다.
</details>
