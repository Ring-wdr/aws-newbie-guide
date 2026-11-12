# M01 치트시트

## 주체 한눈에

| 요구 | 답 |
|---|---|
| 계정을 만든 이메일 | 루트 사용자 — MFA, 액세스 키 없음, 평소 사용 금지 |
| 직원의 콘솔·CLI 로그인 (여러 계정) | **IAM Identity Center** (권한 세트, 외부 IdP·AD 연동) |
| 같은 권한을 여러 사람에게 | IAM **그룹** (중첩 불가, Principal 불가) |
| EC2·Lambda·ECS가 AWS 호출 | **역할** (인스턴스 프로파일·실행 역할·태스크 역할) |
| 다른 계정의 리소스 | 상대 계정의 **역할** 맡기 (+ 양쪽 허용) |
| 제3자 업체 | 교차 계정 역할 + **외부 ID** |
| CI/CD (GitHub Actions 등) | **OIDC** 공급자 + `AssumeRoleWithWebIdentity` |
| 앱 고객 가입·로그인 | **Cognito 사용자 풀** (JWT) |
| 앱 고객이 AWS를 직접 호출 | **Cognito 자격 증명 풀** (임시 자격 증명) |

## 정책 종류

| 종류 | 붙는 곳 | 권한을 주나 | 결합 |
|---|---|---|---|
| 자격 증명 기반 (관리형·인라인) | 사용자·그룹·역할 | 준다 | 합집합 |
| 리소스 기반 (버킷·큐·키·함수 정책, **신뢰 정책**) | 리소스 | 준다 (Principal 필수) | 같은 계정: 합집합 / 교차 계정: 양쪽 모두 필요 |
| 권한 경계 | 사용자·역할 | **안 준다** (상한) | ∩ |
| SCP | 루트·OU·멤버 계정 | **안 준다** (상한, 멤버 계정 루트 포함, 관리 계정 제외) | 계층마다 ∩ |
| 세션 정책 | AssumeRole 등의 `--policy` | **안 준다** (상한) | ∩ |

**평가**: 명시적 Deny > Allow > 암묵적 Deny(기본). 최종 = SCP ∩ (자격 증명 정책 ∪ 리소스 정책) ∩ 경계 ∩ 세션 정책, Deny 하나면 끝.

오류 문구로 원인 찾기 (에뮬레이터에서 실제로 본 문구):

| 문구 | 뜻 |
|---|---|
| `with an explicit deny in an identity-based policy` | 사용자·그룹·역할 정책의 Deny |
| `with an explicit deny in a resource-based policy` | 버킷 정책 등의 Deny |
| `because no identity-based policy allows` | Allow 없음 (암묵적) |
| `because no permissions boundary allows` | 권한 경계 밖 |
| `because no session policy allows` | 세션 정책 밖 |

## 정책 문법

```json
{"Version": "2012-10-17",
 "Statement": [{"Sid": "...", "Effect": "Allow|Deny",
   "Action": "svc:Api" | "NotAction": [...],
   "Resource": "arn:..." | "NotResource": [...],
   "Principal": {...},            // 리소스 기반·신뢰 정책에만
   "Condition": {"연산자": {"키": "값"}}}]}
```

| 조건 키 | 용도 |
|---|---|
| `aws:MultiFactorAuthPresent` (`BoolIfExists`) | MFA 세션만 |
| `aws:SourceIp` | IP 제한 |
| `aws:SecureTransport` | HTTPS만 |
| `aws:RequestedRegion` | 리전 제한 (SCP에서 `NotAction`과 함께) |
| `aws:PrincipalOrgID` | 우리 조직 계정만 (리소스 정책) |
| `sts:ExternalId` | 제3자 역할 맡기 |
| `<발급자>:sub`, `<발급자>:aud` | OIDC 연동 조건 |
| `${aws:username}` | 정책 변수 — 자기 자신만 |

## 한계값 (2026-11 AWS 문서 기준)

| 항목 | 값 |
|---|---|
| 사용자당 액세스 키 | 2 |
| 사용자당 그룹 | 10 |
| 계정당 사용자 | 5,000 |
| 사용자당 MFA 장치 | 8 |
| 관리형 정책 버전 | 5 |
| 관리형 정책 크기 | 6,144자 (공백 제외) |
| 인라인 정책 합계 | 사용자 2,048 · 그룹 5,120 · 역할 10,240자 |
| 붙일 수 있는 관리형 정책 | 사용자 10(최대 20) · 그룹 10 · 역할 20(최대 25) |
| 역할 신뢰 정책 크기 | 2,048자 (최대 8,192까지 증설) |
| AssumeRole 세션 | 15분 ~ 역할 최대 세션(1~12시간, 기본 1시간). 역할 체이닝 1시간 |
| SCP 크기 / 엔터티당 SCP | 10,240자 / 10개 (최소 1개) |
| OU 중첩 | 루트 아래 5단계 |

## Organizations·계정 관리

| 요구 | 답 |
|---|---|
| 청구서 하나, 볼륨 할인, RI·SP 공유 | Organizations **통합 결제** |
| 멤버 계정 전체에서 서비스·리전·행동 금지 | **SCP** (모든 기능 세트 필요) |
| 다계정 랜딩 존 자동 구성, 가드레일, 계정 자동 발급 | **Control Tower** (예방=SCP, 탐지=Config, 사전=CFN Hooks) |
| 서브넷·TGW를 다른 계정과 공유 | **AWS RAM** |
| 사내 AD로 AWS 앱 로그인, AWS에 데이터 저장 X | **AD Connector** |
| AWS에 진짜 AD, 온프레미스와 신뢰 | **AWS Managed Microsoft AD** |
| 작고 싼 AD 호환 (신뢰·MFA 불가) | **Simple AD** |

## 자주 쓴 CLI

```bash
aws iam create-user / create-group / add-user-to-group
aws iam create-policy --policy-document file://p.json ; attach-group-policy ; put-user-policy
aws iam put-user-permissions-boundary --permissions-boundary <정책 ARN>
aws iam create-role --assume-role-policy-document file://trust.json ; put-role-policy
aws sts assume-role --role-arn ... --role-session-name ... [--duration-seconds] [--policy] [--external-id]
aws sts get-caller-identity
aws iam simulate-principal-policy --policy-source-arn <주체 ARN> --action-names ... --resource-arns ...
aws iam simulate-custom-policy --policy-input-list "$(cat p.json)" --action-names ... \
  [--permissions-boundary-policy-input-list "$(cat b.json)"] [--context-entries ContextKeyName=...,ContextKeyValues=...,ContextKeyType=...]
aws iam generate-credential-report ; get-credential-report
aws organizations list-roots ; create-organizational-unit ; list-organizational-units-for-parent
```

## 에뮬레이터 주의

- IAM·EC2·KMS는 사용자 정책을 평가한다. S3·SQS·DynamoDB는 **데이터 API만** 평가하고 버킷·큐·테이블 생성·목록은 통과시킨다 → 권한 설계는 시뮬레이터로 확인.
- SCP·계정 API, MFA 활성화는 501. 임시 키는 `EMULATOR…`.
