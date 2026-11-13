# M01. IAM과 계정 관리

> 시나리오: TodayOrder 2단계 — 팀에 합류해 AWS 계정을 받았다. "누구에게 어떤 권한을 줄까"를 정한다. 사람은 그룹으로, 서버와 CI는 역할로, 여러 계정은 조직으로 묶는다.
> 도메인: D1(보안 아키텍처) · 예상 시간: 약 6시간

## 목표

- 사용자·그룹·역할·정책의 관계를 그림으로 그릴 수 있다.
- 정책 JSON(Effect/Action/Resource/Condition/Principal)을 읽고, 여러 정책이 겹칠 때의 평가 결과(명시적 Deny > Allow > 암묵적 Deny, 권한 경계·SCP·세션 정책의 교집합)를 **손으로 판정**할 수 있다.
- 역할과 STS로 임시 자격 증명을 받고, 교차 계정·제3자(외부 ID)·EC2(인스턴스 프로파일)·CI(OIDC) 패턴을 고를 수 있다.
- Organizations·SCP·통합 결제·IAM Identity Center·Control Tower·RAM·Directory Service의 쓰임을 구분할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [루트 사용자, IAM 사용자, 그룹, MFA](./01-root-users-groups-mfa.md) | 45분 | 🟢 (MFA 활성화 🔴) |
| 2 | [정책 문서 해부 — 자격 증명 기반 vs 리소스 기반](./02-policy-anatomy.md) | 45분 | 🟢 |
| 3 | [정책 평가 로직 — 명시적 Deny, 권한 경계, SCP, 세션 정책](./03-policy-evaluation.md) | 60분 | 🟢 / 🟡 |
| 4 | [역할과 STS — AssumeRole, 신뢰 정책, 임시 자격 증명](./04-roles-and-sts.md) | 55분 | 🟢 |
| 5 | [조직 단위 관리 — Organizations, OU, SCP, 통합 결제, Identity Center, Control Tower, RAM](./05-organizations-scp.md) | 60분 | 🟢 / 🔴 |
| 6 | [자격 증명 연동 — SAML·OIDC, Cognito와의 구분, Directory Service](./06-federation-and-directory.md) | 40분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 사용자·그룹·정책 생성과 연결 (암호 정책, 정책 변수, 키 2개 한도, 자격 증명 보고서, MFA 501 관찰) | [labs/lab01-users-groups-policies.sh](./labs/lab01-users-groups-policies.sh) | 1, 2 | 🟢 (MFA 활성화 🔴) |
| 역할 + 신뢰 정책, `assume-role` 임시 자격 증명, 신뢰 정책에 없는 주체 거부, 세션 정책, 외부 ID, 인스턴스 프로파일 | [labs/lab02-role-assume-role.sh](./labs/lab02-role-assume-role.sh) | 4 | 🟢 |
| 권한 거부 재현: IAM·EC2 암묵적 Deny → Allow → 명시적 Deny 우선 → 권한 경계 / 같은 사용자의 S3 대비 | [labs/lab03-access-denied.sh](./labs/lab03-access-denied.sh) | 3 | 🟢 / 🟡(S3) |
| 정책 평가 워크시트를 손으로 풀고 `iam simulate-principal-policy`로 채점 | [labs/lab04-policy-worksheet.sh](./labs/lab04-policy-worksheet.sh) | 3 | 🟢 |
| Organizations OU 트리 구성, SCP·계정 API 501 관찰, Identity Center 읽기 | [labs/lab05-organizations-ou.sh](./labs/lab05-organizations-ou.sh) | 5 | 🟢 (SCP 🔴) |
| SCP 워크시트: SCP JSON 작성, "SCP ∩ IAM" 손 판정, `iam simulate-custom-policy`로 채점 | [labs/lab06-scp-worksheet.sh](./labs/lab06-scp-worksheet.sh) | 3, 5 | 🔴 대체 실습(스크립트는 실행됨) |
| OIDC 연동: GitHub Actions 배포 역할 구성 (토큰 교환은 하지 않음) | [labs/lab07-oidc-federation.sh](./labs/lab07-oidc-federation.sh) | 6 | 🟡 |
| boto3: 최소 권한 정책 생성기 | [sdk/least_privilege_policy.py](./sdk/least_privilege_policy.py) | 2 | 🟢 |
| boto3: 역할을 맡아 새 세션 만들기 | [sdk/assume_role_session.py](./sdk/assume_role_session.py) | 4 | 🟢 |

정책 원문(워크시트용 JSON): [labs/policies/](./labs/policies/) · 공용 정리 함수: [labs/_lib.sh](./labs/_lib.sh)

워크시트(lab04, lab06)는 **손으로 먼저 풀고** 답을 넣어 채점한다.

```bash
MY_ANSWERS="A D D A D I I I I A" bash curriculum/m01-iam-identity/labs/lab04-policy-worksheet.sh
MY_ANSWERS="D A D A I A I I A D" bash curriculum/m01-iam-identity/labs/lab06-scp-worksheet.sh
```

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m01-iam-identity/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인하고, 모든 lab을 **두 번씩**(멱등성) 실행하고, 워크시트 채점 모드와 sdk 예제를 실행한다. 마지막 줄이 `MODULE m01 OK`면 통과.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

에뮬레이터 1.0.322에서 직접 확인한 것이다. 대부분은 재생성된 [FIDELITY.md](../../docs/FIDELITY.md)의 "M01 IAM과 계정 관리" 사실 표에도 있다. ★는 그 보고서에 아직 없는 이 모듈만의 관찰이다.

| 오퍼레이션 / 동작 | 증상 | 이 모듈의 대응 |
|---|---|---|
| `organizations` `CreatePolicy`·`AttachPolicy`·`ListPolicies`·`ListPoliciesForTarget`·`EnablePolicyType` | `501 NotImplemented` (SCP 사용 불가). `DescribeOrganization`은 SCP를 `ENABLED`로 표시 | lab06 SCP 워크시트(시뮬레이터 채점) |
| `organizations` `CreateAccount`·`ListAccounts`·`DescribeAccount`·`ListAccountsForParent`·`MoveAccount`·`ListChildren`·`ListParents`·`UpdateOrganizationalUnit` | `501 NotImplemented` | OU 생성·조회·삭제(`ListOrganizationalUnitsForParent`, `DescribeOrganizationalUnit`)만 실습 |
| `iam` `EnableMFADevice`·`ListMFADevices`·`DeactivateMFADevice`·`DeleteVirtualMFADevice` | `501 NotImplemented`. `CreateVirtualMFADevice`는 동작하므로 만든 가상 MFA 장치는 에뮬레이터 재시작 전까지 지울 수 없다 | MFA는 개념 + 시뮬레이터 `--context-entries`로 조건 판정 |
| `iam` `GetAccountSummary`·`GetAccountPasswordPolicy` | `InvalidAction: unknown action` (501이 아님). `UpdateAccountPasswordPolicy`는 동작하고 `CreateLoginProfile`에 실제로 적용됨 | 문서에서 개념만 |
| ★ `iam` `GenerateCredentialReport` 재요청 | 4시간 안에 다시 요청하면 `LimitExceeded` ("1 report every 14400 seconds") | lab01은 기존 보고서를 읽는다 |
| S3·SQS·DynamoDB의 사용자 정책 평가 | **리소스 단위 데이터 API**(S3 `GetObject`·`PutObject`·`DeleteObject`·`ListObjectsV2`·`PutBucketPolicy`·`HeadBucket`, SQS `SendMessage`·`ReceiveMessage`·`GetQueueAttributes`·`DeleteQueue`, DynamoDB `PutItem`·`GetItem`·`Scan`)는 암묵적·명시적 Deny 모두 집행한다. 평가하지 않는 것은 **계정·관리 API**(S3 `ListBuckets`·`CreateBucket`·`DeleteBucket`·`PutBucketVersioning`, SQS `ListQueues`·`CreateQueue`, DynamoDB `ListTables`·`CreateTable`·`DescribeTable`·`DeleteTable`). 그래서 정책 없는 사용자가 **다른 사람이 만든 버킷·테이블을 지울 수도 있다** | lab03 Part B는 `CreateBucket`·`ListBuckets` 통과(🟡)와 `GetObject` 거부를 함께 보여 준다 |
| ★ 그 밖의 서비스 평가 여부 (정책 없는 사용자) | 거부: IAM, EC2, KMS, Secrets Manager. 통과: Lambda `ListFunctions`, SNS `ListTopics`, Logs `DescribeLogGroups`, SSM `DescribeParameters`, CloudWatch `ListMetrics`, RDS `DescribeDBInstances`, Organizations `ListRoots` | 거부 재현은 IAM·EC2로만 |
| STS AssumeRole — 호출자 정책 미평가 | AssumeRole은 **역할의 신뢰 정책만** 검사하고 호출자의 자격 증명 정책은 전혀 평가하지 않는다. 신뢰 정책이 계정 루트를 믿으면 `sts:AssumeRole` 허용이 없는 사용자도, 심지어 `sts:AssumeRole`에 **명시적 Deny**가 붙은 사용자도 역할을 맡았다. 실제 AWS는 둘 다 거부 | lab02는 사용자 ARN을 직접 믿는 신뢰 정책 사용(실제 AWS와 결과가 같은 구성). 신뢰 정책 쪽 조건(`sts:ExternalId`)은 올바르게 집행됨 |
| 세션 정책 | IAM API에는 적용, **EC2에는 적용하지 않음**(세션 정책의 명시적 Deny도 EC2에서는 무시. EC2는 역할 권한 정책과 권한 경계는 적용) | lab02는 IAM API로 세션 정책 확인 |
| 자격 증명 정책의 `Condition` (실제 호출) | 전역 조건 키는 **서비스·키마다 다르게** 평가된다(FIDELITY `iam-conditions`). S3 `ListObjectsV2`·SQS `SendMessage`의 `aws:SecureTransport`·`aws:PrincipalAccount`는 **AWS와 같다**(맞는 조건부 Allow는 통과, 맞지 않는 조건부 Deny는 적용 안 됨). 반면 S3·SQS의 `aws:RequestedRegion`, 그리고 DynamoDB `Scan`·EC2 `DescribeVpcs`·IAM `ListUsers`의 세 키(`aws:SecureTransport`·`aws:PrincipalAccount`·`aws:RequestedRegion`)는 **조건부 Allow는 결코 적용되지 않고 조건부 Deny는 항상 적용**된다. 저자가 EC2·IAM에서 본 것: `StringNotEquals`·`Null` 같은 다른 연산자도, 서로 모순되는 조건도 전부 Deny 적용. 예외는 IAM API의 `aws:username`(자기 이름일 때만 정확)이고 EC2는 `aws:username=nobody` Deny도 적용. 정책 시뮬레이터(`--context-entries`)는 같은 조건을 올바르게 판정한다 | 조건 판정은 시뮬레이터로 한다(레슨 03 Part D, lab06). 실제 호출로 보여 줄 수 있는 것은 S3·SQS의 `aws:SecureTransport`·`aws:PrincipalAccount`뿐이다 |
| `iam:PassRole` | `run-instances --iam-instance-profile`에 PassRole을 검사하지 않음(명시적 Deny가 있어도 통과) | 문서에서 설명 |
| `iam` `CreatePolicy`에 `Principal` | 자격 증명 기반 정책에 `Principal`이 있어도 받아 준다(실제 AWS: `MalformedPolicyDocument`) | 레슨 02에 명시 |
| 비활성 액세스 키 | `Inactive`로 바꾼 키를 **IAM API만** 거부한다(`InvalidClientTokenId`). STS(`GetCallerIdentity`, `AssumeRole` — 임시 자격 증명 발급까지 됨), EC2, S3, SQS, KMS, DynamoDB, Lambda는 받아들인다. 삭제한 키는 STS도 `InvalidClientTokenId` | 레슨 01 "실제 AWS에서는" |
| ★ `simulate-principal-policy`와 정책 변수 | `${aws:username}` 리소스를 채우지 않아 `implicitDeny`로 판정(실제 호출은 허용됨) | 워크시트에 정책 변수를 쓰지 않음 |
| `simulate-custom-policy --policy-input-list file://...` | `InvalidInput: Policy input list item 1 has invalid content`. `"$(cat 파일)"`로 넘기면 동작 | lab06은 문자열로 전달 |
| `sts:AssumeRoleWithWebIdentity` | 토큰 서명을 검증하려고 발급자 공개 키를 가져오려 함 → 임의 토큰은 `InvalidIdentityToken` | lab07은 공급자·역할 구성까지(🟡) |
| IAM Identity Center | 계정 인스턴스가 미리 있음. `CreatePermissionSet`·`ListPermissionSets`는 `ValidationException`(계정 인스턴스 미지원 — AWS 규칙과 같음). `identitystore create-user`는 동작 | lab05에서 읽기만 |
| 임시 자격 증명 키 접두사 | `EMULATOR…` (실제 AWS: 임시 `ASIA…`, 장기 `AKIA…`) | 레슨 04 "실제 AWS에서는" |
| 계정 분리 없음 | 모든 요청이 계정 `000000000000`. 교차 계정 실습 불가 | 교차 계정은 다이어그램·워크시트 |

## 설계 대비 대체 사유

- **SCP (CURRICULUM 🔴)**: SCP API가 501이라 lab06 워크시트로 대체했다. 각 계층 SCP와 IAM 정책을 `simulate-custom-policy`로 따로 평가해 교집합을 계산하므로 판정 논리는 실제 AWS와 같다. 계층 구조(루트·OU·하위 OU), 거부 목록/허용 목록 전략, 관리 계정 예외까지 문항으로 다룬다.
- **권한 거부 lab의 S3 대비 (CURRICULUM 🟡 "같은 사용자가 S3에서는 통과")**: 실제로는 S3가 **부분적으로** 평가했다(객체 API 거부, 버킷 관리 API 통과). 실습은 이 사실 그대로 — 통과하는 `CreateBucket`·`ListBuckets`(🟡)와 거부되는 `GetObject`를 나란히 보여 준다.
- **추가 실습**: lab07(OIDC 연동, 레슨 6)은 CURRICULUM에 없지만 레슨 6을 손으로 만져 보게 하려고 넣었다. 레슨 4의 세션 정책·외부 ID·최대 세션 시간·인스턴스 프로파일은 lab02에 포함했다. boto3 예제는 요구된 "최소 권한 정책 생성기" 외에 `assume_role_session.py`를 더했다.
- **개념만 다룬 항목**(CURRICULUM 지시대로): MFA 활성화(501), AWS RAM, Directory Service, 통합 결제, Control Tower. IAM Identity Center는 에뮬레이터 인스턴스를 읽어 계정/조직 인스턴스 차이를 보여 주는 데 그쳤다.
