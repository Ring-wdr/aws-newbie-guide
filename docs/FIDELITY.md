# 에뮬레이터 충실도(FIDELITY) 보고서

> 이 문서는 `tools/probe/probe.py` 실행 결과(`tools/probe/results.json`)와 사람이 쓴 판정(`tools/probe/notes.md`)으로 **자동 생성**된다. 직접 고치지 말고 두 파일을 고친 뒤 다시 생성한다.

| 항목 | 값 |
|---|---|
| 에뮬레이터 버전 | `1.0.322` (릴리스 2026.11.10) |
| 에뮬레이터 커밋 | `7753983c6e495ec3612695b1336bf4936fc7b7fd` |
| 탐침 실행 시각 | 2026-11-13 03:21 UTC |
| 클라이언트 | `aws-cli/2.40.1 Python/3.14.8 Darwin/24.6.0 script-exe/arm64` · boto3 1.44.1 · Python 3.15.0 |

다시 만들기:

```bash
export EMULATOR_PORT=9297            # 자기 포트
scripts/emulator-reset.sh            # 깨끗한 에뮬레이터
source scripts/env.sh
uv run python tools/probe/probe.py   # 전체 (약 수 분) · 일부: --service s3,sqs
```

탐침은 실행마다 새 이름(`todayorder-probe-*-<무작위>`)을 쓰고 끝나면 대부분 정리하므로 같은 에뮬레이터에서 다시 돌려도 된다. 다만 계정에 한 번만 되는 호출(`iam GenerateCredentialReport`, `macie2 EnableMacie`, `securityhub EnableSecurityHub`)은 두 번째 실행부터 409 오류로 기록된다(AWS와 같은 동작). 보고서를 갱신할 때는 깨끗한 에뮬레이터에서 실행한다.

등급 정의는 [CURRICULUM.md 3장](./CURRICULUM.md#3-에뮬레이터-충실도-등급): 🟢 재현 · 🟡 부분(리소스는 만들어지지만 동작(실행·전달·차단)의 일부 또는 전부가 일어나지 않는다) · 🔴 개념(501이거나 의미 없음).

## 요약

에뮬레이터 1.0.322(2026-11-10 릴리스) 기준이다. 처음 보고서(M00 시점)를 13개 모듈 저자와 리뷰어가 다시 확인했고, 그 결과를 탐침에 반영해 새로 만든 보고서다. 핵심은 다음과 같다.

1. **실제로 "도는" 것이 많다.**
   - Lambda `Invoke`는 함수 코드를 실행한다(단, CPython이 아니라 RustPython과 축소된 boto3).
   - 서비스 간 전달이 일어난다: SNS→SQS(필터 정책 포함), S3 이벤트→SQS·Lambda, EventBridge→SQS, Pipes, Step Functions(서비스 통합·Retry/Catch), CloudWatch 경보→SNS, S3 복제, Firehose→S3.
   - 그 밖에 실행되는 것: Glue Python shell 작업, Athena SQL, Secrets Manager 교체 Lambda, Config 자동 수정, ASG 인스턴스 새로 고침, ALB 앞의 WAF 차단(컨테이너 안).
2. **IAM은 "평가 안 함"이 아니라 "부분 평가"다.**
   - 사용자 정책을 평가하는 곳:
     - IAM·EC2·KMS·Secrets Manager(정책 없는 사용자의 `GetSecretValue`·`ListSecrets`·`CreateSecret`·`DescribeSecret` 모두 거부, 허용하면 성공)
     - S3·SQS·DynamoDB의 **리소스 단위 데이터 요청**(GetObject·PutObject·ListObjectsV2, SendMessage·ReceiveMessage, PutItem·Scan 등)
     - Lambda 실행 역할·Glue 작업 역할로 하는 호출
   - 평가하지 않는 곳:
     - S3·SQS·DynamoDB의 **계정·관리 요청**(ListBuckets·CreateBucket·DeleteBucket·PutBucketVersioning, ListQueues·CreateQueue, ListTables·CreateTable·DescribeTable·DeleteTable)
     - AssumeRole을 하는 호출자의 정책
     - EC2에 대한 세션 정책
     - `iam:PassRole`
   - 비활성 액세스 키는 IAM API만 거부한다.
   - 자격 증명 정책의 전역 조건 키는 **서비스와 키마다 다르게** 평가된다(`iam-conditions`: S3 `ListObjectsV2`, SQS `SendMessage`, DynamoDB `Scan`, EC2 `DescribeVpcs`, IAM `ListUsers` × 세 키 × 조건부 Allow·조건부 Deny).
     - S3·SQS: `aws:SecureTransport`·`aws:PrincipalAccount`는 AWS처럼 판정한다(맞는 조건의 Allow는 적용, 맞지 않는 조건의 Deny는 미적용). `aws:RequestedRegion`이 붙은 문장은 Allow는 결코, Deny는 항상 적용된다.
     - DynamoDB·EC2·IAM: 세 키 모두 Allow는 결코, Deny는 항상 적용된다.
     - 정책 시뮬레이터(`--context-entries`)와 역할 신뢰 정책의 조건은 올바르게 판정한다.
3. **VPC·EC2 컨트롤 플레인은 🟢 수준이다.** 다만 삭제·교체 계열(피어링 삭제/거절/수락, `ReplaceRoute`, TGW 경로·연결 삭제)과 Egress-only IGW·리전 NAT·VPN·Client VPN은 501이다.
4. **시간이 걸리는 동작은 빠르거나 일어나지 않는다.**
   - 빠른 것: TTL 삭제·Firehose 버퍼·CloudTrail 로그는 수 초, Glacier Standard 복원은 1초 안에 끝남(`s3`), Scheduler `at()`은 지정 시각 전에 발화.
   - 일어나지 않는 것: 수명 주기 전환, Lambda 비동기 실패의 OnFailure 대상·함수 DLQ(`DeadLetterConfig`) 전달(`lambda-runtime`, 35초 관찰).
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

## 서비스별 결과

API 열은 `성공/시도`, 동작 열은 `실제처럼 관찰/검사`. 등급 근거의 ✍️ 는 사람이 판정한 것, 🤖 는 자동 제안이다.

| 모듈 | 서비스 | 등급 | API | 501 | 기타 오류 | 동작 | 근거 |
|---|---|---|---|---|---|---|---|
| M00 | [`client-config`](#svc-client-config) | 🟢 | 1/1 |  |  | 5/5 | ✍️ 127.0.0.1 필수·S3 Control 도달 불가·호스트 접두사 문제가 문서대로 재현됨 |
| M01 | [`iam`](#svc-iam) | 🟢 | 22/28 | 4 | 2 | 9/14 | ✍️ CRUD·정책 버전·시뮬레이터 완전. MFA 장치 활성화·조회 501, GetAccountSummary 미지원. 권한 집행은 `iam-enforcement` |
| M01 | [`iam-enforcement`](#svc-iam-enforcement) | 🟡 | 4/4 |  |  | 18/42 | ✍️ 데이터 요청·IAM·EC2·Secrets Manager는 거부를 재현. S3·SQS·DynamoDB 계정·관리 요청, AssumeRole 호출자 정책, EC2 세션 정책, PassRole, 비활성 키(IAM 외)는 AWS와 다름 |
| M01 | [`iam-conditions`](#svc-iam-conditions) | 🟡 | 0/0 |  |  | 8/30 | ✍️ S3·SQS는 `aws:SecureTransport`·`aws:PrincipalAccount`를 정확히 판정, `aws:RequestedRegion`은 Allow 미적용·Deny 항상. DynamoDB·EC2·IAM은 세 키 모두 Allow 미적용·Deny 항상 |
| M01 | [`sts`](#svc-sts) | 🟢 | 6/6 |  |  | 4/4 | ✍️ AssumeRole 임시 자격 증명·신뢰 정책 거부까지 재현 (키 접두사만 ASIA가 아니라 EMULATOR) |
| M01 | [`organizations`](#svc-organizations) | 🟡 | 3/13 | 10 |  | 1/1 | ✍️ 조직·루트·OU만. SCP(활성화·생성·목록·연결)와 계정(생성·목록·조회·이동)·ListChildren은 501 |
| M02 | [`ec2-vpc`](#svc-ec2-vpc) | 🟢 | 40/43 | 3 |  | 26/27 | ✍️ VPC·서브넷·라우팅·IGW·NAT·SG·NACL·엔드포인트·TGW 생성·조회. 트래픽은 흐르지 않음 |
| M02 | [`vpc-gaps`](#svc-vpc-gaps) | 🟡 | 5/16 | 11 |  | 0/4 | ✍️ 피어링 수락·거절·삭제, ReplaceRoute, TGW 경로·연결 삭제, Egress-only IGW, 리전 NAT, Client VPN 501. TGW 기본 연결·전파 무시, NAT 삭제 후 경로 active, 기본 VPC에 IGW 없음 |
| M03 | [`ec2-instances`](#svc-ec2-instances) | 🟡 | 15/18 | 3 |  | 9/9 | ✍️ 상태 전이는 실제처럼 관찰되지만 부팅·사용자 데이터 실행 없음. DescribeInstanceStatus·ModifyInstanceAttribute·DescribeTags 501 |
| M03 | [`ebs-ami`](#svc-ebs-ami) | 🟡 | 15/18 | 2 | 1 | 10/10 | ✍️ 볼륨·스냅샷·시작 템플릿(버전 포함) OK. CreateImage·RegisterImage 501, 스냅샷에서 볼륨 복원 실패 |
| M03 | [`elbv2`](#svc-elbv2) | 🟡 | 10/10 |  |  | 8/9 | ✍️ 구성 전부 OK, ALB가 컨테이너 안에서 HTTP 응답. 호스트에서 접속 불가, 대상 헬스는 HTTP 검사 없이 인스턴스 상태를 따름(`compute-gaps`) |
| M03 | [`autoscaling`](#svc-autoscaling) | 🟡 | 3/8 | 5 |  | 5/6 | ✍️ ASG가 Desired만큼 인스턴스를 띄우고 인스턴스 새로 고침도 됨. 조정 정책·예약·수명 주기 후크 501, 자가 치유 없음 |
| M03 | [`compute-gaps`](#svc-compute-gaps) | 🟡 | 5/10 | 5 |  | 3/7 | ✍️ DeleteKeyPair 501, 종료 후 루트 볼륨 in-use, IOPS 비율 미검사, ALB host-header 미매칭, ASG 대상 그룹 미등록, ASG 조회·SetInstanceHealth 501. 인스턴스 새로 고침은 동작. 대상 헬스는 HTTP 검사 없이 running이면 healthy, 중지하면 unhealthy |
| M04 | [`s3`](#svc-s3) | 🟢 | 45/45 |  |  | 44/45 | ✍️ 버전·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·복제·이벤트 알림·버킷 정책 Deny·수명 주기 검증(현재 AWS 규칙) 실제처럼. 전환은 시간이 흘러도 안 일어남, SSE-KMS 키 비활성 무시 |
| M04 | [`s3-gaps`](#svc-s3-gaps) | 🟡 | 6/9 | 3 |  | 1/9 | ✍️ MFA Delete 미집행, 객체 잠금 버킷 일시 중지 허용, 복제 구성 검증 느슨, SSE-C 차단 미집행, 퍼블릭 정책 익명 GET 403, DataSync 0개 복사, Storage Gateway·DataSync 일부 501 |
| M04 | [`efs`](#svc-efs) | 🟡 | 7/7 |  |  | 4/5 | ✍️ 파일 시스템·마운트 타깃·액세스 포인트 생성. 마운트 타깃 AZ·IP가 서브넷 CIDR을 따르지 않음, 마운트 불가 |
| M05 | [`rds`](#svc-rds) | 🟡 | 16/16 |  |  | 11/13 | ✍️ 인스턴스·복제본·스냅샷·Aurora 클러스터 OK, 컨테이너 안에 실제 DB. 호스트 접속 불가, Multi-AZ 장애 조치 재현 안 됨 |
| M05 | [`dynamodb`](#svc-dynamodb) | 🟢 | 28/28 |  |  | 24/24 | ✍️ 키 설계·Query/Scan·조건부 쓰기·GSI·Streams·트랜잭션·TTL·백업 실제처럼. PITR은 `db-gaps` |
| M05 | [`elasticache`](#svc-elasticache) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 클러스터·복제 그룹 available, 엔드포인트에 실제 캐시 서버 없음 |
| M05 | [`db-gaps`](#svc-db-gaps) | 🟡 | 1/6 | 5 |  | 1/4 | ✍️ RDS PITR·복제본 승격·사용자 지정 엔드포인트·자동 백업 조회 501, ElastiCache 복제 그룹 삭제 501, DAX 서브넷 그룹 실패, DynamoDB PITR 복원 창이 앞으로 가지 않음 |
| M06 | [`sqs`](#svc-sqs) | 🟢 | 19/19 |  |  | 16/16 | ✍️ 가시성 타임아웃·DLQ·재처리·롱 폴링·지연·FIFO 순서/중복 제거·1 MiB 제한 모두 재현 |
| M06 | [`sns`](#svc-sns) | 🟢 | 22/22 |  |  | 9/9 | ✍️ SQS 구독 전달·필터 정책(속성/본문)·Raw 전달·FIFO 재현. 큐 정책이 없으면 전달 안 됨(AWS와 동일) |
| M06 | [`eventbridge`](#svc-eventbridge) | 🟢 | 15/15 |  |  | 4/4 | ✍️ 패턴 일치 이벤트만 SQS 대상에 전달, Pipes 전달. Scheduler 발화 시각은 `integration-better` |
| M06 | [`stepfunctions`](#svc-stepfunctions) | 🟢 | 11/11 |  |  | 6/6 | ✍️ 실행이 SUCCEEDED/FAILED까지, 이력, SQS 서비스 통합, EXPRESS 동기 실행 |
| M06 | [`kinesis`](#svc-kinesis) | 🟢 | 12/12 |  |  | 6/6 | ✍️ 상태 전이·파티션 키→샤드·GetRecords 순서·리샤딩 |
| M06 | [`integration-better`](#svc-integration-better) | 🟢 | 3/3 |  |  | 2/4 | ✍️ Step Functions Retry/Catch, Cognito JWT 권한 부여자(Issuer는 에뮬레이터 주소) 동작. Scheduler `at()`은 지정 시각 전 발화 |
| M07 | [`lambda`](#svc-lambda) | 🟢 | 26/26 |  |  | 15/15 | ✍️ 생성·버전·별칭·동시성·Invoke(실제 실행)·이벤트 소스 매핑 소비·함수 URL 발급. 로그 그룹은 역할에 logs 권한이 있을 때만 |
| M07 | [`apigateway`](#svc-apigateway) | 🟢 | 15/15 |  |  | 1/1 | ✍️ REST API MOCK·Lambda 프록시를 `https://127.0.0.1:<포트>/_aws/execute-api/<id>/<stage>/<경로>` 로 실제 호출 |
| M07 | [`apigatewayv2`](#svc-apigatewayv2) | 🟢 | 11/11 |  |  | 3/3 | ✍️ HTTP API → Lambda 프록시 실제 실행. Lambda 리소스 정책(AddPermission) 없이도 통과함은 AWS와 다름 |
| M07 | [`ecr`](#svc-ecr) | 🟢 | 7/7 |  |  | 1/1 | ✍️ 저장소·수명 주기 정책·인증 토큰 (이미지 푸시는 시험 안 함) |
| M07 | [`ecs`](#svc-ecs) | 🟡 | 6/6 |  |  | 1/2 | ✍️ 클러스터·작업 정의·서비스 생성. 태스크는 이미지를 실제로 내려받으려다 STOPPED(탐침은 `registry.invalid` 이미지를 씀. 외부 접속 위험 — 환경 메모) |
| M07 | [`cognito`](#svc-cognito) | 🟢 | 12/12 |  |  | 5/5 | ✍️ 사용자 풀 가입·확인·로그인으로 JWT 발급, 자격 증명 풀 임시 자격 증명 |
| M07 | [`lambda-runtime`](#svc-lambda-runtime) | 🟡 | 5/5 |  |  | 3/8 | ✍️ RustPython 런타임, 실행 역할 정책 집행(AWS와 같음). 비동기 실패의 OnFailure 대상·함수 DLQ 미전달, 재시도 설정 무시, 동기 호출마다 메모리 누수 |
| M07 | [`lambda-permissions`](#svc-lambda-permissions) | 🟢 | 3/3 |  |  | 5/5 | ✍️ REST API·SNS·S3 → Lambda는 리소스 정책을 AWS처럼 요구. HTTP API만 검사하지 않음(`apigatewayv2`) |
| M08 | [`route53`](#svc-route53) | 🟡 | 13/13 |  |  | 6/7 | ✍️ 영역·레코드 CRUD·가중치 응답 OK. 상태 확인은 항상 Success, 실제 DNS 질의 불가. 응답 선택은 `edge-better` |
| M08 | [`cloudfront`](#svc-cloudfront) | 🟡 | 5/6 | 1 |  | 4/5 | ✍️ 배포·OAC·캐시 정책·무효화 생성, 컨테이너 안에서 HTTP 응답. 호스트 접속 불가, TestFunction 501 |
| M08 | [`globalaccelerator`](#svc-globalaccelerator) | 🟡 | 3/3 |  |  | 1/1 | ✍️ 가속기·리스너·엔드포인트 그룹, 정적 IP 2개 표시. 트래픽 없음 |
| M08 | [`wafv2`](#svc-wafv2) | 🟢 | 6/6 |  |  | 2/2 | ✍️ IP 세트·Web ACL(속도 기반·관리형 규칙)·ALB 연결. 차단은 `edge-better`에서 실제 403 확인 |
| M08 | [`edge-better`](#svc-edge-better) | 🟡 | 0/1 | 1 |  | 1/3 | ✍️ WAF가 ALB 앞에서 실제 403 차단(컨테이너 안). Route 53 지연 시간 응답이 위치와 무관, 라우팅 정책 혼용 허용, CIDR 컬렉션 조회 501 |
| M09 | [`kms`](#svc-kms) | 🟢 | 20/20 |  |  | 13/13 | ✍️ 암복호화·데이터 키(봉투)·서명·교체·삭제 예약·다중 리전 키·키 정책 Deny 집행·비활성 키 DisabledException |
| M09 | [`secretsmanager`](#svc-secretsmanager) | 🟢 | 9/10 |  | 1 | 6/6 | ✍️ 버전 스테이지 이동·복구, 교체 Lambda가 실제로 실행(`security-better`), 사용자 정책 평가(`iam-enforcement`) |
| M09 | [`ssm`](#svc-ssm) | 🟢 | 15/16 | 1 |  | 8/9 | ✍️ 파라미터 계층·SecureString·버전·레이블. Session Manager 501, 공개 리전 파라미터 없음, 비활성 CMK의 SecureString도 복호화됨 |
| M09 | [`acm`](#svc-acm) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 가져온 인증서는 ISSUED. DNS 검증 인증서는 PENDING_VALIDATION에서 끝나지 않음 |
| M09 | [`cloudtrail`](#svc-cloudtrail) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 추적·로깅·S3에 로그 파일. LookupEvents에 IAM 이벤트만 나오고 S3·KMS 이벤트는 안 나옴 |
| M09 | [`config`](#svc-config) | 🟢 | 8/8 |  |  | 3/3 | ✍️ 기록기·전달 채널(버킷 정책 검사)·관리형 규칙이 실제로 NON_COMPLIANT 판정 |
| M09 | [`guardduty`](#svc-guardduty) | 🟡 | 8/8 |  |  | 2/2 | ✍️ 탐지기·샘플 결과. 실제 위협 탐지는 없음 |
| M09 | [`security-better`](#svc-security-better) | 🟢 | 3/4 | 1 |  | 4/6 | ✍️ Secrets Manager 교체, Config 자동 수정 실제 실행, KMS DisabledException. SSM의 비활성 CMK 무시, Audit Manager 501, CloudTrail KMS 이벤트 없음 |
| M10 | [`cloudwatch`](#svc-cloudwatch) | 🟢 | 9/9 |  |  | 7/8 | ✍️ 사용자 지정 지표, 경보가 데이터로 스스로 ALARM 전이, SNS 액션 전달, 복합 경보. AWS/EC2 기본 지표 없음 |
| M10 | [`logs`](#svc-logs) | 🟢 | 9/9 |  |  | 6/6 | ✍️ 로그 그룹·이벤트·FilterLogEvents·지표 필터→지표·Insights 쿼리(`pct()` 등 일부 함수 실패 — m10 README) |
| M10 | [`cloudformation`](#svc-cloudformation) | 🟡 | 12/12 |  |  | 12/13 | ✍️ 스택 생성이 리소스를 실제로 만들고 Outputs·롤백·삭제까지. VPC 스택 변경 세트 501 롤백, 타이밍·드리프트는 `cfn-timing` |
| M10 | [`cfn-timing`](#svc-cfn-timing) | 🔴 | 1/1 |  |  | 1/4 | ✍️ 30초 간격 조회로는 NAT 경로 스택이 롤백(2초 간격이면 성공). 드리프트가 손대지 않은 IGW·경로·NAT·EIP를 DELETED, 추가한 SG 규칙을 IN_SYNC로 오판 |
| M11 | [`firehose`](#svc-firehose) | 🟢 | 4/4 |  |  | 2/2 | ✍️ S3에 실제 객체가 생김. 버퍼 시간 무시, 역할은 신뢰 정책만 검사(`analytics-gaps`) |
| M11 | [`glue`](#svc-glue) | 🟡 | 8/10 | 2 |  | 2/2 | ✍️ 데이터베이스·테이블·Python shell 작업 실행. 크롤러 실행·GetPartitions 501, Spark 작업 실패(m11 README) |
| M11 | [`athena`](#svc-athena) | 🟡 | 4/4 |  |  | 2/3 | ✍️ Glue 테이블(S3 JSON)에 SQL이 실제로 실행. 결과 파일 안 씀, SQL 방언·파티션은 `analytics-gaps` |
| M11 | [`analytics-gaps`](#svc-analytics-gaps) | 🟡 | 2/5 | 3 |  | 1/5 | ✍️ Athena: 파티션 열 미지원·위치 아래 파일 전부 읽음·Trino 함수 없음·작업 그룹 목록/삭제 501. Glue Python shell 실제 실행, Firehose는 역할 권한 정책 미검사 |
| M12 | [`backup`](#svc-backup) | 🟡 | 4/5 | 1 |  | 2/2 | ✍️ 볼트·계획·선택, 온디맨드 백업 COMPLETED와 복구 지점은 탐침 확인. 복원하면 **빈 테이블**이 생기고 목록 계열은 501이라(모듈 저자 관찰 (m12 README)) 백업→복원 흐름은 재현되지 않음 |
| M12 | [`dms`](#svc-dms) | 🟡 | 5/6 | 1 |  | 1/1 | ✍️ 복제 인스턴스·엔드포인트·작업 생성. TestConnection 등 501, 실제 복제 없음 |
| M13 | [`budgets`](#svc-budgets) | 🟡 | 4/5 | 1 |  | 1/1 | ✍️ 예산·알림 저장(실제 지출 0). Cost Explorer GetCostAndUsage 501 |
| M13 | [`tagging`](#svc-tagging) | 🟡 | 3/3 |  |  | 1/2 | ✍️ TagResources 동작. GetResources가 SQS만 찾고 S3·DynamoDB·EC2는 못 찾음 |
| 기타 | [`misc-optional`](#svc-misc-optional) | 🟡 | 27/29 | 2 |  | 4/4 | ✍️ 시험 범위 "한눈에" 서비스들: 대부분 호출 가능. QuickSight·SageMaker 일부 501 |

## 모듈별로 확인된 사실 (저자·학습자 필독)

모듈별로, 실습을 설계할 때 **사실로 받아들여도 되는 것**을 정리했다. 근거 열의 `키`는 이 보고서 아래쪽의 탐침 행이다. "모듈 저자 관찰 (mNN README)"는 이 탐침이 다시 확인하지 않고 모듈 README와 PR 리뷰에서 옮긴 것이다.

### M01 IAM과 계정 관리

| 사실 | 근거 |
|---|---|
| IAM 사용자·그룹·역할·정책·정책 버전·인스턴스 프로파일 CRUD는 AWS와 같다 | `iam` |
| `simulate-custom-policy`·`simulate-principal-policy`는 명시적/암묵적 Deny와 `--context-entries` 조건을 올바르게 판정한다 → 정책 판정 워크시트의 채점기로 쓸 수 있다 | `iam`, `iam-enforcement` |
| 정책 없는 사용자는 IAM·EC2·KMS 요청, Secrets Manager `GetSecretValue`·`ListSecrets`·`CreateSecret`·`DescribeSecret`, S3 `GetObject`·`PutObject`·`ListObjectsV2`, SQS `SendMessage`·`ReceiveMessage`, DynamoDB `PutItem`·`Scan`에서 거부된다. `Allow *` + 명시적 Deny `s3:GetObject`도 집행된다 | `iam-enforcement` |
| 같은 사용자가 S3 `ListBuckets`·`CreateBucket`·`PutBucketVersioning`·`DeleteBucket`, SQS `ListQueues`·`CreateQueue`, DynamoDB `ListTables`·`CreateTable`·`DescribeTable`·`DeleteTable`은 **통과**한다(남의 버킷·테이블도 지울 수 있다). 이 계정 수준 요청에는 명시적 Deny도 적용되지 않는다 | `iam-enforcement` |
| AssumeRole은 **역할의 신뢰 정책만** 본다. 신뢰 정책이 계정 루트를 믿으면, 정책이 없는 사용자도 `sts:AssumeRole`을 명시적으로 Deny 당한 사용자도 역할을 맡는다. 신뢰 정책의 주체·조건(`sts:ExternalId`)은 집행된다 | `iam-enforcement`, `sts` |
| 세션 정책은 IAM 요청에는 적용되고 EC2 요청에는 적용되지 않는다(Deny도 무시) | `iam-enforcement` |
| `iam:PassRole`을 검사하지 않는다(`run-instances --iam-instance-profile`이 명시적 Deny에도 통과) | `iam-enforcement` |
| `Inactive`로 바꾼 액세스 키는 IAM API만 거부한다(`InvalidClientTokenId`). STS·S3·EC2 등은 받아 준다 | `iam-enforcement` |
| 자격 증명 정책의 전역 조건 키는 서비스·키마다 다르게 평가된다. 시험: 각 키마다 조건부 Allow만 가진 사용자와 `Allow *` + 조건부 Deny 사용자, 조건은 실제 요청에 맞는 값(Allow)·맞지 않는 값(Deny) | `iam-conditions` |
| ↳ S3 `ListObjectsV2`·SQS `SendMessage`: `aws:SecureTransport`(`true`/`false`)와 `aws:PrincipalAccount`(`000000000000`/다른 계정)는 **AWS와 같다** — 조건부 Allow로 통과하고, 맞지 않는 조건부 Deny는 적용되지 않는다 | `iam-conditions` |
| ↳ S3·SQS의 `aws:RequestedRegion`(`us-east-1`/`eu-west-1`): 조건부 Allow는 **결코** 적용되지 않고(거부), 맞지 않는 조건부 Deny가 **항상** 적용된다(거부) | `iam-conditions` |
| ↳ DynamoDB `Scan`·EC2 `DescribeVpcs`·IAM `ListUsers`: 세 키 모두 조건부 Allow는 결코 적용되지 않고 조건부 Deny는 항상 적용된다 | `iam-conditions` |
| ↳ `aws:username`은 IAM API에서 정확하고 EC2에서는 Deny가 항상 적용된다 | 모듈 저자 관찰 (m01 README) |
| ↳ 그러므로 조건 키 실습의 판정은 시뮬레이터로 한다. 실제 호출로 보여 주려면 S3·SQS의 `aws:SecureTransport`·`aws:PrincipalAccount`만 쓴다 | `iam`, `iam-conditions` |
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
| ALB: 구성·리스너 규칙(path·header·query)과 컨테이너 안 HTTP 응답은 동작한다. **host-header 조건은 매칭되지 않는다** | `elbv2`, `compute-gaps` |
| 대상 헬스는 HTTP 검사를 하지 않고 인스턴스 상태를 따른다: 리스너에 연결된 대상 그룹에 등록하면 `initial`(`Elb.RegistrationInProgress`) → 약 1초 뒤 `healthy`, 인스턴스를 중지하면 수 초 안에 `unhealthy`(`Target.Timeout`). 리스너에 연결되지 않은 대상 그룹의 대상은 `unused`(`Target.NotInUse`)다(AWS와 같음) | `compute-gaps` |
| ASG: Min/Max/Desired·`SetDesiredCapacity`·**인스턴스 새로 고침(Successful)**은 동작한다. 조정 정책·예약·후크·각종 Describe·`SetInstanceHealth`는 501이다. `--target-group-arns`의 인스턴스는 대상 그룹에 등록되지 않고, 자가 치유는 없다 | `autoscaling`, `compute-gaps` |
| ASG 축소 시 새 인스턴스부터 종료한다. 혼합 인스턴스 정책·시작 템플릿 태그·메타데이터 옵션은 반영되지 않는다. 배치 그룹 제한과 최대 절전 조건은 검사하지 않는다 | 모듈 저자 관찰 (m03 README) |

### M04 스토리지

| 사실 | 근거 |
|---|---|
| 버전 관리·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·Glacier 복원 흐름(복원 전 `InvalidObjectState`, 복원 후 읽기 — 단 Standard 복원이 1초 안에 끝남)·버킷 정책 Deny·BPA·SSE-S3/KMS/C 헤더·복제·S3→SQS 이벤트는 AWS와 같다 | `s3` |
| 수명 주기 검증은 **현재 AWS 규칙과 같다**. STANDARD_IA 10일·ONEZONE_IA 1일 전환 규칙을 받아 준다. AWS는 2026-07-16에 "Standard에 30일 머문 뒤에야 Standard-IA·One Zone-IA로 전환" 제한을 없앴다([What's New, 2026-07-16](https://aws.amazon.com/about-aws/whats-new/2026/07/s3-removes-30-day-transitions-standard-ia-one-zone-ia/)). 없어진 것은 전환 전 대기뿐이고 **최소 보관 기간 요금은 남아 있다**: IA에 들어간 객체를 30일이 되기 전에 삭제·덮어쓰기·전환하면 30일을 채운 만큼 청구된다. 또 2024-09부터 수명 주기 전환은 기본적으로 **128 KB 미만 객체를 옮기지 않는다**(비용 계산에 영향. 에뮬레이터에서는 전환이 일어나지 않으므로 확인하지 않음). 한 규칙 안에서 최소 보관 기간보다 빠른 연쇄 전환(Glacier IR 4일 → Deep Archive 20일), 역방향 전환, 중복 규칙 ID, 0일 만료는 거부한다. 다만 전환 자체는 시간이 흘러도 일어나지 않는다 | `s3` |
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
| 비동기 실패의 OnFailure 대상(SQS)과 함수 DLQ(`DeadLetterConfig` → SQS)는 35초 안에 전달되지 않는다. `MaximumRetryAttempts=0`도 무시된다(3번 실행). `DeadLetterConfig` 설정 자체는 저장·조회된다 | `lambda-runtime` |
| 동기 호출 한 번마다 에뮬레이터 메모리가 약 7 MiB씩 늘고 줄지 않는다 → 반복 실습 시 리셋(환경 메모) | `lambda-runtime` |
| REST API Lambda 프록시, SNS → Lambda, S3 → Lambda 알림은 Lambda 리소스 정책(`add-permission`)을 요구한다. 없으면 각각 500 / 조용히 미실행 / `InvalidArgument`이다. **HTTP API만** 권한 없이 호출된다 | `lambda-permissions`, `apigatewayv2` |
| `/aws/lambda/<함수>` 로그 그룹은 실행 역할에 logs 권한이 있을 때만 생긴다 | `lambda`, `apigatewayv2` |
| Cognito 가입·확인·로그인·JWT 발급과 HTTP API JWT 권한 부여자(토큰 없음 401, 유효 토큰 200)가 동작한다. 토큰의 `iss`는 에뮬레이터 주소(`https://127.0.0.1:<포트>/<풀 ID>`)이고 권한 부여자의 Issuer에도 그 값을 넣어야 한다 | `cognito`, `integration-better` |
| ECS 태스크는 이미지를 실제로 내려받으려다 `STOPPED`(`CannotPullContainerError: failed to resolve ref registry.invalid/...`)가 된다. 실제 레지스트리 주소를 주면 외부로 연결을 시도하므로 `.invalid` 주소를 쓴다 | `ecs`, 모듈 저자 관찰 (m07 README) |

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
| Backup 볼트·계획·선택·온디맨드 백업 COMPLETED·복구 지점이 동작한다. `ListCopyJobs`는 501이다. 복원 결과가 빈 테이블이라(아래 행) 백업→복원 흐름 전체는 재현되지 않는다(🟡) | `backup` |
| Backup 신뢰 정책은 `CreateBackupSelection`에서만 검사하고 `StartBackupJob`은 없는 역할·리소스로도 COMPLETED다. 복원은 **빈 테이블**을 만든다. 볼트 잠금은 집행되고 `ListBackupPlans` 등 목록 계열은 501이다 | 모듈 저자 관찰 (m12 README, PR #8 재현) |
| DMS 복제 인스턴스·엔드포인트·작업 생성은 된다. `TestConnection`·삭제·중지 계열은 501이고, 데이터 이동은 없으며, 잘못된 엔진·매핑도 받아 준다 | `dms`, 모듈 저자 관찰 (m12 README) |
| 리전 분리가 없으므로 다중 리전은 포트가 다른 두 에뮬레이터(`scripts/dr-env.sh`, `emulator_site("DR_")`)로 흉내 낸다 | `client-config`, M00 |

### M13 비용 최적화

| 사실 | 근거 |
|---|---|
| Budgets 구성은 저장되지만 실제 지출은 항상 0이다. Cost Explorer `GetCostAndUsage`·`GetCostForecast`는 501이다 | `budgets`, 모듈 저자 관찰 (m13 README) |
| Tagging API `GetResources`는 SQS만 찾는다 → 태그 감사는 서비스별 API로 한다. Organizations 태그 정책 `CreatePolicy`는 501이다 | `tagging`, 모듈 저자 관찰 (m13 README) |
| S3 수명 주기 규칙은 현재 AWS 규칙대로 검증되지만(IA 전환 전 30일 대기는 2026-07-16에 없어졌고 30일 최소 보관 요금은 남음, 128 KB 미만 객체는 기본적으로 전환 안 됨 — M04 표 참고) 전환은 일어나지 않는다 → 비용은 워크시트로 계산한다 | `s3` |

### 모든 저자가 알아야 할 공통 사항

- **정책을 실제처럼 써야 한다.** 큐 정책, 버킷 정책, 역할 신뢰 정책·권한, Lambda 리소스 정책(`add-permission`)이 없으면 전달이 **조용히** 일어나지 않거나 거부된다(HTTP API만 예외).
- **조건 키가 있는 IAM 정책은 시뮬레이터로 판정한다.** 실제 호출로 맞게 동작하는 조합은 S3·SQS의 `aws:SecureTransport`·`aws:PrincipalAccount`뿐이다(`iam-conditions`).
- **코드에 바깥 주소를 쓰지 않는다.** 이미지·URL·구독 엔드포인트·Issuer에는 `.invalid` 같은 예약 이름을 쓴다. `tools/probe/no_external_hosts.py`로 검사할 수 있다(환경 메모).
- **상태와 시간을 단언하지 않는다.** waiter나 짧은 간격 폴링을 쓰되, CloudFormation은 2초 간격으로 폴링한다. "몇 초 뒤"라는 시간이나 "생성 직후 상태"는 단언하지 않는다.
- **목록 결과를 `--query ... --output text`로 변수에 담지 않는다**(페이지마다 `None` 줄). `--output json`이나 `--no-paginate`를 쓴다.
- **boto3 예제는 `emulator_guard`를 먼저 호출한다.** 두 사이트는 `emulator_site()`와 `emulator_site("DR_")`로 구분한다.

## 탐침이 다시 확인하지 않은 모듈 저자 관찰

아래는 이 탐침이 직접 다시 실행하지 않고 **모듈 README와 PR 리뷰에서 옮긴** 관찰이다. 위 "모듈별로 확인된 사실" 표에서 근거가 "모듈 저자 관찰"인 행의 출처 목록이기도 하다.

| 모듈 | 관찰 | 출처 |
|---|---|---|
| M01 | `aws:username` 조건은 IAM API에서만 정확하고 EC2에서는 Deny가 항상 적용됨. (README의 "`aws:PrincipalAccount` Deny 항상 적용"은 서비스에 따라 다름 — `iam-conditions`: S3·SQS는 정확, DynamoDB·EC2·IAM은 항상 적용) | 모듈 저자 관찰 (m01 README), PR #4 리뷰 재현 |
| M01 | `simulate-principal-policy`가 `${aws:username}` 정책 변수를 채우지 않음. `--policy-input-list file://`는 `InvalidInput` | 모듈 저자 관찰 (m01 README) |
| M01 | `AssumeRoleWithWebIdentity`는 발급자 공개 키를 가져오려 함(임의 토큰 거부). Identity Center는 계정 인스턴스 | 모듈 저자 관찰 (m01 README) |
| M01 | `GenerateCredentialReport`를 4시간 안에 다시 요청하면 `LimitExceeded`("1 report every 14400 seconds") | 모듈 저자 관찰 (m01 README L68) |
| M01 | 정책 없는 사용자도 통과하는 요청: Lambda `ListFunctions`, SNS `ListTopics`, Logs `DescribeLogGroups`, SSM `DescribeParameters`, CloudWatch `ListMetrics`, RDS `DescribeDBInstances`, Organizations `ListRoots` (거부 쪽인 IAM·EC2·KMS·Secrets Manager는 `iam-enforcement` 행으로 확인) | 모듈 저자 관찰 (m01 README L70) |
| M02 | 접두사 목록 CIDR `198.18.x.x` 하나, Direct Connect 위치 3개, Network Firewall은 차단 없음 | 모듈 저자 관찰 (m02 README) |
| M03 | ASG 축소 시 새 인스턴스부터 종료, 혼합 인스턴스 정책·템플릿 태그 미반영, 배치 그룹·최대 절전 제한 미검사, EIP 재연결 허용, `CopyImage`·`ModifySnapshotTier` 501 | 모듈 저자 관찰 (m03 README), PR #11 리뷰 재현(축소 순서) |
| M03 | `run-instances --block-device-mappings`(루트 볼륨 크기·암호화)가 무시되고 AMI 기본값(8 GiB, 비암호화)으로 생성 | 모듈 저자 관찰 (m03 README L70) |
| M03 | 스팟 중단 없음. RI 가격표가 결제 방식별 할인을 반영하지 않음. 용량 예약을 지정해 띄워도 `AvailableInstanceCount`가 줄지 않음 | 모듈 저자 관찰 (m03 README L74) |
| M03 | ALB 리디렉션 응답의 `Location` 호스트가 원래 호스트가 아니라 `elasticloadbalancingv2.amazonaws.com` | 모듈 저자 관찰 (m03 README L78) |
| M03 | NLB `--subnet-mappings`로 준 EIP가 응답에 표시되지 않음 | 모듈 저자 관찰 (m03 README L79) |
| M03 | Elastic Beanstalk 환경이 `Ready/Green`까지 가지만 실제 ASG·ELB는 없음. 카탈로그에 없는 솔루션 스택 이름도 허용 | 모듈 저자 관찰 (m03 README L88) |
| M04 | 존재하지 않는 역할로도 복제 구성 허용. SSE-KMS 응답이 별칭을 그대로 돌려줌. FSx `ImportPath` 미저장. EFS 같은 AZ 다른 서브넷 마운트 타깃 허용 | 모듈 저자 관찰 (m04 README), PR #14 재확인(EFS) |
| M04 | S3 정적 웹 사이트·Transfer Acceleration 설정은 저장되지만 해당 엔드포인트가 없음 | 모듈 저자 관찰 (m04 README L77) |
| M05 | RDS Multi-AZ DB 클러스터 멤버 미생성, Aurora `MultiAZ` 표시 false, 글로벌 테이블 리전 분리 없음, `timestream-write` `AmbiguousService`, TTL 삭제 Stream 레코드에 `userIdentity` 없음 | 모듈 저자 관찰 (m05 README), PR #7 리뷰 재현 |
| M06 | Scheduler cron 일정 미발화(20초 관찰), `QueueDeletedRecently` 비결정적 | 모듈 저자 관찰 (m06 README) |
| M07 | 함수 안 RustPython 제약 목록(`socket.gethostname`·`os.listdir` 오류, 네트워크 허용 서비스 목록) | 모듈 저자 관찰 (m07 README), PR #9 리뷰(외부 접속 감사) |
| M07 | Cognito 토큰의 `iss`가 `https://127.0.0.1:<포트>/<풀 ID>`이고, JWT 권한 부여자의 Issuer를 AWS 형식으로 넣으면 유효 토큰도 401 | 모듈 저자 관찰 (m07 README L66) (`iss` 값은 `integration-better` 행으로도 확인) |
| M07 | ECS 태스크가 `PROVISIONING → PENDING → STOPPED`(`CannotPullContainerError`). 이미지를 실제로 내려받으려 하며 ECR 주소를 주면 실제 AWS 호스트(`000000000000.dkr.ecr.us-east-1.amazonaws.com:443`)로 연결을 시도 | 모듈 저자 관찰 (m07 README L67) |
| M08 | 지리적 위치·지리 근접·IP 기반 응답 고정, CloudFront `DefaultRootObject` 무시, GA `ListEndpointGroups` 501, WAF IP 세트가 `X-Forwarded-For`를 기본 처리, 속도 기반 규칙 정확 | 모듈 저자 관찰 (m08 README), PR #12 리뷰 재현 |
| M09 | Config 수정 설정이 연결된 규칙도 삭제됨(AWS: `ResourceInUseException`), GuardDuty 결과가 EventBridge로 안 감, KMS 온디맨드 교체 목록이 비동기 | 모듈 저자 관찰 (m09 README), PR #12 리뷰 |
| M09 | Config가 지운 버킷의 평가 결과를 이름으로 기억함 → 평가 대상 버킷 이름에 실행마다 다른 접미사 | 모듈 저자 관찰 (m09 README L75) |
| M10 | Insights `pct()` 실패, SSM `DescribePatchBaselines`·`ListCommandInvocations`·`ListDocuments`·`DescribeMaintenanceWindows` 501, `SendCommand` 대상 0개 | 모듈 저자 관찰 (m10 README), PR #10 리뷰 재현 |
| M11 | Glue Spark 작업 `awsglue.context` 없음, Glue Python shell 작업 역할 정책 집행, 줄바꿈 없는 JSON → 모든 열 NULL 한 행, Athena 실행 시간 3초 고정 | 모듈 저자 관찰 (m11 README), PR #10 리뷰 재현 |
| M12 | Backup `StartBackupJob` 신뢰 미검사·복원 빈 테이블·목록 계열 501·볼트 잠금 집행, DMS 삭제·중지 계열 501, `ReplaceRouteTableAssociation` 501(탐침 `vpc-gaps`로도 확인), ASG `DescribeLoadBalancerTargetGroups` 501 | 모듈 저자 관찰 (m12 README), PR #8 리뷰 재현 |
| M12 | Backup `StartCopyJob`/`DescribeCopyJob`이 동작(같은 에뮬레이터의 다른 볼트로 COMPLETED) | 모듈 저자 관찰 (m12 README L69) |
| M12 | 같은 이름으로 `CreateBackupPlan`을 다시 하면 `AlreadyExistsException` | 모듈 저자 관찰 (m12 README L71) |
| M12 | 등록 해제한 ELB 대상이 `draining`으로 남음(실제 AWS도 등록 해제 지연 동안 draining) | 모듈 저자 관찰 (m12 README L77) |
| M12 | Elastic Disaster Recovery·MGN: `InitializeService` 뒤 `DescribeSourceServers`가 빈 목록 | 모듈 저자 관찰 (m12 README L79) |
| M12 | Application Discovery Service `DescribeAgents` 501 | 모듈 저자 관찰 (m12 README L80) |
| M13 | Cost Explorer 비용 할당 태그·추천 API 501, 이상 탐지 모니터 생성은 동작, Compute Optimizer `OptInRequiredException`, Organizations `TAG_POLICY` 501, DynamoDB 태그 반영 지연 | 모듈 저자 관찰 (m13 README) |

## 환경 메모

- **메모리 상한 기본 2g.** `scripts/emulator-up.sh`의 기본 `EMULATOR_MEMORY`는 2g다(공식 가이드와 같음). 빈 에뮬레이터는 약 174 MiB를 쓴다. 동기 Lambda `Invoke`는 호출 한 번에 약 7 MiB씩 늘리고 그 메모리를 되돌려 주지 않는다(`lambda-runtime` 행). 1 GiB 상한에서는 약 120회 호출 뒤 `OOMKilled`(종료 코드 137)되었다. 학습자에게는 `Could not connect to the endpoint URL`만 보인다. `env.sh`와 `emulator-status.sh`가 OOM을 알려 주며, 대처는 `scripts/emulator-reset.sh`다.
- **호스트 잠자기 뒤 시계 어긋남.** 노트북이 잠들었다 깨면 Colima VM(= 에뮬레이터 컨테이너)의 시계가 뒤처질 수 있다. 그러면 STS는 `SignatureDoesNotMatch`, S3·DynamoDB 등은 `RequestTimeTooSkewed`로 모든 요청을 거부한다. M03·M04·M05·M12 작업 중에 실제로 겪었다. `scripts/clock-check.sh`가 차이를 재고, `env.sh`는 서명 거부일 때만 이 진단을 보여 준다. 해결 명령(VM의 `systemd-timesyncd` 재시작 또는 `date -s`)은 실제로 잠자기 뒤 어긋난 상황에서는 아직 검증하지 못했다(M00 레슨 3).
- **리소스 엔드포인트는 컨테이너 안에만 있다.** RDS·Aurora·ElastiCache 주소, ALB·NLB `DNSName`, CloudFront `DomainName`은 `127.0.0.1:<임의 포트>`이고 에뮬레이터 컨테이너 **안에서만** 열린다. 호스트에서는 접속할 수 없다. 확인하려면 `docker exec aws-emulator-$EMULATOR_PORT curl ...`을 쓴다. API Gateway 실행 URL(`https://127.0.0.1:<API 포트>/_aws/execute-api/...`)만 호스트에서 열린다.
- **외부 접속 위험.** 에뮬레이터는 받은 주소를 실제로 따라간다. ECS 태스크는 이미지를 **실제로 내려받으려** 하고, ECR 주소를 주면 실제 AWS 호스트(`000000000000.dkr.ecr.us-east-1.amazonaws.com:443`)로 연결을 시도했다(m07 README). Cognito JWT 권한 부여자에 AWS 형식의 Issuer를 넣으면 JWKS를 실제 AWS에서 가져오려 할 수 있다(m07 리뷰 경고, 미검증).
  - **이 탐침의 이전 실행도 외부에 연결을 시도했다.** 이 보고서 이전의 모든 탐침 실행(PR #2 이후)은 ECS 작업 정의에 `public.ecr.aws/nginx/nginx:latest`를 썼고, 에뮬레이터는 `RunTask` 때 public.ecr.aws에서 이미지를 익명으로 받으려 했다(태스크는 `CannotPullContainerError`로 STOPPED). 같은 실행들은 SNS https 구독 엔드포인트(`https://example.com/hook`), HTTP API `HTTP_PROXY` 통합(`https://example.com/orders`), JWT 권한 부여자 Issuer(`https://cognito-idp.us-east-1.amazonaws.com/...`)도 바깥 주소로 등록했다. 에뮬레이터가 이 셋에 실제로 연결했는지는 기록하지 않았다. 자격 증명이나 계정 정보는 보내지 않았다(익명 요청, 에뮬레이터 내부 키만 사용).
  - 지금은 탐침의 이미지·URL·엔드포인트가 모두 `.invalid` 주소다(`registry.invalid/todayorder/nginx:latest`, `hook.todayorder.invalid` 등). `tools/probe/no_external_hosts.py`가 **탐침 시작 때**와 **M00 verify.sh**에서 tools·scripts·src·M00 코드를 정적으로 검사해, 이미지·URL·주소 키·메일 자리에 예약 이름(`.invalid`·`.test`·`.example`·`.localhost`)이나 루프백 이외의 호스트가 있으면 실패한다(Docker Hub로 가는 `nginx:latest` 같은 이름 포함). 의도된 예외(가드가 거부해야 하는 주소, 설치 안내 링크, 설치용 Dockerfile)는 그 줄에 `external-host-ok: <이유>`를 단다.
- **보고서의 근거.** 표의 각 행은 이 탐침의 실제 호출 결과다. 탐침이 다시 확인하지 않은 항목은 아래 "탐침이 다시 확인하지 않은 모듈 저자 관찰"에 출처(`모듈 저자 관찰 (mNN README)`)와 함께 따로 적었다.

## 501 NotImplemented 오퍼레이션

| 모듈 | 서비스 | 오퍼레이션/동작 |
|---|---|---|
| M01 | `iam` | EnableMFADevice |
| M01 | `iam` | ListMFADevices |
| M01 | `iam` | DeactivateMFADevice |
| M01 | `iam` | DeleteVirtualMFADevice |
| M01 | `organizations` | EnablePolicyType(SCP) |
| M01 | `organizations` | CreatePolicy(SCP) |
| M01 | `organizations` | ListPolicies(SCP) |
| M01 | `organizations` | AttachPolicy(FullAWSAccess → OU) |
| M01 | `organizations` | DescribeAccount |
| M01 | `organizations` | ListAccountsForParent |
| M01 | `organizations` | ListChildren |
| M01 | `organizations` | MoveAccount |
| M01 | `organizations` | CreateAccount |
| M01 | `organizations` | ListAccounts |
| M02 | `ec2-vpc` | CreateEgressOnlyInternetGateway |
| M02 | `ec2-vpc` | AcceptVpcPeeringConnection |
| M02 | `ec2-vpc` | CreateVpnConnection |
| M02 | `vpc-gaps` | RejectVpcPeeringConnection |
| M02 | `vpc-gaps` | DeleteVpcPeeringConnection |
| M02 | `vpc-gaps` | ReplaceRoute |
| M02 | `vpc-gaps` | ReplaceRouteTableAssociation |
| M02 | `vpc-gaps` | CreateNatGateway(AvailabilityMode=regional) |
| M02 | `vpc-gaps` | CreateEgressOnlyInternetGateway |
| M02 | `vpc-gaps` | DescribeEgressOnlyInternetGateways |
| M02 | `vpc-gaps` | CreateTransitGatewayRoute |
| M02 | `vpc-gaps` | SearchTransitGatewayRoutes |
| M02 | `vpc-gaps` | DeleteTransitGatewayVpcAttachment |
| M02 | `vpc-gaps` | CreateClientVpnEndpoint |
| M03 | `ec2-instances` | DescribeInstanceStatus |
| M03 | `ec2-instances` | DescribeTags |
| M03 | `ec2-instances` | ModifyInstanceAttribute(InstanceType=t3.small, 중지 상태) |
| M03 | `ebs-ami` | RegisterImage(스냅샷 기반) |
| M03 | `ebs-ami` | CreateImage(인스턴스에서 AMI) |
| M03 | `autoscaling` | PutScalingPolicy(TargetTracking CPU 50%) |
| M03 | `autoscaling` | PutScalingPolicy(StepScaling) |
| M03 | `autoscaling` | PutScheduledUpdateGroupAction |
| M03 | `autoscaling` | PutLifecycleHook(launching) |
| M03 | `autoscaling` | DescribeScalingActivities |
| M03 | `compute-gaps` | DeleteKeyPair |
| M03 | `compute-gaps` | DescribePolicies |
| M03 | `compute-gaps` | DescribeLifecycleHooks |
| M03 | `compute-gaps` | DescribeScheduledActions |
| M03 | `compute-gaps` | SetInstanceHealth |
| M04 | `s3-gaps` | CreateLocationNfs |
| M04 | `s3-gaps` | CreateSMBFileShare |
| M04 | `s3-gaps` | ListTapes |
| M05 | `db-gaps` | RestoreDBInstanceToPointInTime |
| M05 | `db-gaps` | PromoteReadReplica |
| M05 | `db-gaps` | CreateDBClusterEndpoint |
| M05 | `db-gaps` | DescribeDBInstanceAutomatedBackups |
| M05 | `db-gaps` | DeleteReplicationGroup |
| M08 | `cloudfront` | TestFunction |
| M08 | `edge-better` | ListCidrCollections |
| M09 | `ssm` | StartSession |
| M09 | `security-better` | auditmanager GetAccountStatus |
| M11 | `glue` | GetPartitions |
| M11 | `glue` | StartCrawler |
| M11 | `analytics-gaps` | ListWorkGroups |
| M11 | `analytics-gaps` | ListNamedQueries |
| M11 | `analytics-gaps` | DeleteWorkGroup |
| M12 | `backup` | ListCopyJobs |
| M12 | `dms` | TestConnection |
| M13 | `budgets` | ce GetCostAndUsage |
| 기타 | `misc-optional` | quicksight ListDashboards |
| 기타 | `misc-optional` | sagemaker ListNotebookInstances |

## 501 이외의 오류와 AWS와 다른 동작

탐침 입력이 잘못됐을 가능성도 있으니, 실습에 쓰기 전에 직접 재현해 볼 것.

| 모듈 | 서비스 | 오퍼레이션/동작 | 상태 | 상세 |
|---|---|---|---|---|
| M01 | `iam` | GetAccountSummary (AWS: 동작 / 에뮬레이터: InvalidAction 예상) | ❌ | HTTP 400 InvalidAction: unknown action: GetAccountSummary |
| M01 | `iam` | GetAccountPasswordPolicy (AWS: 동작 / 에뮬레이터: InvalidAction 예상) | ❌ | HTTP 400 InvalidAction: unknown action: GetAccountPasswordPolicy |
| M01 | `iam` | 자격 증명 기반 정책에 Principal → MalformedPolicyDocument | ⚠️ 다름 | 기대 MalformedPolicyDocument, 실제로는 성공했다 |
| M01 | `iam` | 정책 없는 사용자의 s3:ListAllMyBuckets 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 명시적 Deny(s3:*)가 ListBuckets(계정 수준)를 막음 | ⚠️ 다름 | 허용됨 — 계정 수준 호출에는 명시적 Deny도 집행되지 않는다(객체 API는 집행: iam-enforcement) |
| M01 | `iam-enforcement` | 정책 없는 사용자의 s3:ListAllMyBuckets(ListBuckets) 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 s3:CreateBucket 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 s3:PutBucketVersioning 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 s3:DeleteBucket(관리자가 만든 빈 버킷) 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 sqs:CreateQueue 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 dynamodb:CreateTable 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 dynamodb:DescribeTable 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 dynamodb:DeleteTable(관리자가 만든 테이블) 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | Allow * + 명시적 Deny s3:ListAllMyBuckets → ListBuckets 거부 | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 호출자 정책에 sts:AssumeRole 명시적 Deny → AssumeRole 거부 (신뢰 정책은 계정 루트) | ⚠️ 다름 | 허용됨 — AssumeRole 은 호출자의 자격 증명 정책을 평가하지 않는다 |
| M01 | `iam-enforcement` | 정책 없는 사용자의 AssumeRole 거부 (신뢰 정책은 계정 루트) | ⚠️ 다름 | 허용됨 — 호출자 정책 미평가 |
| M01 | `iam-enforcement` | 세션 정책의 Deny 가 EC2 DescribeVpcs 에 적용 | ⚠️ 다름 | 허용됨 — EC2 는 세션 정책을 무시 |
| M01 | `iam-enforcement` | iam:PassRole 명시적 Deny 인 사용자의 run-instances(인스턴스 프로파일) 거부 | ⚠️ 다름 | 허용됨 — PassRole 미검사 |
| M01 | `iam-enforcement` | 비활성(Inactive) 액세스 키로 STS GetCallerIdentity 거부 | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 비활성(Inactive) 액세스 키로 S3 ListBuckets 거부 | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | 비활성(Inactive) 액세스 키로 EC2 DescribeVpcs 거부 | ⚠️ 다름 | 허용됨 |
| M01 | `iam-enforcement` | Deny 조건 aws:RequestedRegion=eu-west-1 은 us-east-1 호출에 적용되지 않음 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — 조건이 맞지 않는데도 Deny 적용 |
| M01 | `iam-enforcement` | Deny 조건 aws:RequestedRegion=eu-west-1 은 us-east-1 호출에 적용되지 않음 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — 조건이 맞지 않는데도 Deny 적용 |
| M01 | `iam-enforcement` | Allow 조건 aws:RequestedRegion=us-east-1 이 us-east-1 호출에 적용됨 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — 조건이 맞는데도 Allow 미적용 |
| M01 | `iam-enforcement` | Allow 조건 aws:RequestedRegion=us-east-1 이 us-east-1 호출에 적용됨 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — 조건이 맞는데도 Allow 미적용 |
| M01 | `iam-enforcement` | Deny 조건 aws:SecureTransport=false 는 HTTPS 호출에 적용되지 않음 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — HTTPS인데도 Deny 적용 |
| M01 | `iam-enforcement` | Deny 조건 aws:SecureTransport=false 는 HTTPS 호출에 적용되지 않음 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — HTTPS인데도 Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:SecureTransport · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · S3 s3:ListBucket: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · S3 s3:ListBucket: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · SQS sqs:SendMessage: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · SQS sqs:SendMessage: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:RequestedRegion · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| M01 | `iam-conditions` | 조건 키 aws:PrincipalAccount · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| M02 | `ec2-vpc` | 피어링 수락 후 active | ⚠️ 다름 | 최종 pending-acceptance |
| M02 | `vpc-gaps` | NAT 게이트웨이를 지우면 그 경로가 blackhole 로 바뀜 | ⚠️ 다름 | 경로 State=['active'] |
| M02 | `vpc-gaps` | DefaultRouteTableAssociation=enable 이면 새 연결이 기본 TGW 라우팅 테이블에 자동 연결 | ⚠️ 다름 | 연결 0개 |
| M02 | `vpc-gaps` | DefaultRouteTablePropagation=enable 이면 새 연결이 기본 TGW 라우팅 테이블로 자동 전파 | ⚠️ 다름 | 전파 0개 |
| M02 | `vpc-gaps` | 기본 VPC 에 IGW 와 0.0.0.0/0 경로가 있음 | ⚠️ 다름 | 172.31.0.0/16 IGW 0개, 0.0.0.0/0 경로 없음 |
| M03 | `ebs-ami` | CreateVolume(SnapshotId=… 스냅샷에서 복원) | ❌ | HTTP 400 InvalidSnapshot.NotFound: The snapshot 'snap-0000000000000009e' does not exist. |
| M03 | `elbv2` | 호스트(macOS)에서 ALB DNSName으로 직접 연결 | ⚠️ 다름 | ConnectionRefusedError — 리스너 포트가 컨테이너 밖으로 게시되지 않음 |
| M03 | `autoscaling` | 인스턴스를 직접 종료하면 ASG가 대체 인스턴스를 띄움(자가 치유) | ⚠️ 다름 | 20초 후에도 종료된 인스턴스가 ASG에 ['InService/Healthy'] 로 남음 |
| M03 | `compute-gaps` | gp3 10 GiB 에 20,000 IOPS 요청이 거부됨(IOPS:GiB 비율 검사) | ⚠️ 다름 | 받아 줌 — 비율 미검사 |
| M03 | `compute-gaps` | 인스턴스 종료 시 DeleteOnTermination 루트 볼륨이 삭제됨 | ⚠️ 다름 | 남은 볼륨 상태 ['in-use'] |
| M03 | `compute-gaps` | ALB host-header 조건 규칙이 매칭됨(컨테이너 안 요청) | ⚠️ 다름 | 응답 본문 'default' |
| M03 | `compute-gaps` | ASG(--target-group-arns) 인스턴스가 대상 그룹에 자동 등록됨 | ⚠️ 다름 | ASG 인스턴스 2개, 대상 그룹 등록 0개 |
| M04 | `s3` | KMS 키를 비활성화하면 SSE-KMS 객체 읽기 실패 | ⚠️ 다름 | 읽힘 — S3가 KMS 키 상태를 확인하지 않음 |
| M04 | `s3-gaps` | 존재하지 않는 MFA 장치·임의 코드로 MFA Delete 를 켤 수 없음 | ⚠️ 다름 | 받아 줌 |
| M04 | `s3-gaps` | MFA Delete 켠 버킷에서 MFA 없이 버전 영구 삭제 → 거부 | ⚠️ 다름 | 기대 AccessDenied, 실제로는 성공했다 |
| M04 | `s3-gaps` | 객체 잠금 버킷의 버전 관리 일시 중지 → 거부 | ⚠️ 다름 | 기대 InvalidBucketState, 실제로는 성공했다 |
| M04 | `s3-gaps` | 버전 관리 없는 대상 버킷으로 복제 구성 → 거부 | ⚠️ 다름 | 기대 InvalidRequest, 실제로는 성공했다 |
| M04 | `s3-gaps` | 존재하지 않는 대상 버킷으로 복제 구성 → 거부 | ⚠️ 다름 | 기대 InvalidRequest, 실제로는 성공했다 |
| M04 | `s3-gaps` | 기본 암호화 설정이 SSE-C 를 차단하면 SSE-C 업로드 거부 | ⚠️ 다름 | BlockedEncryptionTypes 에 SSE-C 있음, 업로드 성공 |
| M04 | `s3-gaps` | 퍼블릭 정책(BPA 해제) 버킷의 객체를 익명 GET 하면 200 | ⚠️ 다름 | IsPublic=True, 익명 GET HTTP 403 |
| M04 | `s3-gaps` | DataSync S3→S3 작업이 파일을 실제로 복사 | ⚠️ 다름 | 처음 상태 LAUNCHING → SUCCESS, FilesTransferred=0, 대상 객체 0개 |
| M04 | `efs` | AZ별 마운트 타깃 IP가 해당 서브넷(10.30.x.x) 안에 있음 | ⚠️ 다름 | [('us-east-1a', '10.0.0.4', 'creating'), ('us-east-1b', '10.0.1.4', 'creating')] |
| M05 | `rds` | 호스트(macOS)에서 Endpoint 포트로 TCP 연결 | ⚠️ 다름 | 연결 불가(포트가 컨테이너 밖에 게시되지 않음) |
| M05 | `rds` | 강제 장애 조치 후 AZ가 바뀜 | ⚠️ 다름 | us-east-1a → us-east-1a |
| M05 | `elasticache` | 엔드포인트 포트에 실제 캐시 서버가 떠 있음(컨테이너 안 TCP) | ⚠️ 다름 | 컨테이너 안: CLOSED |
| M05 | `db-gaps` | DAX CreateSubnetGroup(유효한 서브넷) 이 성공 | ⚠️ 다름 | InvalidParameterValueException: Some input subnets in :[subnet-00000000000000163, subnet-00000000000000165] are invalid. |
| M05 | `db-gaps` | PITR LatestRestorableDateTime 이 시간이 지나면 앞으로 감 | ⚠️ 다름 | PITR 켠 직후 2026-11-13 12:18:02.330000+09:00 → 6초 뒤 2026-11-13 12:18:02.330000+09:00 |
| M05 | `db-gaps` | PITR RestoreDateTime(v1과 v2 사이) 복원 → 그 시점 데이터(v1) | ⚠️ 다름 | 복원 결과 오류 InvalidRestoreTimeException: An invalid restore time was specified. RestoreDateTime must be between EarliestR |
| M06 | `integration-better` | Cognito 토큰 iss 가 https://cognito-idp.<리전>.amazonaws.com/<풀 ID> | ⚠️ 다름 | https://127.0.0.1:9297/us-east-1_4e32655dd |
| M06 | `integration-better` | Scheduler at() 일정은 지정 시각(10분 뒤) 전에는 발화하지 않음 | ⚠️ 다름 | 11초 만에 전달됨 |
| M07 | `ecs` | RunTask 태스크가 RUNNING까지 전이 (실제로 이미지를 받아 실행하려 함) | ⚠️ 다름 | 전이 PROVISIONING → PENDING → STOPPED; stoppedReason=CannotPullContainerError: failed to resolve ref registry.invalid/todayorder/nginx:latest: failed to do request |
| M07 | `lambda-runtime` | Lambda python3.12 런타임이 CPython | ⚠️ 다름 | sys.version=3.14.0.alpha (heads/unknown-branch:0000000, Nov 10 2026, 20:50:33) [RustPython 0.6.0 with  |
| M07 | `lambda-runtime` | 비동기 실패가 OnFailure 대상(SQS)에 전달됨 | ⚠️ 다름 | 35초 안에 0건 |
| M07 | `lambda-runtime` | MaximumRetryAttempts=0 이면 비동기 실패 함수가 1번만 실행됨 | ⚠️ 다름 | 실행 3번 |
| M07 | `lambda-runtime` | 비동기 실패가 함수 DLQ(DeadLetterConfig, SQS)에 전달됨 | ⚠️ 다름 | 35초 안에 0건 (함수 실행 3번) |
| M07 | `lambda-runtime` | 동기 Invoke 를 반복해도 에뮬레이터 메모리가 늘지 않음 | ⚠️ 다름 | 278 → 389 MiB, 호출당 약 7.4 MiB 증가(회수되지 않음) |
| M08 | `route53` | 상태 확인이 실제로 대상을 검사함(존재하지 않는 도메인 → 실패여야 함) | ⚠️ 다름 | 관찰 8건 ['Success: HTTP Status Code 200, OK', 'Success: HTTP Status Code 200, OK'] — 존재하지 않는 대상인데 Success면 시뮬레이션된 결과 |
| M08 | `cloudfront` | 배포 도메인 이름(*.cloudfront.net) 발급 | ⚠️ 다름 | DomainName=127.0.0.1:32769 Status=InProgress — 에뮬레이터는 컨테이너 안의 로컬 포트를 준다 |
| M08 | `edge-better` | 지연 시간 레코드: 질의자 위치(리졸버 IP)에 따라 다른 답 | ⚠️ 다름 | 미국 리졸버 ['192.0.2.20'], 서울 리졸버 ['192.0.2.20'] |
| M08 | `edge-better` | 같은 이름·유형에 서로 다른 라우팅 정책(가중치+지연 시간) → InvalidChangeBatch | ⚠️ 다름 | 기대 InvalidChangeBatch, 실제로는 성공했다 |
| M09 | `secretsmanager` | RotateSecret(Lambda ARN 지정) | ❌ | HTTP 400 AccessDeniedException: Secrets Manager cannot invoke the specified Lambda function. Ensure that the function policy grants access to the principal secretsmanager.amazonaws.com. |
| M09 | `ssm` | 공개 파라미터(리전 목록)가 들어 있음 | ⚠️ 다름 | 0개 |
| M09 | `acm` | Route 53에 검증 CNAME을 만들면 ISSUED로 전환(20초 대기) | ⚠️ 다름 | PENDING_VALIDATION |
| M09 | `cloudtrail` | S3 CreateBucket이 LookupEvents(이벤트 기록)에 나타남 | ⚠️ 다름 |  |
| M09 | `security-better` | CMK 를 비활성화하면 SecureString 복호화(WithDecryption) 실패 | ⚠️ 다름 | 복호화됨(True) |
| M09 | `security-better` | CloudTrail LookupEvents 에 KMS 관리 이벤트(CreateKey)가 나타남 | ⚠️ 다름 |  |
| M10 | `cloudwatch` | 기본 EC2 지표(AWS/EC2)가 저절로 생김 | ⚠️ 다름 | 0개 — 인스턴스가 실제로 돌지 않으므로 없을 수 있음 |
| M10 | `cloudformation` | (VPC 스택) 변경 세트 실행 후 UPDATE_COMPLETE, 서브넷 3개 | ⚠️ 다름 | UPDATE_ROLLBACK_COMPLETE, 서브넷 2 ['IgwAttach: NotImplemented: this emulator does not change the properties of an existing AWS::EC2::VPCGatewayAttachment in '] |
| M10 | `cfn-timing` | CLI 웨이터처럼 30초 간격으로만 조회해도 NAT·경로가 있는 VPC 스택이 CREATE_COMPLETE | ⚠️ 다름 | 관찰 CREATE_IN_PROGRESS → ROLLBACK_IN_PROGRESS → ROLLBACK_COMPLETE AWS::EC2::Route todayorder-probe-cfnwaiter-98519aa0-PrivateDefault-7188114573E2 was still CREATE_IN_PROGRESS when the wa |
| M10 | `cfn-timing` | 드리프트: 손대지 않은 IGW·경로·NAT·EIP·라우팅 테이블은 IN_SYNC | ⚠️ 다름 | {"Igw": "DELETED", "IgwAttach": "DELETED", "PublicDefault": "DELETED", "PrivateDefault": "DELETED", "Nat": "DELETED", "NatEip": "DELETED", "PublicRt": "DELETED"} |
| M10 | `cfn-timing` | 드리프트: 스택 밖에서 SG 인바운드 규칙을 추가하면 MODIFIED | ⚠️ 다름 | WebSg=IN_SYNC |
| M11 | `athena` | 쿼리 결과 파일이 작업 그룹 결과 위치(S3)에 저장됨 | ⚠️ 다름 | results/ 아래 0개, 버킷 전체 ['orders/dt=2026-11-01/p.json'] |
| M11 | `analytics-gaps` | Athena: 등록된 파티션(dt=2026-11-01) 데이터만 읽음 (2건) | ⚠️ 다름 | SUCCEEDED [['3']] |
| M11 | `analytics-gaps` | Athena: 파티션 열 dt 로 WHERE 필터 | ⚠️ 다름 | FAILED no such column: dt in SELECT count(*) FROM "todayorder_probe_db_127a4839.orders" WHERE dt = '2026-11-01' at offset 65 |
| M11 | `analytics-gaps` | Athena: Trino 함수 date_trunc·from_iso8601_timestamp | ⚠️ 다름 | FAILED no such function: date_trunc in SELECT date_trunc('day', from_iso8601_timestamp('2026-11-01T10:00:00Z')) at offset 7 |
| M11 | `analytics-gaps` | Firehose: 역할에 S3 권한이 없으면 배달하지 못함 | ⚠️ 다름 | 배달됨(권한 정책 미검사) |
| M13 | `tagging` | 태그로 S3·SQS·DynamoDB·VPC를 한 번에 찾음 | ⚠️ 다름 | {'s3': False, 'sqs': True, 'dynamodb': False, 'ec2': False} |

## 서비스별 상세

<a id="svc-client-config"></a>

### M00 · client-config

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBucket(127.0.0.1) | ✅ |  |
| 동작 | boto3 + localhost 엔드포인트로 S3 HeadBucket | ✅ 동작 | boto3(Python)는 localhost여도 경로 방식으로 보내 성공한다 (JS/Java/Go SDK는 가상 호스트 방식이라 실패한다고 문서에 명시) |
| 동작 | 가상 호스트 방식(<bucket>.localhost)은 실패해야 함 | ✅ 동작 | EndpointConnectionError: Could not connect to the endpoint URL: "https://todayorder-probe-cfgbucket-81fa1393.localhost:9297/" |
| 동작 | S3 Control은 에뮬레이터에 도달하지 못함 | ✅ 동작 | EndpointConnectionError: Could not connect to the endpoint URL: "https://000000000000.127.0.0.1:9297/v20180820/configuration/publicAccessBlock" |
| 동작 | 호스트 접두사 주입을 켜면 sync- 접두사로 연결 실패 | ✅ 동작 | Could not connect to the endpoint URL: "https://sync-127.0.0.1:9297/" |
| 동작 | 에뮬레이터 키가 아닌 키로 서명하면 거부 | ✅ 동작 | InvalidClientTokenId: The security token included in the request is invalid. |

<a id="svc-iam"></a>

### M01 · iam

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateUser | ✅ |  |
| API | CreateGroup | ✅ |  |
| API | AddUserToGroup | ✅ |  |
| API | CreatePolicy | ✅ |  |
| API | AttachGroupPolicy | ✅ |  |
| API | CreatePolicyVersion | ✅ |  |
| API | ListPolicyVersions | ✅ |  |
| API | ListAttachedGroupPolicies | ✅ |  |
| API | PutUserPolicy (인라인) | ✅ |  |
| API | PutUserPermissionsBoundary | ✅ |  |
| API | CreateLoginProfile | ✅ |  |
| API | CreateVirtualMFADevice | ✅ |  |
| API | EnableMFADevice | ⛔ 501 | HTTP 501 NotImplemented: operation EnableMFADevice is scaffolded but not implemented in this emulator |
| API | ListMFADevices | ⛔ 501 | HTTP 501 NotImplemented: operation ListMFADevices is scaffolded but not implemented in this emulator |
| API | DeactivateMFADevice | ⛔ 501 | HTTP 501 NotImplemented: operation DeactivateMFADevice is scaffolded but not implemented in this emulator |
| API | DeleteVirtualMFADevice | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteVirtualMFADevice is scaffolded but not implemented in this emulator |
| API | GetAccountSummary (AWS: 동작 / 에뮬레이터: InvalidAction 예상) | ❌ | HTTP 400 InvalidAction: unknown action: GetAccountSummary |
| API | GetAccountPasswordPolicy (AWS: 동작 / 에뮬레이터: InvalidAction 예상) | ❌ | HTTP 400 InvalidAction: unknown action: GetAccountPasswordPolicy |
| 동작 | 자격 증명 기반 정책에 Principal → MalformedPolicyDocument | ⚠️ 다름 | 기대 MalformedPolicyDocument, 실제로는 성공했다 |
| API | GetAccountPasswordPolicy/UpdateAccountPasswordPolicy | ✅ |  |
| API | GetPolicy (AWS 관리형 ReadOnlyAccess) | ✅ |  |
| API | GenerateCredentialReport | ✅ |  |
| API | CreateRole | ✅ |  |
| API | PutRolePolicy | ✅ |  |
| API | CreateInstanceProfile | ✅ |  |
| API | AddRoleToInstanceProfile | ✅ |  |
| API | SimulateCustomPolicy | ✅ |  |
| 동작 | SimulateCustomPolicy가 명시적 Deny/암묵적 Deny를 판정 | ✅ 동작 | 결과 {'s3:GetObject': 'allowed', 's3:DeleteBucket': 'explicitDeny', 'ec2:RunInstances': 'implicitDeny'} |
| API | SimulatePrincipalPolicy | ✅ |  |
| 동작 | SimulatePrincipalPolicy가 그룹 정책을 반영 | ✅ 동작 | 결과 {'s3:GetObject': 'allowed', 'ec2:RunInstances': 'implicitDeny'} |
| API | CreateAccessKey | ✅ |  |
| 동작 | IAM 사용자 액세스 키로 서명한 요청을 받아 줌 | ✅ 동작 | arn:aws:iam::000000000000:user/todayorder-probe-user-d585e241 |
| 동작 | 권한 없는 사용자의 iam:CreateUser가 거부됨(암묵적 Deny) | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 s3:ListAllMyBuckets 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) [계정 수준 호출 — 전체 표는 iam-enforcement] | ⚠️ 다름 | 허용됨 — 이 서비스는 계정·관리 수준 호출에 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 ec2:DescribeVpcs 거부(암묵적 Deny) | ✅ 동작 | UnauthorizedOperation |
| 동작 | 정책 없는 사용자의 iam:ListUsers 거부(암묵적 Deny) | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 kms:ListKeys 거부(암묵적 Deny) | ✅ 동작 | AccessDeniedException |
| 동작 | Allow iam:ListUsers 를 붙이면 허용됨 | ✅ 동작 | 허용 |
| 동작 | 명시적 Deny iam:ListUsers 가 Allow를 이김 | ✅ 동작 | AccessDenied |
| 동작 | 명시적 Deny(s3:*)가 ListBuckets(계정 수준)를 막음 | ⚠️ 다름 | 허용됨 — 계정 수준 호출에는 명시적 Deny도 집행되지 않는다(객체 API는 집행: iam-enforcement) |

<a id="svc-iam-enforcement"></a>

### M01 · iam-enforcement

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | 정책 없는 사용자의 s3:ListAllMyBuckets(ListBuckets) 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 s3:CreateBucket 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 s3:PutBucketVersioning 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 s3:DeleteBucket(관리자가 만든 빈 버킷) 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 s3:GetObject 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 s3:PutObject 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 s3:ListBucket(ListObjectsV2) 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 sqs:CreateQueue 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 sqs:SendMessage 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 sqs:ReceiveMessage 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 dynamodb:CreateTable 거부(암묵적 Deny) [계정 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 dynamodb:DescribeTable 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 dynamodb:PutItem 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | 정책 없는 사용자의 dynamodb:Scan 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | 정책 없는 사용자의 dynamodb:DeleteTable(관리자가 만든 테이블) 거부(암묵적 Deny) [관리 수준] | ⚠️ 다름 | 허용됨 |
| 동작 | 정책 없는 사용자의 secretsmanager:ListSecrets 거부(암묵적 Deny) [계정 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | 정책 없는 사용자의 secretsmanager:CreateSecret 거부(암묵적 Deny) [계정 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | 정책 없는 사용자의 secretsmanager:DescribeSecret 거부(암묵적 Deny) [관리 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | 정책 없는 사용자의 secretsmanager:GetSecretValue 거부(암묵적 Deny) [데이터 수준] | ✅ 동작 | AccessDeniedException |
| 동작 | secretsmanager:GetSecretValue 를 허용한 사용자는 비밀 값 읽기 성공(대조군) | ✅ 동작 | OK |
| 동작 | Allow * + 명시적 Deny s3:GetObject → GetObject 거부 | ✅ 동작 | AccessDenied |
| 동작 | Allow * + 명시적 Deny s3:ListAllMyBuckets → ListBuckets 거부 | ⚠️ 다름 | 허용됨 |
| 동작 | 호출자 정책에 sts:AssumeRole 명시적 Deny → AssumeRole 거부 (신뢰 정책은 계정 루트) | ⚠️ 다름 | 허용됨 — AssumeRole 은 호출자의 자격 증명 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 AssumeRole 거부 (신뢰 정책은 계정 루트) | ⚠️ 다름 | 허용됨 — 호출자 정책 미평가 |
| API | AssumeRole(세션 정책: Deny iam:ListUsers·ec2:DescribeVpcs) | ✅ |  |
| 동작 | 세션 정책의 Deny 가 IAM ListUsers 에 적용 | ✅ 동작 | AccessDenied |
| 동작 | 세션 정책의 Deny 가 EC2 DescribeVpcs 에 적용 | ⚠️ 다름 | 허용됨 — EC2 는 세션 정책을 무시 |
| 동작 | iam:PassRole 명시적 Deny 인 사용자의 run-instances(인스턴스 프로파일) 거부 | ⚠️ 다름 | 허용됨 — PassRole 미검사 |
| 동작 | 비활성(Inactive) 액세스 키로 IAM ListUsers 거부 | ✅ 동작 | InvalidClientTokenId |
| 동작 | 비활성(Inactive) 액세스 키로 STS GetCallerIdentity 거부 | ⚠️ 다름 | 허용됨 |
| 동작 | 비활성(Inactive) 액세스 키로 S3 ListBuckets 거부 | ⚠️ 다름 | 허용됨 |
| 동작 | 비활성(Inactive) 액세스 키로 EC2 DescribeVpcs 거부 | ⚠️ 다름 | 허용됨 |
| 동작 | Deny 조건 aws:RequestedRegion=eu-west-1 은 us-east-1 호출에 적용되지 않음 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — 조건이 맞지 않는데도 Deny 적용 |
| 동작 | Deny 조건 aws:RequestedRegion=eu-west-1 은 us-east-1 호출에 적용되지 않음 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — 조건이 맞지 않는데도 Deny 적용 |
| 동작 | Allow 조건 aws:RequestedRegion=us-east-1 이 us-east-1 호출에 적용됨 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — 조건이 맞는데도 Allow 미적용 |
| 동작 | Allow 조건 aws:RequestedRegion=us-east-1 이 us-east-1 호출에 적용됨 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — 조건이 맞는데도 Allow 미적용 |
| 동작 | Deny 조건 aws:SecureTransport=false 는 HTTPS 호출에 적용되지 않음 (ec2:DescribeVpcs 허용) | ⚠️ 다름 | UnauthorizedOperation — HTTPS인데도 Deny 적용 |
| 동작 | Deny 조건 aws:SecureTransport=false 는 HTTPS 호출에 적용되지 않음 (iam:ListUsers 허용) | ⚠️ 다름 | AccessDenied — HTTPS인데도 Deny 적용 |
| API | SimulateCustomPolicy(Deny(RequestedRegion=eu-west-1), 컨텍스트 us-east-1) | ✅ |  |
| 동작 | 시뮬레이터가 조건 키를 올바르게 판정: Deny(RequestedRegion=eu-west-1) → allowed | ✅ 동작 | {'iam:ListUsers': 'allowed', 'ec2:DescribeVpcs': 'allowed'} |
| API | SimulateCustomPolicy(Allow(RequestedRegion=us-east-1), 컨텍스트 us-east-1) | ✅ |  |
| 동작 | 시뮬레이터가 조건 키를 올바르게 판정: Allow(RequestedRegion=us-east-1) → allowed | ✅ 동작 | {'iam:ListUsers': 'allowed', 'ec2:DescribeVpcs': 'allowed'} |
| API | SimulateCustomPolicy(Deny SecureTransport=false, 컨텍스트 true) | ✅ |  |
| 동작 | 시뮬레이터가 조건 키를 올바르게 판정: Deny(SecureTransport=false) → allowed | ✅ 동작 | {'iam:ListUsers': 'allowed'} |

<a id="svc-iam-conditions"></a>

### M01 · iam-conditions

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | 조건 키 aws:SecureTransport · S3 s3:ListBucket: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:SecureTransport · S3 s3:ListBucket: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:SecureTransport · SQS sqs:SendMessage: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:SecureTransport · SQS sqs:SendMessage: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:SecureTransport · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| 동작 | 조건 키 aws:SecureTransport · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| 동작 | 조건 키 aws:SecureTransport · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| 동작 | 조건 키 aws:SecureTransport · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| 동작 | 조건 키 aws:SecureTransport · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(HTTPS 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| 동작 | 조건 키 aws:SecureTransport · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(HTTPS 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| 동작 | 조건 키 aws:RequestedRegion · S3 s3:ListBucket: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| 동작 | 조건 키 aws:RequestedRegion · S3 s3:ListBucket: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| 동작 | 조건 키 aws:RequestedRegion · SQS sqs:SendMessage: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| 동작 | 조건 키 aws:RequestedRegion · SQS sqs:SendMessage: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| 동작 | 조건 키 aws:RequestedRegion · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| 동작 | 조건 키 aws:RequestedRegion · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| 동작 | 조건 키 aws:RequestedRegion · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| 동작 | 조건 키 aws:RequestedRegion · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| 동작 | 조건 키 aws:RequestedRegion · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| 동작 | 조건 키 aws:RequestedRegion · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(us-east-1 호출) | ⚠️ 다름 | AccessDenied — Deny 적용 |
| 동작 | 조건 키 aws:PrincipalAccount · S3 s3:ListBucket: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:PrincipalAccount · S3 s3:ListBucket: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:PrincipalAccount · SQS sqs:SendMessage: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:PrincipalAccount · SQS sqs:SendMessage: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ✅ 동작 | 허용 |
| 동작 | 조건 키 aws:PrincipalAccount · DynamoDB dynamodb:Scan: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDeniedException — Allow 미적용 |
| 동작 | 조건 키 aws:PrincipalAccount · DynamoDB dynamodb:Scan: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDeniedException — Deny 적용 |
| 동작 | 조건 키 aws:PrincipalAccount · EC2 ec2:DescribeVpcs: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | UnauthorizedOperation — Allow 미적용 |
| 동작 | 조건 키 aws:PrincipalAccount · EC2 ec2:DescribeVpcs: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | UnauthorizedOperation — Deny 적용 |
| 동작 | 조건 키 aws:PrincipalAccount · IAM iam:ListUsers: 맞는 조건의 Allow 가 적용됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDenied — Allow 미적용 |
| 동작 | 조건 키 aws:PrincipalAccount · IAM iam:ListUsers: 맞지 않는 조건의 Deny 는 적용 안 됨(계정 000000000000의 사용자) | ⚠️ 다름 | AccessDenied — Deny 적용 |

<a id="svc-sts"></a>

### M01 · sts

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | GetCallerIdentity | ✅ |  |
| 동작 | 계정 ID가 000000000000 | ✅ 동작 | arn:aws:iam::000000000000:user/emulator |
| API | CreateRole(사전) | ✅ |  |
| API | AssumeRole | ✅ |  |
| 동작 | AssumeRole 임시 자격 증명(SessionToken, Expiration 포함) | ✅ 동작 | AccessKeyId 접두사=EMUL (실제 AWS는 ASIA) |
| 동작 | 임시 자격 증명으로 호출하면 assumed-role ARN | ✅ 동작 | arn:aws:sts::000000000000:assumed-role/todayorder-probe-assume-2637944a/probe |
| API | CreateRole(EC2 전용 신뢰 정책) | ✅ |  |
| 동작 | 신뢰 정책에 없는 주체의 AssumeRole이 거부됨 | ✅ 동작 | AccessDenied: User: arn:aws:iam::000000000000:user/emulator is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::000000000000:role/todayorder-probe-ec2only- |
| API | GetSessionToken | ✅ |  |
| API | GetAccessKeyInfo | ✅ |  |

<a id="svc-organizations"></a>

### M01 · organizations

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | DescribeOrganization | ✅ |  |
| 동작 | 조직이 처음부터 존재함(CreateOrganization 불필요) | ✅ 동작 | FeatureSet=ALL |
| API | ListRoots | ✅ |  |
| API | EnablePolicyType(SCP) | ⛔ 501 | HTTP 501 NotImplemented: operation EnablePolicyType is scaffolded but not implemented in this emulator |
| API | CreateOrganizationalUnit | ✅ |  |
| API | CreatePolicy(SCP) | ⛔ 501 | HTTP 501 NotImplemented: operation CreatePolicy is scaffolded but not implemented in this emulator |
| API | ListPolicies(SCP) | ⛔ 501 | HTTP 501 NotImplemented: operation ListPolicies is scaffolded but not implemented in this emulator |
| API | AttachPolicy(FullAWSAccess → OU) | ⛔ 501 | HTTP 501 NotImplemented: operation AttachPolicy is scaffolded but not implemented in this emulator |
| API | DescribeAccount | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeAccount is scaffolded but not implemented in this emulator |
| API | ListAccountsForParent | ⛔ 501 | HTTP 501 NotImplemented: operation ListAccountsForParent is scaffolded but not implemented in this emulator |
| API | ListChildren | ⛔ 501 | HTTP 501 NotImplemented: operation ListChildren is scaffolded but not implemented in this emulator |
| API | MoveAccount | ⛔ 501 | HTTP 501 NotImplemented: operation MoveAccount is scaffolded but not implemented in this emulator |
| API | CreateAccount | ⛔ 501 | HTTP 501 NotImplemented: operation CreateAccount is scaffolded but not implemented in this emulator |
| API | ListAccounts | ⛔ 501 | HTTP 501 NotImplemented: operation ListAccounts is scaffolded but not implemented in this emulator |

<a id="svc-ec2-vpc"></a>

### M02 · ec2-vpc

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | DescribeAvailabilityZones | ✅ |  |
| 동작 | us-east-1 AZ 목록 조회 | ✅ 동작 | us-east-1a, us-east-1b, us-east-1c |
| API | CreateVpc | ✅ |  |
| 동작 | VPC 상태 pending→available | ✅ 동작 | 생성 직후 pending |
| API | ModifyVpcAttribute(EnableDnsHostnames) | ✅ |  |
| API | CreateSubnet(us-east-1a) | ✅ |  |
| API | CreateSubnet(us-east-1b) | ✅ |  |
| API | DescribeSubnets | ✅ |  |
| 동작 | 서브넷이 실제로 저장되고 AZ·CIDR이 유지됨 | ✅ 동작 | [('us-east-1a', '10.0.1.0/24'), ('us-east-1b', '10.0.2.0/24')] |
| 동작 | /24 서브넷의 사용 가능 IP = 251 (AWS 예약 5개) | ✅ 동작 | [251, 251] |
| 동작 | VPC CIDR 밖의 서브넷 → InvalidSubnet.Range | ✅ 동작 | InvalidSubnet.Range: The CIDR '10.1.0.0/24' is invalid. |
| 동작 | 기존 서브넷과 겹치는 CIDR → InvalidSubnet.Conflict | ✅ 동작 | InvalidSubnet.Conflict: The CIDR '10.0.1.128/25' conflicts with another subnet |
| API | ModifySubnetAttribute(MapPublicIpOnLaunch) | ✅ |  |
| 동작 | MapPublicIpOnLaunch 반영 | ✅ 동작 | True |
| API | CreateInternetGateway | ✅ |  |
| API | AttachInternetGateway | ✅ |  |
| API | CreateRouteTable | ✅ |  |
| API | CreateRoute(0.0.0.0/0 → IGW) | ✅ |  |
| API | AssociateRouteTable | ✅ |  |
| 동작 | 라우팅 테이블에 local 경로 + IGW 경로 | ✅ 동작 | [('10.0.0.0/16', 'local'), ('0.0.0.0/0', 'igw-0000000000000018e')] |
| 동작 | VPC 생성 시 기본(main) 라우팅 테이블 자동 생성 | ✅ 동작 | 1개 |
| API | AllocateAddress | ✅ |  |
| API | CreateNatGateway | ✅ |  |
| 동작 | NAT 게이트웨이 pending→available | ✅ 동작 | 생성 직후 pending |
| API | CreateRoute(0.0.0.0/0 → NAT) | ✅ |  |
| 동작 | NAT 게이트웨이에 EIP 공인 IP가 붙음 | ✅ 동작 | [{'AllocationId': 'eipalloc-00000000000000191', 'NetworkInterfaceId': 'eni-00000000000000192', 'PrivateIp': '10.0.1.4',  |
| API | CreateEgressOnlyInternetGateway | ⛔ 501 | HTTP 501 NotImplemented: operation CreateEgressOnlyInternetGateway is scaffolded but not implemented in this emulator |
| API | CreateSecurityGroup(web) | ✅ |  |
| API | CreateSecurityGroup(app) | ✅ |  |
| API | CreateSecurityGroup(db) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(0.0.0.0/0:443 → web) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(SG 참조 web→app) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(SG 참조 app→db) | ✅ |  |
| 동작 | SG 체이닝 규칙이 조회됨(db ← app 참조) | ✅ 동작 | ['sg-00000000000000198'] |
| 동작 | 새 SG의 기본 아웃바운드 전체 허용 규칙 | ✅ 동작 | [{'IpProtocol': '-1', 'UserIdGroupPairs': [], 'IpRanges': [{'CidrIp': '0.0.0.0/0'}], 'Ipv6Ranges': [], 'PrefixListIds':  |
| API | DescribeSecurityGroupRules | ✅ |  |
| 동작 | DescribeSecurityGroupRules가 규칙을 반환 | ✅ 동작 | 2개 |
| 동작 | 같은 규칙 중복 추가 → InvalidPermission.Duplicate | ✅ 동작 | InvalidPermission.Duplicate: the specified rule "peer: 0.0.0.0/0, TCP, from port: 443, to port: 443, ALLOW" already exists |
| 동작 | 다른 SG가 참조 중인 SG 삭제 → DependencyViolation | ✅ 동작 | DependencyViolation: resource sg-00000000000000198 has a dependent object |
| API | CreateNetworkAcl | ✅ |  |
| API | CreateNetworkAclEntry(100 allow 443) | ✅ |  |
| API | CreateNetworkAclEntry(90 deny 203.0.113.0/24) | ✅ |  |
| API | CreateNetworkAclEntry(egress 100 allow 1024-65535) | ✅ |  |
| 동작 | NACL 규칙 번호·allow/deny·기본 * deny(32767) 조회 | ✅ 동작 | [(90, 'deny', False), (100, 'allow', False), (100, 'allow', True), (32767, 'deny', False), (32767, 'deny', True)] |
| 동작 | 같은 규칙 번호 중복 → NetworkAclEntryAlreadyExists | ✅ 동작 | NetworkAclEntryAlreadyExists: The network acl entry identified by 100 already exists. |
| API | ReplaceNetworkAclAssociation | ✅ |  |
| API | CreateVpcEndpoint(Gateway S3) | ✅ |  |
| 동작 | 게이트웨이 엔드포인트가 라우팅 테이블에 prefix list 경로 추가 | ✅ 동작 | [{'DestinationPrefixListId': 'pl-e9da6b72', 'GatewayId': 'vpce-000000000000001a1', 'Origin': 'CreateRoute', 'State': 'active'}] |
| API | CreateVpcEndpoint(Interface SQS) | ✅ |  |
| 동작 | 인터페이스 엔드포인트 ENI·DNS 항목 | ✅ 동작 | ENI ['eni-000000000000001a2'] DNS 2개 |
| API | DescribeVpcEndpointServices | ✅ |  |
| API | CreateVpc(피어용 10.1.0.0/16) | ✅ |  |
| API | CreateVpcPeeringConnection | ✅ |  |
| 동작 | 피어링 생성 후 pending-acceptance 로 전이 | ✅ 동작 | 생성 직후 initiating-request → pending-acceptance |
| API | AcceptVpcPeeringConnection | ⛔ 501 | HTTP 501 NotImplemented: operation AcceptVpcPeeringConnection is scaffolded but not implemented in this emulator |
| 동작 | 피어링 수락 후 active | ⚠️ 다름 | 최종 pending-acceptance |
| API | CreateRoute(10.1.0.0/16 → pcx) | ✅ |  |
| 동작 | CIDR이 겹치는 VPC 피어링은 실패(failed/거부) | ✅ 동작 | 상태 failed, 수락 시도 → accept 오류: NotImplemented |
| API | CreateTransitGateway | ✅ |  |
| 동작 | TGW pending→available | ✅ 동작 | 생성 직후 pending |
| API | CreateTransitGatewayVpcAttachment | ✅ |  |
| 동작 | TGW VPC 연결 pending→available | ✅ 동작 | 생성 직후 pending |
| API | CreateTransitGatewayRouteTable | ✅ |  |
| API | CreateRoute(10.2.0.0/16 → TGW) | ✅ |  |
| API | CreateCustomerGateway | ✅ |  |
| API | CreateVpnGateway | ✅ |  |
| API | CreateVpnConnection | ⛔ 501 | HTTP 501 NotImplemented: operation CreateVpnConnection is scaffolded but not implemented in this emulator |
| API | CreateFlowLogs(cloud-watch-logs) | ✅ |  |
| 동작 | Flow Log ID 발급(Unsuccessful 없음) | ✅ 동작 | [] |
| 동작 | 서브넷이 남은 VPC 삭제 → DependencyViolation | ✅ 동작 | DependencyViolation: The vpc 'vpc-00000000000000182' has dependencies and cannot be deleted. |

<a id="svc-vpc-gaps"></a>

### M02 · vpc-gaps

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateVpcPeeringConnection | ✅ |  |
| API | RejectVpcPeeringConnection | ⛔ 501 | HTTP 501 NotImplemented: operation RejectVpcPeeringConnection is scaffolded but not implemented in this emulator |
| API | DeleteVpcPeeringConnection | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteVpcPeeringConnection is scaffolded but not implemented in this emulator |
| API | ReplaceRoute | ⛔ 501 | HTTP 501 NotImplemented: operation ReplaceRoute is scaffolded but not implemented in this emulator |
| API | ReplaceRouteTableAssociation | ⛔ 501 | HTTP 501 NotImplemented: operation ReplaceRouteTableAssociation is scaffolded but not implemented in this emulator |
| API | CreateNatGateway(zonal) | ✅ |  |
| 동작 | NAT 게이트웨이를 지우면 그 경로가 blackhole 로 바뀜 | ⚠️ 다름 | 경로 State=['active'] |
| API | CreateNatGateway(AvailabilityMode=regional) | ⛔ 501 | HTTP 501 NotImplemented: operation CreateNatGateway with a regional availability mode is scaffolded but not implemented in this emulator |
| API | CreateEgressOnlyInternetGateway | ⛔ 501 | HTTP 501 NotImplemented: operation CreateEgressOnlyInternetGateway is scaffolded but not implemented in this emulator |
| API | DescribeEgressOnlyInternetGateways | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeEgressOnlyInternetGateways is scaffolded but not implemented in this emulator |
| API | CreateTransitGateway(기본 연결·전파 enable) | ✅ |  |
| API | CreateTransitGatewayVpcAttachment | ✅ |  |
| 동작 | DefaultRouteTableAssociation=enable 이면 새 연결이 기본 TGW 라우팅 테이블에 자동 연결 | ⚠️ 다름 | 연결 0개 |
| 동작 | DefaultRouteTablePropagation=enable 이면 새 연결이 기본 TGW 라우팅 테이블로 자동 전파 | ⚠️ 다름 | 전파 0개 |
| API | CreateTransitGatewayRoute | ⛔ 501 | HTTP 501 NotImplemented: operation CreateTransitGatewayRoute is scaffolded but not implemented in this emulator |
| API | SearchTransitGatewayRoutes | ⛔ 501 | HTTP 501 NotImplemented: operation SearchTransitGatewayRoutes is scaffolded but not implemented in this emulator |
| API | DeleteTransitGatewayVpcAttachment | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteTransitGatewayVpcAttachment is scaffolded but not implemented in this emulator |
| API | ACM ImportCertificate(Client VPN 서버 인증서) | ✅ |  |
| API | CreateClientVpnEndpoint | ⛔ 501 | HTTP 501 NotImplemented: operation CreateClientVpnEndpoint is scaffolded but not implemented in this emulator |
| 동작 | 기본 VPC 에 IGW 와 0.0.0.0/0 경로가 있음 | ⚠️ 다름 | 172.31.0.0/16 IGW 0개, 0.0.0.0/0 경로 없음 |

<a id="svc-ec2-instances"></a>

### M03 · ec2-instances

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| 동작 | 사용 가능한 AMI 확보 | ✅ 동작 | ami-0000000000000004c |
| API | CreateKeyPair | ✅ |  |
| 동작 | CreateKeyPair가 개인 키(KeyMaterial)를 반환 | ✅ 동작 | bb:c2:f6:d8:2c:62:50:5f:b0:1f:43:ba:49:5 |
| API | RunInstances(t3.micro, UserData) | ✅ |  |
| 동작 | 인스턴스 상태 pending→running | ✅ 동작 | pending → running |
| 동작 | 프라이빗 IP·서브넷·AZ가 채워짐 | ✅ 동작 | 10.20.1.4 subnet-00000000000000089 us-east-1a |
| API | DescribeInstanceAttribute(userData) | ✅ |  |
| 동작 | 사용자 데이터가 저장되어 조회됨(실행은 안 됨) | ✅ 동작 | '#!/bin/bash\necho hello > /tmp/hello\n' |
| API | DescribeInstanceStatus | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeInstanceStatus is scaffolded but not implemented in this emulator |
| API | ModifyInstanceMetadataOptions(HttpTokens=required) | ✅ |  |
| 동작 | IMDSv2 필수(HttpTokens=required) 반영 | ✅ 동작 | {'State': 'pending', 'HttpTokens': 'required', 'HttpPutResponseHopLimit': 2, 'HttpEndpoint': 'enabled', 'HttpProtocolIpv |
| API | CreateTags | ✅ |  |
| API | DescribeTags | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeTags is scaffolded but not implemented in this emulator |
| API | StopInstances | ✅ |  |
| 동작 | running→stopping→stopped | ✅ 동작 | stopping → stopped |
| API | ModifyInstanceAttribute(InstanceType=t3.small, 중지 상태) | ⛔ 501 | HTTP 501 NotImplemented: operation ModifyInstanceAttribute is scaffolded but not implemented in this emulator |
| API | StartInstances | ✅ |  |
| 동작 | stopped→running | ✅ 동작 | running |
| API | RebootInstances | ✅ |  |
| API | MonitorInstances(세부 모니터링) | ✅ |  |
| API | RunInstances(스팟: InstanceMarketOptions) | ✅ |  |
| API | DescribeSpotPriceHistory | ✅ |  |
| API | DescribeInstanceTypes(t3.micro) | ✅ |  |
| API | CreatePlacementGroup(cluster) | ✅ |  |
| API | TerminateInstances | ✅ |  |
| 동작 | →shutting-down→terminated | ✅ 동작 | terminated |

<a id="svc-ebs-ami"></a>

### M03 · ebs-ami

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| API | CreateVolume(gp3 10GiB) | ✅ |  |
| API | CreateVolume(io2 Iops=3000, MultiAttach) | ✅ |  |
| 동작 | st1 최소 크기(125GiB) 미만 → InvalidParameterValue | ✅ 동작 | InvalidParameterValue: Invalid value '1' for size. A st1 volume holds from 125 to 16384 GiB |
| 동작 | 볼륨 creating→available | ✅ 동작 | 생성 직후 creating |
| API | RunInstances(볼륨 연결용) | ✅ |  |
| API | AttachVolume | ✅ |  |
| 동작 | 볼륨 in-use(attached) | ✅ 동작 | in-use |
| API | DetachVolume | ✅ |  |
| 동작 | 다른 AZ의 볼륨 연결 → InvalidVolume.ZoneMismatch | ✅ 동작 | InvalidVolume.ZoneMismatch: The volume 'vol-0000000000000009d' is not in the same availability zone as instance 'i-00000000000000003' |
| API | ModifyVolume(gp3 → 20GiB) | ✅ |  |
| API | CreateSnapshot | ✅ |  |
| 동작 | 스냅샷 pending→completed | ✅ 동작 | 생성 직후 pending |
| API | CopySnapshot(Encrypted) | ✅ |  |
| 동작 | 암호화 사본 스냅샷 Encrypted=True | ✅ 동작 | True |
| API | CreateVolume(SnapshotId=… 스냅샷에서 복원) | ❌ | HTTP 400 InvalidSnapshot.NotFound: The snapshot 'snap-0000000000000009e' does not exist. |
| API | RegisterImage(스냅샷 기반) | ⛔ 501 | HTTP 501 NotImplemented: operation RegisterImage is scaffolded but not implemented in this emulator |
| API | CreateImage(인스턴스에서 AMI) | ⛔ 501 | HTTP 501 NotImplemented: operation CreateImage is scaffolded but not implemented in this emulator |
| API | EnableEbsEncryptionByDefault | ✅ |  |
| API | GetEbsEncryptionByDefault | ✅ |  |
| 동작 | 기본 암호화 켜짐 반영 | ✅ 동작 | True |
| 동작 | 기본 암호화 후 새 볼륨이 Encrypted=True | ✅ 동작 | True |
| API | CreateLaunchTemplate | ✅ |  |
| API | CreateLaunchTemplateVersion | ✅ |  |
| 동작 | 버전 2가 생기고 SourceVersion의 ImageId를 상속 | ✅ 동작 | [(1, 't3.micro', True), (2, 't3.small', True)] |
| API | ModifyLaunchTemplate(DefaultVersion=2) | ✅ |  |
| API | RunInstances(LaunchTemplate) | ✅ |  |
| 동작 | 시작 템플릿 최신 버전 값으로 인스턴스 생성 | ✅ 동작 | t3.small |

<a id="svc-elbv2"></a>

### M03 · elbv2

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateLoadBalancer(ALB) | ✅ |  |
| 동작 | ALB DNSName 발급 | ✅ 동작 | 127.0.0.1:35911 |
| 동작 | ALB provisioning→active | ✅ 동작 | 생성 직후 provisioning |
| API | CreateLoadBalancer(NLB) | ✅ |  |
| API | CreateTargetGroup(instance, /health) | ✅ |  |
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| API | RegisterTargets | ✅ |  |
| API | DescribeTargetHealth | ✅ |  |
| 동작 | 대상 헬스 상태(실제 헬스 체크는 없음) | ✅ 동작 | ['unused', 'unused'] — 리스너 없음 상태 |
| API | ModifyTargetGroupAttributes(stickiness) | ✅ |  |
| 동작 | 스티키 세션 속성 반영 | ✅ 동작 |  |
| API | CreateListener(HTTP:80 → TG) | ✅ |  |
| API | CreateRule(path /api/*) | ✅ |  |
| API | CreateRule(fixed-response) | ✅ |  |
| 동작 | 리스너 규칙 우선순위 조회(default 포함) | ✅ 동작 | ['10', '20', 'default'] |
| 동작 | 리스너 연결 후 대상 헬스 상태 | ✅ 동작 | ['healthy', 'healthy'] |
| 동작 | ALB 리스너가 실제로 HTTP를 처리(컨테이너 안에서 fixed-response 규칙 확인) | ✅ 동작 | DNSName=127.0.0.1:35911 → hello-from-alb HTTP200 |
| 동작 | ALB forward 규칙 → 대상 인스턴스(실체 없음)로 전달 시 응답 | ✅ 동작 | /api/x → HTTP502 |
| 동작 | 호스트(macOS)에서 ALB DNSName으로 직접 연결 | ⚠️ 다름 | ConnectionRefusedError — 리스너 포트가 컨테이너 밖으로 게시되지 않음 |

<a id="svc-autoscaling"></a>

### M03 · autoscaling

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| API | CreateAutoScalingGroup(min1 max4 desired2) | ✅ |  |
| 동작 | Min/Max/Desired 값이 그대로 저장됨 | ✅ 동작 | Min=1 Max=4 Desired=2 |
| 동작 | Desired=2 만큼 인스턴스가 실제로 시작됨 | ✅ 동작 | Instances=2 |
| 동작 | ASG 인스턴스가 EC2 DescribeInstances에도 나타남 | ✅ 동작 | 2개 |
| API | PutScalingPolicy(TargetTracking CPU 50%) | ⛔ 501 | HTTP 501 NotImplemented: operation PutScalingPolicy is scaffolded but not implemented in this emulator |
| API | PutScalingPolicy(StepScaling) | ⛔ 501 | HTTP 501 NotImplemented: operation PutScalingPolicy is scaffolded but not implemented in this emulator |
| API | PutScheduledUpdateGroupAction | ⛔ 501 | HTTP 501 NotImplemented: operation PutScheduledUpdateGroupAction is scaffolded but not implemented in this emulator |
| API | PutLifecycleHook(launching) | ⛔ 501 | HTTP 501 NotImplemented: operation PutLifecycleHook is scaffolded but not implemented in this emulator |
| API | SetDesiredCapacity(3) | ✅ |  |
| 동작 | SetDesiredCapacity 3 → 인스턴스 3개 | ✅ 동작 | Instances=3 |
| 동작 | Max 초과 Desired → ValidationError | ✅ 동작 | ValidationError: New SetDesiredCapacity value 10 is above max value 4 for the AutoScalingGroup: todayorder-probe-asg-c2f4ad52 |
| API | DescribeScalingActivities | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeScalingActivities is scaffolded but not implemented in this emulator |
| 동작 | 인스턴스를 직접 종료하면 ASG가 대체 인스턴스를 띄움(자가 치유) | ⚠️ 다름 | 20초 후에도 종료된 인스턴스가 ASG에 ['InService/Healthy'] 로 남음 |

<a id="svc-compute-gaps"></a>

### M03 · compute-gaps

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| API | DeleteKeyPair | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteKeyPair is scaffolded but not implemented in this emulator |
| API | CreateVolume(gp3 10 GiB, 20000 IOPS — AWS: 비율 초과로 거부) | ✅ |  |
| 동작 | gp3 10 GiB 에 20,000 IOPS 요청이 거부됨(IOPS:GiB 비율 검사) | ⚠️ 다름 | 받아 줌 — 비율 미검사 |
| 동작 | 인스턴스 종료 시 DeleteOnTermination 루트 볼륨이 삭제됨 | ⚠️ 다름 | 남은 볼륨 상태 ['in-use'] |
| 동작 | 등록한 running 대상이 HTTP 응답 없이도 healthy 가 됨(실제 헬스 체크 없음) | ✅ 동작 | 등록 직후 [('initial', 'Elb.RegistrationInProgress')], 1초 뒤 [('healthy', '')] |
| 동작 | 대상 인스턴스를 중지하면 unhealthy 가 됨 | ✅ 동작 | 6초 뒤 중지한 대상 ('unhealthy', 'Target.Timeout'), 나머지 ('healthy', ''), 인스턴스 상태 stopped |
| API | CreateRule(host-header api.todayorder.example → 'host') | ✅ |  |
| 동작 | ALB host-header 조건 규칙이 매칭됨(컨테이너 안 요청) | ⚠️ 다름 | 응답 본문 'default' |
| API | CreateAutoScalingGroup(--target-group-arns, desired 2) | ✅ |  |
| 동작 | ASG(--target-group-arns) 인스턴스가 대상 그룹에 자동 등록됨 | ⚠️ 다름 | ASG 인스턴스 2개, 대상 그룹 등록 0개 |
| API | DescribePolicies | ⛔ 501 | HTTP 501 NotImplemented: operation DescribePolicies is scaffolded but not implemented in this emulator |
| API | DescribeLifecycleHooks | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeLifecycleHooks is scaffolded but not implemented in this emulator |
| API | DescribeScheduledActions | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeScheduledActions is scaffolded but not implemented in this emulator |
| API | SetInstanceHealth | ⛔ 501 | HTTP 501 NotImplemented: operation SetInstanceHealth is scaffolded but not implemented in this emulator |
| API | StartInstanceRefresh | ✅ |  |
| 동작 | 인스턴스 새로 고침이 Successful 까지 진행(인스턴스 교체) | ✅ 동작 | Status=Successful, 교체 전후 겹치는 인스턴스 0개 |

<a id="svc-s3"></a>

### M04 · s3

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBucket(main) | ✅ |  |
| 동작 | us-east-1에서 내 버킷과 같은 이름으로 재생성 → 200(AWS도 us-east-1만 예외적으로 성공) | ✅ 동작 | 성공 |
| 동작 | 대문자 버킷 이름 → InvalidBucketName | ✅ 동작 | InvalidBucketName: The specified bucket is not valid. |
| API | PutObject | ✅ |  |
| API | GetObject | ✅ |  |
| 동작 | GetObject 본문·메타데이터 왕복 | ✅ 동작 | ETag="5d41402abc4b2a76b9719d911017c592" |
| API | HeadObject | ✅ |  |
| API | ListObjectsV2(Prefix, Delimiter) | ✅ |  |
| 동작 | ListObjectsV2 prefix 조회 | ✅ 동작 | KeyCount=1 |
| API | CopyObject | ✅ |  |
| API | DeleteObject | ✅ |  |
| 동작 | 없는 키 → NoSuchKey | ✅ 동작 | NoSuchKey: The specified key does not exist. |
| API | PutObjectTagging | ✅ |  |
| API | PutBucketTagging | ✅ |  |
| API | PutBucketVersioning(Enabled) | ✅ |  |
| 동작 | 버전 관리 켠 뒤 PutObject마다 VersionId 발급 | ✅ 동작 | a0520cb32a93673dfd1f772a047c4db8 / 6fc71ad72bbb8b559afaf72ff6b6b8ff |
| API | DeleteObject(버전 관리 버킷) | ✅ |  |
| 동작 | 삭제하면 삭제 마커(DeleteMarker=true)가 생김 | ✅ 동작 | VersionId=8bea7b854e239c41ebaff920fd36c749 |
| 동작 | 삭제 마커가 최신이면 GetObject → NoSuchKey | ✅ 동작 | NoSuchKey: The specified key does not exist. |
| API | ListObjectVersions | ✅ |  |
| 동작 | ListObjectVersions: 버전 2개 + 삭제 마커 1개 | ✅ 동작 | Versions=2 DeleteMarkers=1 |
| API | GetObject(VersionId=첫 버전) | ✅ |  |
| 동작 | 이전 버전 내용 복구 가능 | ✅ 동작 |  |
| 동작 | 삭제 마커를 지우면 객체가 되살아남 | ✅ 동작 |  |
| API | PutBucketLifecycleConfiguration | ✅ |  |
| API | GetBucketLifecycleConfiguration | ✅ |  |
| 동작 | 수명 주기 규칙 왕복(전환은 시간이 지나도 실제로 일어나지 않음 — 확인 불가) | ✅ 동작 |  |
| 동작 | STANDARD_IA 10일 전환 규칙 수락 (2026-07 이후 AWS와 같음) | ✅ 동작 |  |
| 동작 | ONEZONE_IA 7일 전환 규칙 수락 (2026-07 이후 AWS와 같음) | ✅ 동작 |  |
| 동작 | STANDARD_IA 0일 전환 규칙 수락 (2026-07 이후 AWS와 같음) | ✅ 동작 |  |
| 동작 | 최소 보관 기간(Glacier IR 90일)보다 빠른 연쇄 전환 → InvalidArgument | ✅ 동작 | InvalidArgument: 'Days' in the 'Transition' action for StorageClass 'DEEP_ARCHIVE' for filter '(prefix=lc/)' must be 90 days more than 'filter '(prefix=lc/)'' 'Days' in the 'Tra |
| 동작 | 거꾸로 된 전환(GLACIER → STANDARD_IA) → InvalidArgument | ✅ 동작 | InvalidArgument: 'Days' in the 'Transition' action for StorageClass 'GLACIER' for filter '(prefix=lc/)' must be greater than 'Days' in the 'Transition' action for StorageClass ' |
| 동작 | 같은 규칙 ID 두 개 → InvalidArgument | ✅ 동작 | InvalidArgument: Rule 2: ID "dup" identifies an earlier rule as well; a rule identifier is unique within a lifecycle configuration |
| 동작 | 만료 0일 → InvalidArgument | ✅ 동작 | InvalidArgument: 'Days' for Expiration action must be a positive integer |
| 동작 | 미리 서명된 GET URL을 curl로 다운로드 | ✅ 동작 | HTTP 200 |
| 동작 | 서명을 바꾼 URL은 거부 | ✅ 동작 | HTTP 403 <Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calcu |
| 동작 | 만료된 미리 서명 URL은 거부 | ✅ 동작 | HTTP 403 <Error><Code>AccessDenied</Code><Message>Request has expired</Message><X-Amz-Exp |
| 동작 | 미리 서명된 PUT URL로 curl 업로드 | ✅ 동작 | HTTP 200 |
| 동작 | 서명 없는 GET(퍼블릭 아님)은 거부 | ✅ 동작 | HTTP 403 |
| API | CreateMultipartUpload | ✅ |  |
| API | UploadPart(1) | ✅ |  |
| API | UploadPart(2) | ✅ |  |
| API | ListParts | ✅ |  |
| API | CompleteMultipartUpload | ✅ |  |
| 동작 | 멀티파트 결과 크기·ETag(-2 접미사) | ✅ 동작 | 5243904 "dd1fd2c473c304eca8d2822fcc4d7d33-2" |
| 동작 | 마지막이 아닌 파트가 5MiB 미만 → EntityTooSmall | ✅ 동작 | EntityTooSmall: Your proposed upload is smaller than the minimum allowed size |
| API | AbortMultipartUpload | ✅ |  |
| API | upload_file(boto3 TransferManager, 자동 멀티파트) | ✅ |  |
| API | PutBucketPolicy(Deny GetObject *) | ✅ |  |
| API | GetBucketPolicy | ✅ |  |
| 동작 | 버킷 정책 왕복 | ✅ 동작 |  |
| 동작 | 버킷 정책의 명시적 Deny가 GetObject를 막음 | ✅ 동작 | AccessDenied |
| 동작 | 잘못된 정책 JSON → MalformedPolicy | ✅ 동작 | MalformedPolicy: Policy must be a JSON policy document with a non-empty Statement list, each statement carrying an Effect of Allow or Deny and an Action |
| API | PutPublicAccessBlock(버킷 수준) | ✅ |  |
| API | GetPublicAccessBlock | ✅ |  |
| 동작 | 퍼블릭 액세스 차단 상태에서 퍼블릭 정책 → AccessDenied | ✅ 동작 | AccessDenied: User: arn:aws:iam::000000000000:user/emulator is not authorized to perform: s3:PutBucketPolicy on resource: "arn:aws:s3:::todayorder-probe-main-c3c1581d" becaus |
| API | GetBucketOwnershipControls | ✅ |  |
| 동작 | 기본 객체 소유권(BucketOwnerEnforced)에서 ACL 설정 → AccessControlListNotSupported | ✅ 동작 | AccessControlListNotSupported: The bucket does not allow ACLs |
| API | PutBucketEncryption(SSE-S3) | ✅ |  |
| 동작 | 기본 암호화 SSE-S3 → HeadObject ServerSideEncryption=AES256 | ✅ 동작 | AES256 |
| API | PutObject(SSE-KMS) | ✅ |  |
| 동작 | SSE-KMS 객체 HeadObject에 aws:kms·키 ID | ✅ 동작 | aws:kms b15b1758-02a1-462c-8982-65cf8601de82 |
| 동작 | KMS 키를 비활성화하면 SSE-KMS 객체 읽기 실패 | ⚠️ 다름 | 읽힘 — S3가 KMS 키 상태를 확인하지 않음 |
| API | PutBucketEncryption(SSE-KMS, BucketKey) | ✅ |  |
| API | PutObject(SSE-C) | ✅ |  |
| 동작 | SSE-C 객체를 키 없이 읽기 → InvalidRequest | ✅ 동작 | InvalidRequest: The object was stored using a form of Server Side Encryption. The correct parameters must be provided to retrieve the object. |
| API | CreateBucket(replica) | ✅ |  |
| API | PutBucketReplication | ✅ |  |
| 동작 | 복제 규칙 → 새 객체가 대상 버킷에 실제로 복제됨 | ✅ 동작 | 원본 ReplicationStatus=PENDING |
| API | CreateBucket(nover) | ✅ |  |
| 동작 | 버전 관리 없는 버킷에 복제 → InvalidRequest | ✅ 동작 | InvalidRequest: Versioning must be 'Enabled' on the bucket to apply a replication configuration |
| API | CreateBucket(notify) | ✅ |  |
| API | PutBucketNotificationConfiguration(SQS) | ✅ |  |
| 동작 | S3 ObjectCreated 이벤트가 SQS 큐에 실제로 도착 | ✅ 동작 | 수신 키 ['uploads/a.jpg']; 기타 ['s3:TestEvent'] |
| 동작 | prefix 필터(uploads/)만 전달 | ✅ 동작 | ['uploads/a.jpg'] |
| API | PutBucketWebsite | ✅ |  |
| API | GetBucketWebsite | ✅ |  |
| API | CreateBucket(ObjectLockEnabledForBucket) | ✅ |  |
| API | PutObjectLockConfiguration(GOVERNANCE 1일) | ✅ |  |
| 동작 | 기본 보존 기간이 객체에 적용됨 | ✅ 동작 | GOVERNANCE 2026-11-14 03:21:09+00:00 |
| 동작 | 보존 중인 객체 버전 삭제 → AccessDenied | ✅ 동작 | AccessDenied: Access Denied because object protected by object lock. |
| API | PutObject(StorageClass=GLACIER) | ✅ |  |
| 동작 | StorageClass=GLACIER 저장 | ✅ 동작 | GLACIER |
| 동작 | 복원 전 GLACIER 객체 읽기 → InvalidObjectState | ✅ 동작 | InvalidObjectState: The operation is not valid for the object's storage class |
| API | RestoreObject(Days=1, Standard) | ✅ |  |
| 동작 | 복원 요청 후 HeadObject Restore 헤더 | ✅ 동작 | ongoing-request="true" |
| 동작 | GLACIER Standard 복원이 60초 안에 끝남(실제 AWS 는 3~5시간) | ✅ 동작 | 0.5초 뒤 ongoing-request=false=True, 이후 GetObject=OK |
| API | PutObject(INTELLIGENT_TIERING) | ✅ |  |
| API | PutBucketAccelerateConfiguration | ✅ |  |
| API | PutBucketRequestPayment(Requester) | ✅ |  |

<a id="svc-s3-gaps"></a>

### M04 · s3-gaps

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | PutBucketVersioning(MFADelete=Enabled, 임의 MFA 코드) | ✅ |  |
| 동작 | 존재하지 않는 MFA 장치·임의 코드로 MFA Delete 를 켤 수 없음 | ⚠️ 다름 | 받아 줌 |
| 동작 | MFA Delete 켠 버킷에서 MFA 없이 버전 영구 삭제 → 거부 | ⚠️ 다름 | 기대 AccessDenied, 실제로는 성공했다 |
| 동작 | 객체 잠금 버킷의 버전 관리 일시 중지 → 거부 | ⚠️ 다름 | 기대 InvalidBucketState, 실제로는 성공했다 |
| 동작 | 버전 관리 없는 대상 버킷으로 복제 구성 → 거부 | ⚠️ 다름 | 기대 InvalidRequest, 실제로는 성공했다 |
| 동작 | 존재하지 않는 대상 버킷으로 복제 구성 → 거부 | ⚠️ 다름 | 기대 InvalidRequest, 실제로는 성공했다 |
| 동작 | 기본 암호화 설정이 SSE-C 를 차단하면 SSE-C 업로드 거부 | ⚠️ 다름 | BlockedEncryptionTypes 에 SSE-C 있음, 업로드 성공 |
| 동작 | 퍼블릭 정책(BPA 해제) 버킷의 객체를 익명 GET 하면 200 | ⚠️ 다름 | IsPublic=True, 익명 GET HTTP 403 |
| API | CreateLocationS3(원본) | ✅ |  |
| API | CreateLocationS3(대상) | ✅ |  |
| API | CreateTask | ✅ |  |
| 동작 | DataSync 작업 상태(생성 직후 → 대기 후) | ✅ 동작 | CREATING → AVAILABLE (AWS도 CREATING 을 거친다) |
| API | StartTaskExecution | ✅ |  |
| 동작 | DataSync S3→S3 작업이 파일을 실제로 복사 | ⚠️ 다름 | 처음 상태 LAUNCHING → SUCCESS, FilesTransferred=0, 대상 객체 0개 |
| API | CreateLocationNfs | ⛔ 501 | HTTP 501 NotImplemented: operation CreateLocationNfs is scaffolded but not implemented in this emulator |
| API | ActivateGateway(임의 활성화 키, FILE_S3) | ✅ |  |
| API | CreateSMBFileShare | ⛔ 501 | HTTP 501 NotImplemented: operation CreateSMBFileShare is scaffolded but not implemented in this emulator |
| API | ListTapes | ⛔ 501 | HTTP 501 NotImplemented: operation ListTapes is scaffolded but not implemented in this emulator |

<a id="svc-efs"></a>

### M04 · efs

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFileSystem(generalPurpose, Encrypted) | ✅ |  |
| 동작 | 파일 시스템 creating→available | ✅ 동작 | 생성 직후 creating |
| 동작 | 같은 CreationToken 재사용 → FileSystemAlreadyExists(멱등성) | ✅ 동작 | FileSystemAlreadyExists: File system 'fs-e220a8397b1dcdaf1' already exists with creation token 'todayorder-probe-efs-cc9af120' |
| API | CreateMountTarget | ✅ |  |
| API | CreateMountTarget | ✅ |  |
| 동작 | AZ별 마운트 타깃 IP가 해당 서브넷(10.30.x.x) 안에 있음 | ⚠️ 다름 | [('us-east-1a', '10.0.0.4', 'creating'), ('us-east-1b', '10.0.1.4', 'creating')] |
| 동작 | 같은 AZ에 마운트 타깃 두 번 → MountTargetConflict | ✅ 동작 | MountTargetConflict: File system fs-e220a8397b1dcdaf1 already has mount target fsmt-6e789e6aa1b965f4b in Availability Zone us-east-1a |
| API | CreateAccessPoint | ✅ |  |
| API | PutLifecycleConfiguration(AFTER_30_DAYS → IA) | ✅ |  |
| API | PutBackupPolicy | ✅ |  |
| API | PutFileSystemPolicy(TLS 강제) | ✅ |  |
| 동작 | 마운트 타깃이 남은 파일 시스템 삭제 → FileSystemInUse | ✅ 동작 | FileSystemInUse: File system 'fs-e220a8397b1dcdaf1' still has 2 mount target(s); delete them first |

<a id="svc-rds"></a>

### M05 · rds

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | DescribeDBEngineVersions(postgres) | ✅ |  |
| API | DescribeOrderableDBInstanceOptions(mysql) | ✅ |  |
| API | CreateDBSubnetGroup | ✅ |  |
| API | CreateDBParameterGroup(postgres16) | ✅ |  |
| API | ModifyDBParameterGroup(log_min_duration_statement) | ✅ |  |
| API | CreateDBInstance(postgres, MultiAZ) | ✅ |  |
| 동작 | DB 인스턴스 creating→available | ✅ 동작 | creating → available |
| 동작 | Endpoint 주소·포트 반환 | ✅ 동작 | 127.0.0.1:38565 |
| 동작 | MultiAZ·SecondaryAvailabilityZone 표시 | ✅ 동작 | MultiAZ=True AZ=us-east-1a Secondary=None |
| 동작 | Endpoint 포트에 실제 DB가 떠 있음(컨테이너 안 TCP) | ✅ 동작 | 컨테이너 안: OPEN |
| 동작 | Endpoint가 PostgreSQL 프로토콜로 응답(SSLRequest → 'S'/'N') | ✅ 동작 | 응답 'S' |
| 동작 | 호스트(macOS)에서 Endpoint 포트로 TCP 연결 | ⚠️ 다름 | 연결 불가(포트가 컨테이너 밖에 게시되지 않음) |
| API | CreateDBInstanceReadReplica | ✅ |  |
| 동작 | 읽기 복제본이 원본을 가리킴 | ✅ 동작 | Source=todayorder-probe-db-8fa3bbbc; 원본 Replicas=['todayorder-probe-db-rr-8fa3bbbc'] |
| API | CreateDBSnapshot | ✅ |  |
| 동작 | 스냅샷 creating→available | ✅ 동작 | 생성 직후 creating |
| API | RestoreDBInstanceFromDBSnapshot | ✅ |  |
| API | DescribeDBSnapshots(automated) | ✅ |  |
| API | ModifyDBInstance(DBInstanceClass, ApplyImmediately) | ✅ |  |
| 동작 | Modify 후 클래스 변경 반영 | ✅ 동작 | db.t3.small / available |
| API | RebootDBInstance(ForceFailover) | ✅ |  |
| 동작 | 강제 장애 조치 후 AZ가 바뀜 | ⚠️ 다름 | us-east-1a → us-east-1a |
| 동작 | 같은 식별자 → DBInstanceAlreadyExists | ✅ 동작 | DBInstanceAlreadyExists: DB instance already exists |
| API | CreateDBInstance(mysql) | ✅ |  |
| API | CreateDBCluster(aurora-postgresql) | ✅ |  |
| 동작 | Aurora 클러스터 엔드포인트(쓰기)·리더 엔드포인트 | ✅ 동작 | 127.0.0.1 / todayorder-probe-aurora-8fa3bbbc.cluster-ro-00000000000v.us-east-1.rds.amazonaws.com |
| API | CreateDBInstance(Aurora 클러스터 인스턴스) | ✅ |  |
| 동작 | 클러스터 멤버(쓰기 인스턴스)로 조회됨 | ✅ 동작 | [{'DBInstanceIdentifier': 'todayorder-probe-aurora-1-8fa3bbbc', 'IsClusterWriter': True, 'DBClusterParameterGroupStatus' |
| API | CreateDBProxy | ✅ |  |

<a id="svc-dynamodb"></a>

### M05 · dynamodb

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | 테이블 이름 2글자 → ValidationException | ✅ 동작 | HTTP 400 ValidationException: 1 validation error detected: Value 'ab' at 'tableName' failed to satisfy constraint: Member must have length greater than or equal to 3 |
| API | CreateTable(PK/SK, 온디맨드, Streams) | ✅ |  |
| 동작 | 테이블 CREATING→ACTIVE | ✅ 동작 | 생성 직후 CREATING |
| API | DescribeTable | ✅ |  |
| API | PutItem | ✅ |  |
| API | GetItem(ConsistentRead) | ✅ |  |
| 동작 | GetItem 왕복 | ✅ 동작 |  |
| API | Query(pk=USER#1, begins_with sk) | ✅ |  |
| API | Scan(전체) | ✅ |  |
| 동작 | Query는 파티션만, Scan은 전체를 읽음(Count/ScannedCount) | ✅ 동작 | Query Count=5 ScannedCount=5 CU=0.5; Scan ScannedCount=7 CU=0.5 |
| API | Scan(FilterExpression) | ✅ |  |
| 동작 | FilterExpression은 읽은 뒤 거른다(ScannedCount > Count) | ✅ 동작 | Count=2 ScannedCount=7 |
| 동작 | Limit=2 페이지네이션(LastEvaluatedKey) | ✅ 동작 | [2, 2, 1] |
| API | UpdateItem(조건부 재고 차감 2) | ✅ |  |
| 동작 | 재고 3 → 1 | ✅ 동작 | 1 |
| 동작 | 재고 1에서 2 차감 → ConditionalCheckFailedException | ✅ 동작 | ConditionalCheckFailedException: The conditional request failed |
| 동작 | 이미 있는 키에 attribute_not_exists → ConditionalCheckFailedException | ✅ 동작 | ConditionalCheckFailedException: The conditional request failed |
| API | UpdateTable(GSI 추가: status-index) | ✅ |  |
| 동작 | GSI CREATING→ACTIVE(백필) | ✅ 동작 | ['ACTIVE'] |
| API | Query(GSI status=PAID) | ✅ |  |
| 동작 | GSI 쿼리가 기존 항목까지 반환(백필) | ✅ 동작 | Count=2 |
| 동작 | GSI 강력 일관 읽기 → ValidationException | ✅ 동작 | ValidationException: Consistent reads are not supported on global secondary indexes |
| API | UpdateTimeToLive | ✅ |  |
| API | DescribeTimeToLive | ✅ |  |
| 동작 | TTL 상태 ENABLED(또는 ENABLING) | ✅ 동작 | {'TimeToLiveStatus': 'ENABLING', 'AttributeName': 'expires_at'} |
| 동작 | 만료 시각이 지난 항목이 5초 안에 삭제됨(AWS는 보통 수일 내, 즉시 아님) | ✅ 동작 | 삭제됨 |
| 동작 | Streams 켜면 LatestStreamArn 발급 | ✅ 동작 | -df92f0df/stream/2026-11-13T03:17:38.708 |
| API | DescribeStream | ✅ |  |
| API | GetShardIterator(TRIM_HORIZON) | ✅ |  |
| API | GetRecords | ✅ |  |
| 동작 | 스트림에 INSERT/MODIFY 레코드가 실제로 기록됨 | ✅ 동작 | 9건 ['INSERT', 'MODIFY'] |
| 동작 | NEW_AND_OLD_IMAGES: MODIFY 레코드에 OldImage/NewImage | ✅ 동작 |  |
| API | TransactWriteItems(주문 생성 + 재고 차감) | ✅ |  |
| 동작 | 조건 하나가 실패하면 트랜잭션 전체 취소 → TransactionCanceledException | ✅ 동작 | TransactionCanceledException: Transaction cancelled, please refer cancellation reasons for specific reasons [None, ConditionalCheckFailed] |
| 동작 | 취소된 트랜잭션의 다른 쓰기(주문 901)도 반영되지 않음(원자성) | ✅ 동작 |  |
| API | TransactGetItems | ✅ |  |
| API | BatchWriteItem(25개) | ✅ |  |
| 동작 | BatchWriteItem 26개(한도 25) → ValidationException | ✅ 동작 | ValidationException: Too many items requested for the BatchWriteItem call |
| API | BatchGetItem | ✅ |  |
| API | ExecuteStatement(PartiQL SELECT) | ✅ |  |
| API | CreateTable(PROVISIONED 5/5) | ✅ |  |
| API | UpdateTable(PROVISIONED → PAY_PER_REQUEST) | ✅ |  |
| 동작 | 용량 모드 전환 반영 | ✅ 동작 | PAY_PER_REQUEST |
| API | UpdateContinuousBackups(PITR) | ✅ |  |
| API | DescribeContinuousBackups | ✅ |  |
| 동작 | PITR ENABLED | ✅ 동작 |  |
| API | CreateBackup | ✅ |  |
| 동작 | 백업 CREATING→AVAILABLE | ✅ 동작 | 생성 직후 CREATING |
| API | RestoreTableFromBackup | ✅ |  |
| 동작 | 백업에서 복원한 테이블에 데이터가 있음 | ✅ 동작 | Count=33 |
| API | ExportTableToPointInTime | ✅ |  |
| API | UpdateTable(글로벌 테이블 복제본 us-west-2) | ✅ |  |

<a id="svc-elasticache"></a>

### M05 · elasticache

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateCacheSubnetGroup | ✅ |  |
| API | CreateReplicationGroup(valkey, 복제본 1, Multi-AZ) | ✅ |  |
| 동작 | 복제 그룹 creating→available | ✅ 동작 | creating → available |
| 동작 | 기본(쓰기)·리더 엔드포인트 반환 | ✅ 동작 | Primary=master.to-rg-fe58bc53.000001.us-east-1.cache.amazonaws.com:6379 Reader=replica.to-rg-fe58bc53.000001.us-east-1.cache.amazonaws.com members=2 |
| 동작 | 엔드포인트 포트에 실제 캐시 서버가 떠 있음(컨테이너 안 TCP) | ⚠️ 다름 | 컨테이너 안: CLOSED |
| API | TestFailover | ✅ |  |
| API | CreateCacheCluster(memcached 2노드) | ✅ |  |
| 동작 | Memcached 클러스터 available + 구성 엔드포인트 | ✅ 동작 | available {'Address': 'to-mc-fe58bc53.000004.cfg.us-east-1.cache.amazonaws.com', 'Port': 11211} |
| API | CreateServerlessCache(valkey) | ✅ |  |

<a id="svc-db-gaps"></a>

### M05 · db-gaps

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | RestoreDBInstanceToPointInTime | ⛔ 501 | HTTP 501 NotImplemented: operation RestoreDBInstanceToPointInTime is scaffolded but not implemented in this emulator |
| API | PromoteReadReplica | ⛔ 501 | HTTP 501 NotImplemented: operation PromoteReadReplica is scaffolded but not implemented in this emulator |
| API | CreateDBClusterEndpoint | ⛔ 501 | HTTP 501 NotImplemented: operation CreateDBClusterEndpoint is scaffolded but not implemented in this emulator |
| API | DescribeDBInstanceAutomatedBackups | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeDBInstanceAutomatedBackups is scaffolded but not implemented in this emulator |
| API | DeleteReplicationGroup | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteReplicationGroup is scaffolded but not implemented in this emulator |
| 동작 | DAX CreateSubnetGroup(유효한 서브넷) 이 성공 | ⚠️ 다름 | InvalidParameterValueException: Some input subnets in :[subnet-00000000000000163, subnet-00000000000000165] are invalid. |
| API | UpdateContinuousBackups(PITR on) | ✅ |  |
| 동작 | PITR LatestRestorableDateTime 이 시간이 지나면 앞으로 감 | ⚠️ 다름 | PITR 켠 직후 2026-11-13 12:18:02.330000+09:00 → 6초 뒤 2026-11-13 12:18:02.330000+09:00 |
| 동작 | PITR UseLatestRestorableTime 복원 → 최신 데이터(v2) | ✅ 동작 | 복원된 값 v2 |
| 동작 | PITR RestoreDateTime(v1과 v2 사이) 복원 → 그 시점 데이터(v1) | ⚠️ 다름 | 복원 결과 오류 InvalidRestoreTimeException: An invalid restore time was specified. RestoreDateTime must be between EarliestR |

<a id="svc-sqs"></a>

### M06 · sqs

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateQueue(std) | ✅ |  |
| API | GetQueueAttributes(All) | ✅ |  |
| 동작 | 기본 속성 값 기록 | ✅ 동작 | MaximumMessageSize=1048576 VisibilityTimeout=30 MessageRetentionPeriod=345600 |
| API | ListQueues | ✅ |  |
| API | GetQueueUrl | ✅ |  |
| API | SendMessage(+MessageAttributes) | ✅ |  |
| API | ReceiveMessage | ✅ |  |
| 동작 | 본문·메시지 속성이 그대로 전달 | ✅ 동작 | order-1 |
| 동작 | 가시성 타임아웃 중에는 다른 소비자에게 안 보임 | ✅ 동작 | 즉시 재수신 0건 |
| 동작 | 가시성 타임아웃(2초) 후 재전달, ApproximateReceiveCount=2 | ✅ 동작 | 재수신 1건, count=2 |
| API | ChangeMessageVisibility(0) | ✅ |  |
| 동작 | ChangeMessageVisibility(0) 직후 다시 보임 | ✅ 동작 | 1건 |
| API | DeleteMessage | ✅ |  |
| 동작 | DeleteMessage 후 다시 오지 않음 | ✅ 동작 | 0건 |
| 동작 | 롱 폴링: 빈 큐에서 WaitTimeSeconds=2 만큼 대기 | ✅ 동작 | 2.0s 대기 |
| API | SendMessage(DelaySeconds=3) | ✅ |  |
| 동작 | DelaySeconds=3: 처음엔 안 보이고 나중에 도착 | ✅ 동작 | 즉시 0건, 이후 1건 |
| API | SendMessageBatch | ✅ |  |
| API | PurgeQueue | ✅ |  |
| 동작 | PurgeQueue 후 큐가 빔 | ✅ 동작 | 0건 남음 |
| 동작 | 1 MiB 초과 메시지 거부 | ✅ 동작 | InvalidParameterValue: One or more parameters are invalid. Reason: Message must be shorter than 1048576 bytes. |
| API | CreateQueue(dlq) | ✅ |  |
| API | CreateQueue(src) | ✅ |  |
| API | SetQueueAttributes(RedrivePolicy maxReceiveCount=2) | ✅ |  |
| 동작 | maxReceiveCount=2 초과 후 메시지가 DLQ로 이동 | ✅ 동작 | 원본 큐에서 2번 수신, DLQ 1건 |
| API | ListDeadLetterSourceQueues | ✅ |  |
| API | StartMessageMoveTask | ✅ |  |
| 동작 | StartMessageMoveTask로 DLQ → 원본 큐 재처리 | ✅ 동작 | 원본 큐 수신 1건 |
| API | ListMessageMoveTasks | ✅ |  |
| API | CreateQueue(orders.fifo) | ✅ |  |
| 동작 | FIFO: 그룹 내 순서 유지 | ✅ 동작 | 수신 순서 ['m0', 'm1', 'm2'] |
| 동작 | FIFO: 같은 MessageDeduplicationId 재전송은 버려짐 | ✅ 동작 | 수신 ['m0', 'm1', 'm2'] |
| 동작 | FIFO 큐에 MessageGroupId 없이 보내면 거부 | ✅ 동작 | MissingParameter: The request must contain the parameter MessageGroupId. |
| API | CreateQueue(cbd.fifo) | ✅ |  |
| 동작 | FIFO ContentBasedDeduplication: 같은 본문 두 번 → 1건 | ✅ 동작 | 1건 수신 |

<a id="svc-sns"></a>

### M06 · sns

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateTopic | ✅ |  |
| API | GetTopicAttributes | ✅ |  |
| API | ListTopics | ✅ |  |
| API | CreateQueue(fan-envelope) | ✅ |  |
| API | Subscribe(sqs:fan-envelope) | ✅ |  |
| API | CreateQueue(fan-raw) | ✅ |  |
| API | Subscribe(sqs:fan-raw) | ✅ |  |
| API | CreateQueue(fan-filter) | ✅ |  |
| API | Subscribe(sqs:fan-filter) | ✅ |  |
| API | CreateQueue(fan-bodyfilter) | ✅ |  |
| API | Subscribe(sqs:fan-bodyfilter) | ✅ |  |
| API | CreateQueue(fan-nopolicy) | ✅ |  |
| API | Subscribe(sqs:fan-nopolicy) | ✅ |  |
| API | Publish(eventType=order_created) | ✅ |  |
| API | Publish(eventType=order_paid) | ✅ |  |
| 동작 | SNS → SQS 팬아웃: 메시지가 구독 큐에 실제로 도착(SNS 봉투 JSON) | ✅ 동작 | 2건, 봉투 키=['Message', 'MessageAttributes', 'MessageId', 'Timestamp', 'TopicArn', 'Type'] |
| 동작 | RawMessageDelivery=true: 원문 그대로 도착 | ✅ 동작 | ['{"id": 1, "amount": 50}', '{"id": 2, "amount": 150}'] |
| 동작 | FilterPolicy(MessageAttributes): order_paid 만 도착 | ✅ 동작 | 1건 ['{"id": 2, "amount": 150}'] |
| 동작 | FilterPolicyScope=MessageBody, amount>=100 만 도착 | ✅ 동작 | 1건 ['{"id": 2, "amount": 150}'] |
| 동작 | 큐 정책(sqs:SendMessage 허용) 없는 구독 큐에는 전달되지 않음 | ✅ 동작 | 0건 도착 |
| API | PublishBatch | ✅ |  |
| 동작 | PublishBatch 2건이 구독 큐에 도착 | ✅ 동작 | 2건 |
| API | Subscribe(email) | ✅ |  |
| 동작 | email 구독은 확인 대기 상태 | ✅ 동작 | b80:81c915e6-9128-486a-a7fc-e1b965f8a7ed |
| API | Subscribe(https) | ✅ |  |
| API | ListSubscriptionsByTopic | ✅ |  |
| 동작 | 구독 목록 조회 | ✅ 동작 | 7개 |
| API | CreateTopic(FIFO) | ✅ |  |
| API | CreateQueue(fanf.fifo) | ✅ |  |
| API | Subscribe(FIFO 큐, raw) | ✅ |  |
| 동작 | FIFO 토픽 → FIFO 큐: 순서 유지 + 중복 제거 | ✅ 동작 | ['f0', 'f1', 'f2'] |

<a id="svc-eventbridge"></a>

### M06 · eventbridge

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateEventBus | ✅ |  |
| API | PutRule(이벤트 패턴) | ✅ |  |
| API | CreateQueue(ebtarget) | ✅ |  |
| API | PutTargets(SQS) | ✅ |  |
| API | TestEventPattern | ✅ |  |
| API | PutEvents | ✅ |  |
| 동작 | PutEvents FailedEntryCount=0 | ✅ 동작 | 0 |
| 동작 | 규칙 패턴과 일치하는 이벤트만 SQS 대상에 전달 | ✅ 동작 | 수신 ['match'] |
| API | PutRule(schedule rate(1 minute)) | ✅ |  |
| API | ListRules | ✅ |  |
| API | CreateArchive | ✅ |  |
| API | Scheduler CreateSchedule | ✅ |  |
| API | Scheduler GetSchedule | ✅ |  |
| API | CreateQueue(pipesrc) | ✅ |  |
| API | CreateQueue(pipedst) | ✅ |  |
| API | Pipes CreatePipe(신뢰 정책이 틀린 역할) | ✅ |  |
| 동작 | Pipes: 역할 신뢰 정책에 pipes.amazonaws.com 이 없으면 CREATE_FAILED | ✅ 동작 | CREATE_FAILED: Pipes cannot assume the execution role arn:aws:iam::000000000000:role/todayorder-probe-pipebad-6a9108a4: its trust polic |
| API | Pipes CreatePipe(SQS→SQS) | ✅ |  |
| 동작 | Pipes: 원본 큐 메시지가 대상 큐로 전달 | ✅ 동작 | 1건 |

<a id="svc-stepfunctions"></a>

### M06 · stepfunctions

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateStateMachine(STANDARD, Pass/Wait/Choice/Succeed/Fail) | ✅ |  |
| API | DescribeStateMachine | ✅ |  |
| API | StartExecution | ✅ |  |
| 동작 | 실행이 SUCCEEDED, 출력에 Pass 결과 반영 | ✅ 동작 | status=SUCCEEDED output={"id":"o-1","order":{"amount":150},"size":"big"} |
| API | GetExecutionHistory | ✅ |  |
| 동작 | 실행 이력에 상태 전이 이벤트가 기록 | ✅ 동작 | 12개 이벤트: ['ExecutionStarted', 'PassStateEntered', 'PassStateExited', 'WaitStateEntered']… |
| API | CreateStateMachine(Fail) | ✅ |  |
| 동작 | Fail 상태 → 실행 FAILED, error 전달 | ✅ 동작 | status=FAILED error=PaymentFailed |
| API | CreateQueue(sfntarget) | ✅ |  |
| API | CreateStateMachine(Task: sqs:sendMessage, 권한 없는 역할) | ✅ |  |
| 동작 | 실행 역할에 sqs:SendMessage 가 없으면 Task가 AccessDenied로 FAILED (IAM 평가됨) | ✅ 동작 | status=FAILED error=SQS.AmazonSQSException cause=User: arn:aws:iam::000000000000:role/todayorder-probe-sfnrole-a84a7730 is not authorized t |
| API | CreateStateMachine(Task: sqs:sendMessage, sqs:SendMessage 허용 역할) | ✅ |  |
| 동작 | Task(sqs:sendMessage) 서비스 통합이 실제로 메시지를 보냄 | ✅ 동작 | status=SUCCEEDED 수신 1건 |
| API | CreateStateMachine(EXPRESS) | ✅ |  |
| API | StartSyncExecution | ✅ |  |
| 동작 | EXPRESS StartSyncExecution이 결과를 동기 반환 | ✅ 동작 | status=SUCCEEDED output={"ok":true} |
| API | ListStateMachines | ✅ |  |

<a id="svc-kinesis"></a>

### M06 · kinesis

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateStream(2 shards) | ✅ |  |
| 동작 | 스트림 상태 CREATING → ACTIVE | ✅ 동작 | 처음 상태=CREATING |
| API | DescribeStreamSummary | ✅ |  |
| API | ListShards | ✅ |  |
| API | PutRecord #0 | ✅ |  |
| API | PutRecord #1 | ✅ |  |
| API | PutRecord #2 | ✅ |  |
| 동작 | 같은 파티션 키 → 같은 샤드, 시퀀스 번호 증가 | ✅ 동작 | shard=shardId-000000000001 |
| API | PutRecords(10) | ✅ |  |
| 동작 | PutRecords FailedRecordCount=0 | ✅ 동작 | 0 |
| API | GetShardIterator(TRIM_HORIZON) | ✅ |  |
| API | GetRecords | ✅ |  |
| 동작 | GetRecords가 넣은 순서대로 데이터를 반환 | ✅ 동작 | 7건 ['order-0', 'order-1', 'order-2'] |
| 동작 | 모든 샤드 합계 = 13건 | ✅ 동작 | 13건 |
| API | UpdateShardCount(4) | ✅ |  |
| 동작 | UpdateShardCount 후 열린 샤드 4개 | ✅ 동작 | OpenShardCount=4 |
| API | IncreaseStreamRetentionPeriod(48h) | ✅ |  |
| API | CreateStream(ON_DEMAND) | ✅ |  |

<a id="svc-integration-better"></a>

### M06 · integration-better

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFunction(sfnfail) | ✅ |  |
| 동작 | Step Functions Retry(MaxAttempts 2) → Task 3번 실패 후 Catch(States.ALL)로 SUCCEEDED | ✅ 동작 | 실패 이벤트 3건, 실행 SUCCEEDED |
| 동작 | Cognito 토큰 iss 가 https://cognito-idp.<리전>.amazonaws.com/<풀 ID> | ⚠️ 다름 | https://127.0.0.1:9297/us-east-1_4e32655dd |
| API | CreateFunction(jwtfn) | ✅ |  |
| 동작 | HTTP API JWT 권한 부여자: 토큰 없으면 401, 유효한 IdToken 이면 200 | ✅ 동작 | 토큰 없음 401, 토큰 200 (Issuer 는 토큰의 iss 를 그대로 사용) |
| API | CreateSchedule(at() 10분 뒤) | ✅ |  |
| 동작 | Scheduler at() 일정은 지정 시각(10분 뒤) 전에는 발화하지 않음 | ⚠️ 다름 | 11초 만에 전달됨 |

<a id="svc-lambda"></a>

### M07 · lambda

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFunction(python3.12, zip) | ✅ |  |
| 동작 | 함수 상태 Pending → Active | ✅ 동작 | 생성 직후 State=Pending |
| API | GetFunction | ✅ |  |
| API | UpdateFunctionConfiguration(env, 256MB, 900s) | ✅ |  |
| 동작 | 타임아웃 15분(900초) 초과 거부 | ✅ 동작 | ValidationException: Value '901' at 'timeout' failed to satisfy constraint: Member must have value less than or equal to 900 |
| API | UpdateFunctionCode | ✅ |  |
| API | PublishVersion | ✅ |  |
| API | UpdateFunctionCode(v3) | ✅ |  |
| API | PublishVersion(2) | ✅ |  |
| 동작 | 버전 번호가 1, 2로 증가 | ✅ 동작 | 1, 2 |
| API | CreateAlias(live → v1, v2 10% 가중치) | ✅ |  |
| 동작 | 별칭 라우팅 가중치가 저장됨 | ✅ 동작 | {"AdditionalVersionWeights": {"2": 0.1}} |
| API | ListVersionsByFunction | ✅ |  |
| API | PutFunctionConcurrency(5) | ✅ |  |
| API | PutProvisionedConcurrencyConfig(live, 1) | ✅ |  |
| API | GetAccountSettings | ✅ |  |
| API | Invoke(RequestResponse) | ✅ |  |
| 동작 | Invoke가 핸들러를 실제로 실행해 결과 반환 | ✅ 동작 | StatusCode=200 FunctionError=None payload={"statusCode": 200, "body": "{\"echo\": {\"orderId\": \"o-1\"}, \"env\": \"prod\"}"} |
| API | CreateFunction(예외를 던지는 핸들러) | ✅ |  |
| API | Invoke(예외) | ✅ |  |
| 동작 | 핸들러 예외 → FunctionError=Unhandled, errorType 반환 | ✅ 동작 | FunctionError=Unhandled payload={"errorMessage":"boom","errorType":"ValueError","requestId":"2805b697-61c7-48bb-9b6f-f078247acd22"," |
| 동작 | Invoke 후 /aws/lambda/<함수> 로그 그룹이 생김(실행 역할에 logs:* 권한이 있을 때) | ✅ 동작 |  |
| API | Invoke(DryRun) | ✅ |  |
| 동작 | DryRun은 204 반환(실행 없이 권한·파라미터만 검사) | ✅ 동작 | StatusCode=204 |
| API | Invoke(Event, 비동기) | ✅ |  |
| 동작 | 비동기 Invoke는 202 반환 | ✅ 동작 | StatusCode=202 |
| 동작 | 없는 함수 Invoke → ResourceNotFoundException | ✅ 동작 | ResourceNotFoundException: Function not found: arn:aws:lambda:us-east-1:000000000000:function:todayorder-probe-nope-faec2c60:$LATEST |
| 동작 | 큐 가시성 타임아웃이 함수 타임아웃보다 짧으면 매핑 거부 | ✅ 동작 | InvalidParameterValueException: Queue visibility timeout: 60 seconds is less than Function timeout: 900 seconds |
| API | CreateEventSourceMapping(SQS) | ✅ |  |
| 동작 | 이벤트 소스 매핑 상태 Creating → Enabled | ✅ 동작 | Enabled |
| 동작 | SQS 메시지가 매핑을 통해 Lambda로 소비되어 큐에서 사라짐 | ✅ 동작 | visible=0 inflight=0 |
| API | UpdateEventSourceMapping(Enabled=False) | ✅ |  |
| API | AddPermission(s3.amazonaws.com) | ✅ |  |
| API | GetPolicy(리소스 기반 정책) | ✅ |  |
| 동작 | AddPermission이 리소스 기반 정책에 반영 | ✅ 동작 |  |
| API | PublishLayerVersion | ✅ |  |
| API | UpdateFunctionConfiguration(Layers) | ✅ |  |
| API | CreateFunctionUrlConfig(AuthType=NONE) | ✅ |  |
| 동작 | 함수 URL 발급 | ✅ 동작 | https://62b7f56b9b13454384431ac920563599.lambda-url.us-east-1.on.aws/ |
| API | PutFunctionEventInvokeConfig(OnFailure → SQS) | ✅ |  |
| API | ListFunctions | ✅ |  |

<a id="svc-apigateway"></a>

### M07 · apigateway

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateRestApi(REGIONAL) | ✅ |  |
| API | GetResources | ✅ |  |
| API | CreateResource(/orders) | ✅ |  |
| API | PutMethod(GET, NONE) | ✅ |  |
| API | PutIntegration(MOCK) | ✅ |  |
| API | PutMethodResponse(200) | ✅ |  |
| API | PutIntegrationResponse(200) | ✅ |  |
| API | CreateDeployment(stage=dev) | ✅ |  |
| API | GetStage | ✅ |  |
| API | UpdateStage(스로틀링 100rps/200burst) | ✅ |  |
| API | TestInvokeMethod | ✅ |  |
| 동작 | 배포된 REST API(MOCK)를 HTTPS로 실제 호출 | ✅ 동작 | 성공 URL=https://127.0.0.1:9297/_aws/execute-api/8ib9n34r0l/dev/orders |
| API | CreateApiKey | ✅ |  |
| API | CreateUsagePlan(throttle+quota) | ✅ |  |
| API | CreateUsagePlanKey | ✅ |  |
| API | CreateAuthorizer(COGNITO_USER_POOLS) | ✅ |  |

<a id="svc-apigatewayv2"></a>

### M07 · apigatewayv2

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateApi(HTTP) | ✅ |  |
| 동작 | HTTP API 엔드포인트 URL 발급 | ✅ 동작 | https://127.0.0.1:9297/_aws/execute-api/e77k44w5b0 |
| API | CreateIntegration(HTTP_PROXY) | ✅ |  |
| API | CreateRoute(GET /orders) | ✅ |  |
| API | CreateStage($default, AutoDeploy) | ✅ |  |
| API | GetRoutes | ✅ |  |
| API | CreateAuthorizer(JWT) | ✅ |  |
| API | CreateFunction(API용) | ✅ |  |
| API | CreateApi(HTTP, Lambda 프록시) | ✅ |  |
| API | CreateIntegration(AWS_PROXY → Lambda, 2.0) | ✅ |  |
| 동작 | HTTP API → Lambda 프록시를 HTTPS로 호출하면 함수가 실행되어 응답 (AddPermission 없이도 성공) | ✅ 동작 | https://127.0.0.1:9297/_aws/execute-api/6o9xe5f0aw/orders → 200 {"echo": {"version": "2.0", "routeKey": "GET /orders", "rawPath": "/orders", "rawQueryStri |
| 동작 | 실행 역할에 logs 권한이 없으면 /aws/lambda/<함수> 로그 그룹이 생기지 않음(AWS와 동일) | ✅ 동작 | 생기지 않음 |
| API | CreateApi(WEBSOCKET) | ✅ |  |
| API | CreateRoute($connect) | ✅ |  |

<a id="svc-ecr"></a>

### M07 · ecr

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateRepository(scanOnPush, IMMUTABLE) | ✅ |  |
| 동작 | 저장소 URI 발급 | ✅ 동작 | 000000000000.dkr.ecr.us-east-1.amazonaws.com/todayorder-probe-api-48bf6a60 |
| API | PutLifecyclePolicy | ✅ |  |
| API | GetLifecyclePolicy | ✅ |  |
| API | PutImageScanningConfiguration | ✅ |  |
| API | GetAuthorizationToken | ✅ |  |
| API | DescribeImages | ✅ |  |
| API | SetRepositoryPolicy | ✅ |  |

<a id="svc-ecs"></a>

### M07 · ecs

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateCluster(FARGATE 용량 공급자) | ✅ |  |
| API | RegisterTaskDefinition(Fargate, awsvpc) | ✅ |  |
| API | CreateService(desired=2, FARGATE) | ✅ |  |
| 동작 | 서비스가 desiredCount만큼 태스크를 만듦 | ✅ 동작 | lastStatus=['PROVISIONING', 'PROVISIONING'] |
| API | UpdateService(desired=3) | ✅ |  |
| API | RunTask(FARGATE) | ✅ |  |
| 동작 | RunTask 태스크가 RUNNING까지 전이 (실제로 이미지를 받아 실행하려 함) | ⚠️ 다름 | 전이 PROVISIONING → PENDING → STOPPED; stoppedReason=CannotPullContainerError: failed to resolve ref registry.invalid/todayorder/nginx:latest: failed to do request |
| API | ListClusters | ✅ |  |

<a id="svc-cognito"></a>

### M07 · cognito

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateUserPool | ✅ |  |
| API | CreateUserPoolClient(USER_PASSWORD_AUTH) | ✅ |  |
| API | AdminCreateUser | ✅ |  |
| API | SignUp | ✅ |  |
| 동작 | SignUp 직후 미확인 상태 | ✅ 동작 | UserConfirmed=False |
| 동작 | 확인 전 로그인 → UserNotConfirmedException | ✅ 동작 | UserNotConfirmedException: User is not confirmed. |
| API | AdminConfirmSignUp | ✅ |  |
| API | InitiateAuth(USER_PASSWORD_AUTH) | ✅ |  |
| 동작 | 로그인 성공 시 JWT(Id/Access/Refresh 토큰) 발급 | ✅ 동작 | IdToken 712자, ExpiresIn=3600 |
| API | GetUser(AccessToken) | ✅ |  |
| 동작 | 틀린 비밀번호 → NotAuthorizedException | ✅ 동작 | NotAuthorizedException: Incorrect username or password. |
| API | CreateGroup | ✅ |  |
| API | CreateIdentityPool | ✅ |  |
| API | SetIdentityPoolRoles | ✅ |  |
| API | GetId(비인증) | ✅ |  |
| API | GetCredentialsForIdentity | ✅ |  |
| 동작 | 자격 증명 풀이 임시 AWS 자격 증명 발급 | ✅ 동작 |  |

<a id="svc-lambda-runtime"></a>

### M07 · lambda-runtime

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFunction(rtfn) | ✅ |  |
| 동작 | Lambda python3.12 런타임이 CPython | ⚠️ 다름 | sys.version=3.14.0.alpha (heads/unknown-branch:0000000, Nov 10 2026, 20:50:33) [RustPython 0.6.0 with  |
| 동작 | 실행 역할에 dynamodb 권한이 없으면 함수 안 PutItem 이 AccessDenied (역할 정책 집행) | ✅ 동작 | {"ok": false, "err": "An error occurred (AccessDeniedException) when calling the PutItem operation: User: arn:aws:sts::000000000000:assumed-role/todayorder-prob |
| 동작 | dynamodb:PutItem 을 허용하면 함수 안 PutItem 성공 | ✅ 동작 | {"ok": true} |
| API | PutFunctionEventInvokeConfig(재시도 0, OnFailure → SQS) | ✅ |  |
| API | Invoke(Event, 실패하는 핸들러) | ✅ |  |
| 동작 | 비동기 실패가 OnFailure 대상(SQS)에 전달됨 | ⚠️ 다름 | 35초 안에 0건 |
| 동작 | MaximumRetryAttempts=0 이면 비동기 실패 함수가 1번만 실행됨 | ⚠️ 다름 | 실행 3번 |
| API | PutFunctionEventInvokeConfig(재시도 0, 대상 없음) | ✅ |  |
| API | UpdateFunctionConfiguration(DeadLetterConfig → SQS) | ✅ |  |
| 동작 | 함수 DeadLetterConfig 설정이 조회됨 | ✅ 동작 | arn:aws:sqs:us-east-1:000000000000:todayorder-probe-rtfndlq-14edbe97 |
| 동작 | 비동기 실패가 함수 DLQ(DeadLetterConfig, SQS)에 전달됨 | ⚠️ 다름 | 35초 안에 0건 (함수 실행 3번) |
| 동작 | 동기 Invoke 를 반복해도 에뮬레이터 메모리가 늘지 않음 | ⚠️ 다름 | 278 → 389 MiB, 호출당 약 7.4 MiB 증가(회수되지 않음) |

<a id="svc-lambda-permissions"></a>

### M07 · lambda-permissions

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFunction(permfn) | ✅ |  |
| 동작 | REST API(AWS_PROXY) → Lambda: 리소스 정책(add-permission) 없으면 실패(500) | ✅ 동작 | HTTP 500 {"message":"Internal server error"} |
| API | AddPermission(apigateway.amazonaws.com) | ✅ |  |
| 동작 | REST API: add-permission 후 200 | ✅ 동작 | HTTP 200 |
| API | Subscribe(lambda, add-permission 없음) | ✅ |  |
| 동작 | SNS → Lambda: 리소스 정책 없으면 함수가 실행되지 않음 | ✅ 동작 | 10초 뒤 항목 0개 (AWS도 실행하지 않지만 전달 실패를 지표·로그로 남긴다) |
| 동작 | SNS → Lambda: add-permission 후 함수 실행 | ✅ 동작 |  |
| 동작 | S3 → Lambda 알림: 리소스 정책 없으면 구성 거부(InvalidArgument) | ✅ 동작 | InvalidArgument: Unable to validate the following destination configurations |

<a id="svc-route53"></a>

### M08 · route53

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateHostedZone(퍼블릭) | ✅ |  |
| 동작 | 퍼블릭 호스팅 영역에 NS/SOA 기본 레코드와 위임 세트 | ✅ 동작 | NameServers=['ns-1526.awsdns-14.com', 'ns-152.awsdns-22.net'] |
| API | CreateHostedZone(프라이빗, VPC 연결) | ✅ |  |
| 동작 | 프라이빗 호스팅 영역 PrivateZone=True | ✅ 동작 |  |
| API | ChangeResourceRecordSets(A, CNAME) | ✅ |  |
| 동작 | GetChange 상태 PENDING → INSYNC | ✅ 동작 | 처음 PENDING, 이후 INSYNC |
| API | CreateHealthCheck(HTTPS) | ✅ |  |
| API | GetHealthCheckStatus | ✅ |  |
| 동작 | 상태 확인이 실제로 대상을 검사함(존재하지 않는 도메인 → 실패여야 함) | ⚠️ 다름 | 관찰 8건 ['Success: HTTP Status Code 200, OK', 'Success: HTTP Status Code 200, OK'] — 존재하지 않는 대상인데 Success면 시뮬레이션된 결과 |
| API | ChangeResourceRecordSets(가중치) | ✅ |  |
| API | ChangeResourceRecordSets(장애 조치) | ✅ |  |
| API | ChangeResourceRecordSets(지연 시간) | ✅ |  |
| API | ChangeResourceRecordSets(지리적 위치) | ✅ |  |
| API | ChangeResourceRecordSets(다중값 응답) | ✅ |  |
| API | ChangeResourceRecordSets(Alias → S3 웹 사이트) | ✅ |  |
| 동작 | 영역 apex에 CNAME을 만들면 InvalidChangeBatch로 거부 | ✅ 동작 | InvalidChangeBatch: [RRSet of type CNAME with DNS name 119671a1.todayorder.example. is not permitted at apex in zone 119671a1.todayorder.example.] |
| API | ListResourceRecordSets | ✅ |  |
| 동작 | 레코드 목록에 생성한 레코드가 모두 보임 | ✅ 동작 | 15개, 유형 ['A', 'CNAME', 'NS', 'SOA'] |
| API | TestDNSAnswer(가중치) | ✅ |  |
| 동작 | TestDNSAnswer가 가중치 레코드 중 하나를 응답 | ✅ 동작 | RecordData=['192.0.2.2'] ResponseCode=NOERROR |
| 동작 | 실제 DNS 질의(dig) | ⏭️ | 에뮬레이터는 HTTPS API 포트 하나만 노출한다. 컨테이너에서 DNS(53) 포트를 내보내지 않으므로 dig로 확인 불가 |

<a id="svc-cloudfront"></a>

### M08 · cloudfront

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateOriginAccessControl | ✅ |  |
| API | CreateCachePolicy | ✅ |  |
| API | CreateDistribution(S3 오리진 + OAC) | ✅ |  |
| 동작 | 배포 도메인 이름(*.cloudfront.net) 발급 | ⚠️ 다름 | DomainName=127.0.0.1:32769 Status=InProgress — 에뮬레이터는 컨테이너 안의 로컬 포트를 준다 |
| 동작 | 배포 상태 InProgress → Deployed | ✅ 동작 | 처음 InProgress, 이후 Deployed |
| 동작 | 버킷 정책 없이 배포로 GET → 403 (OAC가 허용되지 않음) | ✅ 동작 | HTTP 403 |
| 동작 | OAC용 버킷 정책 추가 후 배포 주소로 GET → 객체 반환 (컨테이너 안에서 curl) | ✅ 동작 | HTTP 200 'hello-cloudfront' |
| API | CreateInvalidation | ✅ |  |
| 동작 | 무효화 상태 | ✅ 동작 | InProgress |
| API | CreateFunction(CloudFront Functions) | ✅ |  |
| API | TestFunction | ⛔ 501 | HTTP 501 NotImplemented: operation TestFunction is scaffolded but not implemented in this emulator |

<a id="svc-globalaccelerator"></a>

### M08 · globalaccelerator

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateAccelerator(us-east-1 클라이언트) | ✅ |  |
| 동작 | 정적 애니캐스트 IP 2개 할당(us-east-1) | ✅ 동작 | IP ['198.18.0.0', '198.18.0.1'] Status=IN_PROGRESS |
| API | CreateListener(TCP 443) | ✅ |  |
| API | CreateEndpointGroup(ap-northeast-2) | ✅ |  |

<a id="svc-wafv2"></a>

### M08 · wafv2

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateIPSet(REGIONAL) | ✅ |  |
| API | CreateWebACL(REGIONAL, 속도 기반 + 관리형 규칙 그룹) | ✅ |  |
| API | GetWebACL | ✅ |  |
| 동작 | Web ACL에 규칙 3개가 저장됨 | ✅ 동작 | 3개, Capacity=703 |
| API | AssociateWebACL(ALB) | ✅ |  |
| API | GetWebACLForResource | ✅ |  |
| 동작 | ALB에 연결된 Web ACL 조회 | ✅ 동작 |  |
| API | CreateWebACL(CLOUDFRONT 범위) | ✅ |  |

<a id="svc-edge-better"></a>

### M08 · edge-better

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | ALB 에 연결한 WAF Web ACL 이 차단 목록 IP 요청을 실제로 403 으로 막음(컨테이너 안에서 확인) | ✅ 동작 | 정상 200, 차단 목록 IP 403 |
| 동작 | 지연 시간 레코드: 질의자 위치(리졸버 IP)에 따라 다른 답 | ⚠️ 다름 | 미국 리졸버 ['192.0.2.20'], 서울 리졸버 ['192.0.2.20'] |
| 동작 | 같은 이름·유형에 서로 다른 라우팅 정책(가중치+지연 시간) → InvalidChangeBatch | ⚠️ 다름 | 기대 InvalidChangeBatch, 실제로는 성공했다 |
| API | ListCidrCollections | ⛔ 501 | HTTP 501 NotImplemented: operation ListCidrCollections is scaffolded but not implemented in this emulator |

<a id="svc-kms"></a>

### M09 · kms

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateKey(대칭) | ✅ |  |
| 동작 | 키 메타데이터(KeySpec SYMMETRIC_DEFAULT, Enabled) | ✅ 동작 | KeySpec=SYMMETRIC_DEFAULT KeyManager=CUSTOMER |
| API | CreateAlias | ✅ |  |
| API | Encrypt(별칭으로) | ✅ |  |
| 동작 | 암호문은 평문과 다름 | ✅ 동작 | 75바이트 |
| API | Decrypt | ✅ |  |
| 동작 | Encrypt → Decrypt 왕복 | ✅ 동작 |  |
| 동작 | 암호화 컨텍스트가 다르면 Decrypt 실패 | ✅ 동작 | InvalidCiphertextException:  |
| API | GenerateDataKey(AES_256) | ✅ |  |
| 동작 | 봉투 암호화: 암호화된 데이터 키를 Decrypt하면 평문 데이터 키와 같음 | ✅ 동작 |  |
| API | GenerateDataKeyWithoutPlaintext | ✅ |  |
| API | EnableKeyRotation | ✅ |  |
| API | GetKeyRotationStatus | ✅ |  |
| 동작 | 자동 교체 활성화 조회 | ✅ 동작 | RotationPeriodInDays=365 |
| API | RotateKeyOnDemand | ✅ |  |
| API | TagResource | ✅ |  |
| API | ListResourceTags | ✅ |  |
| API | PutKeyPolicy(Decrypt Deny) | ✅ |  |
| 동작 | 키 정책의 명시적 Deny가 Decrypt를 막음 | ✅ 동작 | AccessDeniedException |
| API | CreateKey(비대칭 RSA_2048 SIGN_VERIFY) | ✅ |  |
| API | Sign | ✅ |  |
| API | Verify | ✅ |  |
| 동작 | Sign → Verify 성공 | ✅ 동작 |  |
| 동작 | 변조된 메시지의 서명 검증 실패 | ✅ 동작 | KMSInvalidSignatureException:  |
| API | GetPublicKey | ✅ |  |
| API | CreateKey(MultiRegion=True) | ✅ |  |
| 동작 | 다중 리전 키 ID는 mrk- 접두사 | ✅ 동작 | mrk-8b37 |
| API | ReplicateKey(us-west-2) | ✅ |  |
| API | ScheduleKeyDeletion(7일) | ✅ |  |
| 동작 | 삭제 예약 후 KeyState=PendingDeletion | ✅ 동작 | PendingDeletion |
| 동작 | 삭제 대기 중인 키로 Encrypt하면 KMSInvalidStateException | ✅ 동작 | KMSInvalidStateException: arn:aws:kms:us-east-1:000000000000:key/abff868c-3629-4938-91af-8a93bb90ba14 is pending deletion. |
| API | CancelKeyDeletion | ✅ |  |
| 동작 | 삭제 대기 기간 7일 미만은 거부 | ✅ 동작 | ValidationException:  |

<a id="svc-secretsmanager"></a>

### M09 · secretsmanager

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateSecret | ✅ |  |
| 동작 | ARN 끝에 무작위 6자 접미사 | ✅ 동작 | todayorder-probe-db-7ce344a6/password-xJtxRU |
| API | GetSecretValue | ✅ |  |
| API | PutSecretValue | ✅ |  |
| 동작 | 새 값 저장 시 AWSCURRENT → 새 버전, AWSPREVIOUS → 이전 버전 | ✅ 동작 | {'06c15747-ba21-41c4-8ef7-4589355c157b': ['AWSCURRENT'], 'ddaa698d-76d7-4de7-8d69-37eae8ffef4a': ['AWSPREVIOUS']} |
| 동작 | VersionStage=AWSPREVIOUS로 이전 값 조회 | ✅ 동작 |  |
| API | UpdateSecretVersionStage(롤백) | ✅ |  |
| 동작 | 스테이지 이동으로 AWSCURRENT 롤백 | ✅ 동작 | {"username": "app", "password": "v1"} |
| API | RotateSecret(Lambda ARN 지정) | ❌ | HTTP 400 AccessDeniedException: Secrets Manager cannot invoke the specified Lambda function. Ensure that the function policy grants access to the principal secretsmanager.amazonaws.com. |
| API | GetRandomPassword | ✅ |  |
| API | ReplicateSecretToRegions(us-west-2) | ✅ |  |
| API | CreateSecret(삭제 테스트) | ✅ |  |
| API | DeleteSecret(복구 기간 7일) | ✅ |  |
| 동작 | 삭제 예약된 비밀은 조회 불가(InvalidRequestException) | ✅ 동작 | InvalidRequestException: You can't perform this operation on the secret because it was marked for deletion. |
| API | RestoreSecret | ✅ |  |
| 동작 | RestoreSecret 후 다시 조회 가능 | ✅ 동작 |  |

<a id="svc-ssm"></a>

### M09 · ssm

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | PutParameter(String) | ✅ |  |
| API | PutParameter(StringList) | ✅ |  |
| API | PutParameter(SecureString, 고객 관리형 키) | ✅ |  |
| API | PutParameter(SecureString, 기본 aws/ssm 키) | ✅ |  |
| API | GetParameter(SecureString, 복호화 없이) | ✅ |  |
| 동작 | WithDecryption 없이 조회하면 암호문이 반환됨 | ✅ 동작 | ASQzOGZjMzExYi05MjkzLTQzNWQtYWRhYi05ZGJi |
| API | GetParameter(WithDecryption) | ✅ |  |
| 동작 | WithDecryption=True면 평문 | ✅ 동작 |  |
| API | GetParametersByPath(Recursive) | ✅ |  |
| 동작 | 계층 경로 재귀 조회로 4개 모두 | ✅ 동작 | ['/api/hosts', '/api/timeout', '/db/password', '/db/token'] |
| 동작 | Recursive=False면 바로 아래 단계만(0개) | ✅ 동작 | 0개 |
| API | GetParameterHistory | ✅ |  |
| 동작 | 덮어쓰면 버전 2가 됨 | ✅ 동작 |  |
| API | LabelParameterVersion | ✅ |  |
| API | GetParameter(:label) | ✅ |  |
| 동작 | 레이블로 이전 버전 조회 | ✅ 동작 | 30 |
| API | PutParameter(Advanced 계층) | ✅ |  |
| 동작 | Standard 계층 4KB 초과 값은 거부 | ✅ 동작 | ValidationException: Standard tier parameters support a maximum parameter value of 4096 characters. To create a larger parameter value, upgrade the parameter to use the advanced-par |
| API | GetParametersByPath(공개 파라미터 /aws/service/global-infrastructure/regions) | ✅ |  |
| 동작 | 공개 파라미터(리전 목록)가 들어 있음 | ⚠️ 다름 | 0개 |
| API | GetParameter(공개 AL2023 AMI) | ✅ |  |
| 동작 | 최신 AL2023 AMI ID 공개 파라미터 | ✅ 동작 | ami-0000000000000004c |
| API | SendCommand(AWS-RunShellScript) | ✅ |  |
| API | StartSession | ⛔ 501 | HTTP 501 NotImplemented: operation StartSession is scaffolded but not implemented in this emulator |
| API | DescribeInstanceInformation | ✅ |  |

<a id="svc-acm"></a>

### M09 · acm

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | RequestCertificate(DNS 검증) | ✅ |  |
| API | DescribeCertificate | ✅ |  |
| 동작 | DNS 검증용 CNAME 레코드(ResourceRecord) 제공 | ✅ 동작 | Status=PENDING_VALIDATION RR={'Name': '_d72c59a2c4b2b2e5b0025ff0823826e7.api.fac823f3.todayorder.example.', 'Type': 'CNAME', 'Value': '_9b88a81a93fd63322be21d37edf3f2c5.ed6dad4bf7.acm-validations.aws. |
| 동작 | 검증 레코드가 없으면 ISSUED가 되지 않음 | ✅ 동작 | FAILED ADDITIONAL_VERIFICATION_REQUIRED — .example 등 예약 도메인은 수 초 만에 FAILED(ADDITIONAL_VERIFICATION_REQUIRED) |
| API | RequestCertificate(Route 53 영역 도메인) | ✅ |  |
| 동작 | Route 53에 검증 CNAME을 만들면 ISSUED로 전환(20초 대기) | ⚠️ 다름 | PENDING_VALIDATION |
| API | ImportCertificate(자체 서명) | ✅ |  |
| 동작 | 가져온 인증서 Type=IMPORTED | ✅ 동작 | Type=IMPORTED Status=ISSUED |
| API | ListCertificates | ✅ |  |

<a id="svc-cloudtrail"></a>

### M09 · cloudtrail

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateTrail(멀티 리전) | ✅ |  |
| API | StartLogging | ✅ |  |
| API | GetTrailStatus | ✅ |  |
| 동작 | GetTrailStatus IsLogging=True | ✅ 동작 |  |
| API | PutEventSelectors(S3 데이터 이벤트) | ✅ |  |
| 동작 | IAM CreateUser가 LookupEvents(이벤트 기록)에 나타남 | ✅ 동작 |  |
| 동작 | S3 CreateBucket이 LookupEvents(이벤트 기록)에 나타남 | ⚠️ 다름 |  |
| API | LookupEvents | ✅ |  |
| 동작 | 추적이 S3 버킷에 로그 파일을 씀(10초 대기) | ✅ 동작 | 객체 27개 — 실제 AWS는 약 5분 간격 |

<a id="svc-config"></a>

### M09 · config

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | PutConfigurationRecorder | ✅ |  |
| 동작 | Config 전달 채널: 버킷 정책이 없으면 거부(버킷 정책을 평가함) | ✅ 동작 | InsufficientDeliveryPolicyException: Insufficient delivery policy to s3 bucket: todayorder-probe-nopolicy-d5a6d4d7, unable to get s3 bucket acl. |
| API | PutDeliveryChannel | ✅ |  |
| API | StartConfigurationRecorder | ✅ |  |
| API | DescribeConfigurationRecorderStatus | ✅ |  |
| 동작 | 기록기 recording=True | ✅ 동작 |  |
| API | PutConfigRule(관리형 S3_BUCKET_VERSIONING_ENABLED) | ✅ |  |
| API | StartConfigRulesEvaluation | ✅ |  |
| 동작 | 규칙이 실제로 평가됨(버전 관리 꺼진 버킷 → NON_COMPLIANT) | ✅ 동작 | {'ComplianceType': 'NON_COMPLIANT', 'ComplianceContributorCount': {'CappedCount': 3, 'CapExceeded': False}} |
| API | ListDiscoveredResources(S3 버킷) | ✅ |  |
| API | PutConformancePack | ✅ |  |

<a id="svc-guardduty"></a>

### M09 · guardduty

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateDetector | ✅ |  |
| API | GetDetector | ✅ |  |
| 동작 | 탐지기 Status=ENABLED | ✅ 동작 | ENABLED |
| API | CreateSampleFindings | ✅ |  |
| 동작 | 샘플 결과(finding)가 ListFindings에 나타남 | ✅ 동작 | 1건 |
| API | ListFindings | ✅ |  |
| API | inspector2 Enable(EC2) | ✅ |  |
| API | macie2 EnableMacie | ✅ |  |
| API | securityhub EnableSecurityHub | ✅ |  |
| API | detective CreateGraph | ✅ |  |

<a id="svc-security-better"></a>

### M09 · security-better

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | 비활성화된 KMS 키로 Decrypt → DisabledException | ✅ 동작 | DisabledException: arn:aws:kms:us-east-1:000000000000:key/935558a6-8403-4f48-a1ea-34d192364471 is disabled. |
| 동작 | CMK 를 비활성화하면 SecureString 복호화(WithDecryption) 실패 | ⚠️ 다름 | 복호화됨(True) |
| API | CreateFunction(rotfn) | ✅ |  |
| API | RotateSecret(add-permission 후) | ✅ |  |
| 동작 | Secrets Manager 교체가 Lambda 를 실제로 호출해 AWSCURRENT 값을 바꿈 | ✅ 동작 | AWSCURRENT=rotated-2307c1ce |
| API | PutRemediationConfigurations(Automatic, AWS-ConfigureS3BucketVersioning) | ✅ |  |
| 동작 | Config 자동 수정(SSM Automation)이 실제로 실행되어 버전 관리를 켬 | ✅ 동작 | Status=Enabled |
| API | auditmanager GetAccountStatus | ⛔ 501 | HTTP 501 NotImplemented: operation GetAccountStatus is scaffolded but not implemented in this emulator |
| 동작 | CloudTrail LookupEvents 에 IAM 관리 이벤트가 나타남 | ✅ 동작 |  |
| 동작 | CloudTrail LookupEvents 에 KMS 관리 이벤트(CreateKey)가 나타남 | ⚠️ 다름 |  |

<a id="svc-cloudwatch"></a>

### M10 · cloudwatch

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | PutMetricData(사용자 지정 네임스페이스·차원) | ✅ |  |
| API | ListMetrics(네임스페이스) | ✅ |  |
| 동작 | 게시한 지표가 ListMetrics에 보임 | ✅ 동작 | 1개 |
| API | GetMetricStatistics | ✅ |  |
| 동작 | 데이터 포인트 집계(평균 200, 표본 3, 최댓값 300) | ✅ 동작 | [{'Timestamp': datetime.datetime(2026, 11, 13, 12, 19, tzinfo=tzlocal()), 'SampleCount': 3.0, 'Average': 200.0, 'Maximum': 300.0, 'Unit': 'Millisecond |
| API | GetMetricData | ✅ |  |
| 동작 | GetMetricData 합계 600 | ✅ 동작 | [600.0] |
| API | ListMetrics(AWS/EC2) | ✅ |  |
| 동작 | 기본 EC2 지표(AWS/EC2)가 저절로 생김 | ⚠️ 다름 | 0개 — 인스턴스가 실제로 돌지 않으므로 없을 수 있음 |
| API | PutMetricAlarm(SNS 액션) | ✅ |  |
| 동작 | 임계값 초과 데이터만으로 알람이 스스로 ALARM이 됨(25초 대기, Period=10) | ✅ 동작 | 처음 INSUFFICIENT_DATA → ALARM |
| API | DescribeAlarmHistory | ✅ |  |
| 동작 | 알람 상태 변경 이력이 기록됨 | ✅ 동작 | 1건 |
| 동작 | 알람 액션: SNS → 구독한 SQS 큐로 알림 도착 | ✅ 동작 | 1건 {"Version":"1.0","AlarmName":"todayorder-probe-latency-high-7f533b1c","AWSAccountId":"000000000000", |
| API | PutCompositeAlarm | ✅ |  |
| 동작 | 복합 알람이 하위 알람 상태를 따라 ALARM | ✅ 동작 | ALARM |
| API | PutDashboard | ✅ |  |

<a id="svc-logs"></a>

### M10 · logs

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateLogGroup | ✅ |  |
| API | PutRetentionPolicy(7일) | ✅ |  |
| 동작 | 허용되지 않은 보존 기간(8일)은 거부 | ✅ 동작 | InvalidParameterException: Invalid retention value. Valid values are: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653] |
| API | PutMetricFilter(ERROR 개수) | ✅ |  |
| API | CreateLogStream | ✅ |  |
| API | PutLogEvents | ✅ |  |
| API | GetLogEvents | ✅ |  |
| 동작 | GetLogEvents로 4건 조회 | ✅ 동작 | 4건 |
| API | FilterLogEvents(패턴 ERROR) | ✅ |  |
| 동작 | FilterLogEvents가 패턴으로 2건만 반환 | ✅ 동작 | 2건 |
| 동작 | FilterLogEvents 구문 패턴("payment failed") 1건 | ✅ 동작 | 1건 |
| 동작 | 지표 필터: ERROR 로그 2건 → CloudWatch 지표 ErrorCount 합계 2 | ✅ 동작 | [{'Timestamp': datetime.datetime(2026, 11, 13, 12, 19, tzinfo=tzlocal()), 'Sum': 2.0, 'Unit': 'None'}] |
| API | PutSubscriptionFilter(→ Kinesis) | ✅ |  |
| API | StartQuery(Logs Insights) | ✅ |  |
| 동작 | Logs Insights 쿼리가 완료되고 결과 n=2 | ✅ 동작 | status=Complete [[{'field': 'n', 'value': '2'}]] |

<a id="svc-cloudformation"></a>

### M10 · cloudformation

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | ValidateTemplate | ✅ |  |
| 동작 | ValidateTemplate가 파라미터를 읽음 | ✅ 동작 |  |
| API | CreateStack(VPC 템플릿) | ✅ |  |
| 동작 | 스택이 CREATE_COMPLETE에 도달 | ✅ 동작 | CREATE_COMPLETE |
| 동작 | 스택 리소스 9개 모두 CREATE_COMPLETE | ✅ 동작 | 9개 ['CREATE_COMPLETE'] |
| 동작 | 선언한 리소스가 EC2 API로 실제 조회됨(VPC·서브넷 2·IGW 연결·0.0.0.0/0 라우트·SG) | ✅ 동작 | vpc=vpc-000000000000001de subnets=2 igw=1 routes=['local', 'igw-000000000000001ea'] sg=1 |
| 동작 | Outputs(Ref, Fn::GetAtt) 값 | ✅ 동작 | {'VpcId': 'vpc-000000000000001de', 'PublicSubnetA': 'subnet-000000000000001e6', 'VpcCidrOut': '10.20.0.0/16'} |
| API | CreateChangeSet(서브넷 추가) | ✅ |  |
| API | DescribeChangeSet | ✅ |  |
| 동작 | 변경 세트가 Add PrivateA 1건을 보여 줌 | ✅ 동작 | CREATE_COMPLETE [('Add', 'PrivateA')] |
| API | ExecuteChangeSet | ✅ |  |
| 동작 | (VPC 스택) 변경 세트 실행 후 UPDATE_COMPLETE, 서브넷 3개 | ⚠️ 다름 | UPDATE_ROLLBACK_COMPLETE, 서브넷 2 ['IgwAttach: NotImplemented: this emulator does not change the properties of an existing AWS::EC2::VPCGatewayAttachment in '] |
| API | DetectStackDrift | ✅ |  |
| 동작 | 드리프트 감지 결과 | ✅ 동작 | DRIFTED |
| API | DeleteStack | ✅ |  |
| 동작 | DeleteStack 후 VPC가 실제로 삭제됨 | ✅ 동작 |  |
| API | CreateStack(잘못된 참조) | ✅ |  |
| 동작 | 실패한 스택은 ROLLBACK_COMPLETE (생성됐던 리소스는 롤백) | ✅ 동작 | ROLLBACK_COMPLETE |
| 동작 | 알 수 없는 리소스 유형은 ValidationError | ✅ 동작 | ValidationError: Template format error: Unrecognized resource types: [AWS::Nope::Thing] |
| API | CreateStack(S3+SQS+DynamoDB) | ✅ |  |
| 동작 | S3(버전 관리)·SQS(가시성 45)·DynamoDB가 속성까지 실제 생성 | ✅ 동작 | CREATE_COMPLETE versioning=Enabled visibility=45 table=ACTIVE |
| API | CreateChangeSet(앱 스택에 큐 추가) | ✅ |  |
| 동작 | (앱 스택) 변경 세트 Add Dlq → UPDATE_COMPLETE | ✅ 동작 | [('Add', 'Dlq')] → UPDATE_COMPLETE |
| API | CreateStackSet | ✅ |  |
| API | CreateStackInstances(us-east-1, us-west-2) | ✅ |  |

<a id="svc-cfn-timing"></a>

### M10 · cfn-timing

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | CLI 웨이터처럼 30초 간격으로만 조회해도 NAT·경로가 있는 VPC 스택이 CREATE_COMPLETE | ⚠️ 다름 | 관찰 CREATE_IN_PROGRESS → ROLLBACK_IN_PROGRESS → ROLLBACK_COMPLETE AWS::EC2::Route todayorder-probe-cfnwaiter-98519aa0-PrivateDefault-7188114573E2 was still CREATE_IN_PROGRESS when the wa |
| 동작 | 2초 간격 조회로 같은 스택이 CREATE_COMPLETE | ✅ 동작 | CREATE_COMPLETE (2초) |
| API | DetectStackDrift | ✅ |  |
| 동작 | 드리프트: 손대지 않은 IGW·경로·NAT·EIP·라우팅 테이블은 IN_SYNC | ⚠️ 다름 | {"Igw": "DELETED", "IgwAttach": "DELETED", "PublicDefault": "DELETED", "PrivateDefault": "DELETED", "Nat": "DELETED", "NatEip": "DELETED", "PublicRt": "DELETED"} |
| 동작 | 드리프트: 스택 밖에서 SG 인바운드 규칙을 추가하면 MODIFIED | ⚠️ 다름 | WebSg=IN_SYNC |

<a id="svc-firehose"></a>

### M11 · firehose

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBucket(대상) | ✅ |  |
| API | CreateDeliveryStream(S3, 버퍼 60초/1MB) | ✅ |  |
| 동작 | 전송 스트림 ACTIVE | ✅ 동작 |  |
| API | PutRecord | ✅ |  |
| API | PutRecordBatch | ✅ |  |
| 동작 | 버퍼 시간(60초) 안팎에 S3 객체가 실제로 생김 | ✅ 동작 | 3s 대기, 객체 ['orders/2026/11/13/03/todayorder-probe-orders-852bf30c-1-2026-11-13-03-19-11-0-c7da564f-1893-4fa1-8873-ee86c5e762d6'] |

<a id="svc-glue"></a>

### M11 · glue

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateDatabase | ✅ |  |
| API | CreateTable(파티션 dt, JSON, S3 위치) | ✅ |  |
| API | GetTables | ✅ |  |
| 동작 | 테이블 정의가 카탈로그에 보임 | ✅ 동작 |  |
| API | BatchCreatePartition | ✅ |  |
| API | GetPartitions | ⛔ 501 | HTTP 501 NotImplemented: operation GetPartitions is scaffolded but not implemented in this emulator |
| 동작 | Glue가 역할의 신뢰 정책을 확인(없는 역할 거부) | ✅ 동작 | InvalidInputException: Service is unable to assume provided role. Please verify role's TrustPolicy |
| API | CreateCrawler | ✅ |  |
| API | StartCrawler | ⛔ 501 | HTTP 501 NotImplemented: operation StartCrawler is scaffolded but not implemented in this emulator |
| API | CreateJob | ✅ |  |
| API | StartJobRun | ✅ |  |
| API | ListJobs | ✅ |  |

<a id="svc-athena"></a>

### M11 · athena

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateWorkGroup(결과 위치) | ✅ |  |
| API | StartQueryExecution(SELECT 1) | ✅ |  |
| 동작 | SELECT 1이 실행되어 결과 반환 | ✅ 동작 | QUEUED → RUNNING → SUCCEEDED rows=[['one'], ['1']] |
| API | StartQueryExecution(Glue 테이블 집계) | ✅ |  |
| 동작 | Glue 테이블(S3 JSON)에 SUM 쿼리 → 3500 | ✅ 동작 | QUEUED → RUNNING → SUCCEEDED rows=[['total'], ['3500']] |
| 동작 | 쿼리 결과 파일이 작업 그룹 결과 위치(S3)에 저장됨 | ⚠️ 다름 | results/ 아래 0개, 버킷 전체 ['orders/dt=2026-11-01/p.json'] |
| API | ListQueryExecutions | ✅ |  |

<a id="svc-analytics-gaps"></a>

### M11 · analytics-gaps

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| 동작 | Athena: 등록된 파티션(dt=2026-11-01) 데이터만 읽음 (2건) | ⚠️ 다름 | SUCCEEDED [['3']] |
| 동작 | Athena: 파티션 열 dt 로 WHERE 필터 | ⚠️ 다름 | FAILED no such column: dt in SELECT count(*) FROM "todayorder_probe_db_127a4839.orders" WHERE dt = '2026-11-01' at offset 65 |
| 동작 | Athena: Trino 함수 date_trunc·from_iso8601_timestamp | ⚠️ 다름 | FAILED no such function: date_trunc in SELECT date_trunc('day', from_iso8601_timestamp('2026-11-01T10:00:00Z')) at offset 7 |
| API | ListWorkGroups | ⛔ 501 | HTTP 501 NotImplemented: operation ListWorkGroups is scaffolded but not implemented in this emulator |
| API | ListNamedQueries | ⛔ 501 | HTTP 501 NotImplemented: operation ListNamedQueries is scaffolded but not implemented in this emulator |
| API | DeleteWorkGroup | ⛔ 501 | HTTP 501 NotImplemented: operation DeleteWorkGroup is scaffolded but not implemented in this emulator |
| API | CreateJob(pythonshell) | ✅ |  |
| 동작 | Glue Python shell 작업이 스크립트를 실제로 실행(S3 객체 생성) | ✅ 동작 | JobRunState=SUCCEEDED, glue-out 객체 1개 |
| API | CreateDeliveryStream(S3 권한 없는 역할) | ✅ |  |
| 동작 | Firehose: 역할에 S3 권한이 없으면 배달하지 못함 | ⚠️ 다름 | 배달됨(권한 정책 미검사) |

<a id="svc-backup"></a>

### M12 · backup

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBackupVault | ✅ |  |
| API | CreateBackupPlan(일일 + 복사 액션) | ✅ |  |
| API | CreateBackupSelection(태그 기준) | ✅ |  |
| API | StartBackupJob(DynamoDB 테이블) | ✅ |  |
| 동작 | 백업 작업이 COMPLETED, 복구 지점 생성 | ✅ 동작 | State=COMPLETED RecoveryPoint=int:18e77c9e-7430-434b-0000-000000000007 |
| 동작 | 볼트에 복구 지점이 보임 | ✅ 동작 | 1개 |
| API | ListCopyJobs | ⛔ 501 | HTTP 501 NotImplemented: operation ListCopyJobs is scaffolded but not implemented in this emulator |

<a id="svc-dms"></a>

### M12 · dms

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateReplicationSubnetGroup | ✅ |  |
| API | CreateReplicationInstance | ✅ |  |
| 동작 | 복제 인스턴스 creating → available | ✅ 동작 | 처음 creating → available |
| API | CreateEndpoint(source mysql) | ✅ |  |
| API | CreateEndpoint(target aurora-postgresql) | ✅ |  |
| API | TestConnection | ⛔ 501 | HTTP 501 NotImplemented: operation TestConnection is scaffolded but not implemented in this emulator |
| API | CreateReplicationTask(full-load-and-cdc) | ✅ |  |

<a id="svc-budgets"></a>

### M13 · budgets

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBudget(월 COST 100 USD + 80% 알림) | ✅ |  |
| API | DescribeBudgets | ✅ |  |
| 동작 | 예산 조회(CalculatedSpend 포함?) | ✅ 동작 | {'ActualSpend': {'Amount': '0', 'Unit': 'USD'}} |
| API | DescribeNotificationsForBudget | ✅ |  |
| API | DescribeBudgetPerformanceHistory | ✅ |  |
| API | ce GetCostAndUsage | ⛔ 501 | HTTP 501 NotImplemented: operation GetCostAndUsage is scaffolded but not implemented in this emulator |

<a id="svc-tagging"></a>

### M13 · tagging

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | GetResources(TagFilters) | ✅ |  |
| 동작 | 태그로 S3·SQS·DynamoDB·VPC를 한 번에 찾음 | ⚠️ 다름 | {'s3': False, 'sqs': True, 'dynamodb': False, 'ec2': False} |
| API | TagResources(태그 없는 큐에 일괄 태깅) | ✅ |  |
| 동작 | TagResources가 대상 서비스(SQS)에 실제 반영 | ✅ 동작 | {'owner': 'orders-team'} |
| API | GetTagKeys | ✅ |  |

<a id="svc-misc-optional"></a>

### 기타 · misc-optional

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | elasticbeanstalk CreateApplication | ✅ |  |
| API | lightsail GetRegions | ✅ |  |
| API | batch CreateComputeEnvironment(FARGATE) | ✅ |  |
| API | storagegateway ListGateways | ✅ |  |
| API | datasync ListTasks | ✅ |  |
| API | fsx CreateFileSystem(LUSTRE) | ✅ |  |
| API | redshift CreateCluster | ✅ |  |
| API | opensearch CreateDomain | ✅ |  |
| API | emr ListClusters | ✅ |  |
| API | kafka ListClustersV2 | ✅ |  |
| API | mq CreateBroker | ✅ |  |
| API | appflow ListFlows | ✅ |  |
| API | transfer CreateServer(SFTP) | ✅ |  |
| API | servicecatalog ListPortfolios | ✅ |  |
| API | ram CreateResourceShare | ✅ |  |
| API | ds CreateDirectory(SimpleAD) | ✅ |  |
| API | sso-admin ListInstances | ✅ |  |
| API | service-quotas GetServiceQuota(Lambda 동시 실행) | ✅ |  |
| API | compute-optimizer GetEnrollmentStatus | ✅ |  |
| API | controltower ListLandingZones | ✅ |  |
| API | lakeformation GetDataLakeSettings | ✅ |  |
| API | quicksight ListDashboards | ⛔ 501 | HTTP 501 NotImplemented: operation ListDashboards is scaffolded but not implemented in this emulator |
| API | comprehend DetectSentiment | ✅ |  |
| API | translate TranslateText | ✅ |  |
| API | rekognition ListCollections | ✅ |  |
| API | polly SynthesizeSpeech | ✅ |  |
| API | sagemaker ListNotebookInstances | ⛔ 501 | HTTP 501 NotImplemented: operation ListNotebookInstances is scaffolded but not implemented in this emulator |
| API | wellarchitected ListWorkloads | ✅ |  |
| API | license-manager ListLicenseConfigurations | ✅ |  |
| 동작 | drs: 초기화 전 호출 → UninitializedAccountException (AWS와 동일) | ✅ 동작 | UninitializedAccountException: Elastic Disaster Recovery has not been initialized for this account; call InitializeService first |
| 동작 | mgn: 초기화 전 호출 → UninitializedAccountException (AWS와 동일) | ✅ 동작 | UninitializedAccountException: Account not initialized |
| 동작 | health: Business 이상 지원 플랜 필요 → SubscriptionRequiredException (AWS와 동일) | ✅ 동작 | SubscriptionRequiredException: You must have a Business, Enterprise On-Ramp, or Enterprise Support plan from Amazon Web Services Support to use the Health API. |
| 동작 | support(Trusted Advisor API): 유료 지원 플랜 필요 → SubscriptionRequiredException (AWS와 동일) | ✅ 동작 | SubscriptionRequiredException: Amazon Web Services Premium Support Subscription is required to use this service. |
