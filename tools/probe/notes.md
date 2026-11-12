<!-- 이 파일은 report.py 가 docs/FIDELITY.md 에 끼워 넣는 "사람이 쓴" 부분이다. 탐침을 다시 돌려 결과가 바뀌면 여기도 고친다.
     원칙: 여기 적는 사실은 (1) 탐침의 서비스 키 행으로 뒷받침되거나 (2) "모듈 저자 관찰 (mNN README)"로 출처를 밝힌다. -->

<!-- section: summary -->

에뮬레이터 1.0.322(2026-11-10 릴리스) 기준이다. 처음 보고서(M00 시점)를 13개 모듈 저자와 리뷰어가 다시 확인했고, 그 결과를 탐침에 반영해 새로 만든 보고서다. 핵심은 다음과 같다.

1. **실제로 "도는" 것이 많다.**
   - Lambda `Invoke`는 함수 코드를 실행한다(단, CPython이 아니라 RustPython과 축소된 boto3).
   - 서비스 간 전달이 일어난다: SNS→SQS(필터 정책 포함), S3 이벤트→SQS·Lambda, EventBridge→SQS, Pipes, Step Functions(서비스 통합·Retry/Catch), CloudWatch 경보→SNS, S3 복제, Firehose→S3.
   - 그 밖에 실행되는 것: Glue Python shell 작업, Athena SQL, Secrets Manager 교체 Lambda, Config 자동 수정, ASG 인스턴스 새로 고침, ALB 앞의 WAF 차단(컨테이너 안).
2. **IAM은 "평가 안 함"이 아니라 "부분 평가"다.**
   - 사용자 정책을 평가하는 곳:
     - IAM·EC2·KMS·Secrets Manager
     - S3·SQS·DynamoDB의 **리소스 단위 데이터 요청**(GetObject·PutObject·ListObjectsV2, SendMessage·ReceiveMessage, PutItem·Scan 등)
     - Lambda 실행 역할·Glue 작업 역할로 하는 호출
   - 평가하지 않는 곳:
     - S3·SQS·DynamoDB의 **계정·관리 요청**(ListBuckets·CreateBucket·DeleteBucket·PutBucketVersioning, ListQueues·CreateQueue, ListTables·CreateTable·DescribeTable·DeleteTable)
     - AssumeRole을 하는 호출자의 정책
     - EC2에 대한 세션 정책
     - `iam:PassRole`
   - 비활성 액세스 키는 IAM API만 거부한다.
   - 자격 증명 정책에 전역 조건 키를 걸면 Deny는 항상, Allow는 결코 적용되지 않는다. 정책 시뮬레이터와 신뢰 정책 조건은 올바르게 판정한다.
3. **VPC·EC2 컨트롤 플레인은 🟢 수준이다.** 다만 삭제·교체 계열(피어링 삭제/거절/수락, `ReplaceRoute`, TGW 경로·연결 삭제)과 Egress-only IGW·리전 NAT·VPN·Client VPN은 501이다.
4. **시간이 걸리는 동작은 빠르거나 일어나지 않는다.**
   - 빠른 것: TTL 삭제·Firehose 버퍼·Glacier 복원·CloudTrail 로그는 수 초, Scheduler `at()`은 지정 시각 전에 발화.
   - 일어나지 않는 것: 수명 주기 전환, Lambda 비동기 대상·DLQ 전달.
   - CloudFormation은 조회할 때만 진행하고 대기 리소스에 약 10초 마감이 있어, 30초 간격의 CLI waiter로는 NAT 경로가 있는 스택이 롤백된다.
5. **리소스 엔드포인트는 컨테이너 안에만 있다.** RDS, ALB, CloudFront가 실제로 응답하지만 호스트에서는 닿지 않는다. API Gateway 실행 URL만 호스트에서 열린다.

남은 501은 대부분 **관리·삭제·조정 계열**이다.
- Auto Scaling: 정책·후크·조회
- Organizations: SCP·계정
- IAM: MFA 장치
- RDS: PITR·승격·사용자 지정 엔드포인트
- ElastiCache: 복제 그룹 삭제
- Backup·DMS: 목록·삭제 계열
- Cost Explorer: 비용·예측
- 분석: Glue 크롤러, Athena 작업 그룹 목록·삭제
- 운영: SSM 세션·패치, Audit Manager

<!-- section: grades -->

| 서비스 | 등급 | 한 줄 근거 |
|---|---|---|
| client-config | 🟢 | 127.0.0.1 필수·S3 Control 도달 불가·호스트 접두사 문제가 문서대로 재현됨 |
| iam | 🟢 | CRUD·정책 버전·시뮬레이터 완전. MFA 장치 활성화·조회 501, GetAccountSummary 미지원. 권한 집행은 `iam-enforcement` |
| iam-enforcement | 🟡 | 데이터 요청·IAM·EC2는 거부를 재현. 계정·관리 요청, AssumeRole 호출자 정책, EC2 세션 정책, PassRole, 비활성 키(IAM 외), 전역 조건 키는 AWS와 다름 |
| sts | 🟢 | AssumeRole 임시 자격 증명·신뢰 정책 거부까지 재현 (키 접두사만 ASIA가 아니라 EMULATOR) |
| organizations | 🟡 | 조직·루트·OU만. SCP(활성화·생성·목록·연결)와 계정(생성·목록·조회·이동)·ListChildren은 501 |
| ec2-vpc | 🟢 | VPC·서브넷·라우팅·IGW·NAT·SG·NACL·엔드포인트·TGW 생성·조회. 트래픽은 흐르지 않음 |
| vpc-gaps | 🟡 | 피어링 수락·거절·삭제, ReplaceRoute, TGW 경로·연결 삭제, Egress-only IGW, 리전 NAT, Client VPN 501. TGW 기본 연결·전파 무시, NAT 삭제 후 경로 active, 기본 VPC에 IGW 없음 |
| ec2-instances | 🟡 | 상태 전이는 실제처럼 관찰되지만 부팅·사용자 데이터 실행 없음. DescribeInstanceStatus·ModifyInstanceAttribute·DescribeTags 501 |
| ebs-ami | 🟡 | 볼륨·스냅샷·시작 템플릿(버전 포함) OK. CreateImage·RegisterImage 501, 스냅샷에서 볼륨 복원 실패 |
| compute-gaps | 🟡 | DeleteKeyPair 501, 종료 후 루트 볼륨 in-use, IOPS 비율 미검사, ALB host-header 미매칭, ASG 대상 그룹 미등록, ASG 조회·SetInstanceHealth 501. 인스턴스 새로 고침은 동작 |
| elbv2 | 🟡 | 구성 전부 OK, ALB가 컨테이너 안에서 HTTP 응답. 호스트에서 접속 불가, 대상 헬스는 검사 없이 healthy |
| autoscaling | 🟡 | ASG가 Desired만큼 인스턴스를 띄우고 인스턴스 새로 고침도 됨. 조정 정책·예약·수명 주기 후크 501, 자가 치유 없음 |
| s3 | 🟢 | 버전·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·복제·이벤트 알림·버킷 정책 Deny·수명 주기 검증(2026-07 규칙) 실제처럼. 전환은 시간이 흘러도 안 일어남, SSE-KMS 키 비활성 무시 |
| s3-gaps | 🟡 | MFA Delete 미집행, 객체 잠금 버킷 일시 중지 허용, 복제 구성 검증 느슨, SSE-C 차단 미집행, 퍼블릭 정책 익명 GET 403, DataSync 0개 복사, Storage Gateway·DataSync 일부 501 |
| efs | 🟡 | 파일 시스템·마운트 타깃·액세스 포인트 생성. 마운트 타깃 AZ·IP가 서브넷 CIDR을 따르지 않음, 마운트 불가 |
| rds | 🟡 | 인스턴스·복제본·스냅샷·Aurora 클러스터 OK, 컨테이너 안에 실제 DB. 호스트 접속 불가, Multi-AZ 장애 조치 재현 안 됨 |
| dynamodb | 🟢 | 키 설계·Query/Scan·조건부 쓰기·GSI·Streams·트랜잭션·TTL·백업 실제처럼. PITR은 `db-gaps` |
| elasticache | 🟡 | 클러스터·복제 그룹 available, 엔드포인트에 실제 캐시 서버 없음 |
| db-gaps | 🟡 | RDS PITR·복제본 승격·사용자 지정 엔드포인트·자동 백업 조회 501, ElastiCache 복제 그룹 삭제 501, DAX 서브넷 그룹 실패, DynamoDB PITR 복원 창이 앞으로 가지 않음 |
| sqs | 🟢 | 가시성 타임아웃·DLQ·재처리·롱 폴링·지연·FIFO 순서/중복 제거·1 MiB 제한 모두 재현 |
| sns | 🟢 | SQS 구독 전달·필터 정책(속성/본문)·Raw 전달·FIFO 재현. 큐 정책이 없으면 전달 안 됨(AWS와 동일) |
| eventbridge | 🟢 | 패턴 일치 이벤트만 SQS 대상에 전달, Pipes 전달. Scheduler 발화 시각은 `integration-better` |
| stepfunctions | 🟢 | 실행이 SUCCEEDED/FAILED까지, 이력, SQS 서비스 통합, EXPRESS 동기 실행 |
| integration-better | 🟢 | Step Functions Retry/Catch, Cognito JWT 권한 부여자(Issuer는 에뮬레이터 주소) 동작. Scheduler `at()`은 지정 시각 전 발화 |
| kinesis | 🟢 | 상태 전이·파티션 키→샤드·GetRecords 순서·리샤딩 |
| firehose | 🟢 | S3에 실제 객체가 생김. 버퍼 시간 무시, 역할은 신뢰 정책만 검사(`analytics-gaps`) |
| lambda | 🟢 | 생성·버전·별칭·동시성·Invoke(실제 실행)·이벤트 소스 매핑 소비·함수 URL 발급. 로그 그룹은 역할에 logs 권한이 있을 때만 |
| lambda-runtime | 🟡 | RustPython 런타임, 실행 역할 정책 집행(AWS와 같음). 비동기 실패 대상·재시도 설정 무시, 동기 호출마다 메모리 누수 |
| lambda-permissions | 🟢 | REST API·SNS·S3 → Lambda는 리소스 정책을 AWS처럼 요구. HTTP API만 검사하지 않음(`apigatewayv2`) |
| apigateway | 🟢 | REST API MOCK·Lambda 프록시를 `https://127.0.0.1:<포트>/_aws/execute-api/<id>/<stage>/<경로>` 로 실제 호출 |
| apigatewayv2 | 🟢 | HTTP API → Lambda 프록시 실제 실행. Lambda 리소스 정책(AddPermission) 없이도 통과함은 AWS와 다름 |
| ecr | 🟢 | 저장소·수명 주기 정책·인증 토큰 (이미지 푸시는 시험 안 함) |
| ecs | 🟡 | 클러스터·작업 정의·서비스 생성. 태스크는 이미지를 실제로 내려받으려다 STOPPED(외부 접속 위험 — 환경 메모) |
| cognito | 🟢 | 사용자 풀 가입·확인·로그인으로 JWT 발급, 자격 증명 풀 임시 자격 증명 |
| route53 | 🟡 | 영역·레코드 CRUD·가중치 응답 OK. 상태 확인은 항상 Success, 실제 DNS 질의 불가. 응답 선택은 `edge-better` |
| edge-better | 🟡 | WAF가 ALB 앞에서 실제 403 차단(컨테이너 안). Route 53 지연 시간 응답이 위치와 무관, 라우팅 정책 혼용 허용, CIDR 컬렉션 조회 501 |
| cloudfront | 🟡 | 배포·OAC·캐시 정책·무효화 생성, 컨테이너 안에서 HTTP 응답. 호스트 접속 불가, TestFunction 501 |
| globalaccelerator | 🟡 | 가속기·리스너·엔드포인트 그룹, 정적 IP 2개 표시. 트래픽 없음 |
| wafv2 | 🟢 | IP 세트·Web ACL(속도 기반·관리형 규칙)·ALB 연결. 차단은 `edge-better`에서 실제 403 확인 |
| kms | 🟢 | 암복호화·데이터 키(봉투)·서명·교체·삭제 예약·다중 리전 키·키 정책 Deny 집행·비활성 키 DisabledException |
| secretsmanager | 🟢 | 버전 스테이지 이동·복구, 교체 Lambda가 실제로 실행(`security-better`) |
| ssm | 🟢 | 파라미터 계층·SecureString·버전·레이블. Session Manager 501, 공개 리전 파라미터 없음, 비활성 CMK의 SecureString도 복호화됨 |
| security-better | 🟢 | Secrets Manager 교체, Config 자동 수정 실제 실행, KMS DisabledException. SSM의 비활성 CMK 무시, Audit Manager 501, CloudTrail KMS 이벤트 없음 |
| acm | 🟡 | 가져온 인증서는 ISSUED. DNS 검증 인증서는 PENDING_VALIDATION에서 끝나지 않음 |
| cloudtrail | 🟡 | 추적·로깅·S3에 로그 파일. LookupEvents에 IAM 이벤트만 나오고 S3·KMS 이벤트는 안 나옴 |
| config | 🟢 | 기록기·전달 채널(버킷 정책 검사)·관리형 규칙이 실제로 NON_COMPLIANT 판정 |
| guardduty | 🟡 | 탐지기·샘플 결과. 실제 위협 탐지는 없음 |
| cloudwatch | 🟢 | 사용자 지정 지표, 경보가 데이터로 스스로 ALARM 전이, SNS 액션 전달, 복합 경보. AWS/EC2 기본 지표 없음 |
| logs | 🟢 | 로그 그룹·이벤트·FilterLogEvents·지표 필터→지표·Insights 쿼리(`pct()` 등 일부 함수 실패 — m10 README) |
| cloudformation | 🟡 | 스택 생성이 리소스를 실제로 만들고 Outputs·롤백·삭제까지. VPC 스택 변경 세트 501 롤백, 타이밍·드리프트는 `cfn-timing` |
| cfn-timing | 🔴 | 30초 간격 조회로는 NAT 경로 스택이 롤백(2초 간격이면 성공). 드리프트가 손대지 않은 IGW·경로·NAT·EIP를 DELETED, 추가한 SG 규칙을 IN_SYNC로 오판 |
| glue | 🟡 | 데이터베이스·테이블·Python shell 작업 실행. 크롤러 실행·GetPartitions 501, Spark 작업 실패(m11 README) |
| athena | 🟡 | Glue 테이블(S3 JSON)에 SQL이 실제로 실행. 결과 파일 안 씀, SQL 방언·파티션은 `analytics-gaps` |
| analytics-gaps | 🟡 | Athena: 파티션 열 미지원·위치 아래 파일 전부 읽음·Trino 함수 없음·작업 그룹 목록/삭제 501. Glue Python shell 실제 실행, Firehose는 역할 권한 정책 미검사 |
| backup | 🟢 | 볼트·계획·선택, 온디맨드 백업 COMPLETED와 복구 지점. 복원은 빈 테이블, 목록 계열 501(m12 README) |
| dms | 🟡 | 복제 인스턴스·엔드포인트·작업 생성. TestConnection 등 501, 실제 복제 없음 |
| budgets | 🟡 | 예산·알림 저장(실제 지출 0). Cost Explorer GetCostAndUsage 501 |
| tagging | 🟡 | TagResources 동작. GetResources가 SQS만 찾고 S3·DynamoDB·EC2는 못 찾음 |
| misc-optional | 🟡 | 시험 범위 "한눈에" 서비스들: 대부분 호출 가능. QuickSight·SageMaker 일부 501 |

<!-- section: facts -->

모듈별로, 실습을 설계할 때 **사실로 받아들여도 되는 것**을 정리했다. 근거 열의 `키`는 이 보고서 아래쪽의 탐침 행이다. "모듈 저자 관찰 (mNN README)"는 이 탐침이 다시 확인하지 않고 모듈 README와 PR 리뷰에서 옮긴 것이다.

### M01 IAM과 계정 관리

| 사실 | 근거 |
|---|---|
| IAM 사용자·그룹·역할·정책·정책 버전·인스턴스 프로파일 CRUD는 AWS와 같다 | `iam` |
| `simulate-custom-policy`·`simulate-principal-policy`는 명시적/암묵적 Deny와 `--context-entries` 조건을 올바르게 판정한다 → 정책 판정 워크시트의 채점기로 쓸 수 있다 | `iam`, `iam-enforcement` |
| 정책 없는 사용자는 IAM·EC2·KMS 요청과 S3 `GetObject`·`PutObject`·`ListObjectsV2`, SQS `SendMessage`·`ReceiveMessage`, DynamoDB `PutItem`·`Scan`에서 거부된다. `Allow *` + 명시적 Deny `s3:GetObject`도 집행된다 | `iam-enforcement` |
| 같은 사용자가 S3 `ListBuckets`·`CreateBucket`·`PutBucketVersioning`·`DeleteBucket`, SQS `ListQueues`·`CreateQueue`, DynamoDB `ListTables`·`CreateTable`·`DescribeTable`·`DeleteTable`은 **통과**한다(남의 버킷·테이블도 지울 수 있다). 이 계정 수준 요청에는 명시적 Deny도 적용되지 않는다 | `iam-enforcement` |
| AssumeRole은 **역할의 신뢰 정책만** 본다. 신뢰 정책이 계정 루트를 믿으면, 정책이 없는 사용자도 `sts:AssumeRole`을 명시적으로 Deny 당한 사용자도 역할을 맡는다. 신뢰 정책의 주체·조건(`sts:ExternalId`)은 집행된다 | `iam-enforcement`, `sts` |
| 세션 정책은 IAM 요청에는 적용되고 EC2 요청에는 적용되지 않는다(Deny도 무시) | `iam-enforcement` |
| `iam:PassRole`을 검사하지 않는다(`run-instances --iam-instance-profile`이 명시적 Deny에도 통과) | `iam-enforcement` |
| `Inactive`로 바꾼 액세스 키는 IAM API만 거부한다(`InvalidClientTokenId`). STS·S3·EC2 등은 받아 준다 | `iam-enforcement` |
| 자격 증명 정책에서 전역 조건 키(`aws:RequestedRegion`, `aws:SecureTransport`, `aws:PrincipalAccount` 등)를 쓰면, 실제 호출에서는 Deny가 **항상** 적용되고 Allow는 **결코** 적용되지 않는다. 예외로 IAM API의 `aws:username`은 정확하다. EC2에서는 `aws:username` Deny도 항상 적용된다. 조건이 있는 정책은 시뮬레이터로만 판정한다 | `iam-enforcement` (`aws:username`·`aws:PrincipalAccount`: 모듈 저자 관찰 (m01 README)) |
| 자격 증명 정책에 `Principal`이 있어도 받아 준다(AWS: `MalformedPolicyDocument`) | `iam` |
| MFA 장치 활성화·조회·비활성화·삭제는 501이다. `CreateVirtualMFADevice`만 동작한다. `GetAccountSummary`·`GetAccountPasswordPolicy`는 `InvalidAction`이다 | `iam` |
| 조직은 처음부터 있다. OU만 만들 수 있고 SCP와 계정 API는 501이다 | `organizations` |
| `AssumeRoleWithWebIdentity`는 토큰 서명을 검증하려 해서 임의 토큰을 거부한다. IAM Identity Center는 계정 인스턴스로 미리 있다 | 모듈 저자 관찰 (m01 README) |

### M02 VPC 네트워킹

| 사실 | 근거 |
|---|---|
| VPC·서브넷(AZ·CIDR, /24 → 사용 가능 IP 251)·라우팅·IGW·NAT(available)·SG(체이닝)·NACL·게이트웨이/인터페이스 엔드포인트·TGW·Flow Logs의 생성·조회와 검증 오류는 AWS와 같다. 패킷은 흐르지 않는다 | `ec2-vpc` |
| 피어링: 요청과 `pending-acceptance`까지. 수락·거절·삭제는 501이다 | `ec2-vpc`, `vpc-gaps` |
| `ReplaceRoute`·`ReplaceRouteTableAssociation`은 501이다 → 삭제 후 생성으로 대체 | `vpc-gaps` |
| TGW 정적 경로·경로 검색·VPC 연결 삭제는 501이다. 기본 연결·전파 설정이 `enable`이어도 새 연결은 기본 TGW 라우팅 테이블에 연결·전파되지 않는다 | `vpc-gaps` |
| Egress-only IGW, 리전 NAT, Client VPN, Site-to-Site VPN은 501이다 | `vpc-gaps`, `ec2-vpc` |
| NAT 게이트웨이를 지워도 그 경로가 `blackhole`이 아니라 `active`로 남는다 | `vpc-gaps` |
| 기본 VPC에는 IGW도 `0.0.0.0/0` 경로도 없다 | `vpc-gaps` |
| 접두사 목록의 CIDR은 `198.18.x.x` 하나뿐이고, Direct Connect 위치는 3개만 나온다 | 모듈 저자 관찰 (m02 README) |

### M03 컴퓨트와 확장

| 사실 | 근거 |
|---|---|
| 인스턴스 상태 전이(pending→running→stopped→terminated), 프라이빗 IP, IMDSv2 설정, 사용자 데이터 저장이 된다. 부팅과 실행은 하지 않는다 | `ec2-instances` |
| `DescribeInstanceStatus`, `ModifyInstanceAttribute`, `DescribeTags`, `DeleteKeyPair`, `CreateImage`, `RegisterImage`는 501이다. 스냅샷에서 볼륨을 복원하면 실패한다 | `ec2-instances`, `ebs-ami`, `compute-gaps` |
| 종료된 인스턴스의 루트 볼륨이 `in-use`로 남고, EBS IOPS:GiB 비율을 검사하지 않는다 | `compute-gaps` |
| ALB: 구성·리스너 규칙(path·header·query)과 컨테이너 안 HTTP 응답은 동작한다. **host-header 조건은 매칭되지 않는다.** 대상 헬스는 검사 없이 healthy다 | `elbv2`, `compute-gaps` |
| ASG: Min/Max/Desired·`SetDesiredCapacity`·**인스턴스 새로 고침(Successful)**은 동작한다. 조정 정책·예약·후크·각종 Describe·`SetInstanceHealth`는 501이다. `--target-group-arns`의 인스턴스는 대상 그룹에 등록되지 않고, 자가 치유는 없다 | `autoscaling`, `compute-gaps` |
| ASG 축소 시 새 인스턴스부터 종료한다. 혼합 인스턴스 정책·시작 템플릿 태그·메타데이터 옵션은 반영되지 않는다. 배치 그룹 제한과 최대 절전 조건은 검사하지 않는다 | 모듈 저자 관찰 (m03 README) |

### M04 스토리지

| 사실 | 근거 |
|---|---|
| 버전 관리·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·Glacier 복원·버킷 정책 Deny·BPA·SSE-S3/KMS/C 헤더·복제·S3→SQS 이벤트는 AWS와 같다 | `s3` |
| 수명 주기 검증은 **2026-07-16 이후 AWS 규칙과 같다**. STANDARD_IA·ONEZONE_IA로 30일 전에 전환하는 규칙을 받아 준다(AWS가 30일 제한을 없앰. 30일 최소 보관 요금은 그대로). 한 규칙 안에서 최소 보관 기간보다 빠른 연쇄 전환(Glacier IR 4일 → Deep Archive 20일), 역방향 전환, 중복 규칙 ID, 0일 만료는 거부한다. 다만 전환 자체는 시간이 흘러도 일어나지 않는다 | `s3` |
| MFA Delete는 아무 코드나 받고 집행하지 않는다. 객체 잠금 버킷의 버전 관리를 일시 중지할 수 있다 | `s3-gaps` |
| 복제 구성은 버전 관리 없는 대상·없는 대상 버킷(그리고 없는 역할 — m04 README)도 받아 준다. 버전 관리 없는 원본만 거부한다 | `s3-gaps` |
| 새 버킷의 SSE-C 차단은 표시만 되고 집행되지 않는다. 퍼블릭 정책 + BPA 해제여도 익명 GET은 403이다. SSE-KMS 키를 비활성화해도 객체가 읽힌다 | `s3-gaps`, `s3` |
| DataSync S3→S3 작업은 `SUCCESS`이지만 0개를 복사한다. `CreateLocationNfs`, Storage Gateway `CreateSMBFileShare`·`ListTapes`는 501이다 | `s3-gaps` |
| S3 Control(액세스 포인트, 계정 BPA)은 SDK가 계정 ID를 호스트명에 붙여 도달하지 못한다 | `client-config` |
| EFS 마운트 타깃 AZ·IP는 서브넷을 따르지 않고(서브넷마다 고정), 같은 AZ의 다른 서브넷에도 두 번째 마운트 타깃이 생긴다. 마운트는 불가하다 | `efs`, 모듈 저자 관찰 (m04 README, PR #14 재확인) |

### M05 데이터베이스

| 사실 | 근거 |
|---|---|
| DynamoDB 키 설계·소비 용량·조건부 쓰기·GSI·Streams·트랜잭션·TTL(수 초 안 삭제)·백업은 AWS와 같다. 생성 응답은 `CREATING`이고, 직후 상태는 경쟁 상태다 | `dynamodb` |
| DynamoDB PITR: `LatestRestorableDateTime`이 PITR을 켠 시각에 멈춘다. 최신 시점 복원은 현재 데이터를 돌려주고, 중간 시각은 `InvalidRestoreTimeException`이다 → 특정 시점 복원은 재현되지 않는다 | `db-gaps` |
| RDS 인스턴스·복제본·스냅샷·Aurora는 동작하고 컨테이너 안에 실제 DB 엔진이 뜬다(호스트에서 접속 불가). Multi-AZ 장애 조치는 재현되지 않는다 | `rds` |
| RDS PITR 복원·복제본 승격·Aurora 사용자 지정 엔드포인트·자동 백업 조회는 501이다 | `db-gaps` |
| ElastiCache 복제 그룹 삭제는 501이다. DAX 서브넷 그룹은 유효한 서브넷으로도 실패한다 | `db-gaps` |
| `timestream-write` CLI는 `AmbiguousService`다. DocumentDB·Neptune·Keyspaces는 구성만 된다 | 모듈 저자 관찰 (m05 README) |

### M06 애플리케이션 통합

| 사실 | 근거 |
|---|---|
| SQS(가시성·DLQ·재처리·FIFO·1 MiB)·SNS(필터·Raw·FIFO)·EventBridge 규칙·Pipes·Kinesis는 AWS와 같다. 큐 정책이 없으면 SNS→SQS가 **조용히** 전달되지 않는다 | `sqs`, `sns`, `eventbridge`, `kinesis` |
| Step Functions 실행·이력·서비스 통합, **Retry/Catch**(MaxAttempts 2 → TaskFailed 3건, Catch로 SUCCEEDED)는 AWS와 같다. 실행 역할 권한도 검사한다 | `stepfunctions`, `integration-better` |
| EventBridge Scheduler `at()` 일정은 지정 시각 전에(약 10초 만에) 발화한다. cron 일정은 발화를 확인하지 못했다(m06 README) | `integration-better` |

### M07 서버리스와 컨테이너

| 사실 | 근거 |
|---|---|
| Lambda `Invoke`(동기·비동기·DryRun)는 코드를 실제로 실행한다. 런타임은 **RustPython**이고 boto3는 에뮬레이터의 대체 모듈이다(`client`·`resource`·`Session`만, 일부 서비스만, `sts`·`lambda` 클라이언트 없음 — 상세는 m07 README) | `lambda`, `lambda-runtime` |
| 함수 안 호출에는 **실행 역할 정책이 집행된다**(권한 없으면 AccessDenied, 허용하면 성공) | `lambda-runtime` |
| 비동기 실패 대상(OnFailure)·함수 DLQ는 전달되지 않고 `MaximumRetryAttempts=0`도 무시된다(3번 실행) | `lambda-runtime` |
| 동기 호출 한 번마다 에뮬레이터 메모리가 약 7 MiB씩 늘고 줄지 않는다 → 반복 실습 시 리셋(환경 메모) | `lambda-runtime` |
| REST API Lambda 프록시, SNS → Lambda, S3 → Lambda 알림은 Lambda 리소스 정책(`add-permission`)을 요구한다. 없으면 각각 500 / 조용히 미실행 / `InvalidArgument`이다. **HTTP API만** 권한 없이 호출된다 | `lambda-permissions`, `apigatewayv2` |
| `/aws/lambda/<함수>` 로그 그룹은 실행 역할에 logs 권한이 있을 때만 생긴다 | `lambda`, `apigatewayv2` |
| Cognito 가입·확인·로그인·JWT 발급과 HTTP API JWT 권한 부여자(토큰 없음 401, 유효 토큰 200)가 동작한다. 토큰의 `iss`는 에뮬레이터 주소(`https://127.0.0.1:<포트>/<풀 ID>`)이고 권한 부여자의 Issuer에도 그 값을 넣어야 한다 | `cognito`, `integration-better` |
| ECS 태스크는 이미지를 실제로 내려받으려다 `STOPPED`(`CannotPullContainerError`)가 된다. 실제 레지스트리 주소를 주면 외부로 연결을 시도하므로 `.invalid` 주소를 쓴다 | `ecs`, 모듈 저자 관찰 (m07 README) |

### M08 DNS와 엣지

| 사실 | 근거 |
|---|---|
| 호스팅 영역·레코드 CRUD, 가중치·단순·다중값 `TestDNSAnswer` 응답은 AWS와 같다 | `route53` |
| 지연 시간 레코드의 응답은 질의자 위치와 무관하다. 지리적 위치·지리 근접·IP 기반도 위치를 따르지 않는다(m08 README). 같은 이름에 서로 다른 라우팅 정책을 섞어도 받아 준다. CIDR 컬렉션 조회는 501이다 | `edge-better` |
| 상태 확인은 대상과 무관하게 항상 Success이고, 실제 DNS 질의는 불가하다 | `route53` |
| **WAF Web ACL이 ALB 앞에서 실제로 403 차단한다**(IP 세트 등, 컨테이너 안에서 확인). SQLi·XSS·User-Agent·속도 기반 규칙과 `get-sampled-requests`도 동작한다(m08 README) | `edge-better` |
| CloudFront 배포·OAC·캐시는 컨테이너 안에서 실제 HTTP로 동작한다(`DomainName`은 `127.0.0.1:<포트>`). `TestFunction`은 501이다 | `cloudfront` |
| Global Accelerator는 구성만 되고 `ListEndpointGroups`는 501이다(m08 README) | `globalaccelerator` |

### M09 보안과 암호화

| 사실 | 근거 |
|---|---|
| KMS 봉투 암호화·서명·교체·삭제 예약·다중 리전 키·키 정책 Deny와, 비활성 키의 `DisabledException`은 AWS와 같다 | `kms`, `security-better` |
| **Secrets Manager 교체가 실제로 Lambda 4단계를 실행한다**(`add-permission` 필요) | `security-better` |
| **Config 자동 수정이 실제로 실행된다**(버킷 버전 관리 켜짐). 수정 설정이 연결된 규칙도 삭제된다(m09 README) | `security-better` |
| SSM SecureString은 CMK를 비활성화해도 복호화된다. 키 정책 Deny는 집행된다(m09 README) | `security-better` |
| CloudTrail `LookupEvents`에는 IAM 이벤트만 나오고 S3·KMS 이벤트는 나오지 않는다. 로그 파일은 S3에 즉시 쓴다 | `cloudtrail`, `security-better` |
| ACM DNS 검증 인증서는 발급되지 않는다(`PENDING_VALIDATION`). 가져온 인증서는 ISSUED다 | `acm` |
| Audit Manager `GetAccountStatus`는 501이다. GuardDuty는 샘플 결과만 나오고 EventBridge로 전달되지 않는다(m09 README) | `security-better`, `guardduty` |

### M10 모니터링·운영·IaC

| 사실 | 근거 |
|---|---|
| 사용자 지정 지표·경보 자동 평가·SNS 액션·복합 경보·로그·지표 필터·Insights 쿼리가 동작한다. `AWS/EC2` 기본 지표는 없다. Insights의 `pct()`는 실패한다(m10 README) | `cloudwatch`, `logs` |
| CloudFormation 스택은 실제 리소스를 만들고 Outputs·롤백·삭제가 된다. 다만 **스택은 `DescribeStacks`가 올 때만 진행하고, 다른 리소스를 기다리는 리소스에는 약 10초의 마감이 있다.** 그래서 0초·30초에 조회하는 CLI `wait stack-create-complete`로는 NAT 경로가 있는 VPC 스택이 `ROLLBACK_COMPLETE`가 되고, 2초 간격 조회로는 `CREATE_COMPLETE`가 된다 | `cfn-timing` |
| VPC 스택 변경 세트는 `VPCGatewayAttachment` 갱신이 501이라 롤백된다. 앱 스택(S3·SQS·DynamoDB) 변경 세트는 동작한다 | `cloudformation` |
| 드리프트 감지: S3·SQS 속성 차이는 정확하다. 그러나 손대지 않은 IGW·경로·NAT·EIP·라우팅 테이블(그리고 DynamoDB 테이블 — m10 README)은 `DELETED`로, 스택 밖에서 추가한 SG 규칙은 `IN_SYNC`로 잘못 보고한다 | `cfn-timing`, `cloudformation` |
| SSM `StartSession`·패치 기준선·명령 호출 목록 등은 501이고, `SendCommand`는 대상 없이 Pending이다 | `ssm`, 모듈 저자 관찰 (m10 README) |

### M11 데이터 분석

| 사실 | 근거 |
|---|---|
| Firehose는 S3에 실제로 쓴다(버퍼 시간 무시). 역할의 **신뢰 정책만** 검사하고 S3 권한 정책은 검사하지 않는다 | `firehose`, `analytics-gaps` |
| Glue 카탈로그(DB·테이블·`BatchCreatePartition`)가 동작하고, **Python shell 작업이 실제로 실행**된다(작업 역할 정책 집행 — m11 README). 크롤러 실행·`GetPartitions`는 501이고, Spark(`glueetl`) 작업은 실패한다(m11 README) | `glue`, `analytics-gaps` |
| Athena는 SQLite 계열 엔진으로 SQL을 실제로 실행한다. 파티션 열을 모른다(`WHERE dt=…` → `no such column`). 등록과 무관하게 테이블 위치 아래 파일을 **모두** 읽는다. Trino 함수(`date_trunc`, `from_iso8601_timestamp` 등)가 없다. 결과 파일은 S3에 쓰지 않는다. 작업 그룹 목록·삭제·이름 붙은 쿼리 목록은 501이다 | `athena`, `analytics-gaps` |

### M12 고가용성·DR·마이그레이션

| 사실 | 근거 |
|---|---|
| Backup 볼트·계획·선택·온디맨드 백업 COMPLETED·복구 지점이 동작한다. `ListCopyJobs`는 501이다 | `backup` |
| Backup 신뢰 정책은 `CreateBackupSelection`에서만 검사하고 `StartBackupJob`은 없는 역할·리소스로도 COMPLETED다. 복원은 **빈 테이블**을 만든다. 볼트 잠금은 집행되고 `ListBackupPlans` 등 목록 계열은 501이다 | 모듈 저자 관찰 (m12 README, PR #8 재현) |
| DMS 복제 인스턴스·엔드포인트·작업 생성은 된다. `TestConnection`·삭제·중지 계열은 501이고, 데이터 이동은 없으며, 잘못된 엔진·매핑도 받아 준다 | `dms`, 모듈 저자 관찰 (m12 README) |
| 리전 분리가 없으므로 다중 리전은 포트가 다른 두 에뮬레이터(`scripts/dr-env.sh`, `emulator_site("DR_")`)로 흉내 낸다 | `client-config`, M00 |

### M13 비용 최적화

| 사실 | 근거 |
|---|---|
| Budgets 구성은 저장되지만 실제 지출은 항상 0이다. Cost Explorer `GetCostAndUsage`·`GetCostForecast`는 501이다 | `budgets`, 모듈 저자 관찰 (m13 README) |
| Tagging API `GetResources`는 SQS만 찾는다 → 태그 감사는 서비스별 API로 한다. Organizations 태그 정책 `CreatePolicy`는 501이다 | `tagging`, 모듈 저자 관찰 (m13 README) |
| S3 수명 주기 규칙은 2026-07 AWS 규칙대로 검증되지만 전환은 일어나지 않는다 → 비용은 워크시트로 계산한다 | `s3` |

### 모든 저자가 알아야 할 공통 사항

- **정책을 실제처럼 써야 한다.** 큐 정책, 버킷 정책, 역할 신뢰 정책·권한, Lambda 리소스 정책(`add-permission`)이 없으면 전달이 **조용히** 일어나지 않거나 거부된다(HTTP API만 예외).
- **조건 키가 있는 IAM 정책은 실제 호출로 시험하지 않는다.** 시뮬레이터로 판정한다.
- **상태와 시간을 단언하지 않는다.** waiter나 짧은 간격 폴링을 쓰되, CloudFormation은 2초 간격으로 폴링한다. "몇 초 뒤"라는 시간이나 "생성 직후 상태"는 단언하지 않는다.
- **목록 결과를 `--query ... --output text`로 변수에 담지 않는다**(페이지마다 `None` 줄). `--output json`이나 `--no-paginate`를 쓴다.
- **boto3 예제는 `emulator_guard`를 먼저 호출한다.** 두 사이트는 `emulator_site()`와 `emulator_site("DR_")`로 구분한다.

<!-- section: cited -->

아래는 이 탐침이 직접 다시 실행하지 않고 **모듈 README와 PR 리뷰에서 옮긴** 관찰이다. 위 "모듈별로 확인된 사실" 표에서 근거가 "모듈 저자 관찰"인 행의 출처 목록이기도 하다.

| 모듈 | 관찰 | 출처 |
|---|---|---|
| M01 | `aws:username` 조건은 IAM API에서만 정확하고 EC2에서는 Deny가 항상 적용됨. `aws:PrincipalAccount` 조건도 Deny 항상 적용 | 모듈 저자 관찰 (m01 README), PR #4 리뷰 재현 |
| M01 | `simulate-principal-policy`가 `${aws:username}` 정책 변수를 채우지 않음. `--policy-input-list file://`는 `InvalidInput` | 모듈 저자 관찰 (m01 README) |
| M01 | `AssumeRoleWithWebIdentity`는 발급자 공개 키를 가져오려 함(임의 토큰 거부). Identity Center는 계정 인스턴스 | 모듈 저자 관찰 (m01 README) |
| M02 | 접두사 목록 CIDR `198.18.x.x` 하나, Direct Connect 위치 3개, Network Firewall은 차단 없음 | 모듈 저자 관찰 (m02 README) |
| M03 | ASG 축소 시 새 인스턴스부터 종료, 혼합 인스턴스 정책·템플릿 태그 미반영, 배치 그룹·최대 절전 제한 미검사, EIP 재연결 허용, `CopyImage`·`ModifySnapshotTier` 501 | 모듈 저자 관찰 (m03 README), PR #11 리뷰 재현(축소 순서) |
| M04 | 존재하지 않는 역할로도 복제 구성 허용. SSE-KMS 응답이 별칭을 그대로 돌려줌. FSx `ImportPath` 미저장. EFS 같은 AZ 다른 서브넷 마운트 타깃 허용 | 모듈 저자 관찰 (m04 README), PR #14 재확인(EFS) |
| M05 | RDS Multi-AZ DB 클러스터 멤버 미생성, Aurora `MultiAZ` 표시 false, 글로벌 테이블 리전 분리 없음, `timestream-write` `AmbiguousService`, TTL 삭제 Stream 레코드에 `userIdentity` 없음 | 모듈 저자 관찰 (m05 README), PR #7 리뷰 재현 |
| M06 | Scheduler cron 일정 미발화(20초 관찰), `QueueDeletedRecently` 비결정적 | 모듈 저자 관찰 (m06 README) |
| M07 | 함수 안 RustPython 제약 목록(`socket.gethostname`·`os.listdir` 오류, 네트워크 허용 서비스 목록), ECS 이미지 풀이 실제 ECR 호스트로 연결 시도 | 모듈 저자 관찰 (m07 README), PR #9 리뷰(외부 접속 감사) |
| M08 | 지리적 위치·지리 근접·IP 기반 응답 고정, CloudFront `DefaultRootObject` 무시, GA `ListEndpointGroups` 501, WAF IP 세트가 `X-Forwarded-For`를 기본 처리, 속도 기반 규칙 정확 | 모듈 저자 관찰 (m08 README), PR #12 리뷰 재현 |
| M09 | Config 수정 설정이 연결된 규칙도 삭제됨(AWS: `ResourceInUseException`), GuardDuty 결과가 EventBridge로 안 감, KMS 온디맨드 교체 목록이 비동기 | 모듈 저자 관찰 (m09 README), PR #12 리뷰 |
| M10 | Insights `pct()` 실패, SSM `DescribePatchBaselines`·`ListCommandInvocations`·`ListDocuments`·`DescribeMaintenanceWindows` 501, `SendCommand` 대상 0개 | 모듈 저자 관찰 (m10 README), PR #10 리뷰 재현 |
| M11 | Glue Spark 작업 `awsglue.context` 없음, Glue Python shell 작업 역할 정책 집행, 줄바꿈 없는 JSON → 모든 열 NULL 한 행, Athena 실행 시간 3초 고정 | 모듈 저자 관찰 (m11 README), PR #10 리뷰 재현 |
| M12 | Backup `StartBackupJob` 신뢰 미검사·복원 빈 테이블·목록 계열 501·볼트 잠금 집행, DMS 삭제·중지 계열 501, `ReplaceRouteTableAssociation` 501(탐침 `vpc-gaps`로도 확인), ASG `DescribeLoadBalancerTargetGroups` 501 | 모듈 저자 관찰 (m12 README), PR #8 리뷰 재현 |
| M13 | Cost Explorer 비용 할당 태그·추천 API 501, 이상 탐지 모니터 생성은 동작, Compute Optimizer `OptInRequiredException`, Organizations `TAG_POLICY` 501, DynamoDB 태그 반영 지연 | 모듈 저자 관찰 (m13 README) |

<!-- section: env -->

- **메모리 상한 기본 2g.** `scripts/emulator-up.sh`의 기본 `EMULATOR_MEMORY`는 2g다(공식 가이드와 같음). 빈 에뮬레이터는 약 174 MiB를 쓴다. 동기 Lambda `Invoke`는 호출 한 번에 약 7 MiB씩 늘리고 그 메모리를 되돌려 주지 않는다(`lambda-runtime` 행). 1 GiB 상한에서는 약 120회 호출 뒤 `OOMKilled`(종료 코드 137)되었다. 학습자에게는 `Could not connect to the endpoint URL`만 보인다. `env.sh`와 `emulator-status.sh`가 OOM을 알려 주며, 대처는 `scripts/emulator-reset.sh`다.
- **호스트 잠자기 뒤 시계 어긋남.** 노트북이 잠들었다 깨면 Colima VM(= 에뮬레이터 컨테이너)의 시계가 뒤처질 수 있다. 그러면 STS는 `SignatureDoesNotMatch`, S3·DynamoDB 등은 `RequestTimeTooSkewed`로 모든 요청을 거부한다. M03·M04·M05·M12 작업 중에 실제로 겪었다. `scripts/clock-check.sh`가 차이를 재고, `env.sh`는 서명 거부일 때만 이 진단을 보여 준다. 해결 명령(VM의 `systemd-timesyncd` 재시작 또는 `date -s`)은 실제로 잠자기 뒤 어긋난 상황에서는 아직 검증하지 못했다(M00 레슨 3).
- **리소스 엔드포인트는 컨테이너 안에만 있다.** RDS·Aurora·ElastiCache 주소, ALB·NLB `DNSName`, CloudFront `DomainName`은 `127.0.0.1:<임의 포트>`이고 에뮬레이터 컨테이너 **안에서만** 열린다. 호스트에서는 접속할 수 없다. 확인하려면 `docker exec aws-emulator-$EMULATOR_PORT curl ...`을 쓴다. API Gateway 실행 URL(`https://127.0.0.1:<API 포트>/_aws/execute-api/...`)만 호스트에서 열린다.
- **외부 접속 위험.** ECS 태스크는 이미지를 **실제로 내려받으려** 한다. ECR 주소를 주면 실제 AWS 호스트(`000000000000.dkr.ecr.us-east-1.amazonaws.com:443`)로 연결을 시도했다(m07 README). 실습과 탐침은 해석되지 않는 `.invalid` 레지스트리 주소를 써서 외부 연결을 만들지 않는다. 마찬가지로 Cognito JWT 권한 부여자에 AWS 형식의 Issuer를 넣으면 JWKS를 실제 AWS에서 가져오려 할 수 있다(m07 리뷰 경고, 미검증). Issuer에는 토큰의 `iss`(에뮬레이터 주소)를 쓴다.
- **보고서의 근거.** 표의 각 행은 이 탐침의 실제 호출 결과다. 탐침이 다시 확인하지 않은 항목은 아래 "탐침이 다시 확인하지 않은 모듈 저자 관찰"에 출처(`모듈 저자 관찰 (mNN README)`)와 함께 따로 적었다.
