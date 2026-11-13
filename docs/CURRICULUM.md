# 커리큘럼 총 설계서

> 대상: 백엔드 개발자 주니어/신입 · 목표: AWS SAA-C03 합격 수준의 개념 숙지 + 손으로 만져 본 경험
> 실습 환경: [aws-emulator](https://github.com/aws/aws-emulator) (로컬, AWS 계정·과금 없음) · 도구: AWS CLI v2 + Python(boto3)

이 문서는 커리큘럼 전체의 **단일 기준(source of truth)** 이다. 모듈 저자(에이전트)는 여기 정의된 범위·순서·실습 목록을 따른다. 작성 규칙은 [AUTHORING.md](./AUTHORING.md), 에이전트 역할과 브랜치는 [AGENTS.md](./AGENTS.md) 참고.

---

## 1. 설계 원칙

1. **먼저 만들고, 그 다음 이해한다.** 모든 레슨은 `왜 필요한가 → 핵심 개념 → 직접 해 보기 → 실제 AWS에서는 → 시험 포인트 → 스스로 확인` 순서다([AUTHORING.md 2장](./AUTHORING.md)).
2. **출력은 실제로 실행한 것만 싣는다.** 문서에 실린 모든 명령과 출력은 에뮬레이터에서 실제 실행해 얻은 것이어야 한다. 지어낸 출력 금지.
3. **에뮬레이터의 한계를 숨기지 않는다.** 에뮬레이터는 AWS가 아니다. 각 실습에는 충실도 등급을 붙이고, 재현되지 않는 동작은 "실제 AWS에서는" 박스로 설명한다(3장).
4. **백엔드 개발자의 언어로 설명한다.** "왜 이 서비스가 필요한가"를 서버 한 대에서 시작한 서비스가 커지는 이야기(4장 러닝 시나리오)로 풀어 간다.
5. **시험은 '무엇을 고를 것인가'를 묻는다.** 모듈마다 비교표(언제 A, 언제 B)와 시나리오형 문제를 둔다.

## 2. SAA-C03 시험 도메인 매핑

| 도메인 | 비중 | 핵심 질문 | 주 담당 모듈 |
|---|---|---|---|
| D1. 보안 아키텍처 설계 | 30% | 누가, 무엇에, 어떻게 접근하는가 / 데이터는 암호화되는가 | M01, M02, M09, (M04·M05 일부) |
| D2. 복원력 있는 아키텍처 설계 | 26% | 하나가 죽어도 서비스가 사는가 / 느슨하게 결합됐는가 | M03, M05, M06, M07, M08, M10, M12 |
| D3. 고성능 아키텍처 설계 | 24% | 워크로드에 맞는 스토리지·DB·컴퓨트·네트워크인가 | M03, M04, M05, M07, M08, M11 |
| D4. 비용 최적화 아키텍처 설계 | 20% | 같은 요구를 더 싸게 만족하는가 | M13, (전 모듈 "비용 포인트") |

모든 레슨 머리말에는 해당 도메인 태그(`D1`~`D4`)를 단다.

## 3. 에뮬레이터 충실도 등급

aws-emulator는 **컨트롤 플레인(리소스 생성·조회·수정·삭제)** 충실도가 가장 높고, 데이터 플레인과 서비스 간 연동은 서비스마다 다르다. 알려진 주요 제약:

- IAM 정책 평가는 **부분적이다**. IAM·EC2·KMS·Secrets Manager와 S3·SQS·DynamoDB의 **리소스 단위 데이터 요청**(GetObject·PutObject·ListObjectsV2, SendMessage·ReceiveMessage, PutItem·Scan 등)은 사용자 정책의 암묵적·명시적 Deny를 집행한다. 그러나 S3·SQS·DynamoDB의 **계정·관리 요청**(ListBuckets·CreateBucket·DeleteBucket·PutBucketVersioning, ListQueues·CreateQueue, ListTables·CreateTable·DescribeTable·DeleteTable)은 평가하지 않는다. AssumeRole은 역할의 신뢰 정책만 보고 호출자 정책은 보지 않는다(명시적 Deny도 무시). 세션 정책은 IAM에는 적용되고 EC2에는 적용되지 않는다. `iam:PassRole`은 검사하지 않는다. 비활성 액세스 키는 IAM API만 거부한다. 자격 증명 정책의 전역 조건 키는 서비스·키마다 다르게 평가된다: S3·SQS 데이터 요청은 `aws:SecureTransport`·`aws:PrincipalAccount` 조건을 AWS처럼 판정하지만 `aws:RequestedRegion` 조건이 붙은 문장은 Allow가 결코·Deny가 항상 적용되고, DynamoDB·EC2·IAM은 세 키 모두 Allow가 결코·Deny가 항상 적용된다. 따라서 조건이 있는 정책은 `iam simulate-*-policy`(`--context-entries`)로 판정한다. `iam simulate-*-policy`와 신뢰 정책 조건은 올바르게 판정하고, 버킷 정책 Deny·KMS 키 정책·서비스 역할 신뢰 정책·Lambda 실행 역할·Glue 작업 역할 정책은 집행된다. 공식 문서는 "보안 테스트에 쓰지 말라"고 하며, 이 동작은 버전에 따라 바뀔 수 있다.
- 리전·계정을 **분리하지 않는다**. 어떤 리전·계정 ID로 요청해도 받아 주지만 리소스를 나눠 보관하지 않는다. 계정은 `000000000000`으로 보이며, 이 커리큘럼은 리전을 `us-east-1` 하나로 고정한다.
- S3 Control API(액세스 포인트, 계정 수준 퍼블릭 액세스 차단 등)는 SDK가 호스트명에 계정 ID를 붙이기 때문에 에뮬레이터에 **도달하지 않는다** → 🔴.
- 엔드포인트는 반드시 `127.0.0.1` (`localhost`를 쓰면 일부 SDK(JS·Java·Go)가 S3 버킷명을 호스트명에 넣어 실패한다). `AWS_DISABLE_HOST_PREFIX_INJECTION=true`는 에뮬레이터 전용 설정이다.
- 모든 상태는 **메모리**에 있고 에뮬레이터를 끄면 사라진다.
- EC2 인스턴스는 상태만 바뀌고 **부팅되지 않는다**. 반대로 Lambda `Invoke`는 함수 코드를 **실제로 실행**한다(CPython이 아니라 RustPython과 축소된 boto3). SNS→SQS·S3 이벤트·EventBridge·Pipes·Step Functions(Retry/Catch 포함)·CloudWatch 경보→SNS 같은 서비스 간 전달, Glue Python shell 작업, Athena SQL(SQLite 계열 — 파티션 열·Trino 함수 없음), Secrets Manager 교체, Config 자동 수정, ALB 앞의 WAF 차단도 실제로 일어난다. Lambda 리소스 정책은 REST API·SNS·S3 경로에서 집행되고 HTTP API만 예외다.
- RDS 인스턴스·Aurora 쓰기 엔드포인트·ALB·NLB·CloudFront의 **엔드포인트는 `127.0.0.1:<임의 포트>`로 컨테이너 안에만** 열린다. 학습자 PC에서 접속할 수 없다(API Gateway 실행 URL만 예외). ElastiCache·Aurora 리더 엔드포인트는 실제 AWS 형식 이름이라 어디서도 접속할 수 없고, 기본 설정에서는 이름 해석이 바로 실패하고, 격리를 끈(`EMULATOR_DNS=host`) 환경에서는 바깥 DNS에 묻게 되므로 실습에서 접속하지 않는다.
- 조정·관리·삭제 계열에 501이 몰려 있다: Auto Scaling 조정 정책·수명 주기 후크·조회, Organizations SCP·계정, IAM MFA 장치, VPC 피어링 수락·거절·삭제·`ReplaceRoute`·TGW 정적 경로·연결 삭제·Egress-only IGW·리전 NAT·VPN·Client VPN, AMI 생성, RDS PITR·복제본 승격, ElastiCache 복제 그룹 삭제, Glue 크롤러, Athena 작업 그룹 목록·삭제, SSM Session Manager·패치, Backup·DMS 목록·삭제 계열, Cost Explorer.
- 시간 기반 동작은 빠르거나 없다: TTL 삭제·Firehose 버퍼·Glacier 복원은 수 초, EventBridge Scheduler `at()`은 지정 시각 전에 발화, S3 수명 주기 전환·Lambda 비동기 실패 대상·Route 53 상태 확인 실패는 일어나지 않는다. CloudFormation은 `DescribeStacks`가 올 때만 진행하고 대기 리소스에 약 10초 마감이 있어, NAT 경로가 있는 스택은 CLI `wait`로는 롤백되고 2초 간격 폴링으로는 성공한다.
- 동기 Lambda 호출은 회당 약 7 MiB의 에뮬레이터 메모리를 회수하지 않는다(기본 상한 2g, 반복 실습 시 `scripts/emulator-reset.sh`). 노트북이 잠든 뒤에는 VM 시계가 어긋나 서명 오류가 날 수 있다(M00 레슨 3).
- 일부 리소스는 **외부 호스트에 접속을 시도**할 수 있다: ECS 작업 정의에 실제 레지스트리 URI를 넣으면 에뮬레이터 컨테이너가 이미지를 받으려 한다. 실습은 `.invalid` 레지스트리와 예약 이름만 쓴다(AUTHORING 규칙 11). `tools/probe/no_external_hosts.py`가 탐침 시작 때는 탐침 코드를, M00 `verify.sh`에서는 `tools`·`scripts`·`src`·`curriculum/` 전체 소스 텍스트를 정적 검사한다. 에뮬레이터 컨테이너는 기본으로 `--dns 127.0.0.1`로 떠 이름 해석 자체가 실패한다(`EMULATOR_DNS=host`로 해제)(API 응답으로 얻은 주소, 변수로 조립한 이름은 보지 못한다).
- 미구현 오퍼레이션은 `501 NotImplemented`를 반환한다.

따라서 모든 실습에 아래 등급 중 하나를 붙인다. 등급은 추측이 아니라 **M00에서 만든 탐침(probe) 결과와 저자의 실제 실행**으로 정한다.

| 등급 | 의미 | 실습 형태 |
|---|---|---|
| 🟢 재현 | API와 동작이 실제처럼 관찰된다 | 끝까지 실행하고 결과를 검증한다 |
| 🟡 부분 | 리소스는 만들어지지만 동작(실행·전달·차단)의 일부 또는 전부가 일어나지 않는다 | 구성까지 실습하고, 동작은 다이어그램과 "실제 AWS에서는" 박스로 보충 |
| 🔴 개념 | 에뮬레이터로 볼 수 없다 (501이거나 의미 없음) | 개념 + 다이어그램 + 시나리오 문제. 가능하면 "설정값을 읽는" 실습으로 대체 |

[`docs/FIDELITY.md`](./FIDELITY.md)(M00 산출물)에 서비스·오퍼레이션별 탐침 결과를 표로 유지한다. 아래 5장의 등급은 에뮬레이터 1.0.322에서 모듈 저자가 실행하고 검증자가 재현한 **확정 결과**다. 실습별 세부 등급과 근거는 각 모듈 README의 "에뮬레이터 제약" 절에 있다.

## 4. 러닝 시나리오 — "오늘의 주문(TodayOrder)"

전 모듈이 하나의 가상 서비스를 키워 간다. 신입 백엔드 개발자가 입사해, 서버 한 대짜리 주문 서비스를 AWS 아키텍처로 옮겨 가는 이야기다.

| 단계 | 서비스 상황 | 마주치는 문제 | 모듈 |
|---|---|---|---|
| 1 | 팀에 합류, 계정을 받는다 | 누구에게 어떤 권한을 줄까 | M01 |
| 2 | 서버를 둘 네트워크가 필요하다 | 공개/비공개를 어떻게 나눌까 | M02 |
| 3 | API 서버를 띄운다 | 트래픽이 늘면? 서버가 죽으면? | M03 |
| 4 | 상품 이미지·영수증을 저장한다 | 어디에, 얼마에, 얼마나 안전하게 | M04 |
| 5 | 주문 데이터를 저장한다 | RDB냐 NoSQL이냐, 읽기 부하·장애 대응 | M05 |
| 6 | 주문 후 알림·정산이 느려진다 | 동기 호출을 끊어 내기 | M06 |
| 7 | 이벤트성 기능을 빠르게 붙인다 | 서버 없이, 컨테이너로 | M07 |
| 8 | 해외 사용자가 생긴다 | 지연 시간, DNS, 공격 방어 | M08 |
| 9 | 보안 감사를 받는다 | 키·비밀·로그·탐지 | M09 |
| 10 | 새벽에 장애가 난다 | 관측, 알람, 인프라 코드화 | M10 |
| 11 | 데이터로 의사결정을 하고 싶다 | 로그·주문 분석 파이프라인 | M11 |
| 12 | 리전 장애 뉴스를 본다 | 백업, DR, 마이그레이션 | M12 |
| 13 | 청구서가 날아온다 | 무엇을 줄일 수 있나 | M13 |
| 14 | 전체를 다시 설계한다 | Well-Architected, 종합 실습, 모의고사 | M14 |

리소스 이름은 `todayorder-` 접두사를 쓴다 (예: `todayorder-images`, `todayorder-orders`).

## 5. 모듈 상세

각 모듈은 `curriculum/mNN-<slug>/` 에 위치한다. 레슨 수와 실습 목록은 **최소 요구**이며, 저자는 탐침 결과에 따라 실습 등급을 확정하고 필요한 경우 실습을 대체할 수 있다(대체 시 모듈 README에 사유 기록). 아래 "실습"은 실제로 작성·검증되어 병합된 내용을 요약한 것이다(에뮬레이터 1.0.322). 정확한 실습 파일 목록은 각 모듈 README를 따른다.

### M00. 오리엔테이션과 실습 환경 — `m00-orientation`
- 목표: 에뮬레이터를 띄우고, CLI·boto3가 AWS가 아니라 에뮬레이터를 향하는지 확인할 수 있다. 클라우드/리전/AZ/공동 책임 모델을 설명할 수 있다.
- 레슨
  1. 클라우드와 AWS 글로벌 인프라 (리전, AZ, 엣지 로케이션, Local Zones, Wavelength, 공동 책임 모델)
  2. aws-emulator란 무엇이고 무엇이 아닌가 (컨트롤/데이터 플레인, 충실도 등급)
  3. 환경 설치 (Colima, Docker, 에뮬레이터 이미지 로컬 빌드 — 배포된 이미지는 없다, AWS CLI, uv/boto3)
  4. 첫 요청 해부: `aws sts get-caller-identity`, SigV4 서명, 엔드포인트, `--debug`로 HTTP 들여다보기
  5. AWS CLI 생존 기술 (`--query`, `--output`, 페이지네이션, `help`) 과 boto3 client/resource/paginator/waiter
- 실습: 🟢 에뮬레이터 기동·헬스체크 · 🟢 S3 버킷 왕복 · 🟢 검증 오류 관찰(DynamoDB 테이블명 2글자) · 🟢 CLI 생존 기술(`--query`·`--output`·페이지네이션·`wait`) · 🟢 에뮬레이터가 AWS와 다른 곳(501, IAM 부분 평가) · 🟢 boto3: S3 왕복, client·resource·paginator·waiter
- 산출물(환경): `scripts/`, `docs/FIDELITY.md`, `tools/probe/`

### M01. IAM과 계정 관리 — `m01-iam-identity` · D1
- 목표: 사용자/그룹/역할/정책의 관계를 그릴 수 있고, 정책 JSON을 읽고 평가 결과를 손으로 판정할 수 있다.
- 레슨
  1. 루트 사용자, IAM 사용자, 그룹, MFA(루트·사용자 MFA, `aws:MultiFactorAuthPresent` 조건 키) — 그리고 왜 사람에게 액세스 키를 주지 않는가
  2. 정책 문서 해부 (Effect/Action/Resource/Condition/Principal), 자격 증명 기반 vs 리소스 기반
  3. 정책 평가 로직 (명시적 Deny > Allow > 암묵적 Deny), 권한 경계, SCP, 세션 정책
  4. 역할과 STS (AssumeRole, 신뢰 정책, 임시 자격 증명, 교차 계정, 인스턴스 프로파일)
  5. 조직 단위 관리 (Organizations, OU, SCP, 통합 결제, IAM Identity Center, Control Tower 개요, AWS RAM으로 리소스 공유)
  6. 자격 증명 연동 (SAML/OIDC, Cognito와의 구분, AWS Directory Service: Managed Microsoft AD / AD Connector / Simple AD)
- 실습: 🟢 사용자·그룹·정책 · 🟢 역할·신뢰 정책·`assume-role`·세션 정책·ExternalId·인스턴스 프로파일 · 🟢 권한 거부 재현(IAM·EC2, S3 `GetObject`) / 🟡 계정 수준 요청(`CreateBucket`·`ListBuckets`)은 통과 · 🟢 정책 평가 워크시트 10문항을 `simulate-principal-policy`로 채점 · 🟢 Organizations OU / 🔴 SCP(501) — SCP JSON을 쓰고 "SCP ∩ IAM"을 `simulate-custom-policy`로 판정 · 🟡 GitHub Actions용 OIDC 연동 역할 구성 · 🔴 MFA 활성화(501) · 🟢 boto3: 최소 권한 정책 생성기, AssumeRole 세션
- 시험 포인트: 역할 vs 사용자, 교차 계정 접근, SCP는 권한을 주지 않는다, 권한 경계

### M02. VPC 네트워킹 — `m02-vpc-networking` · D1, D2
- 목표: 2-AZ 3-티어 VPC를 CLI로 직접 만들 수 있고, 패킷이 인터넷에서 프라이빗 DB까지 가는 경로를 설명할 수 있다.
- 레슨
  1. IP와 CIDR 속성 과외 (서브넷 계산, RFC1918, AWS 예약 IP 5개)
  2. VPC, 서브넷, 라우팅 테이블, IGW — "퍼블릭 서브넷"의 정의
  3. NAT 게이트웨이 vs NAT 인스턴스, Egress-only IGW, 고가용성 NAT
  4. 보안 그룹 vs NACL (상태 저장/비저장, 평가 순서)
  5. VPC 엔드포인트 (게이트웨이 vs 인터페이스), PrivateLink
  6. VPC 간·온프레미스 연결 (Peering, Transit Gateway, Site-to-Site VPN, Client VPN, Direct Connect, 조합 패턴)
  7. 관측과 방어 (VPC Flow Logs, Network Firewall, Bastion vs Session Manager)
- 실습: 🟢 CIDR 계산을 에뮬레이터로 확인 · 🟢 3-티어 VPC(서브넷 6개, 라우팅, IGW, NAT) · 🟢 `describe-*` 출력으로 경로 추적 워크시트 · 🟢 SG 체이닝 · 🟢 NACL · 🟢 S3 게이트웨이 엔드포인트 + SQS 인터페이스 엔드포인트 · 🟢 Transit Gateway로 VPC 2개 연결(연결·전파를 명시적으로 설정, 정적 경로는 🔴) · 🟡 Peering 요청까지 · 🟡 Flow Logs·Network Firewall 구성 · 🔴 피어링 수락·Egress-only IGW·VPN·Client VPN·Session Manager(501 확인) · 🟢 boto3: VPC 토폴로지 → Mermaid
- 시험 포인트: SG vs NACL, NAT GW AZ별 배치, 게이트웨이 엔드포인트는 S3·DynamoDB, DX+VPN 조합

### M03. 컴퓨트와 확장 — `m03-compute-scaling` · D2, D3, D4
- 목표: 워크로드에 맞는 인스턴스·구매 옵션·스토리지를 고르고, ALB+ASG 무중단 구조를 구성할 수 있다.
- 레슨
  1. EC2 기본 (AMI, 인스턴스 유형 패밀리, 키 페어, 사용자 데이터, 메타데이터/IMDSv2)
  2. 구매 옵션 (온디맨드, 예약, Savings Plans, 스팟, 전용 호스트/인스턴스, 용량 예약)
  3. EBS (gp3/io2/st1/sc1, 스냅샷, 암호화, 다중 연결) 와 인스턴스 스토어
  4. 배치 그룹, ENI/EIP, 최대 절전
  5. 로드 밸런서 (ALB/NLB/GWLB, 대상 그룹, 헬스체크, 스티키 세션, 교차 영역)
  6. Auto Scaling (시작 템플릿, 조정 정책: 대상 추적·단계·단순·예약 + 예측 조정, 쿨다운, 수명 주기 후크), EC2 Auto Scaling vs AWS Auto Scaling(여러 서비스의 조정 계획) vs Application Auto Scaling(ECS·DynamoDB·Aurora 등의 조정)
  7. 그 밖의 컴퓨트 한눈에 (Elastic Beanstalk, Lightsail, Batch, Outposts, VMware Cloud on AWS, Serverless Application Repository)
- 실습: 🟢 인스턴스 시작·상태 전이 · 🟡 구매 옵션 API 읽기 · 🟢 EBS 볼륨·스냅샷 / 🔴 스냅샷 복원·AMI 생성 — AMI 읽기로 대체 · 🟡 배치 그룹·ENI·EIP·최대 절전 · 🟡 ALB·NLB + 대상 그룹 + 리스너 규칙(규칙 동작 확인은 `docker exec` 선택 과제) · 🟢 시작 템플릿 + ASG + 희망 용량 + 인스턴스 새로 고침 / 🔴 조정 정책·예약 작업·수명 주기 후크(501), 자가 치유, 대상 그룹 자동 등록 — 정책 JSON 7개와 "이 지표면 몇 대?" 워크시트 12문항 · 🟡 Beanstalk·Lightsail·Batch · 🟢 boto3: 워크시트 채점기, 태그 없는 리소스 찾기
- 시험 포인트: 스팟 적합 워크로드, ALB vs NLB, 조정 정책 선택, EBS 유형 선택

### M04. 스토리지 — `m04-storage` · D1, D3, D4
- 목표: 객체/블록/파일 스토리지를 구분하고, S3의 보안·수명 주기·복제 기능을 구성할 수 있다.
- 레슨
  1. S3 기본 (버킷, 객체, 키, 일관성 모델, 내구성 vs 가용성)
  2. 스토리지 클래스와 수명 주기 (Standard~Glacier Deep Archive, Intelligent-Tiering)
  3. 버전 관리, MFA Delete, 객체 잠금(WORM), 복제(CRR/SRR)
  4. S3 보안 (버킷 정책, ACL, 퍼블릭 액세스 차단, 암호화 SSE-S3/KMS/C, 미리 서명된 URL, 액세스 포인트)
  5. S3 성능·기능 (멀티파트, Transfer Acceleration, 이벤트 알림, 정적 웹 호스팅, 요청자 지불(Requester Pays)) — S3 Select는 신규 고객에게 제공되지 않으므로 Athena로 대체됨을 한 줄로만 언급
  6. 파일 스토리지 (EFS, FSx 4종) 와 블록과의 선택 기준
  7. 하이브리드·이전 (Storage Gateway: S3 File / Volume / Tape Gateway, DataSync, Snow 패밀리, Transfer Family)
- 실습: 🟢 객체 CRUD · 🟢 스토리지 클래스·수명 주기 규칙 구성(검증은 2026-07 이후 AWS 규칙과 일치, 전환 자체는 일어나지 않음 — 비용은 워크시트) · 🟢 버전 관리·객체 잠금 / 🟡 MFA Delete(집행 안 됨) · 🟢 복제 · 🟢 버킷 정책 Deny·퍼블릭 액세스 차단·SSE · 🟢 미리 서명된 URL · 🔴 액세스 포인트·계정 수준 차단(S3 Control 도달 불가) · 🟢 멀티파트 · 🟢 이벤트 알림 → SQS · 🟡 EFS · 🟡 Storage Gateway·DataSync·Transfer Family · 🟢 boto3: 영수증 업로드 서비스, 수명 주기 점검기
- 시험 포인트: 클래스 선택(검색 시간·최소 보관 기간), SSE 종류, EFS vs EBS vs S3, Snow vs DataSync vs DX

### M05. 데이터베이스 — `m05-databases` · D2, D3
- 목표: 요구 사항을 읽고 적합한 DB를 고르며, RDS의 가용성·확장 옵션과 DynamoDB 키 설계를 설명할 수 있다.
- 레슨
  1. RDS 기본 (엔진, 파라미터/서브넷 그룹, 백업·스냅샷·PITR)
  2. Multi-AZ vs 읽기 전용 복제본 — 가용성과 확장은 다르다
  3. Aurora (스토리지 구조, 엔드포인트, Global Database, Serverless v2), RDS Proxy
  4. DynamoDB 기본 (파티션 키/정렬 키, 용량 모드, 일관성, 조건부 쓰기)
  5. DynamoDB 심화 (GSI/LSI, Streams, TTL, DAX, Global Tables, 트랜잭션)
  6. 캐시 (ElastiCache Valkey/Redis OSS vs Memcached, 캐싱 전략)
  7. 목적별 DB 한눈에 (Redshift, DocumentDB, Neptune, Keyspaces, Timestream, OpenSearch) — QLDB는 2025년 지원 종료되어 다루지 않는다
- 실습: 🟡 RDS 서브넷·파라미터 그룹·스냅샷 복원 · 🟡 Multi-AZ·읽기 복제본 · 🟡 Aurora 엔드포인트·장애 조치·Global Database·RDS Proxy · 🟢 DynamoDB Query vs Scan 소비 용량 · 🟢 GSI·LSI · 🟢 조건부 쓰기·트랜잭션·멱등 토큰 · 🟢 TTL·Streams · 🟢 용량 모드·백업 / 🟡 PITR 특정 시점 복원·글로벌 테이블 · 🟡 ElastiCache·DAX · 🟡 DocumentDB·Keyspaces·Neptune · 🟢 boto3: 재고 동시성 데모, 주문 저장소
- 시험 포인트: Multi-AZ vs Read Replica, Aurora 기능, DynamoDB 용량 모드, DAX vs ElastiCache

### M06. 애플리케이션 통합과 디커플링 — `m06-integration-messaging` · D2
- 목표: 동기 호출을 큐·토픽·이벤트 버스로 바꾸는 설계를 하고, 각 서비스의 전달 보장을 설명할 수 있다.
- 레슨
  1. 왜 디커플링인가 (강결합의 장애 전파, 버퍼링, 팬아웃)
  2. SQS (표준 vs FIFO, 가시성 타임아웃, 롱 폴링, DLQ, 지연 큐)
  3. SNS (토픽, 구독, 필터 정책, FIFO 토픽) 와 SNS+SQS 팬아웃
  4. EventBridge (버스, 규칙, 패턴, 스케줄러, Pipes)
  5. Step Functions (표준 vs 익스프레스, 상태 유형, 오류 처리)
  6. 스트리밍 (Kinesis Data Streams vs Amazon Data Firehose vs SQS, MSK), Amazon MQ는 언제, SaaS 연동은 AppFlow
- 실습: 🟢 SQS 기본(가시성 타임아웃·롱 폴링·지연) · 🟢 DLQ와 재처리 · 🟢 FIFO · 🟢 SNS→SQS 팬아웃·필터 정책(큐 정책 없을 때의 조용한 실패부터) · 🟢 EventBridge 규칙·패턴 → SQS / 🟡 Scheduler(구성만) · 🟢 Step Functions 주문 워크플로(Choice, Retry/Catch, SQS·Lambda 통합) · 🟢 Kinesis 파티션 키와 샤드 · 🟢 boto3: 주문 워커
- 시험 포인트: SQS vs SNS vs EventBridge vs Kinesis 선택, FIFO 처리량, DLQ, 정확히 한 번

### M07. 서버리스와 컨테이너 — `m07-serverless-containers` · D2, D3
- 목표: Lambda·API Gateway·ECS/EKS의 실행 모델과 한계를 알고, 서버리스 API 구조를 구성할 수 있다.
- 레슨
  1. Lambda 실행 모델 (콜드 스타트, 동시성, 타임아웃 15분, 계층, 버전/별칭)
  2. Lambda 트리거와 호출 유형 (동기/비동기/이벤트 소스 매핑), 대상(destination)
  3. API Gateway (REST vs HTTP vs WebSocket, 스테이지, 스로틀링, 캐싱, 권한 부여자)
  4. Cognito (사용자 풀 vs 자격 증명 풀)
  5. 컨테이너 (ECR, ECS 작업 정의/서비스, EC2 vs Fargate 시작 유형, EKS 개요, App Runner, 온프레미스용 ECS Anywhere·EKS Anywhere·EKS Distro)
  6. 서버리스 아키텍처 패턴 (API+Lambda+DynamoDB, S3 이벤트 처리), 프런트엔드·모바일 한눈에 (Amplify, Device Farm)
- 실습: 🟢 Lambda 구성·버전·별칭과 Invoke(동기/비동기/DryRun, 오류·타임아웃) · 🟢 이벤트 소스 매핑(SQS→Lambda, 부분 배치 실패) / 🟡 비동기 호출의 실패·성공 대상·함수 DLQ(전달 안 됨)·재시도 · 🟢 API Gateway REST(MOCK·Lambda 프록시)·HTTP API 호출 · 🟢 서버리스 주문 API(HTTP API + Lambda + DynamoDB, 실행 역할 정책 집행) · 🟢 S3 이벤트 → Lambda → DynamoDB · 🟡 ECR·ECS(태스크는 STOPPED) · 🟢 Cognito 가입·로그인·JWT 권한 부여자·자격 증명 풀 · 🟢 boto3: Lambda 호출, Cognito 로그인
- 시험 포인트: Lambda 한계값, Fargate vs EC2, API 유형 선택, 사용자 풀 vs 자격 증명 풀
- 주의: 에뮬레이터는 HTTP API에서만 Lambda 리소스 정책(`AddPermission`) 없이 호출을 통과시킨다(REST API는 500). 실습 스크립트에는 실제 AWS에 필요한 권한 설정을 빠짐없이 넣는다. Lambda 호출이 많은 모듈이므로 시작할 때 `scripts/emulator-reset.sh`를 권한다.

### M08. DNS와 엣지 — `m08-dns-edge` · D2, D3
- 목표: Route 53 라우팅 정책과 CloudFront 구성을 요구 사항에 맞게 고를 수 있다.
- 레슨
  1. DNS 기초와 Route 53 (호스팅 영역, 레코드, Alias vs CNAME, TTL)
  2. 라우팅 정책 8종 (단순, 가중치, 지연 시간, 장애 조치, 지리적 위치, 지리 근접, 다중값 응답, IP 기반) 과 상태 확인
  3. CloudFront (오리진, 동작, 캐시 정책, OAC, 서명된 URL/쿠키, Lambda@Edge vs Functions)
  4. Global Accelerator vs CloudFront
  5. 엣지 보안 (WAF, Shield, Firewall Manager) — M09와 연결
- 실습: 🟢 호스팅 영역·레코드, Alias vs CNAME, 프라이빗 영역 · 🟢 라우팅 정책 8종 레코드와 `test-dns-answer`(단순·가중치·다중값) / 🟡 지연 시간·지리·IP 기반 응답 선택(호출자 위치 무시) · 🔴 상태 확인·장애 조치 동작 — 워크시트 · 🟡 CloudFront + OAC · 🟡 Global Accelerator · 🟢 WAF Web ACL 구성과 차단(차단 관찰은 `docker exec` 선택 과제) / 🔴 Shield Advanced·Firewall Manager · 🟢 boto3: 가중치 카나리, 라우팅 정책 인벤토리
- 시험 포인트: Alias, 라우팅 정책 선택, CloudFront vs GA, OAC

### M09. 보안 서비스와 암호화 — `m09-security-encryption` · D1
- 목표: 저장·전송 데이터 암호화 방법을 고르고, 탐지·감사 서비스의 역할을 구분할 수 있다.
- 레슨
  1. KMS (키 종류, 키 정책, 봉투 암호화, 교체, 다중 리전 키), CloudHSM은 언제
  2. 비밀 관리 (Secrets Manager vs Parameter Store), 자동 교체
  3. 인증서 (ACM), 전송 중 암호화
  4. 감사와 규정 준수 (CloudTrail, Config, Audit Manager, Artifact)
  5. 위협 탐지 (GuardDuty, Inspector, Macie, Security Hub, Detective) — 한 줄 구분법
  6. 네트워크·앱 방어 (WAF, Shield, Network Firewall) 복습과 심층 방어
- 실습: 🟢 KMS 기본·키 정책·봉투 암호화(AES-256-GCM), 비활성 키 Decrypt 실패 · 🟢 Secrets Manager 버전 스테이지와 Lambda 교체 · 🟢 Parameter Store · 🟢 ACM 인증서 import / 🟡 DNS 검증 요청 / 🔴 발급 · 🟡 CloudTrail · 🟢 Config 관리형 규칙과 자동 수정 · 🟡 GuardDuty 샘플 결과 · 🟡 Network Firewall 구성 · 🟢 boto3: 봉투 암호화, 앱 설정 로더
- 시험 포인트: SSE-KMS vs SSE-S3, Secrets Manager vs Parameter Store, GuardDuty vs Inspector vs Macie, CloudTrail vs Config

### M10. 모니터링·운영·IaC — `m10-monitoring-iac` · D2
- 목표: 지표·로그·알람을 구성하고, CloudFormation 템플릿으로 인프라를 재현할 수 있다.
- 레슨
  1. CloudWatch 지표와 알람 (네임스페이스, 차원, 해상도, 복합 알람, 사용자 지정 지표)
  2. CloudWatch Logs (그룹/스트림, 보존, 지표 필터, 구독 필터, Insights), X-Ray 개요
  3. CloudFormation (템플릿 구조, 파라미터·출력, 변경 세트, 스택 세트, 드리프트)
  4. Systems Manager (Session Manager, Run Command, Patch Manager, 파라미터)
  5. 운영 지원 (Trusted Advisor, Health Dashboard, Service Quotas, Compute Optimizer, License Manager, Service Catalog, Proton, Managed Grafana, Managed Service for Prometheus, Well-Architected Tool)
- 실습: 🟢 사용자 지정 지표 · 🟢 알람 ALARM 전이 → SNS → SQS, `set-alarm-state`, 복합 알람 · 🟢 로그 그룹·지표 필터·Logs Insights · 🟢 CloudFormation으로 2-AZ 3-티어 VPC(Outputs, 롤백, 삭제 — 2초 간격 폴링) / 🟡 드리프트 / 🔴 VPC 스택 변경 세트 · 🟢 앱 스택(S3·SQS·DynamoDB) 변경 세트·종료 방지 · 🔴/🟡/🟢 Systems Manager(Session Manager 501, Run Command 구성만, Parameter Store) · 🟡 운영 지원 서비스 설정 읽기 · 🟢 boto3: 구조화 로그 전송기(EMF)
- 시험 포인트: 기본 지표에 없는 것(메모리), 알람→ASG/SNS, CloudFormation 기능 구분

### M11. 데이터 분석 — `m11-analytics` · D3
- 목표: 수집→저장→변환→조회 파이프라인을 서비스에 대응시키고, 요구에 맞는 분석 서비스를 고를 수 있다.
- 레슨
  1. 데이터 레이크 개념과 S3 중심 아키텍처, Lake Formation
  2. 수집 (Kinesis Data Streams / Amazon Data Firehose, MSK) 복습과 선택, 그 밖의 수집·교환 (Kinesis Video Streams, Data Exchange, Data Pipeline)
  3. 카탈로그·변환 (Glue 크롤러/ETL/Data Catalog)
  4. 조회 (Athena, Redshift/Spectrum, EMR, OpenSearch, QuickSight — 시험 가이드 표기는 Amazon Quick)
  5. AI/ML 서비스 한눈에 🔴 (Comprehend, Lex, Polly, Rekognition, SageMaker AI, Textract, Transcribe, Translate) — "요구 사항 → 서비스" 한 줄 매칭
- 실습: 🟢 데이터 레이크 버킷 구조 / 🟡 Lake Formation 설정 읽기 · 🟢 Data Firehose → S3(버퍼 시간은 무시됨) · 🟢 Glue 테이블 직접 정의·`BatchCreatePartition` / 🔴 크롤러(501) · 🟢 Glue Python shell ETL 작업 · 🟢 파이프라인 전체: Firehose → 파티션된 S3 → Glue → Athena 매출 쿼리 / 🟡 파티션 프루닝·Trino 함수(에뮬레이터 SQL 엔진 한계) · 🟢 boto3: 주문 이벤트 적재, Athena 매출 리포트
- 시험 포인트: Athena vs Redshift vs EMR, Firehose는 거의 실시간, Glue 역할

### M12. 고가용성·DR·마이그레이션 — `m12-resilience-dr-migration` · D2
- 목표: RTO/RPO 요구에 맞는 DR 전략을 고르고, 마이그레이션 서비스의 용도를 구분할 수 있다.
- 레슨
  1. 가용성 숫자 읽기, 단일 장애점 찾기, AZ·리전 단위 설계
  2. RTO/RPO와 DR 4전략 (백업·복원, 파일럿 라이트, 웜 스탠바이, 다중 사이트)
  3. AWS Backup, 스냅샷 교차 리전 복사, Elastic Disaster Recovery
  4. 마이그레이션 (7R, Application Discovery Service, DMS/SCT, MGN, Migration Hub, Snow/DataSync 복습)
- 실습: 🟢 단일 장애점 찾기(TodayOrder v1 구축 → boto3 감사 → 수정 → 재감사) · 🟡 다중 리전 DR: 에뮬레이터 두 개(`scripts/dr-env.sh`, `emulator_site`)로 파일럿 라이트 동기화·장애·장애 조치·RPO 확인 · 🟢 AWS Backup 볼트·계획·선택·온디맨드 백업·Vault Lock / 🟡 복원(빈 테이블) · 🟡 DMS 구성 · 🟢 boto3: SPOF 감사, 주문 앱, 태그 기반 백업 / 🟡 DR 복제
- 시험 포인트: DR 전략별 RTO/RPO·비용, DMS 지속 복제, Backup 교차 리전/계정

### M13. 비용 최적화 — `m13-cost-optimization` · D4
- 목표: 아키텍처에서 비용 요인을 찾아내고, 같은 요구를 더 싸게 만족하는 대안을 제시할 수 있다.
- 레슨
  1. AWS 과금 구조 (컴퓨트·스토리지·데이터 전송), 데이터 전송 요금 지도
  2. 컴퓨트 비용 (구매 옵션 조합, 적정 크기, 스팟 전략, Graviton)
  3. 스토리지·DB 비용 (클래스 전환, gp2→gp3, 예약 용량, 서버리스 옵션)
  4. 네트워크 비용 (NAT GW vs 엔드포인트, CloudFront, 같은 AZ)
  5. 비용 도구 (Cost Explorer, Budgets, CUR, 비용 할당 태그, Compute Optimizer), Organizations 통합 결제와 볼륨 할인·예약 공유
- 실습: 🟢 EC2 인벤토리로 구매 옵션 비용 추정 / 🔴 실제 청구 · 🟢 수명 주기 계획별 스토리지 비용 계산 · 🟢 NAT 게이트웨이 vs 게이트웨이 엔드포인트 비용 비교 · 🟡 Budgets(지출은 항상 0) / 🔴 Cost Explorer(501) · 🟢 태그 정책 JSON 기준 태그 누락 감사(서비스별 태그 API) / 🔴 Organizations 태그 정책 API · 🔴 데이터 전송·구매 옵션 조합 워크시트 (모든 단가는 예시 숫자)
- 시험 포인트: "가장 비용 효율적인" 문제 풀이 패턴

### M14. 종합 — `m14-capstone-exam` · D1~D4
- 목표: 요구 사항만 보고 전체 아키텍처를 설계·구축하고, 시험형 문제를 근거와 함께 풀 수 있다.
- 구성
  1. Well-Architected 6대 원칙으로 TodayOrder 리뷰
  2. 캡스톤: 요구 사항서 → 설계 → 에뮬레이터에 한 번에 구축하는 스크립트(M02~M10과 M13 Budgets 재료 조합) → 자기 점검표
  3. 서비스 선택 치트시트 (전 모듈 비교표 통합)
  4. 모의고사 65문항(도메인 비중 반영) + 해설 — 자체 제작 문제만 수록
  5. 시험 접수·당일 가이드, 오답 노트 템플릿

## 6. 권장 학습 일정 (8주, 주 10~12시간)

| 주 | 모듈 | 비고 |
|---|---|---|
| 1 | M00, M01 | 환경 구축은 첫날에 끝낸다 |
| 2 | M02 | 가장 어렵다. 서두르지 말 것 |
| 3 | M03, M04 | |
| 4 | M05, M06 | |
| 5 | M07, M08 | |
| 6 | M09, M10 | |
| 7 | M11, M12, M13 | |
| 8 | M14 | 캡스톤 + 모의고사 + 오답 복습 |

## 7. 완료 기준

- 모듈: 모든 실습 스크립트가 깨끗한 에뮬레이터에서 통과하고, 퀴즈 80% 이상.
- 커리큘럼: 캡스톤 자기 점검표 완료, 모의고사(65문항, 130분) 정답률 72% 이상 — 47문항 이상. 채점 스크립트(`curriculum/m14-capstone-exam`의 `grade.py`)가 도메인별 점수를 내고 65% 미만 도메인을 약점으로 표시한다 (자체 기준. 실제 합격선 720점은 환산 점수라 정답률과 1:1로 대응하지 않는다).

## 8. 한계에 대한 솔직한 안내

에뮬레이터 실습만으로는 SAA-C03의 모든 것을 "체험"할 수 없다. 실제 트래픽 흐름, 장애 조치, 자동 조정, 성능·비용은 에뮬레이터에 존재하지 않고, 권한 평가는 부분적으로만 재현된다. 이 커리큘럼은 그 부분을 개념 설명·다이어그램·손으로 푸는 워크시트·시나리오 문제로 채운다. 여유가 있다면 프리 티어 계정에서 🟡/🔴 실습 몇 개를 실제로 해 보기를 권한다(각 실습에 "실제 AWS에서 해 보려면" 메모 제공).
