# M01 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 12문항 중 10문항(80%) 이상 맞히면 다음 모듈로.

---

**1.** TodayOrder의 API 서버(EC2)가 `todayorder-receipts` 버킷의 객체를 읽어야 한다. 가장 안전한 방법은?

- A. 읽기 권한만 가진 IAM 사용자의 액세스 키를 서버의 환경 변수에 넣는다
- B. 버킷을 퍼블릭 읽기로 바꾸고 서버는 서명 없이 읽는다
- C. 루트 사용자의 액세스 키를 AWS Secrets Manager에 저장하고 서버가 꺼내 쓴다
- D. 읽기 권한을 가진 IAM 역할을 인스턴스 프로파일로 인스턴스에 연결한다

<details><summary>정답과 해설</summary>

**D.** 역할은 장기 키가 없고, 인스턴스 안의 SDK가 메타데이터 서비스에서 자동 갱신되는 임시 자격 증명을 받는다.
- A: 장기 키가 서버·AMI·로그에 남고 교체 부담이 있다. 동작은 하지만 "가장 안전"이 아니다.
- B: 영수증(개인정보)이 인터넷에 공개된다.
- C: 루트 키는 만들지 않는 것이 원칙이며, 저장 위치를 바꿔도 모든 권한을 가진 장기 키라는 사실은 그대로다.
</details>

---

**2.** 개발자 그룹 정책은 `dynamodb:*`를 `table/todayorder-orders`에 허용한다. 한 개발자의 인라인 정책에는 `dynamodb:DeleteTable`을 `*`에 Deny한다. 이 개발자가 `todayorder-orders` 테이블을 삭제하려 하면?

- A. 허용 — 그룹 정책이 더 구체적인 리소스를 지정했으므로
- B. 허용 — 관리형 정책이 인라인 정책보다 우선하므로
- C. 거부 — 명시적 Deny가 Allow보다 우선하므로
- D. 거부 — 인라인 정책이 그룹 정책보다 나중에 붙었으므로

<details><summary>정답과 해설</summary>

**C.** 적용되는 정책 어디에든 맞는 Deny가 있으면 Allow와 상관없이 거부된다.
- A: 리소스가 더 구체적이라고 우선하지 않는다. IAM 평가에 "구체성 우선" 규칙은 없다.
- B: 관리형/인라인 사이에 우선순위는 없다. 모두 합쳐서 평가한다.
- D: 붙인 순서는 평가에 영향을 주지 않는다.
</details>

---

**3.** 보안팀이 팀 리드들에게 Lambda 실행 역할을 직접 만들 수 있는 권한을 주려 한다. 단, 팀 리드가 자기보다 강한(예: `AdministratorAccess`) 역할을 만들어 권한을 키우는 일은 막고 싶다. 무엇을 써야 하는가?

- A. 권한 경계: 팀 리드가 만드는 역할에 특정 경계 정책 부착을 조건(`iam:PermissionsBoundary`)으로 강제
- B. 팀 리드 그룹에 `iam:CreateRole`만 허용하고, 다른 IAM 액션은 Deny
- C. SCP로 `iam:CreateRole`을 Deny
- D. 팀 리드의 MFA를 의무화

<details><summary>정답과 해설</summary>

**A.** 권한 경계는 위임을 안전하게 만드는 장치다. 만들어지는 역할은 경계를 넘는 권한을 가질 수 없다.
- B: 다른 IAM 액션(`AttachRolePolicy`·`PutRolePolicy`)까지 Deny하면 권한 정책이 없는 빈 역할만 만들 수 있어 요구 사항(쓸 수 있는 실행 역할)을 못 채운다. 반대로 그 액션들을 풀어 주면 `AdministratorAccess`를 붙인 역할을 만들 수 있어 권한 상승을 막지 못한다.
- C: 역할 생성 자체를 막아 요구 사항("직접 만들 수 있게")을 어긴다.
- D: MFA는 신원 확인 강화일 뿐 권한 범위와 무관하다.
</details>

---

**4.** 조직의 prod OU에 `FullAWSAccess`와 함께 "`ap-northeast-2` 외 리전 요청 Deny(IAM·STS 등 글로벌 서비스 제외)" SCP가 붙어 있다. prod 계정의 관리자(`AdministratorAccess`)가 `eu-west-1`에서 S3 버킷을 만들려 하면?

- A. 허용 — 관리자 정책이 `*`를 허용하므로
- B. 거부 — SCP의 명시적 Deny가 적용되므로
- C. 허용 — SCP는 루트 사용자에게만 적용되므로
- D. 거부 — 리전이 다르면 IAM 정책이 적용되지 않으므로

<details><summary>정답과 해설</summary>

**B.** SCP는 멤버 계정의 모든 IAM 주체에 적용되는 상한선이고, 그 Deny는 어떤 IAM Allow로도 뒤집을 수 없다.
- A: IAM Allow는 SCP의 Deny를 넘지 못한다.
- C: 반대다. SCP는 멤버 계정의 사용자·역할과 루트 사용자 모두에 적용된다.
- D: IAM은 글로벌 서비스이며 정책은 모든 리전에 적용된다. 거부 이유는 SCP다.
</details>

---

**5.** 신규 sandbox OU에 "S3·DynamoDB만 허용"하는 SCP를 붙이고 `FullAWSAccess`를 뗐다. 그 OU 계정의 개발자에게는 IAM 정책이 하나도 없다. 개발자가 S3 버킷 목록을 조회하면?

- A. 허용 — SCP가 S3를 허용하므로
- B. 허용 — 같은 계정 안이므로 암묵적으로 허용된다
- C. 거부 — `FullAWSAccess`를 떼면 모든 서비스가 막히므로
- D. 거부 — SCP는 권한을 주지 않고, IAM 정책에 허용이 없으므로

<details><summary>정답과 해설</summary>

**D.** SCP는 최대치를 정할 뿐 권한을 부여하지 않는다. IAM 정책의 Allow가 있어야 한다.
- A: SCP 허용만으로는 부족하다(가장 흔한 오개념).
- B: 기본값은 암묵적 거부다.
- C: 허용 목록 SCP가 S3를 허용하므로 SCP 단계에서는 막히지 않는다. 막힌 이유는 IAM 쪽이다.
</details>

---

**6.** 외부 보안 감사 SaaS가 TodayOrder 계정의 설정을 읽어야 한다. 업체는 수천 고객의 계정에 같은 방식으로 접근한다. 가장 적절한 구성은?

- A. 업체 계정을 신뢰하는 읽기 전용 역할을 만들고, 신뢰 정책에 업체가 준 외부 ID 조건을 넣는다
- B. 업체 전용 IAM 사용자를 만들고 읽기 전용 액세스 키를 전달한다
- C. 업체 계정을 우리 Organizations 조직에 초대한다
- D. 읽기 전용 역할을 만들고 신뢰 정책 Principal을 `"*"`로 둔다

<details><summary>정답과 해설</summary>

**A.** 교차 계정 역할 + 외부 ID가 제3자 접근의 표준이다. 외부 ID는 다른 고객이 업체를 시켜 우리 역할을 맡게 하는 혼동된 대리인 문제를 막는다.
- B: 장기 키를 외부에 넘기는 것은 유출·교체 문제가 크다.
- C: 업체 계정이 우리 조직의 SCP·결제에 묶이게 되며, 접근 권한을 주는 방법도 아니다.
- D: 누구나 맡을 수 있는 역할이 된다.
</details>

---

**7.** 김 개발자가 `aws sts assume-role`로 받은 키 ID와 비밀 키만 환경 변수에 넣고 호출했더니 `InvalidClientTokenId`가 났다. 원인은?

- A. 역할의 권한 정책에 해당 액션이 없다
- B. 신뢰 정책이 김 개발자를 허용하지 않는다
- C. `AWS_SESSION_TOKEN`을 설정하지 않았다
- D. 역할의 최대 세션 시간이 너무 짧다

<details><summary>정답과 해설</summary>

**C.** 임시 자격 증명은 키 ID·비밀 키·세션 토큰 세 조각이 함께 있어야 유효하다.
- A: 권한 부족은 `AccessDenied`(또는 `UnauthorizedOperation`)로 나온다. 토큰 오류가 아니다.
- B: 신뢰 정책 거부는 `assume-role` 단계에서 `AccessDenied`로 나며, 그랬다면 키를 받지도 못했다.
- D: 세션 시간 초과 요청은 `assume-role` 단계의 `ValidationError`이고, 만료된 토큰은 `ExpiredToken`이다.
</details>

---

**8.** TodayOrder가 계정을 prod·dev·security로 나눴다. 직원 60명이 회사 Google Workspace 계정으로 한 번 로그인해 필요한 계정에 들어가게 하고 싶다. 무엇을 쓰는가?

- A. 계정마다 IAM 사용자 60명을 만들고 같은 암호를 쓰게 한다
- B. IAM Identity Center에 외부 IdP를 연결하고, 그룹별 권한 세트를 계정에 할당한다
- C. Amazon Cognito 사용자 풀에 직원을 가입시킨다
- D. AWS Managed Microsoft AD를 만들고 각 계정에 AD Connector를 둔다

<details><summary>정답과 해설</summary>

**B.** 여러 계정에 대한 직원 SSO의 표준이다. 권한 세트를 할당하면 각 계정에 역할이 생기고 직원은 임시 자격 증명으로 일한다.
- A: 180개의 장기 신원이 생기고, 퇴사자 처리·MFA 관리가 계정마다 필요하다.
- C: Cognito는 우리 앱의 **고객** 신원용이다. AWS 계정 접근 관리 도구가 아니다.
- D: 이미 IdP(Google Workspace)가 있는데 AD를 새로 운영하는 것은 과하다. AD가 필요한 워크로드가 있을 때의 선택이다.
</details>

---

**9.** 회사는 온프레미스 Active Directory를 계속 운영한다. Amazon WorkSpaces 사용자가 기존 AD 계정으로 로그인하길 원하며, 보안 정책상 디렉터리 데이터를 클라우드에 복제하면 안 된다. 온프레미스와는 VPN으로 연결돼 있다. 무엇을 고르는가?

- A. AD Connector
- B. Simple AD
- C. AWS Managed Microsoft AD에 사용자 계정을 다시 만든다
- D. Amazon Cognito 자격 증명 풀

<details><summary>정답과 해설</summary>

**A.** AD Connector는 인증 요청을 온프레미스 AD로 전달하는 프록시라 AWS에 디렉터리 데이터를 두지 않는다.
- B: Simple AD는 별도의 독립 디렉터리라 계정을 다시 만들어야 하고, 온프레미스 AD와 신뢰 관계도 맺을 수 없다.
- C: 클라우드에 디렉터리를 새로 두는 것이라 "복제 금지"를 어긴다(신뢰 관계를 맺어도 AWS에 AD가 생긴다).
- D: 앱 사용자에게 AWS 임시 자격 증명을 주는 서비스로, AD 인증과 무관하다.
</details>

---

**10.** GitHub Actions 배포 워크플로가 장기 액세스 키 없이 TodayOrder 계정에 배포하도록 OIDC 연동 역할을 만들었다. 신뢰 정책에서 **반드시** 좁혀야 하는 것은?

- A. `Principal`을 `{"Service": "github.com"}`으로 지정
- B. 역할의 최대 세션 시간을 12시간으로
- C. `Action`을 `sts:AssumeRole`로
- D. `token.actions.githubusercontent.com:sub` 조건을 우리 저장소(와 브랜치)로 제한

<details><summary>정답과 해설</summary>

**D.** `sub`를 제한하지 않으면 GitHub의 아무 저장소 워크플로나 토큰의 `aud`만 맞추면 역할을 맡을 수 있다.
- A: OIDC 연동의 Principal은 `{"Federated": "<OIDC 공급자 ARN>"}`이다. `github.com`이라는 서비스 주체는 없다.
- B: 세션을 길게 하는 것은 보안을 약하게 할 뿐이다.
- C: 웹 ID 연동의 액션은 `sts:AssumeRoleWithWebIdentity`다.
</details>

---

**11.** 보안팀이 "MFA로 로그인하지 않은 세션은 EC2 인스턴스를 종료할 수 없게" 하려 한다. 개발자 중 일부는 장기 액세스 키로 CLI를 쓴다. 어떤 Deny 조건이 맞는가?

- A. `"Bool": {"aws:MultiFactorAuthPresent": "false"}`
- B. `"Bool": {"aws:MultiFactorAuthPresent": "true"}`
- C. `"BoolIfExists": {"aws:MultiFactorAuthPresent": "false"}`
- D. `"StringEquals": {"aws:username": "mfa"}`

<details><summary>정답과 해설</summary>

**C.** 장기 액세스 키 요청에는 이 키가 아예 없다. `...IfExists`는 키가 없을 때도 조건을 참으로 보아 Deny를 적용한다. (레슨 03에서 시뮬레이터로 확인: 키 없음 → explicitDeny, false → explicitDeny, true → allowed)
- A: 키가 없는 요청(장기 키 CLI)에는 조건이 맞지 않아 Deny가 적용되지 않는다 — 구멍.
- B: MFA 세션을 거부하게 된다(반대).
- D: 의미 없는 조건이다.
</details>

---

**12.** 여러 계정을 운영하는 회사가 네트워크 팀 계정의 VPC 하나를 중앙에서 관리하고, 각 앱 팀 계정이 그 VPC의 서브넷에 자기 EC2를 띄우게 하려 한다. 가장 적절한 서비스는?

- A. VPC 피어링을 계정마다 맺는다
- B. AWS RAM으로 서브넷을 앱 팀 계정(또는 OU)과 공유한다
- C. 앱 팀 계정에 네트워크 계정의 IAM 사용자를 만들어 준다
- D. SCP로 앱 팀 계정이 VPC를 만들지 못하게만 한다

<details><summary>정답과 해설</summary>

**B.** RAM의 VPC 공유는 소유 계정이 네트워크를 관리하고 참여 계정이 공유된 서브넷에 리소스를 만들게 한다.
- A: 피어링은 VPC끼리 연결할 뿐, 각 팀이 여전히 자기 VPC를 운영해야 한다. 요구는 "하나의 VPC"다.
- C: 장기 자격 증명 공유이며, 네트워크 계정 안에 리소스가 섞인다.
- D: 금지만 할 뿐 공유 수단이 아니다(함께 쓸 수는 있다).
</details>
