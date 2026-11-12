# M09 치트시트 — 보안 서비스와 암호화

## 한 줄 구분 (시험이 원하는 것)

| 헷갈리는 짝 | 한 줄 |
|---|---|
| GuardDuty | **위협·침해 탐지**(CloudTrail·VPC Flow Logs·DNS 로그 분석, 에이전트 불필요) |
| Inspector | **취약점(CVE)·네트워크 노출 스캔**(EC2·ECR 이미지·Lambda) |
| Macie | **S3 민감 데이터(PII)** 발견 |
| Security Hub (현 Security Hub CSPM) | 보안 결과 **모으기 + 표준 준수 점수**(CIS, AWS 모범 사례). 2025-12 출시된 새 Security Hub는 이들 신호를 상관 분석해 위험 우선순위 |
| Detective | 결과의 **원인·범위 조사**(행동 그래프) |
| CloudTrail | **누가 무엇을 했나**(API 호출 기록, 이벤트 기록 90일 무료) |
| Config | **리소스 구성 이력 + 규칙 준수 평가 + 자동 수정** |
| Audit Manager | **내** 감사 증거 수집 자동화 |
| Artifact | **AWS의** 규정 준수 보고서 다운로드 |
| Secrets Manager | **자동 교체**·교차 리전 복제가 필요한 비밀, 유료 |
| Parameter Store | 설정 + SecureString, **계층**, Standard 무료, 교체 없음 |
| KMS | 관리형 키, AWS 서비스 통합, 키 정책 |
| CloudHSM | **전용·단일 테넌트 HSM**, 고객 단독 키 통제, PKCS#11/JCE |

## S3 서버 측 암호화

| | 키 관리 | 키 사용 감사 | 키 통제(정책·비활성화) | 언제 |
|---|---|---|---|---|
| SSE-S3 | S3 | ❌ | ❌ | 기본값, 추가 비용 없음 |
| SSE-KMS | KMS(aws/s3 또는 고객 관리형) | ✅ CloudTrail | ✅ | 감사·분리 통제 요구 (대량이면 S3 버킷 키) |
| DSSE-KMS | KMS, 2계층 | ✅ | ✅ | 2계층 암호화 규정 |
| SSE-C | 고객이 요청마다 키 제공 | ❌ | 고객 몫 | 키를 AWS에 두면 안 될 때 (HTTPS 필수, **2026-04부터 새 버킷은 기본 차단** → `BlockedEncryptionTypes`로 허용) |
| 클라이언트 측 | 앱 | – | – | AWS가 평문을 보면 안 될 때 |

## KMS 숫자·규칙

- `Encrypt` 최대 **4,096바이트** → 그 이상은 **봉투 암호화**(`GenerateDataKey`).
- 키 삭제 대기 **7~30일**(기본 30). 대기 중 사용 → `KMSInvalidStateException`. 취소하면 `Disabled`.
- 비활성 키 사용 → `DisabledException`.
- 자동 교체: 고객 관리형 대칭 키, 기간 **90~2560일**(기본 365). AWS 관리형 키는 매년. 교체 후에도 키 ID 동일, 옛 암호문 복호화 가능. `rotate-key-on-demand`로 즉시 교체.
- 다중 리전 키: ID `mrk-…`, 복제본은 같은 키 재료.
- 암호화 컨텍스트가 다르면 `InvalidCiphertextException`. 키 정책 조건 `kms:EncryptionContext:<키>`.
- 기본 키 정책 = root에 `kms:*` = **IAM 정책으로 위임**. 키 정책 Deny는 IAM Allow보다 우선.
- 교차 계정 = 키 정책 + 상대 계정 IAM 정책 (또는 grant). 공유되는 암호화 스냅샷은 **고객 관리형 키**.
- `alias/aws/…` 이름은 AWS 관리형 키 전용.

## Secrets Manager / Parameter Store

| | Secrets Manager | Parameter Store |
|---|---|---|
| 교체 | ✅ Lambda 4단계(create→set→test→finish), RDS 관리형 | ❌ |
| 버전 | `AWSCURRENT`/`AWSPREVIOUS`/`AWSPENDING` | 번호 + 레이블(`이름:레이블`, `이름:버전`) |
| 크기 | 64 KB | Standard 4 KB(무료) / Advanced 8 KB |
| 기타 | 교차 리전 복제, 삭제 복구 기간 7~30일(기본 30) | `GetParametersByPath --recursive`, `/aws/reference/secretsmanager/…` |

- 교체 Lambda에는 **리소스 정책**(`secretsmanager.amazonaws.com`) 필요. VPC 안이면 엔드포인트/NAT.
- SecureString 읽기 = `ssm:GetParameter` + `kms:Decrypt`.

## ACM / 전송 중 암호화

- ACM 공인 인증서 무료·자동 갱신(DNS 검증 권장). **가져온 인증서는 자동 갱신 안 됨.**
- CloudFront = **us-east-1** 인증서, ALB = 같은 리전.
- S3 HTTPS 강제 = `aws:SecureTransport=false` Deny. 사내 인증서 = ACM Private CA. DX 암호화 = DX 위 VPN/MACsec.

## CloudTrail / Config

- 이벤트 기록 90일 무료(관리 이벤트). 장기 보관·조직 전체 = **추적 → S3**(멀티 리전, 무결성 검증). 데이터 이벤트(S3 객체·Lambda Invoke)는 별도 설정·과금. 비정상 호출량 = Insights.
- Config = 기록기 + 전달 채널(버킷 정책) + 규칙. 위반 → **자동 수정(SSM Automation)**, 묶음 = 적합성 팩, 다계정 = 집계자.

## 심층 방어

| 계층 | 서비스 |
|---|---|
| DDoS | Shield Standard(자동) / Advanced |
| L7 웹 공격 | WAF |
| VPC 경계·도메인 허용 목록·IPS | Network Firewall |
| DNS 질의 차단 | Route 53 Resolver DNS Firewall |
| 서브넷, 거부 규칙 | NACL |
| 인스턴스, 허용만 | 보안 그룹 |
| 여러 계정 일괄 | Firewall Manager |
