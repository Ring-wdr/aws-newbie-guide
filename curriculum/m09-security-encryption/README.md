# M09. 보안 서비스와 암호화

> 시나리오: TodayOrder가 첫 보안 감사를 받는다. "데이터는 암호화되나? 키는 누가 갖나? 비밀번호는 어디 있나? 누가 무엇을 했는지 아나? 지금 규정을 어기는 리소스는? 공격을 알아챌 수 있나?" 질문 하나에 서비스 하나씩 답한다.
> 도메인: D1 · 예상 시간: 약 5시간

## 목표

- KMS 키 종류·키 정책·봉투 암호화·교체·삭제 대기·다중 리전 키를 설명하고, KMS와 CloudHSM, SSE-S3·SSE-KMS·SSE-C 중에서 고를 수 있다.
- Secrets Manager와 Parameter Store를 구분하고, 버전 스테이지와 Lambda 자동 교체를 구성할 수 있다.
- ACM으로 인증서를 가져오고 DNS 검증을 요청하며, 전송 중 암호화 지점을 짚을 수 있다.
- CloudTrail과 Config의 차이를 알고, Config 규칙으로 위반을 찾고 자동 수정할 수 있다.
- GuardDuty·Inspector·Macie·Security Hub·Detective를 한 줄로 구분할 수 있다.
- WAF·Shield·Network Firewall·보안 그룹·NACL로 심층 방어를 설계할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [KMS — 키 종류, 키 정책, 봉투 암호화, 교체, 다중 리전 키 (그리고 CloudHSM)](./01-kms.md) | 60분 | 🟢 |
| 2 | [비밀 관리 — Secrets Manager vs Parameter Store, 자동 교체](./02-secrets-management.md) | 50분 | 🟢 |
| 3 | [인증서(ACM)와 전송 중 암호화](./03-acm-and-encryption-in-transit.md) | 35분 | 🟢 / 🟡 / 🔴 |
| 4 | [감사와 규정 준수 — CloudTrail, Config, Audit Manager, Artifact](./04-audit-and-compliance.md) | 55분 | 🟡 / 🟢 |
| 5 | [위협 탐지 — GuardDuty, Inspector, Macie, Security Hub, Detective](./05-threat-detection.md) | 35분 | 🟡 |
| 6 | [네트워크·앱 방어 복습과 심층 방어 — WAF, Shield, Network Firewall](./06-defense-in-depth.md) | 30분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| KMS 키·별칭·Encrypt/Decrypt·암호화 컨텍스트·**비활성화 시 Decrypt 실패**·4 KiB 한도·교체·삭제 예약(`KMSInvalidStateException`)·다중 리전 키 | [labs/lab01-kms-basics.sh](./labs/lab01-kms-basics.sh) | 1 | 🟢 |
| 키 정책 vs IAM 정책, 키 정책 명시적 Deny(암호화 컨텍스트 조건) | [labs/lab02-kms-key-policy.sh](./labs/lab02-kms-key-policy.sh) | 1 | 🟢 |
| 봉투 암호화: GenerateDataKey + 로컬 AES-256-GCM(평문 키는 파이프로만), 변조 탐지, 키 비활성화로 잠김 | [labs/lab03-envelope-encryption.sh](./labs/lab03-envelope-encryption.sh) | 1 | 🟢 |
| Secrets Manager 버전 스테이지·롤백·**Lambda 자동 교체**·삭제 복구 | [labs/lab04-secrets-manager.sh](./labs/lab04-secrets-manager.sh) | 2 | 🟢 |
| Parameter Store 계층·SecureString·KMS 연동·버전·레이블·티어·Secrets Manager 참조 | [labs/lab05-parameter-store.sh](./labs/lab05-parameter-store.sh) | 2 | 🟢 |
| ACM 자체 서명 인증서 가져오기(ISSUED) / DNS 검증 요청(PENDING_VALIDATION) | [labs/lab06-acm-certificates.sh](./labs/lab06-acm-certificates.sh) | 3 | 🟢 가져오기 · 🟡 요청·검증 레코드 · 🔴 발급 |
| CloudTrail 추적(버킷 정책·멀티 리전·무결성 검증), IAM 이벤트 조회, S3 로그 파일 | [labs/lab07-cloudtrail.sh](./labs/lab07-cloudtrail.sh) | 4 | 🟡 |
| Config 기록기·전달 채널·관리형 규칙 NON_COMPLIANT → COMPLIANT·**자동 수정** | [labs/lab08-config-rule.sh](./labs/lab08-config-rule.sh) | 4 | 🟢 |
| GuardDuty 탐지기·샘플 결과, Macie·Security Hub·Inspector·Detective 상태 | [labs/lab09-guardduty-findings.sh](./labs/lab09-guardduty-findings.sh) | 5 | 🟡 |
| Network Firewall 아웃바운드 도메인 허용 목록 규칙 그룹·정책 | [labs/lab10-network-firewall.sh](./labs/lab10-network-firewall.sh) | 6 | 🟡 (구성만) |
| boto3: 봉투 암호화(KMS 데이터 키 + 로컬 AES-256-GCM) | [sdk/envelope_encryption.py](./sdk/envelope_encryption.py) | 1 | 🟢 |
| boto3: 앱 설정 로더(Parameter Store + Secrets Manager, TTL 캐시) | [sdk/app_config_loader.py](./sdk/app_config_loader.py) | 2 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m09-security-encryption/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤 sdk 예제의 안전 장치를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성) sdk 예제를 실행한다. 마지막 줄이 `MODULE m09 OK`면 통과. `labs/_lib.sh`는 lab 공용 도우미(단언, 폴링, JSON 가공, KMS 별칭·IAM 정리)이며 단독으로 실행하지 않는다. lab06은 자체 서명 인증서를 만들려고 `openssl`(macOS·Linux 기본 포함)을 쓴다. lab03과 sdk의 로컬 암호화는 `cryptography`(프로젝트 의존성)를 쓴다 — import 오류가 나면 `uv sync`.

**KMS 키는 바로 지울 수 없다.** 각 lab은 다시 실행할 때 옛 키를 7일 삭제 대기로 예약하고 새 키를 만든다. 에뮬레이터를 재시작하면 모두 사라진다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 봉투 암호화의 로컬 암호 (lab03, sdk/envelope_encryption.py)

둘 다 프로젝트 의존성 `cryptography`의 **AES-256-GCM**을 쓴다(메시지마다 96비트 무작위 nonce, KMS 암호화 컨텍스트를 AAD로 묶음, 변조 시 `InvalidTag`). 대체 구현은 없다 — `import cryptography`가 실패하면 저장소 루트에서 **`uv sync`를 다시 실행**한다(의존성이 추가되기 전에 만든 환경이면 필요하다).

lab03은 셸 실습이지만 로컬 암호화만 짧은 파이썬으로 한다. 평문 데이터 키를 `aws kms generate-data-key` 출력에서 **파이프로만** 넘겨 명령줄(`ps`)·셸 변수·디스크에 남기지 않기 위해서다. 예전 판의 `openssl enc -aes-256-cbc -K <키>`는 무결성 검사가 없고 키가 `ps`에 보여 바꿨다(레슨 1에 이유를 적었다).

## 에뮬레이터 제약

에뮬레이터 1.0.322, 포트 9308에서 직접 실행해 확인했다.

| 오퍼레이션 / 동작 | 증상 | 실습에서의 처리 |
|---|---|---|
| KMS `Decrypt`(비활성화된 키) — **저자 확인 항목** | `DisabledException ... is disabled.` 로 실패, `enable-key` 후 성공 (실제 AWS와 같음) | 🟢 lab01 4단계, lab03 6단계에서 단언 |
| S3 SSE-KMS 객체 읽기(키 비활성화) | 읽힌다(M04에서 관찰, FIDELITY) | "키를 끄면 못 읽는다"는 KMS 직접 호출로 시연 |
| SSM SecureString 복호화(고객 관리형 키 **비활성화**) | 복호화된다 — SSM이 키 상태를 확인하지 않음(AWS와 다름). 키 정책 **Deny**는 집행됨 | lab05는 키 정책 Deny로 시연하고 비활성화 결과는 참고로 출력 |
| SSM 공개 파라미터 `/aws/service/global-infrastructure/...` | 비어 있음 | 사용 안 함 |
| ACM DNS 검증 | Route 53에 검증 CNAME을 넣어도 `PENDING_VALIDATION`에서 바뀌지 않음. `.example`·`.test`·`.local`·`.invalid` 최상위 도메인은 곧 `FAILED`(`ADDITIONAL_VERIFICATION_REQUIRED`) | 요청 🟡 / 발급 🔴. DNS 검증 요청은 예약 이름 `api.todayorder.example.com`으로 |
| CloudTrail `LookupEvents` | IAM 이벤트는 나오지만 **S3·KMS 이벤트는 나오지 않음**. `sourceIPAddress`가 `null`. 로그 파일은 거의 즉시 S3에 씀 | 🟡. 단언은 IAM 이벤트로 |
| Config 자동 수정 | `Automatic=true` 자동 수정이 **실제로 실행**되어 버킷 버전 관리를 켬(규칙 범위의 모든 위반 리소스). 자동 수정이 연결된 규칙도 `DeleteConfigRule`로 지워지고(실제 AWS는 `ResourceInUseException`), 남은 수정 설정이 같은 이름의 규칙에 다시 붙음 | lab08 7단계에서 시연. 규칙 범위를 태그로 좁히고, 시작·끝에 수정 설정 삭제 |
| Config 평가 결과 | 지운 버킷의 평가 결과를 이름으로 기억 | 평가 대상 버킷 이름에 실행마다 다른 접미사 |
| GuardDuty | 실제 위협 탐지 없음(샘플 결과만). 결과가 EventBridge(`source=aws.guardduty`)로 전달되지 않았고 Security Hub에도 모이지 않음 | 🟡 |
| Inspector·Macie·Security Hub·Detective | 활성화·상태 조회까지. Audit Manager `GetAccountStatus`는 501 | 상태 읽기만 |
| Network Firewall | 규칙 그룹·정책 생성은 되지만 트래픽 검사 없음 | 🟡 구성만 |

## 설계 대비 대체 사유

CURRICULUM.md의 M09 실습을 모두 구현했고, 확인 결과에 따라 등급을 다음과 같이 확정·보강했다.

- **"키 비활성화 시 Decrypt 실패"(저자 확인)**: 🟢로 확정 — `DisabledException`.
- **Secrets Manager 🟢 + 자동 교체 추가**: 처음 탐침 보고서는 `RotateSecret`을 오류로 기록했지만, 그것은 Lambda 리소스 정책이 없을 때의 정상 동작이었다(재생성된 FIDELITY.md의 `security-better` 탐침은 교체 실행을 확인한다). `add-permission` 후 에뮬레이터가 교체 Lambda를 실제로 4단계 호출해 비밀번호를 바꾸는 것을 확인해 lab04에 넣었다.
- **Config 🟢 + 자동 수정 추가**: 자동 수정(SSM Automation)이 실제로 실행되어 lab08에 넣었다.
- **CloudTrail 🟡, GuardDuty 🟡, ACM DNS 검증 🟡/🔴**: 그대로.
- 추가: 레슨 6용 lab10(Network Firewall, 🟡). CURRICULUM의 레슨 6에는 실습이 지정되지 않았지만 심층 방어의 빠진 계층을 손으로 만들어 보게 했다.
