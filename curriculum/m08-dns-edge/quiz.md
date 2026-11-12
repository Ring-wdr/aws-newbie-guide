# M08 퀴즈 — DNS와 엣지

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 12문항 중 10문항(80%) 이상 맞히면 다음 모듈로.

---

**1.** TodayOrder의 루트 도메인 `todayorder.example`을 CloudFront 배포에 연결해야 한다. DNS 쿼리 비용도 최소로 하고 싶다. 무엇을 만드나?

- A. `todayorder.example` A 레코드 Alias → CloudFront 배포
- B. `todayorder.example` CNAME → `dxxxx.cloudfront.net`
- C. `todayorder.example` A 레코드 → CloudFront 엣지 IP 몇 개
- D. `www.todayorder.example` CNAME만 만들고 루트는 비워 둔다

<details><summary>정답과 해설</summary>

**A.** apex에는 CNAME을 둘 수 없고(B는 `InvalidChangeBatch`, lab01 4단계), Alias는 apex에 가능하며 AWS 리소스로의 쿼리가 무료다. C는 CloudFront 엣지 IP가 수시로 바뀌어 깨진다. D는 요구(루트 도메인 연결)를 만족하지 못한다.
</details>

---

**2.** 새 주문 API 버전을 전체 트래픽의 5%에만 먼저 노출하고, 문제가 없으면 점차 늘리려 한다. 가장 단순한 DNS 구성은?

- A. 지연 시간 라우팅
- B. 다중값 응답
- C. 가중치 라우팅(기존 95, 신규 5)
- D. 장애 조치 라우팅

<details><summary>정답과 해설</summary>

**C.** 비율로 나누는 것은 가중치 정책이다. A는 지연 기준, B는 건강한 값 여러 개를 함께 주는 것(비율 제어 아님), D는 액티브-패시브다. (리졸버 캐시 때문에 실제 비율은 근사치이므로 TTL을 짧게 둔다.)
</details>

---

**3.** 유럽 연합 사용자의 개인정보는 반드시 `eu-central-1` 서버에서만 처리해야 한다는 법무 요구가 있다. 나머지 사용자는 서울로 보낸다. 무엇을 쓰나?

- A. 지연 시간 라우팅
- B. 지리적 위치 라우팅(대륙 EU → 프랑크푸르트, 기본 `*` → 서울)
- C. 지리 근접 라우팅(Bias +50)
- D. Global Accelerator 트래픽 다이얼

<details><summary>정답과 해설</summary>

**B.** "어느 지역 사용자는 **반드시** 여기"는 위치 기준이며 지리적 위치 정책이다. 기본 레코드가 있어야 나머지 사용자도 응답을 받는다. A는 지연이 짧은 쪽을 고르므로 EU 사용자가 다른 리전으로 갈 수 있다. C는 거리 기반이라 경계 근처 사용자가 다른 리전으로 갈 수 있어 규정 준수를 보장하지 못한다. D는 비율 조절이지 위치 강제가 아니다.
</details>

---

**4.** 장애 조치 레코드를 구성하면서 PRIMARY(서울 ALB)에만 상태 확인을 붙이고 SECONDARY(S3 점검 페이지)에는 붙이지 않았다. 서울 상태 확인이 실패하면?

- A. 아무 응답도 하지 않는다
- B. 두 값을 모두 응답한다
- C. PRIMARY를 계속 응답한다
- D. SECONDARY를 응답한다

<details><summary>정답과 해설</summary>

**D.** 상태 확인이 없는 레코드는 항상 건강한 것으로 친다. PRIMARY가 비정상이면 SECONDARY가 답한다. C는 PRIMARY·SECONDARY가 **모두** 비정상일 때의 동작이다. A·B는 장애 조치 정책의 동작이 아니다.
</details>

---

**5.** 프라이빗 서브넷의 내부 결제 서비스(인터넷에서 접근 불가)가 죽으면 Route 53 장애 조치로 DR 리전으로 넘기고 싶다. 상태 확인을 어떻게 만드나?

- A. 결제 서비스의 프라이빗 IP를 대상으로 하는 HTTP 상태 확인
- B. 결제 서비스 지표에 CloudWatch 경보를 만들고, 경보 기반 상태 확인을 만든다
- C. 상태 확인 없이 장애 조치 레코드만 만든다
- D. 다중값 응답 레코드로 바꾼다

<details><summary>정답과 해설</summary>

**B.** Route 53 상태 검사기는 인터넷에 있어 VPC 안의 프라이빗 IP에 닿지 못한다(A 불가). CloudWatch 경보 상태를 따르는 상태 확인이 정답이다. C는 장애를 감지할 수 없고, D도 상태 확인 문제를 풀지 못한다.
</details>

---

**6.** 이미지·JS 같은 정적 파일을 S3에 두고 전 세계에 빠르게 제공하되, S3 버킷은 퍼블릭으로 열지 않고 SSE-KMS로 암호화하려 한다. 올바른 구성은?

- A. 버킷을 퍼블릭으로 열고 CloudFront 오리진으로 지정
- B. CloudFront + OAI
- C. CloudFront + OAC + 버킷 정책(서비스 주체 `cloudfront.amazonaws.com`, `AWS:SourceArn` 조건)
- D. S3 Transfer Acceleration

<details><summary>정답과 해설</summary>

**C.** OAC는 SigV4로 서명해 S3에 접근하며 SSE-KMS 객체도 지원한다. 버킷 정책의 SourceArn 조건으로 이 배포만 허용한다(lab04: 정책 없음 403 → 정책 후 200, S3 직접 접근은 403). B의 OAI는 레거시이며 SSE-KMS를 지원하지 않는다. A는 버킷 공개 요구 위반, D는 업로드 가속이며 캐시·접근 제어가 아니다.
</details>

---

**7.** 회원 전용 강의 동영상(HLS, 파일 수백 조각)을 CloudFront로 배포한다. 플레이어가 요청하는 URL은 바꿀 수 없다. 로그인한 회원만 보게 하려면?

- A. CloudFront 서명된 쿠키
- B. CloudFront 서명된 URL
- C. S3 미리 서명된 URL
- D. WAF 지역 일치 규칙

<details><summary>정답과 해설</summary>

**A.** 여러 파일에 대해 URL을 바꾸지 않고 접근을 제어하는 것이 서명된 쿠키다. B는 파일마다 URL이 바뀐다. C는 S3에서 직접 받아 CDN 이점이 없고 조각마다 서명이 필요하다. D는 국가 기준이지 회원 인증이 아니다.
</details>

---

**8.** 모든 응답에 `Strict-Transport-Security` 헤더를 붙이고 `/old/*`를 `/new/*`로 리디렉션하려 한다. 초당 요청이 매우 많고 비용과 지연을 최소화하고 싶다.

- A. Lambda@Edge(오리진 응답)
- B. API Gateway 매핑 템플릿
- C. ALB 리스너 규칙
- D. CloudFront Functions(뷰어 요청·응답)

<details><summary>정답과 해설</summary>

**D.** 헤더 조작과 URL 리디렉션은 CloudFront Functions의 대표 용도이며, 1밀리초 미만·대량 처리에 맞다. A도 가능하지만 더 무겁고 비싸며 외부 호출·본문 접근이 필요할 때 쓴다. B·C는 엣지가 아니라 오리진 쪽이라 모든 요청이 오리진까지 간다.
</details>

---

**9.** 대형 거래처가 "방화벽 허용 목록에는 IP 주소만 넣을 수 있다"고 한다. TodayOrder 주문 API는 서울·버지니아 두 리전에서 액티브-액티브로 돈다. 리전 장애 시에도 같은 IP로 접속돼야 한다.

- A. CloudFront 배포의 엣지 IP를 알려 준다
- B. 리전별 NLB에 탄력적 IP를 붙이고 둘 다 알려 준다
- C. Global Accelerator(고정 애니캐스트 IP 2개, 리전별 엔드포인트 그룹)
- D. Route 53 지연 시간 라우팅

<details><summary>정답과 해설</summary>

**C.** GA는 고정 IP 2개로 들어와 건강한 리전 엔드포인트로 보낸다. 리전 장애에도 IP는 그대로다. A의 CloudFront IP는 수시로 바뀐다. B는 장애 시 거래처가 다른 IP로 직접 바꿔야 하고 IP가 리전마다 다르다. D는 IP가 아니라 이름을 주는 방식이다.
</details>

---

**10.** 온라인 게임의 UDP 트래픽을 전 세계 플레이어에게 낮은 지연으로 제공하려 한다. 캐시할 콘텐츠는 없다.

- A. CloudFront
- B. Global Accelerator
- C. S3 Transfer Acceleration
- D. Route 53 다중값 응답

<details><summary>정답과 해설</summary>

**B.** GA는 TCP/UDP를 가장 가까운 엣지에서 AWS 백본으로 실어 나른다. A는 HTTP(S) 전용이며 캐시가 핵심이다. C는 S3 업로드용이다. D는 DNS로 IP를 나눠 줄 뿐 네트워크 경로를 개선하지 않는다.
</details>

---

**11.** 로그인 API에 같은 IP에서 분당 수천 번의 비밀번호 대입 시도가 들어온다. 애플리케이션을 고치지 않고 ALB 앞에서 막고 싶다.

- A. WAF 속도 기반 규칙(키: IP, 범위 축소: URI `/login`)을 ALB의 Web ACL에 넣는다
- B. 보안 그룹에서 해당 IP 대역을 거부한다
- C. Shield Advanced를 구독한다
- D. NACL로 포트 443을 막는다

<details><summary>정답과 해설</summary>

**A.** IP별 요청 수를 세어 한도를 넘으면 막는 것이 WAF 속도 기반 규칙이다(lab06: 20회 이후 403). B는 보안 그룹에 거부 규칙이 없다(허용만 가능). C는 대규모 DDoS 대응 구독으로, 이런 애플리케이션 계층 남용에는 과하고 비싸다. D는 모든 사용자를 막는다.
</details>

---

**12.** AWS Organizations 아래 계정 40개가 있다. 모든 계정의 ALB와 CloudFront에 같은 WAF 관리형 규칙을 강제하고, 새로 만든 계정과 리소스에도 자동으로 적용되게 하고 싶다.

- A. 각 계정에서 CloudFormation으로 Web ACL을 배포한다
- B. SCP로 WAF 설정 변경을 금지한다
- C. Shield Standard
- D. AWS Firewall Manager 보안 정책

<details><summary>정답과 해설</summary>

**D.** 여러 계정에 WAF·Shield·보안 그룹 정책을 중앙에서 일괄·자동 적용하는 서비스가 Firewall Manager다(Organizations, 관리자 계정, Config 필요). A는 새 계정·리소스에 자동 적용되지 않는다(StackSets로 일부 가능하지만 리소스 연결 자동화가 안 된다). C는 L3/L4 자동 보호로 WAF 규칙과 무관하다. B는 금지만 할 뿐 규칙을 적용하지 않는다.
</details>
