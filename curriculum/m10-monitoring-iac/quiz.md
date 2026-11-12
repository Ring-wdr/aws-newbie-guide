# M10 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(12문항 중 10문항) 맞히면 다음 모듈로.

---

**1.** TodayOrder의 API 서버(EC2, Amazon Linux)가 가끔 메모리 부족으로 죽는다. 메모리 사용률이 85%를 넘으면 당직자에게 알리고 싶다. 가장 적은 작업으로 맞는 방법은?

- A. Trusted Advisor의 성능 점검 결과를 SNS로 받는다
- B. EC2 세부 모니터링을 켜고 `AWS/EC2`의 `MemoryUtilization` 지표에 알람을 건다
- C. 인스턴스에 CloudWatch 에이전트를 설치해 메모리 지표를 보내고, 그 지표에 알람 → SNS
- D. CloudTrail 로그에서 메모리 관련 이벤트를 지표 필터로 센다

<details><summary>정답과 해설</summary>

**C.** 메모리는 하이퍼바이저 밖에서 보이지 않아 EC2 기본 지표에 없다. 게스트 OS 안의 CloudWatch 에이전트가 사용자 지정 지표(`CWAgent` 네임스페이스 등)로 보내야 한다. B: 세부 모니터링은 주기만 1분으로 바꿀 뿐 메모리 지표를 만들지 않는다(`AWS/EC2`에 그런 지표가 없다). D: CloudTrail은 API 호출 감사 로그라 OS 메모리와 무관하다. A: Trusted Advisor는 주기적 모범 사례 점검이지 실시간 메모리 알람이 아니다.
</details>

---

**2.** 결제 워커가 1분마다 `Heartbeat` 사용자 지정 지표(값 1)를 보낸다. 워커 프로세스가 죽어 지표가 끊기면 5분 안에 알람이 울려야 한다. 알람 설정으로 맞는 것은?

- A. `Sum < 1`, Period 60, EvaluationPeriods 5, `TreatMissingData=breaching`
- B. `Sum > 1`, Period 300, `TreatMissingData=notBreaching`
- C. `Sum < 1`, Period 60, `TreatMissingData=ignore`
- D. `Sum < 1`, Period 60, EvaluationPeriods 5, `TreatMissingData=missing`

<details><summary>정답과 해설</summary>

**A.** 프로세스가 죽으면 값 0이 오는 게 아니라 **데이터가 아예 안 온다.** `breaching`이면 빈 구간을 위반으로 보고 ALARM이 된다. D: `missing`이면 판단을 보류해 INSUFFICIENT_DATA로 갈 수 있고 ALARM 액션이 실행되지 않는다. B: 조건도 반대이고 `notBreaching`은 끊김을 정상으로 본다. C: `ignore`는 직전 상태(OK)를 유지한다.
</details>

---

**3.** 주문 API의 지연 시간 알람과 5xx 오류 알람이 따로 울려 당직자가 하룻밤에 수십 번 깬다. 실제로 사용자에게 영향이 있는 것은 "지연이 높고 동시에 5xx가 많을 때"뿐이다. 알림 횟수를 줄이는 가장 적합한 방법은?

- A. 알람 대신 CloudWatch 대시보드를 당직자가 계속 보게 한다
- B. 두 알람의 Period를 1시간으로 늘린다
- C. 두 알람의 임계값을 두 배로 올린다
- D. 두 알람을 하위 알람으로 하는 복합 알람(`AND`)을 만들고, 복합 알람에만 SNS 액션을 둔다

<details><summary>정답과 해설</summary>

**D.** 복합 알람은 하위 알람 상태를 논리식으로 묶어 "둘 다일 때만" 알린다(lab02에서 확인). C·B: 진짜 장애도 늦게 잡거나 놓친다. A: 사람이 계속 보는 것은 알람의 목적에 반한다.
</details>

---

**4.** 주문 서비스 로그(JSON)에서 `"level":"ERROR"` 줄이 5분 동안 10건 이상이면 알리고 싶다. 로그는 이미 CloudWatch Logs의 `/todayorder/api` 그룹에 들어온다. 무엇을 만드는가?

- A. 로그 그룹에 구독 필터를 걸어 Lambda가 줄을 세게 한다
- B. 로그 그룹에 지표 필터(`{ $.level = "ERROR" }`, 값 1)를 만들고, 그 지표의 Sum(Period 300) ≥ 10 알람 → SNS
- C. Logs Insights 쿼리를 5분마다 사람이 실행한다
- D. CloudTrail 추적을 켜고 Lambda로 ERROR를 찾는다

<details><summary>정답과 해설</summary>

**B.** 로그 → 지표 → 알람이 표준 경로다(lab03: ERROR 2건 → 지표 합계 2). A: 동작은 하지만 코드와 운영 부담이 늘어나는 과한 설계다. C: 자동이 아니다. D: CloudTrail은 앱 로그가 아니라 AWS API 호출 기록이다.
</details>

---

**5.** 보안팀이 "애플리케이션 로그를 1년간 저렴하게 보관하고, 최근 14일은 빠르게 검색할 수 있어야 한다"고 요구했다. 가장 비용 효율적인 설계는?

- A. 보존 기간 14일 + 구독 필터로 Data Firehose를 거쳐 S3에 저장하고 수명 주기로 저렴한 클래스로 전환한다
- B. 로그를 EBS 볼륨에 파일로 쌓는다
- C. 로그 그룹 보존 기간을 기본값(무기한)으로 둔다
- D. 보존 기간을 365일로 설정한다

<details><summary>정답과 해설</summary>

**A.** 검색이 잦은 최근 데이터만 CloudWatch Logs에 두고, 장기 보관은 S3(+수명 주기)가 훨씬 싸다. 오래된 로그가 필요하면 Athena로 S3를 조회한다(M11). C: 무기한 보관은 저장 요금이 계속 쌓인다. D: 요구는 맞추지만 1년치를 CloudWatch Logs 요금으로 보관한다. B: 인스턴스가 사라지면 로그도 위험하고 검색이 어렵다.
</details>

---

**6.** 마이크로서비스(API Gateway → Lambda 3개 → DynamoDB)로 바꾼 뒤 일부 주문 요청만 4초씩 걸린다. 어느 구간에서 시간이 걸리는지 요청 단위로 보고 싶다. 무엇을 쓰는가?

- A. VPC Flow Logs
- B. CloudTrail
- C. AWS X-Ray(또는 OpenTelemetry 계측 → X-Ray)
- D. AWS Config

<details><summary>정답과 해설</summary>

**C.** 분산 추적은 요청 하나가 서비스들을 지나가며 쓴 시간을 구간별로 보여 주고 서비스 맵을 그린다. B: 누가 어떤 API를 호출했는지(감사)다. D: 리소스 설정 이력·규정 준수다. A: 네트워크 흐름(IP·포트·허용/거부)이라 애플리케이션 지연 구간을 알 수 없다.
</details>

---

**7.** 운영팀이 CloudFormation으로 만든 RDS 스택의 템플릿에서 DB 엔진 관련 속성을 바꾸려 한다. 바꾸는 속성에 따라 DB가 새로 만들어질 수 있다고 들었다. 실행 전에 이를 확인하는 방법은?

- A. `update-stack`을 실행하고 이벤트를 본다
- B. 변경 세트를 만들어 해당 리소스의 `Replacement` 값을 확인한다
- C. 드리프트 감지를 실행한다
- D. `validate-template`을 실행한다

<details><summary>정답과 해설</summary>

**B.** 변경 세트는 실행 전에 `Add/Modify/Remove`와 `Replacement: True/False/Conditional`을 보여 준다(lab05). A: 이미 실행해 버린다. C: 드리프트는 "스택 밖에서 바뀐 것"을 찾는 기능이다. D: 문법·파라미터만 검사하고 실제 변경 영향은 모른다.
</details>

---

**8.** 누군가 콘솔에서 CloudFormation이 만든 SQS 큐의 가시성 타임아웃을 45초에서 5초로 바꿔 주문이 두 번 처리되기 시작했다. 템플릿과 실제가 다른 리소스를 찾는 기능은?

- A. 종료 보호
- B. 변경 세트
- C. 스택 세트
- D. 드리프트 감지

<details><summary>정답과 해설</summary>

**D.** 드리프트 감지는 리소스별로 `MODIFIED`와 기대값·실제값(`/VisibilityTimeout: 45 → 5`)을 보여 준다(lab05). 찾기만 하고 고치지는 않는다. B: 템플릿 변경의 영향 미리보기다. C: 여러 계정·리전 배포다. A: 스택 삭제 방지다.
</details>

---

**9.** 회사는 AWS Organizations로 계정 30개를 운영한다. 모든 계정의 us-east-1과 ap-northeast-2에 같은 CloudTrail·Config 설정 스택을 배포하고, 새 계정이 OU에 들어오면 자동으로 배포되게 하고 싶다. 무엇을 쓰는가?

- A. CloudFormation StackSets(서비스 관리형 권한, 자동 배포 사용)
- B. Elastic Beanstalk
- C. 각 계정에서 CloudFormation 스택을 수동으로 만든다
- D. 중첩 스택

<details><summary>정답과 해설</summary>

**A.** StackSets는 한 템플릿을 여러 계정 × 여러 리전에 배포하고, Organizations와 연동하면 OU에 새로 들어온 계정에 자동 배포한다. C: 반복 작업이고 누락된다. D: 한 스택 안에서 템플릿을 재사용하는 방법이지 계정·리전 확산이 아니다. B: 웹 앱 배포 플랫폼이다.
</details>

---

**10.** 보안 감사에서 "프라이빗 서브넷의 앱 서버에 접속하려고 배스천 호스트의 22번 포트를 인터넷에 열어 둔 것"이 지적됐다. 인바운드 포트를 모두 닫고, 접속 기록도 남겨야 한다. 앱 서버 서브넷에는 NAT 게이트웨이가 없다. 무엇을 해야 하는가?

- A. 앱 서버에 퍼블릭 IP를 붙이고 22번을 회사 IP로만 연다
- B. Site-to-Site VPN을 연결한다
- C. 배스천의 보안 그룹을 회사 IP로만 제한한다
- D. Systems Manager Session Manager를 쓰고, 인스턴스 프로파일에 `AmazonSSMManagedInstanceCore`를 붙이고, `ssm`·`ssmmessages`·`ec2messages` 인터페이스 VPC 엔드포인트를 만든다

<details><summary>정답과 해설</summary>

**D.** Session Manager는 인바운드 포트 없이 에이전트의 아웃바운드 연결로 셸을 열고 세션 로그를 S3·CloudWatch Logs에 남긴다. 인터넷 경로가 없으므로 SSM 인터페이스 엔드포인트가 필요하다. C·A: 여전히 22번 포트와 SSH 키 관리가 남는다(A는 앱 서버를 퍼블릭으로 노출하기까지 한다). B: 네트워크 경로를 만들 뿐 포트·키·감사 문제를 해결하지 않는다.
</details>

---

**11.** 개발팀마다 제각각 EC2·RDS를 만들어 보안 기준이 지켜지지 않는다. 플랫폼팀이 승인한 구성(암호화·태그·인스턴스 유형이 정해진 템플릿)만 개발자가 스스로 골라 배포할 수 있게 하고 싶다. 가장 적합한 서비스는?

- A. AWS Compute Optimizer
- B. Amazon Managed Grafana
- C. AWS Service Catalog
- D. AWS Trusted Advisor

<details><summary>정답과 해설</summary>

**C.** Service Catalog는 승인된 CloudFormation 템플릿을 "제품"으로 포트폴리오에 넣고, 사용자는 자기 권한 없이도 그 제품만 셀프서비스로 배포한다. D: 점검·권고만 한다. A: 크기 권고다. B: 대시보드다.
</details>

---

**12.** 다음 달 대형 프로모션에 대비해 ap-northeast-2에서 NAT 게이트웨이를 AZ마다 하나씩, 환경 3개에 걸쳐 총 9개 만들 계획이다. 배포 당일 실패하지 않으려면 먼저 무엇을 확인해야 하는가?

- A. Trusted Advisor 비용 최적화 점검
- B. Service Quotas에서 해당 리전의 EC2-VPC 탄력적 IP 한도(기본 5)와 NAT 게이트웨이 관련 한도를 확인하고 미리 증가 요청
- C. Compute Optimizer 권고
- D. AWS Health Dashboard의 공용 서비스 상태

<details><summary>정답과 해설</summary>

**B.** NAT 게이트웨이마다 EIP가 하나 필요하고 리전당 EIP 기본 한도는 5개다(lab07에서 `Value: 5.0`, `Adjustable: true`). 증가 승인에는 시간이 걸리므로 미리 요청한다. A·C: 비용·크기 권고라 한도 문제를 막지 못한다. D: AWS 측 장애 정보이지 내 한도가 아니다.
</details>
