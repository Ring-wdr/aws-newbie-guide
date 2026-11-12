# M07 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(12문항 중 10문항) 맞히면 다음 모듈로.

---

**1.** 매일 밤 주문 데이터를 집계하는 작업이 평균 40분 걸린다. 서버 관리를 최소화하고 싶다. 가장 알맞은 실행 방법은?

- A. Lambda 함수의 타임아웃을 60분으로 설정한다
- B. API Gateway가 Lambda를 동기로 호출한다
- C. ECS on Fargate 태스크를 EventBridge Scheduler로 매일 실행한다
- D. Lambda 함수를 프로비저닝된 동시성으로 실행한다

<details><summary>정답과 해설</summary>

**C.** Lambda는 최대 15분(900초)이다. Fargate는 서버 관리 없이 긴 작업을 돌리고, Scheduler가 일정을 건다. A는 설정 자체가 거부된다(lab01에서 901초 거부 확인). B는 API Gateway 통합 타임아웃(약 30초)과 Lambda 15분에 모두 걸린다. D는 콜드 스타트 대책일 뿐 실행 시간 한도는 그대로다.
</details>

---

**2.** 결제 확인 API(Lambda)의 응답 시간이 대부분 50ms인데 가끔 2초가 넘는다. 원인은 콜드 스타트로 확인됐다. 특정 시간대에 일정한 저지연이 필요하다. 무엇을 하는가?

- A. 예약 동시성을 설정한다
- B. 함수 타임아웃을 늘린다
- C. 메모리를 128 MB로 줄인다
- D. 프로비저닝된 동시성을 설정한다(필요하면 Application Auto Scaling으로 시간대별 조정)

<details><summary>정답과 해설</summary>

**D.** 프로비저닝된 동시성은 실행 환경을 미리 초기화해 두어 콜드 스타트를 없앤다. A는 동시성 몫·상한을 정할 뿐 환경을 데워 두지 않는다. C는 CPU도 줄어 더 느려진다. B는 지연과 무관하다.
</details>

---

**3.** 이벤트 날 쿠폰 발급 함수가 폭주해 같은 계정의 결제 함수까지 스로틀(429)됐다. 쿠폰 함수가 결제 함수의 동시성을 빼앗지 못하게 하려면?

- A. 쿠폰 함수에 예약 동시성을 걸어 상한을 둔다(결제 함수에도 예약 동시성으로 몫을 보장할 수 있다)
- B. 결제 함수의 메모리를 늘린다
- C. 쿠폰 함수를 비동기로 호출한다
- D. 결제 함수에 계층을 추가한다

<details><summary>정답과 해설</summary>

**A.** 예약 동시성은 함수가 쓸 몫을 떼어 두는 동시에 상한이 된다. 쿠폰 함수를 제한하거나 결제 함수 몫을 보장하면 서로 침범하지 않는다. B·D는 동시성과 무관하다. C는 호출 방식만 바뀔 뿐 실행 시에는 같은 계정 동시성을 쓴다.
</details>

---

**4.** SQS 큐를 소스로 하는 Lambda 이벤트 소스 매핑을 만들려는데 `InvalidParameterValueException`이 난다. 함수 타임아웃은 120초, 큐의 가시성 타임아웃은 30초다. 무엇을 해야 하는가?

- A. 함수 타임아웃을 900초로 늘린다
- B. 큐의 가시성 타임아웃을 함수 타임아웃 이상(권장 6배, 720초 정도)으로 늘린다
- C. 큐를 FIFO로 바꾼다
- D. 함수에 `add-permission`으로 sqs.amazonaws.com을 허용한다

<details><summary>정답과 해설</summary>

**B.** 가시성 타임아웃이 함수 타임아웃보다 짧으면 처리 중에 메시지가 다시 보여 중복 처리되므로 매핑 생성이 거부된다(lab02). A는 차이를 더 벌린다. C는 무관하다. D: SQS 매핑은 Lambda 서비스가 **폴링**하므로 리소스 정책이 아니라 **실행 역할**에 SQS 읽기 권한이 필요하다.
</details>

---

**5.** SQS → Lambda 처리에서 10건 배치 중 1건만 실패해도 10건이 모두 다시 처리되어 중복 정산이 생긴다. 가장 알맞은 해결은?

- A. 배치 크기를 1로 줄인다
- B. 함수에 비동기 OnFailure 대상을 설정한다
- C. 가시성 타임아웃을 0으로 줄인다
- D. 이벤트 소스 매핑에 `ReportBatchItemFailures`를 켜고, 함수가 실패한 메시지 ID만 `batchItemFailures`로 반환한다

<details><summary>정답과 해설</summary>

**D.** 부분 배치 응답으로 실패한 메시지만 큐에 남기고 성공한 것은 지운다(lab02에서 실패 1건만 재시도되는 것을 확인). A도 동작하지만 처리량이 크게 떨어지고 호출 비용이 는다. C는 중복을 악화시킨다. B: SQS 소스는 비동기 호출이 아니라 매핑이므로 OnFailure 대상이 쓰이지 않는다(큐의 DLQ를 쓴다).
</details>

---

**6.** 파트너사 세 곳에 주문 조회 API를 제공한다. 파트너마다 API 키를 발급하고, 초당 요청 수와 월 호출량을 따로 제한해야 한다. 응답도 일부 캐싱하고 싶다. 무엇을 쓰는가?

- A. API Gateway REST API + API 키 + 사용량 계획 + 스테이지 캐시
- B. API Gateway HTTP API + JWT 권한 부여자
- C. ALB + Lambda 대상
- D. Lambda 함수 URL

<details><summary>정답과 해설</summary>

**A.** API 키·사용량 계획(고객별 스로틀·할당량)·캐싱은 REST API 기능이다. B의 HTTP API에는 API 키·사용량 계획·캐싱이 없다. C·D는 고객별 할당량 관리 기능이 없다.
</details>

---

**7.** API Gateway REST API의 Lambda 프록시 통합을 배포했는데 호출하면 `{"message": "Internal server error"}`(500)만 오고, 함수의 CloudWatch 로그에는 호출 기록이 전혀 없다. 가장 가능성 높은 원인은?

- A. 함수의 실행 역할에 DynamoDB 권한이 없다
- B. 스테이지 스로틀링 한도를 넘었다
- C. 함수의 리소스 기반 정책에 `apigateway.amazonaws.com`의 `lambda:InvokeFunction` 허용이 없다
- D. 함수 메모리가 부족하다

<details><summary>정답과 해설</summary>

**C.** 함수가 **호출조차 되지 않았으므로** 호출 권한(리소스 기반 정책) 문제다(lab03에서 재현, `add-permission` 후 200). A라면 함수는 실행되어 로그에 AccessDenied가 남는다(lab04). B라면 429다. D라면 함수 로그에 실행 기록과 오류가 남는다.
</details>

---

**8.** 모바일 앱 사용자가 로그인 후 자신의 프로필 사진을 S3 버킷의 **자기 폴더에만** 직접 업로드하게 하려 한다. 앱에 장기 자격 증명을 넣으면 안 된다. 가장 알맞은 구성은?

- A. 사용자 풀의 ID 토큰으로 S3에 직접 요청한다
- B. Cognito 사용자 풀로 로그인 → 자격 증명 풀로 임시 자격 증명 → 역할 정책에서 `${cognito-identity.amazonaws.com:sub}` 경로만 허용
- C. IAM 사용자를 고객마다 만들고 액세스 키를 앱에 저장한다
- D. 버킷을 퍼블릭 쓰기로 연다

<details><summary>정답과 해설</summary>

**B.** 자격 증명 풀이 토큰을 임시 AWS 자격 증명으로 바꾸고, 정책 변수로 사용자별 경로를 제한한다. A: JWT는 S3 요청 서명에 쓸 수 없다. C는 확장 불가하고 장기 키 유출 위험. D는 보안 사고다.
</details>

---

**9.** 사내 직원들이 기존 회사 IdP(SAML)로 여러 AWS 계정의 콘솔에 로그인해야 한다. 무엇을 쓰는가?

- A. IAM Identity Center
- B. Cognito 자격 증명 풀
- C. Cognito 사용자 풀
- D. API Gateway Lambda 권한 부여자

<details><summary>정답과 해설</summary>

**A.** 직원(workforce)의 AWS 계정·콘솔 접근은 IAM Identity Center가 맞다. B·C는 내 애플리케이션의 고객(customer) 인증용이다. D는 API 요청 인증이다.
</details>

---

**10.** Fargate에서 도는 주문 API 컨테이너가 DynamoDB를 호출하면 `AccessDenied`가 난다. 작업 정의의 `executionRoleArn` 역할에 DynamoDB 권한을 이미 줬다. 무엇이 문제인가?

- A. Fargate는 DynamoDB를 호출할 수 없다
- B. ECR 저장소 정책을 고쳐야 한다
- C. 보안 그룹에 DynamoDB 포트를 열어야 한다
- D. 앱 코드는 **작업 역할(`taskRoleArn`)** 의 자격 증명을 쓰므로, 작업 역할에 권한을 주고 작업 정의에 지정해야 한다

<details><summary>정답과 해설</summary>

**D.** 작업 실행 역할은 ECS 에이전트가 이미지 풀·로그 전송·비밀 주입에 쓰고, 컨테이너 안 애플리케이션은 작업 역할을 쓴다. A는 틀렸다. C: DynamoDB는 HTTPS(443) 아웃바운드로 호출하며 권한 문제와 무관하다. B는 이미지 풀 권한이다.
</details>

---

**11.** 프라이빗 서브넷(NAT 게이트웨이 없음)의 Fargate 태스크가 계속 `STOPPED`, `CannotPullContainerError`로 끝난다. 이미지 URI와 실행 역할은 정상이다. 비용 효율적으로 해결하려면?

- A. 태스크를 퍼블릭 서브넷에 두고 퍼블릭 IP를 준다
- B. ECR API·ECR DKR 인터페이스 엔드포인트와 S3 게이트웨이 엔드포인트(및 로그용 CloudWatch Logs 엔드포인트)를 만든다
- C. 태스크 메모리를 늘린다
- D. EC2 시작 유형으로 바꾼다

<details><summary>정답과 해설</summary>

**B.** 이미지를 받으려면 ECR(API·도커 레지스트리)과 이미지 계층이 저장된 S3에 닿을 경로가 필요하다. VPC 엔드포인트로 인터넷 없이 해결한다(NAT 게이트웨이도 가능하지만 시간당·데이터 처리 요금이 크다). A는 동작하지만 태스크를 인터넷에 노출해 보안상 바람직하지 않다. C·D는 네트워크 경로 문제를 풀지 못한다.
</details>

---

**12.** 영수증 이미지가 S3에 올라오면 썸네일을 만들어야 한다. 업로드는 하루 수백만 건이고 급증이 잦으며, 처리 실패 건을 잃으면 안 된다. 가장 내구성 있는 구성은?

- A. S3 이벤트 → Lambda(썸네일을 같은 접두사에 저장)
- B. EC2 cron이 매분 버킷 전체를 목록 조회해 새 객체를 찾는다
- C. S3 이벤트 → SQS 큐(DLQ 포함) → Lambda 이벤트 소스 매핑, 썸네일은 다른 접두사/버킷에 저장
- D. S3 이벤트 → SNS 이메일 구독

<details><summary>정답과 해설</summary>

**C.** SQS가 급증을 버퍼링하고, 실패 메시지는 재시도 후 DLQ에 남아 잃지 않는다. 출력 위치를 분리해 무한 루프를 막는다. A는 같은 접두사에 쓰면 자기 출력으로 다시 트리거되는 무한 루프 위험이 있고, 비동기 호출 실패 처리를 따로 설정해야 한다. B는 비효율적이고 느리다. D는 사람에게 알림을 보낼 뿐 처리가 아니다.
</details>
