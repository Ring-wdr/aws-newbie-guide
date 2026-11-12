<!-- 이 파일은 report.py 가 docs/FIDELITY.md 에 끼워 넣는 "사람이 쓴" 부분이다. 탐침을 다시 돌려 결과가 바뀌면 여기도 고친다. -->

<!-- section: summary -->

에뮬레이터 1.0.322(2026-11-10 릴리스)는 **설계 시점의 예상(CURRICULUM.md)보다 훨씬 많이 "실제로" 동작한다.** 가장 큰 차이 다섯 가지:

1. **Lambda `Invoke`가 함수 코드를 실제로 실행한다** (CURRICULUM은 501로 예상). 동기 호출은 핸들러의 반환값을, 예외는 `FunctionError=Unhandled`를 돌려준다. `/aws/lambda/<함수>` 로그 그룹은 **실행 역할에 logs 권한이 있을 때만** 생긴다(AWS와 같음). SQS→Lambda 이벤트 소스 매핑은 큐의 메시지를 실제로 소비하고, API Gateway(HTTP API)→Lambda 프록시도 실행된다.
2. **서비스 간 전달이 실제로 일어난다.** SNS→SQS(필터 정책 포함), S3 이벤트→SQS, EventBridge 규칙→SQS, Pipes, Step Functions 실행(SQS 서비스 통합 포함), CloudWatch 경보→SNS→SQS, S3 복제, Firehose→S3가 모두 관찰됐다.
3. **IAM 정책은 "평가하지 않는다"가 아니라 "서비스마다 다르다".** 사용자에게 붙인 정책을 IAM·EC2·KMS·STS(신뢰 정책)는 평가해 거부하고(명시적 Deny 우선도 재현), S3·SQS·DynamoDB는 평가하지 않는다. 반면 S3 **버킷 정책**의 명시적 Deny, **KMS 키 정책**의 Deny, CloudFront OAC↔버킷 정책, 서비스 역할의 신뢰 정책(Step Functions·Pipes·Glue·Backup·Cognito 자격 증명 풀)은 집행된다. `iam simulate-custom-policy`/`simulate-principal-policy`도 올바르게 판정한다.
4. **VPC·EC2 컨트롤 플레인은 🟢 수준이다.** 서브넷이 AZ·CIDR과 함께 저장되고(/24 → 사용 가능 IP 251), CIDR 범위·중복 오류, NAT 게이트웨이 pending→available, 게이트웨이 엔드포인트의 prefix-list 경로, TGW가 AWS처럼 동작한다. EC2 인스턴스는 pending→running→stopped→terminated로 상태가 바뀐다(부팅은 안 함).
5. **"리소스 자체의 엔드포인트"는 컨테이너 안에서만 산다.** RDS는 실제 DB 엔진(PostgreSQL 프로토콜 응답)을, ALB·CloudFront는 실제 HTTP 응답을 내지만 그 포트가 `127.0.0.1:<임의 포트>`로 **컨테이너 안에** 열려 학습자의 Mac에서는 닿지 않는다. `docker exec aws-emulator-$EMULATOR_PORT curl ...` 로만 확인할 수 있다.

남은 공백(501)은 대부분 **조정·관리 계열**이다: Auto Scaling 정책·예약 작업·수명 주기 후크 전부, Organizations SCP·계정, VPC 피어링 수락·Egress-only IGW·VPN, AMI 생성(`CreateImage`/`RegisterImage`), `ModifyInstanceAttribute`, Glue 크롤러, SSM Session Manager, Cost Explorer.

환경 측정: 빈 에뮬레이터 컨테이너는 약 **174 MiB**, 전체 탐침(Lambda 실행·RDS 엔진·ECS 포함)을 돌리는 동안 최대 **약 325 MiB**. 그래서 스크립트 기본 메모리 상한을 공식 가이드의 2g 대신 **1g**로 두었다(`EMULATOR_MEMORY`로 변경).

<!-- section: grades -->

| 서비스 | 등급 | 한 줄 근거 |
|---|---|---|
| client-config | 🟢 | 127.0.0.1 필수·S3 Control 도달 불가·호스트 접두사 문제가 문서대로 재현됨 |
| iam | 🟢 | CRUD·정책 버전·시뮬레이터 완전. IAM API 자체는 권한도 평가. 단 S3·SQS·DynamoDB에 대한 사용자 정책은 무시됨 |
| sts | 🟢 | AssumeRole 임시 자격 증명·신뢰 정책 거부까지 재현 (키 접두사만 ASIA가 아니라 EMULATOR) |
| organizations | 🟡 | 조직·루트·OU만. SCP 활성화·생성·목록·연결(EnablePolicyType·CreatePolicy·ListPolicies·AttachPolicy), 계정 생성·목록은 501 |
| ec2-vpc | 🟢 | VPC·서브넷·라우팅·IGW·NAT·SG·NACL·엔드포인트·TGW 🟢. 피어링 수락·Egress-only IGW·VPN 501. 트래픽은 흐르지 않음 |
| ec2-instances | 🟡 | 상태 전이는 실제처럼 관찰되지만 부팅·사용자 데이터 실행 없음. DescribeInstanceStatus·ModifyInstanceAttribute·DescribeTags 501 |
| ebs-ami | 🟡 | 볼륨·스냅샷·시작 템플릿(버전 포함) OK. CreateImage·RegisterImage 501, 스냅샷에서 볼륨 복원 실패 |
| elbv2 | 🟡 | 구성 전부 OK, ALB가 컨테이너 안에서 HTTP 응답. 호스트에서 접속 불가, 대상 헬스는 검사 없이 healthy |
| autoscaling | 🟡 | ASG가 Desired만큼 인스턴스를 띄움. 조정 정책·예약·수명 주기 후크 전부 501, 자가 치유 없음 |
| s3 | 🟢 | 버전·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·복제·이벤트 알림·버킷 정책 Deny 모두 실제처럼. 수명 주기 전환은 시간이 흘러도 안 일어남 |
| efs | 🟡 | 파일 시스템·마운트 타깃·액세스 포인트 생성. 마운트 타깃 IP가 서브넷 CIDR을 따르지 않음, 마운트 불가 |
| rds | 🟡 | 인스턴스·복제본·스냅샷·Aurora 클러스터 OK, 컨테이너 안에 실제 DB. 호스트 접속 불가, Multi-AZ 장애 조치 재현 안 됨 |
| dynamodb | 🟢 | 키 설계·Query/Scan·조건부 쓰기·GSI·Streams·트랜잭션·TTL·PITR 모두 실제처럼 |
| elasticache | 🟡 | 클러스터·복제 그룹 available, 엔드포인트에 실제 캐시 서버 없음 |
| sqs | 🟢 | 가시성 타임아웃·DLQ·재처리·롱 폴링·지연·FIFO 순서/중복 제거·1 MiB 제한 모두 재현 |
| sns | 🟢 | SQS 구독 전달·필터 정책(속성/본문)·Raw 전달·FIFO 재현. 큐 정책이 없으면 전달 안 됨(AWS와 동일) |
| eventbridge | 🟢 | 패턴 일치 이벤트만 SQS 대상에 전달, Pipes 전달, Scheduler 생성 |
| stepfunctions | 🟢 | 실행이 SUCCEEDED/FAILED까지, 이력, SQS 서비스 통합, EXPRESS 동기 실행 |
| kinesis | 🟢 | 상태 전이·파티션 키→샤드·GetRecords 순서·리샤딩 |
| firehose | 🟢 | S3에 실제 객체가 생김. 단 버퍼 시간을 무시하고 수 초 만에 씀 |
| lambda | 🟢 | 생성·버전·별칭·동시성·Invoke(실제 실행)·이벤트 소스 매핑 소비·함수 URL 발급. 로그 그룹은 역할에 logs 권한이 있을 때만 생김 |
| apigateway | 🟢 | REST API MOCK 통합을 `https://127.0.0.1:<포트>/_aws/execute-api/<id>/<stage>/<경로>` 로 실제 호출 |
| apigatewayv2 | 🟢 | HTTP API → Lambda 프록시 실제 실행. Lambda 리소스 정책(AddPermission) 없이도 통과함은 AWS와 다름 |
| ecr | 🟢 | 저장소·수명 주기 정책·인증 토큰 (이미지 푸시는 시험 안 함) |
| ecs | 🟡 | 클러스터·작업 정의·서비스 생성. 태스크는 이미지 풀 실패로 STOPPED |
| cognito | 🟢 | 사용자 풀 가입·확인·로그인으로 JWT 발급, 자격 증명 풀 임시 자격 증명 |
| route53 | 🟡 | 영역·레코드(라우팅 정책 전부)·TestDNSAnswer OK. 상태 확인은 시뮬레이션(항상 Success), 실제 DNS 질의 불가 |
| cloudfront | 🟡 | 배포·OAC·캐시 정책·무효화 생성, 컨테이너 안에서 HTTP 응답. 호스트 접속 불가, TestFunction 501 |
| globalaccelerator | 🟡 | 가속기·리스너·엔드포인트 그룹, 정적 IP 2개 표시. 트래픽 없음 |
| wafv2 | 🟡 | IP 세트·Web ACL(속도 기반·관리형 규칙)·ALB 연결 저장. 차단 동작은 시험 안 함 |
| kms | 🟢 | 암복호화·데이터 키(봉투)·서명·교체·삭제 예약·다중 리전 키·키 정책 Deny 집행 |
| secretsmanager | 🟢 | 버전 스테이지 이동·복구. RotateSecret은 Lambda 권한이 필요(AWS와 동일) |
| ssm | 🟢 | 파라미터 계층·SecureString·버전·레이블. Session Manager 501, 공개 리전 파라미터 없음 |
| acm | 🟡 | 가져온 인증서는 ISSUED. DNS 검증 인증서는 PENDING_VALIDATION에서 끝나지 않음 |
| cloudtrail | 🟡 | 추적·로깅·S3에 로그 파일. LookupEvents에 IAM 이벤트는 나오고 S3 이벤트는 안 나옴 |
| config | 🟢 | 기록기·전달 채널(버킷 정책 검사)·관리형 규칙이 실제로 NON_COMPLIANT 판정 |
| guardduty | 🟡 | 탐지기·샘플 결과. 실제 위협 탐지는 없음 |
| cloudwatch | 🟢 | 사용자 지정 지표, 경보가 데이터로 스스로 ALARM 전이, SNS 액션 전달, 복합 경보. AWS/EC2 기본 지표 없음 |
| logs | 🟢 | 로그 그룹·이벤트·FilterLogEvents·지표 필터→지표·Insights 쿼리 |
| cloudformation | 🟡 | 스택 생성이 리소스를 실제로 만들고 Outputs·드리프트·롤백·삭제까지. 단 VPC 스택 변경 세트는 IGW 연결 갱신 501로 롤백 |
| glue | 🟡 | 데이터베이스·테이블·작업 생성. 크롤러 실행·GetPartitions 501 |
| athena | 🟢 | Glue 테이블(S3 JSON)에 SQL이 실제로 실행되어 결과 반환. 결과 파일은 S3에 안 씀 |
| backup | 🟢 | 볼트·계획·선택, 온디맨드 백업 작업 COMPLETED와 복구 지점. ListCopyJobs 501 |
| dms | 🟡 | 복제 인스턴스·엔드포인트·작업 생성. TestConnection 501, 실제 복제 없음 |
| budgets | 🟡 | 예산·알림 저장(실제 지출 0). Cost Explorer GetCostAndUsage 501 |
| tagging | 🟡 | TagResources 동작. GetResources가 SQS만 찾고 S3·DynamoDB·EC2는 못 찾음 |
| misc-optional | 🟡 | 시험 범위 "한눈에" 서비스들: 대부분 호출 가능. QuickSight·SageMaker 일부 501 |

<!-- section: design -->

CURRICULUM.md 5장의 **예상 등급과 관찰이 다른 실습**만 모았다. "→" 오른쪽이 이 탐침 기준 제안 등급이다. 저자는 자기 포트에서 직접 다시 확인하고 확정한다.

### 예상보다 좋다 (🔴/🟡 → 🟢로 올려도 되는 것)

| 모듈 | 실습 (예상) | 관찰 | 제안 |
|---|---|---|---|
| M01 | "거부되어야 할 요청이 통과된다" 관찰 (🟡) | IAM·EC2·KMS는 **실제로 거부한다**(암묵적 Deny, 명시적 Deny 우선 모두). S3·SQS·DynamoDB만 통과 | 🟢/🟡로 재구성: "IAM API로 거부 재현(🟢) → 같은 사용자가 S3에서는 통과(에뮬레이터 한계, 🟡)" 대비. 워크시트 정답 검증에 `iam simulate-principal-policy` 사용 가능(🟢) |
| M01 | 역할 + `assume-role` (🟢) | 신뢰 정책이 허용하지 않는 주체의 AssumeRole이 `AccessDenied`로 거부됨 | 🟢 + "신뢰 정책 거부" 실습 추가 가능. 임시 키 접두사는 `ASIA`가 아니라 `EMULATOR`임을 명시 |
| M02 | 3-티어 VPC (🟢/🟡) | 서브넷 6개·라우팅·IGW·NAT(available까지) 모두 실제처럼 저장·조회 | 🟢 (패킷 흐름은 어차피 관찰 불가라는 점만 "실제 AWS에서는"에) |
| M02 | Peering/TGW (🟡) | TGW·VPC 연결은 available까지 🟢. 피어링은 아래 "나쁘다" 참고 | TGW 🟢 / 피어링 🟡 |
| M03 | 인스턴스 시작·상태 전이 (🟡) | pending→running→stopping→stopped→running→terminated 전이, 프라이빗 IP·AZ·IMDSv2 설정 반영 | 상태 전이 관찰은 🟢. 부팅·사용자 데이터 실행은 없음(🟡 부분은 "실제 AWS에서는") |
| M03 | ALB + 대상 그룹 + 리스너 규칙 (🟡) | 구성 전부 OK. ALB가 컨테이너 안에서 고정 응답 200, 경로 규칙, 대상 없음 502를 실제로 냄 | 🟡 유지하되 `docker exec aws-emulator-$EMULATOR_PORT curl -s http://<DNSName>/path` 로 규칙 동작을 보여 줄 수 있음 (호스트에서는 불가) |
| M04 | 복제·이벤트 알림 (🟡) | 복제 규칙이 새 객체를 대상 버킷에 실제 복사. S3 ObjectCreated 이벤트가 SQS에 실제 도착(prefix 필터 적용) | 🟢. 단 대상 큐 정책에 `s3.amazonaws.com` 허용이 없으면 `InvalidArgument`(AWS와 동일) |
| M04 | 버킷 정책·암호화 (🟢/🟡) | 버킷 정책 명시적 Deny 집행, 퍼블릭 액세스 차단이 퍼블릭 정책 거부, SSE-S3/KMS/C 헤더 정상 | 🟢 (공식 문서는 "버킷 정책을 확인하지 않는다"고 하지만 이 버전은 Deny를 집행함 — 버전 따라 바뀔 수 있으니 실습 단언은 느슨하게) |
| M06 | SNS→SQS 팬아웃·필터 (🟢/🟡) | 전달·필터 정책(속성/본문 범위)·Raw 전달·FIFO 모두 실제 | 🟢. 큐 정책(`sqs:SendMessage` from sns.amazonaws.com) 필수 — 없으면 **조용히** 전달 안 됨 |
| M06 | EventBridge 규칙·대상 (🟡) | 패턴 일치 이벤트만 SQS 대상에 도착, 불일치 이벤트는 안 옴. Pipes SQS→SQS 전달 | 🟢 |
| M06 | Step Functions 주문 워크플로 (🟡) | 실행이 SUCCEEDED/FAILED까지, 이력 이벤트, Choice/Wait/Fail, `sqs:sendMessage` 서비스 통합이 실제로 메시지 전송, EXPRESS `StartSyncExecution` | 🟢. 실행 역할에 권한이 없으면 Task가 AccessDenied로 FAILED (IAM 평가됨) |
| M06 | Kinesis put/get (🟢/🟡) | CREATING→ACTIVE, 같은 파티션 키→같은 샤드, GetRecords 순서 보장, UpdateShardCount | 🟢 |
| M07 | Lambda 생성·구성·버전·별칭 (🟡), **Invoke (🔴)** | **Invoke가 코드를 실제로 실행**(RequestResponse 200+반환값, Event 202, DryRun 204, 예외 → `FunctionError=Unhandled`). 타임아웃 900초 상한 검증 | 🟢. "핸들러를 로컬 Python으로 직접 실행" 우회는 불필요. CURRICULUM §3의 "Lambda Invoke 501" 문구도 틀림 |
| M07 | 이벤트 소스 매핑 SQS→Lambda (🟡) | 매핑 Enabled, 큐 메시지가 실제로 소비됨. 큐 가시성 타임아웃 < 함수 타임아웃이면 생성 거부(AWS 규칙 재현) | 🟢 |
| M07 | API Gateway REST/HTTP (🟡) | REST MOCK, HTTP API→Lambda 프록시를 `https://127.0.0.1:$EMULATOR_PORT/_aws/execute-api/<apiId>/<stage>/<path>` 로 **호스트에서** 호출 가능 (HTTP API `$default` 스테이지는 스테이지 경로 없음) | 🟢. 단 Lambda `AddPermission` 없이도 호출이 통과함은 AWS와 다름 |
| M07 | Cognito 사용자 풀 (🟡) | SignUp→확인→`USER_PASSWORD_AUTH` 로그인으로 실제 JWT 발급, 미확인·비밀번호 오류 예외 정확 | 🟢 |
| M09 | GuardDuty (🟡) | 탐지기·샘플 결과 조회 | 🟡 유지 (확인) |
| M09 | Config 규칙 (🟡) | 관리형 규칙 `S3_BUCKET_VERSIONING_ENABLED`가 실제로 NON_COMPLIANT를 판정 | 🟢 |
| M10 | 알람과 `set-alarm-state` (🟢/🟡) | 경보가 게시한 데이터로 **스스로** ALARM 전이(Period 10초, 25초 이내), SNS 액션이 구독 SQS에 실제 도착, 복합 경보 | 🟢 |
| M10 | 로그 그룹·지표 필터 (🟢) | 지표 필터가 실제 지표를 만들고, FilterLogEvents·Logs Insights 쿼리 동작(2026-10-22 "stub" 보고는 해소됨) | 🟢 확정 |
| M11 | Data Firehose 전송 스트림 (🟡) | S3에 객체가 실제로 생김 (`<prefix>YYYY/MM/DD/HH/...`) | 🟢. 단 버퍼 60초를 무시하고 ~3초 만에 씀 — "거의 실시간" 설명과 타이밍을 연결 짓지 말 것 |
| M11 | Athena 쿼리 실행 요청 (🟡) | Glue 테이블(S3 JSON)에 SQL이 실제로 실행되어 `QUEUED→RUNNING→SUCCEEDED`, `GetQueryResults`로 결과(SUM) 반환 | 🟢 (결과 파일이 S3 출력 위치에 안 생기는 것만 차이) |
| M12 | AWS Backup (🟢/🟡) | 온디맨드 백업 작업 COMPLETED, 복구 지점 생성. 서비스 역할 신뢰 정책 검사 | 🟢 (교차 리전 복사 확인용 ListCopyJobs는 501) |

### 예상보다 나쁘다 (🟢/🟡 → 🟡/🔴로 내려야 하는 것)

| 모듈 | 실습 (예상) | 관찰 | 제안·우회 |
|---|---|---|---|
| M01 | Organizations OU·SCP (🟢/🟡) | 조직은 처음부터 존재(`CreateOrganization` 불필요, FeatureSet=ALL). OU 생성 OK. **`EnablePolicyType`·`CreatePolicy`(SCP)·`ListPolicies`·`AttachPolicy`(기본 `FullAWSAccess`도)·`CreateAccount`·`ListAccounts` 모두 501** | OU 🟢 / SCP 🔴. SCP는 JSON 문서를 쓰고 `iam simulate-custom-policy`로 "SCP+IAM 교집합"을 손으로 판정하는 워크시트로 대체 |
| M02 | NAT GW vs Egress-only IGW (레슨 3) | `CreateEgressOnlyInternetGateway` **501** (2026-10-22 보고 그대로) | 🔴. 개념·다이어그램 |
| M02 | Peering (🟡) | 생성 → `pending-acceptance`까지. **`AcceptVpcPeeringConnection` 501** → active가 안 됨, 피어링 경로 실습 불가 | 🟡(요청까지) / 수락·라우팅은 🔴. TGW로 연결 실습을 대신하면 🟢 |
| M02 | Site-to-Site VPN (레슨 6) | `CreateVpnConnection` 501 | 🔴 |
| M03 | EBS 볼륨·스냅샷·**AMI** (🟢) | 볼륨·스냅샷(completed)·`CopySnapshot` OK. **`CreateImage`·`RegisterImage` 501**, 스냅샷에서 볼륨 복원(`CreateVolume --snapshot-id`)은 `InvalidSnapshot.NotFound` | 볼륨·스냅샷 🟢 / AMI 🔴 / 스냅샷 복원 🔴. AMI는 `describe-images`로 기존 AMI를 읽는 실습으로 대체 |
| M03 | 인스턴스 유형 변경(적정 크기) | `ModifyInstanceAttribute` 501 | 🔴. 시작 템플릿 새 버전(`CreateLaunchTemplateVersion`은 동작)으로 "유형 변경"을 표현 |
| M03 | 시작 템플릿 + ASG + **대상 추적 정책** (🟡) | 시작 템플릿·버전 🟢, ASG가 Desired만큼 인스턴스를 실제로 띄우고 `SetDesiredCapacity` 반영 🟢. **`PutScalingPolicy`(모든 유형)·`PutScheduledUpdateGroupAction`·`PutLifecycleHook`·`DescribeScalingActivities` 501**, 인스턴스를 종료해도 대체 안 함(자가 치유 없음) | ASG 생성·용량 변경 🟢 / 조정 정책·수명 주기 후크·자가 치유 🔴. 정책은 JSON을 쓰고 "이 지표 값이면 몇 대?" 워크시트로 |
| M03 | boto3 태그 없는 리소스 찾기 (🟢) | EC2 `DescribeTags` 501. Resource Groups Tagging API `GetResources`는 SQS만 찾고 S3·DynamoDB·EC2는 못 찾음 | 🟢 유지 가능 — 단 **각 서비스의 describe/list 응답의 Tags 필드**로 구현할 것(`describe_instances`, `list_tags_of_resource`, `get_bucket_tagging`) |
| M04 | 수명 주기 규칙 (🟢) | 규칙 저장·조회는 OK. 단 STANDARD_IA 30일 미만 전환 같은 **검증 오류가 안 남**, 시간이 지나도 전환은 안 일어남 | 🟢(구성) — "규칙이 틀려도 에뮬레이터는 받아 준다"를 명시. 비용 계산은 워크시트 |
| M04 | S3 액세스 포인트·계정 수준 퍼블릭 액세스 차단 (레슨 4) | S3 Control API는 SDK가 `000000000000.127.0.0.1`로 보내 **도달 불가** (CURRICULUM §3 그대로 확인) | 🔴 |
| M04 | SSE-KMS (🟢/🟡) | 헤더는 정상이지만 KMS 키를 비활성화해도 객체가 읽힘 | "키를 끄면 못 읽는다" 시연은 🔴 — KMS 쪽(M09)에서 `Decrypt` 실패로 보여 줄 것 |
| M04 | EFS (🟡) | 생성 OK. 마운트 타깃 IP가 지정 서브넷 CIDR이 아닌 `10.0.x.4`, 상태 `creating`에 머무를 수 있음 | 🟡 유지. 마운트 타깃 IP를 실습 출력으로 강조하지 말 것 |
| M05 | RDS Multi-AZ·읽기 복제본 (🟡) | 생성·복제본·스냅샷·복원·Aurora OK, 실제 DB 엔진이 컨테이너 안에 뜸. **`SecondaryAvailabilityZone` 없음, `reboot --force-failover` 해도 AZ 그대로**, 엔드포인트는 호스트에서 접속 불가 | 🟡 유지. 장애 조치는 다이어그램. DB에 SQL을 날려 보고 싶다면 `docker exec`로 컨테이너 안에서만 가능(학습자용으로는 권장 안 함) |
| M07 | ECR·ECS (🟡) | 구성 OK. 서비스·RunTask 태스크가 PROVISIONING→PENDING→**STOPPED** (`CannotPullContainerError`) | 🟡 유지. STOPPED가 나오는 이유를 README "에뮬레이터 제약"에 |
| M08 | 가중치·장애 조치 레코드와 **상태 확인** (🟢/🟡) | 레코드·`test-dns-answer`(가중치 응답)는 OK. **상태 확인은 존재하지 않는 도메인에도 Success** (시뮬레이션), 실제 DNS 질의(dig) 불가 | 레코드 🟢 / 상태 확인·장애 조치 동작 🔴 |
| M08 | CloudFront (S3 + OAC) (🟡) | 배포·OAC 생성 OK. `DomainName`이 `*.cloudfront.net`이 아니라 `127.0.0.1:<포트>`(컨테이너 안). `TestFunction` 501 | 🟡 유지. 도메인 이름 출력이 실제와 다름을 명시 |
| M08 | Global Accelerator (🟡) | us-east-1 클라이언트로 생성됨, 정적 IP 2개(198.18.x) 표시 | 🟡 유지. **실제 AWS에서 GA API는 us-west-2 엔드포인트로만** 호출한다는 점을 "실제 AWS에서는"에 |
| M09 | ACM (레슨 3) | 가져오기(import) 인증서는 ISSUED. DNS 검증 요청 인증서는 Route 53에 CNAME을 만들어도 **PENDING_VALIDATION에서 안 바뀜**(`.example` 도메인은 FAILED) | 요청·검증 레코드 확인 🟡 / 발급 🔴. 실습은 `openssl`로 만든 자체 서명 인증서 import로 |
| M09 | CloudTrail 추적 (🟡) | 추적·S3 로그 파일 OK, `LookupEvents`에 IAM 이벤트는 나오지만 **S3 이벤트는 안 나옴** | 🟡 유지. 실습 단언은 IAM 이벤트로 |
| M09 | Systems Manager Session Manager (M02 레슨 7, M10 레슨 4) | `StartSession` 501 | 🔴 |
| M10 | CloudFormation으로 M02 VPC 재현 + **변경 세트** (🟢/🟡) | 생성은 🟢(9개 리소스 CREATE_COMPLETE, EC2 API로 실재 확인, Outputs, 드리프트, 롤백, 삭제). **VPC 스택에 서브넷을 추가하는 변경 세트는 `AWS::EC2::VPCGatewayAttachment` 갱신 501로 UPDATE_ROLLBACK_COMPLETE**. S3·SQS·DynamoDB 스택의 변경 세트(리소스 추가)는 UPDATE_COMPLETE | 생성 🟢 / 변경 세트는 **IGW 연결이 없는 스택**(앱 스택: S3·SQS·DynamoDB)으로 실습하면 🟢 |
| M11 | Glue 크롤러 (레슨 3) | `StartCrawler`·`GetPartitions` 501 (`CreateJob`·`StartJobRun`은 이제 동작 — 2026-10-22 보고 해소) | 크롤러 🔴. 테이블은 `create-table`로 직접 정의(🟢) |
| M12 | DMS (🟡) | 복제 인스턴스 available, `TestConnection` 501 | 🟡 유지 |
| M13 | Budgets (🟢/🟡) | 예산·알림 저장 OK, 실제 지출은 항상 0. Cost Explorer `GetCostAndUsage` 501 | Budgets 🟡 / Cost Explorer 🔴 |
| M13 | 태그 누락 감사 (🟢) | Tagging API `GetResources`가 서비스 대부분을 못 찾음 | M03과 같은 우회: 서비스별 태그 API로 구현 |

### 모든 저자가 알아야 할 공통 사항

- **큐·버킷·역할 정책을 실제처럼 써야 한다.** SNS→SQS(큐 정책), S3→SQS 알림(큐 정책), Step Functions·Pipes·Glue·Backup(역할 신뢰 정책·권한), CloudFront OAC(버킷 정책), Config 전달 채널(버킷 정책)은 정책이 없으면 실패하거나 **조용히 아무 일도 일어나지 않는다**. 실습 스크립트가 "전달됐다"를 단언하기 전에 정책부터 만든다.
- **리소스 엔드포인트(RDS, ALB, CloudFront)는 컨테이너 안에만 있다.** 호스트에서 접속하는 실습을 설계하지 말 것.
- **비동기 상태는 기다린다.** 예: DynamoDB `CreateTable` 응답은 (CLI·boto3 모두) `CREATING`이고, 에뮬레이터는 1초 안에 `ACTIVE`가 되는 경우가 많아 직후 `DescribeTable` 결과는 실행마다 다르다(경쟁 상태). 생성 응답의 상태를 보여 주거나 waiter/폴링 뒤의 상태를 보여 주고, "직후 상태"나 "몇 초 뒤"를 단언하지 말 것.
- **시간 기반 동작은 빠르거나 없다.** TTL 삭제는 수 초(실제는 최대 수일), Firehose 버퍼 무시, CloudTrail 로그 즉시, S3 수명 주기 전환은 일어나지 않음.
- **페이지네이션되는 목록 명령의 결과를 `--query ... --output text`로 변수에 담지 말 것.** CLI가 페이지마다 쿼리를 적용해 `None` 줄이 섞일 수 있다(S3 `list-objects-v2`, API Gateway `get-resources` 등에서 실제로 겪음). `--output json`으로 받아 가공하거나 `--no-paginate`를 쓴다 (M00 레슨 5).
- **모든 boto3 예제는 클라이언트를 만들기 전에 `from emulator_guard import require_emulator; require_emulator()`** 를 호출한다. env.sh 없이 실행하면 네트워크 호출 전에 종료한다. 학습자가 자기 AWS 계정에서 돌릴 때만 `TODAYORDER_ALLOW_REAL_AWS=1`(기본 꺼짐). verify.sh에 "env.sh 없이 실행하면 거부되는지" 확인을 넣는 방법은 `curriculum/m00-orientation/labs/verify.sh`의 `guard_refuses` 참고.
- `misc-optional`의 "한눈에" 서비스(Elastic Beanstalk, Lightsail, Batch, Storage Gateway, DataSync, FSx, Redshift, OpenSearch, EMR, MSK, MQ, AppFlow, Transfer, Service Catalog, RAM, Directory Service, Service Quotas, Compute Optimizer, Control Tower, Lake Formation, Comprehend, Translate, Rekognition, Polly, Well-Architected, License Manager)는 대부분 호출이 된다. 필요하면 "설정값을 읽는" 짧은 실습을 붙일 수 있다. QuickSight `ListDashboards`, SageMaker `ListNotebookInstances`는 501.
