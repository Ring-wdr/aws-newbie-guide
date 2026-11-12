# 에뮬레이터 충실도(FIDELITY) 보고서

> 이 문서는 `tools/probe/probe.py` 실행 결과(`tools/probe/results.json`)와 사람이 쓴 판정(`tools/probe/notes.md`)으로 **자동 생성**된다. 직접 고치지 말고 두 파일을 고친 뒤 다시 생성한다.

| 항목 | 값 |
|---|---|
| 에뮬레이터 버전 | `1.0.322` (릴리스 2026.11.10) |
| 에뮬레이터 커밋 | `7753983c6e495ec3612695b1336bf4936fc7b7fd` |
| 탐침 실행 시각 | 2026-11-12 11:45 UTC |
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

에뮬레이터 1.0.322(2026-11-10 릴리스)는 **설계 시점의 예상(CURRICULUM.md)보다 훨씬 많이 "실제로" 동작한다.** 가장 큰 차이 다섯 가지:

1. **Lambda `Invoke`가 함수 코드를 실제로 실행한다** (CURRICULUM은 501로 예상). 동기 호출은 핸들러의 반환값을, 예외는 `FunctionError=Unhandled`를 돌려준다. `/aws/lambda/<함수>` 로그 그룹은 **실행 역할에 logs 권한이 있을 때만** 생긴다(AWS와 같음). SQS→Lambda 이벤트 소스 매핑은 큐의 메시지를 실제로 소비하고, API Gateway(HTTP API)→Lambda 프록시도 실행된다.
2. **서비스 간 전달이 실제로 일어난다.** SNS→SQS(필터 정책 포함), S3 이벤트→SQS, EventBridge 규칙→SQS, Pipes, Step Functions 실행(SQS 서비스 통합 포함), CloudWatch 경보→SNS→SQS, S3 복제, Firehose→S3가 모두 관찰됐다.
3. **IAM 정책은 "평가하지 않는다"가 아니라 "서비스마다 다르다".** 사용자에게 붙인 정책을 IAM·EC2·KMS·STS(신뢰 정책)는 평가해 거부하고(명시적 Deny 우선도 재현), S3·SQS·DynamoDB는 평가하지 않는다. 반면 S3 **버킷 정책**의 명시적 Deny, **KMS 키 정책**의 Deny, CloudFront OAC↔버킷 정책, 서비스 역할의 신뢰 정책(Step Functions·Pipes·Glue·Backup·Cognito 자격 증명 풀)은 집행된다. `iam simulate-custom-policy`/`simulate-principal-policy`도 올바르게 판정한다.
4. **VPC·EC2 컨트롤 플레인은 🟢 수준이다.** 서브넷이 AZ·CIDR과 함께 저장되고(/24 → 사용 가능 IP 251), CIDR 범위·중복 오류, NAT 게이트웨이 pending→available, 게이트웨이 엔드포인트의 prefix-list 경로, TGW가 AWS처럼 동작한다. EC2 인스턴스는 pending→running→stopped→terminated로 상태가 바뀐다(부팅은 안 함).
5. **"리소스 자체의 엔드포인트"는 컨테이너 안에서만 산다.** RDS는 실제 DB 엔진(PostgreSQL 프로토콜 응답)을, ALB·CloudFront는 실제 HTTP 응답을 내지만 그 포트가 `127.0.0.1:<임의 포트>`로 **컨테이너 안에** 열려 학습자의 Mac에서는 닿지 않는다. `docker exec aws-emulator-$EMULATOR_PORT curl ...` 로만 확인할 수 있다.

남은 공백(501)은 대부분 **조정·관리 계열**이다: Auto Scaling 정책·예약 작업·수명 주기 후크 전부, Organizations SCP·계정, VPC 피어링 수락·Egress-only IGW·VPN, AMI 생성(`CreateImage`/`RegisterImage`), `ModifyInstanceAttribute`, Glue 크롤러, SSM Session Manager, Cost Explorer.

환경 측정: 빈 에뮬레이터 컨테이너는 약 **174 MiB**, 전체 탐침(Lambda 실행·RDS 엔진·ECS 포함)을 돌리는 동안 최대 **약 325 MiB**. 그래서 스크립트 기본 메모리 상한을 공식 가이드의 2g 대신 **1g**로 두었다(`EMULATOR_MEMORY`로 변경).

## 서비스별 결과

API 열은 `성공/시도`, 동작 열은 `실제처럼 관찰/검사`. 등급 근거의 ✍️ 는 사람이 판정한 것, 🤖 는 자동 제안이다.

| 모듈 | 서비스 | 등급 | API | 501 | 기타 오류 | 동작 | 근거 |
|---|---|---|---|---|---|---|---|
| M00 | [`client-config`](#svc-client-config) | 🟢 | 1/1 |  |  | 5/5 | ✍️ 127.0.0.1 필수·S3 Control 도달 불가·호스트 접두사 문제가 문서대로 재현됨 |
| M01 | [`iam`](#svc-iam) | 🟢 | 22/22 |  |  | 9/13 | ✍️ CRUD·정책 버전·시뮬레이터 완전. IAM API 자체는 권한도 평가. 단 S3·SQS·DynamoDB에 대한 사용자 정책은 무시됨 |
| M01 | [`sts`](#svc-sts) | 🟢 | 6/6 |  |  | 4/4 | ✍️ AssumeRole 임시 자격 증명·신뢰 정책 거부까지 재현 (키 접두사만 ASIA가 아니라 EMULATOR) |
| M01 | [`organizations`](#svc-organizations) | 🟡 | 3/9 | 6 |  | 1/1 | ✍️ 조직·루트·OU만. SCP 활성화·생성·목록·연결(EnablePolicyType·CreatePolicy·ListPolicies·AttachPolicy), 계정 생성·목록은 501 |
| M02 | [`ec2-vpc`](#svc-ec2-vpc) | 🟢 | 40/43 | 3 |  | 26/27 | ✍️ VPC·서브넷·라우팅·IGW·NAT·SG·NACL·엔드포인트·TGW 🟢. 피어링 수락·Egress-only IGW·VPN 501. 트래픽은 흐르지 않음 |
| M03 | [`ec2-instances`](#svc-ec2-instances) | 🟡 | 15/18 | 3 |  | 9/9 | ✍️ 상태 전이는 실제처럼 관찰되지만 부팅·사용자 데이터 실행 없음. DescribeInstanceStatus·ModifyInstanceAttribute·DescribeTags 501 |
| M03 | [`ebs-ami`](#svc-ebs-ami) | 🟡 | 15/18 | 2 | 1 | 10/10 | ✍️ 볼륨·스냅샷·시작 템플릿(버전 포함) OK. CreateImage·RegisterImage 501, 스냅샷에서 볼륨 복원 실패 |
| M03 | [`elbv2`](#svc-elbv2) | 🟡 | 10/10 |  |  | 8/9 | ✍️ 구성 전부 OK, ALB가 컨테이너 안에서 HTTP 응답. 호스트에서 접속 불가, 대상 헬스는 검사 없이 healthy |
| M03 | [`autoscaling`](#svc-autoscaling) | 🟡 | 3/8 | 5 |  | 5/6 | ✍️ ASG가 Desired만큼 인스턴스를 띄움. 조정 정책·예약·수명 주기 후크 전부 501, 자가 치유 없음 |
| M04 | [`s3`](#svc-s3) | 🟢 | 45/45 |  |  | 36/38 | ✍️ 버전·삭제 마커·미리 서명 URL(curl)·멀티파트·객체 잠금·복제·이벤트 알림·버킷 정책 Deny 모두 실제처럼. 수명 주기 전환은 시간이 흘러도 안 일어남 |
| M04 | [`efs`](#svc-efs) | 🟡 | 7/7 |  |  | 4/5 | ✍️ 파일 시스템·마운트 타깃·액세스 포인트 생성. 마운트 타깃 IP가 서브넷 CIDR을 따르지 않음, 마운트 불가 |
| M05 | [`rds`](#svc-rds) | 🟡 | 16/16 |  |  | 11/13 | ✍️ 인스턴스·복제본·스냅샷·Aurora 클러스터 OK, 컨테이너 안에 실제 DB. 호스트 접속 불가, Multi-AZ 장애 조치 재현 안 됨 |
| M05 | [`dynamodb`](#svc-dynamodb) | 🟢 | 28/28 |  |  | 24/24 | ✍️ 키 설계·Query/Scan·조건부 쓰기·GSI·Streams·트랜잭션·TTL·PITR 모두 실제처럼 |
| M05 | [`elasticache`](#svc-elasticache) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 클러스터·복제 그룹 available, 엔드포인트에 실제 캐시 서버 없음 |
| M06 | [`sqs`](#svc-sqs) | 🟢 | 19/19 |  |  | 16/16 | ✍️ 가시성 타임아웃·DLQ·재처리·롱 폴링·지연·FIFO 순서/중복 제거·1 MiB 제한 모두 재현 |
| M06 | [`sns`](#svc-sns) | 🟢 | 22/22 |  |  | 9/9 | ✍️ SQS 구독 전달·필터 정책(속성/본문)·Raw 전달·FIFO 재현. 큐 정책이 없으면 전달 안 됨(AWS와 동일) |
| M06 | [`eventbridge`](#svc-eventbridge) | 🟢 | 15/15 |  |  | 4/4 | ✍️ 패턴 일치 이벤트만 SQS 대상에 전달, Pipes 전달, Scheduler 생성 |
| M06 | [`stepfunctions`](#svc-stepfunctions) | 🟢 | 11/11 |  |  | 6/6 | ✍️ 실행이 SUCCEEDED/FAILED까지, 이력, SQS 서비스 통합, EXPRESS 동기 실행 |
| M06 | [`kinesis`](#svc-kinesis) | 🟢 | 12/12 |  |  | 6/6 | ✍️ 상태 전이·파티션 키→샤드·GetRecords 순서·리샤딩 |
| M07 | [`lambda`](#svc-lambda) | 🟢 | 26/26 |  |  | 15/15 | ✍️ 생성·버전·별칭·동시성·Invoke(실제 실행)·이벤트 소스 매핑 소비·함수 URL 발급. 로그 그룹은 역할에 logs 권한이 있을 때만 생김 |
| M07 | [`apigateway`](#svc-apigateway) | 🟢 | 15/15 |  |  | 1/1 | ✍️ REST API MOCK 통합을 `https://127.0.0.1:<포트>/_aws/execute-api/<id>/<stage>/<경로>` 로 실제 호출 |
| M07 | [`apigatewayv2`](#svc-apigatewayv2) | 🟢 | 11/11 |  |  | 3/3 | ✍️ HTTP API → Lambda 프록시 실제 실행. Lambda 리소스 정책(AddPermission) 없이도 통과함은 AWS와 다름 |
| M07 | [`ecr`](#svc-ecr) | 🟢 | 7/7 |  |  | 1/1 | ✍️ 저장소·수명 주기 정책·인증 토큰 (이미지 푸시는 시험 안 함) |
| M07 | [`ecs`](#svc-ecs) | 🟡 | 6/6 |  |  | 1/2 | ✍️ 클러스터·작업 정의·서비스 생성. 태스크는 이미지 풀 실패로 STOPPED |
| M07 | [`cognito`](#svc-cognito) | 🟢 | 12/12 |  |  | 5/5 | ✍️ 사용자 풀 가입·확인·로그인으로 JWT 발급, 자격 증명 풀 임시 자격 증명 |
| M08 | [`route53`](#svc-route53) | 🟡 | 13/13 |  |  | 6/7 | ✍️ 영역·레코드(라우팅 정책 전부)·TestDNSAnswer OK. 상태 확인은 시뮬레이션(항상 Success), 실제 DNS 질의 불가 |
| M08 | [`cloudfront`](#svc-cloudfront) | 🟡 | 5/6 | 1 |  | 4/5 | ✍️ 배포·OAC·캐시 정책·무효화 생성, 컨테이너 안에서 HTTP 응답. 호스트 접속 불가, TestFunction 501 |
| M08 | [`globalaccelerator`](#svc-globalaccelerator) | 🟡 | 3/3 |  |  | 1/1 | ✍️ 가속기·리스너·엔드포인트 그룹, 정적 IP 2개 표시. 트래픽 없음 |
| M08 | [`wafv2`](#svc-wafv2) | 🟡 | 6/6 |  |  | 2/2 | ✍️ IP 세트·Web ACL(속도 기반·관리형 규칙)·ALB 연결 저장. 차단 동작은 시험 안 함 |
| M09 | [`kms`](#svc-kms) | 🟢 | 20/20 |  |  | 13/13 | ✍️ 암복호화·데이터 키(봉투)·서명·교체·삭제 예약·다중 리전 키·키 정책 Deny 집행 |
| M09 | [`secretsmanager`](#svc-secretsmanager) | 🟢 | 9/10 |  | 1 | 6/6 | ✍️ 버전 스테이지 이동·복구. RotateSecret은 Lambda 권한이 필요(AWS와 동일) |
| M09 | [`ssm`](#svc-ssm) | 🟢 | 15/16 | 1 |  | 8/9 | ✍️ 파라미터 계층·SecureString·버전·레이블. Session Manager 501, 공개 리전 파라미터 없음 |
| M09 | [`acm`](#svc-acm) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 가져온 인증서는 ISSUED. DNS 검증 인증서는 PENDING_VALIDATION에서 끝나지 않음 |
| M09 | [`cloudtrail`](#svc-cloudtrail) | 🟡 | 5/5 |  |  | 3/4 | ✍️ 추적·로깅·S3에 로그 파일. LookupEvents에 IAM 이벤트는 나오고 S3 이벤트는 안 나옴 |
| M09 | [`config`](#svc-config) | 🟢 | 8/8 |  |  | 3/3 | ✍️ 기록기·전달 채널(버킷 정책 검사)·관리형 규칙이 실제로 NON_COMPLIANT 판정 |
| M09 | [`guardduty`](#svc-guardduty) | 🟡 | 8/8 |  |  | 2/2 | ✍️ 탐지기·샘플 결과. 실제 위협 탐지는 없음 |
| M10 | [`cloudwatch`](#svc-cloudwatch) | 🟢 | 9/9 |  |  | 7/8 | ✍️ 사용자 지정 지표, 경보가 데이터로 스스로 ALARM 전이, SNS 액션 전달, 복합 경보. AWS/EC2 기본 지표 없음 |
| M10 | [`logs`](#svc-logs) | 🟢 | 9/9 |  |  | 6/6 | ✍️ 로그 그룹·이벤트·FilterLogEvents·지표 필터→지표·Insights 쿼리 |
| M10 | [`cloudformation`](#svc-cloudformation) | 🟡 | 12/12 |  |  | 12/13 | ✍️ 스택 생성이 리소스를 실제로 만들고 Outputs·드리프트·롤백·삭제까지. 단 VPC 스택 변경 세트는 IGW 연결 갱신 501로 롤백 |
| M11 | [`firehose`](#svc-firehose) | 🟢 | 4/4 |  |  | 2/2 | ✍️ S3에 실제 객체가 생김. 단 버퍼 시간을 무시하고 수 초 만에 씀 |
| M11 | [`glue`](#svc-glue) | 🟡 | 8/10 | 2 |  | 2/2 | ✍️ 데이터베이스·테이블·작업 생성. 크롤러 실행·GetPartitions 501 |
| M11 | [`athena`](#svc-athena) | 🟢 | 4/4 |  |  | 2/3 | ✍️ Glue 테이블(S3 JSON)에 SQL이 실제로 실행되어 결과 반환. 결과 파일은 S3에 안 씀 |
| M12 | [`backup`](#svc-backup) | 🟢 | 4/5 | 1 |  | 2/2 | ✍️ 볼트·계획·선택, 온디맨드 백업 작업 COMPLETED와 복구 지점. ListCopyJobs 501 |
| M12 | [`dms`](#svc-dms) | 🟡 | 5/6 | 1 |  | 1/1 | ✍️ 복제 인스턴스·엔드포인트·작업 생성. TestConnection 501, 실제 복제 없음 |
| M13 | [`budgets`](#svc-budgets) | 🟡 | 4/5 | 1 |  | 1/1 | ✍️ 예산·알림 저장(실제 지출 0). Cost Explorer GetCostAndUsage 501 |
| M13 | [`tagging`](#svc-tagging) | 🟡 | 3/3 |  |  | 1/2 | ✍️ TagResources 동작. GetResources가 SQS만 찾고 S3·DynamoDB·EC2는 못 찾음 |
| 기타 | [`misc-optional`](#svc-misc-optional) | 🟡 | 27/29 | 2 |  | 4/4 | ✍️ 시험 범위 "한눈에" 서비스들: 대부분 호출 가능. QuickSight·SageMaker 일부 501 |

## 설계와 다른 점 (모듈 저자 필독)

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

## 501 NotImplemented 오퍼레이션

| 모듈 | 서비스 | 오퍼레이션/동작 |
|---|---|---|
| M01 | `organizations` | EnablePolicyType(SCP) |
| M01 | `organizations` | CreatePolicy(SCP) |
| M01 | `organizations` | ListPolicies(SCP) |
| M01 | `organizations` | AttachPolicy(FullAWSAccess → OU) |
| M01 | `organizations` | CreateAccount |
| M01 | `organizations` | ListAccounts |
| M02 | `ec2-vpc` | CreateEgressOnlyInternetGateway |
| M02 | `ec2-vpc` | AcceptVpcPeeringConnection |
| M02 | `ec2-vpc` | CreateVpnConnection |
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
| M08 | `cloudfront` | TestFunction |
| M09 | `ssm` | StartSession |
| M11 | `glue` | GetPartitions |
| M11 | `glue` | StartCrawler |
| M12 | `backup` | ListCopyJobs |
| M12 | `dms` | TestConnection |
| M13 | `budgets` | ce GetCostAndUsage |
| 기타 | `misc-optional` | quicksight ListDashboards |
| 기타 | `misc-optional` | sagemaker ListNotebookInstances |

## 501 이외의 오류와 AWS와 다른 동작

탐침 입력이 잘못됐을 가능성도 있으니, 실습에 쓰기 전에 직접 재현해 볼 것.

| 모듈 | 서비스 | 오퍼레이션/동작 | 상태 | 상세 |
|---|---|---|---|---|
| M01 | `iam` | 정책 없는 사용자의 s3:ListAllMyBuckets 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| M01 | `iam` | 명시적 Deny(s3:*)가 ListBuckets를 막음 | ⚠️ 다름 | 허용됨 — 명시적 Deny도 집행되지 않는다 |
| M02 | `ec2-vpc` | 피어링 수락 후 active | ⚠️ 다름 | 최종 pending-acceptance |
| M03 | `ebs-ami` | CreateVolume(SnapshotId=… 스냅샷에서 복원) | ❌ | HTTP 400 InvalidSnapshot.NotFound: The snapshot 'snap-0000000000000009e' does not exist. |
| M03 | `elbv2` | 호스트(macOS)에서 ALB DNSName으로 직접 연결 | ⚠️ 다름 | ConnectionRefusedError — 리스너 포트가 컨테이너 밖으로 게시되지 않음 |
| M03 | `autoscaling` | 인스턴스를 직접 종료하면 ASG가 대체 인스턴스를 띄움(자가 치유) | ⚠️ 다름 | 20초 후에도 종료된 인스턴스가 ASG에 ['InService/Healthy'] 로 남음 |
| M04 | `s3` | STANDARD_IA 전환 30일 미만 → InvalidArgument | ⚠️ 다름 | 기대 InvalidArgument, 실제로는 성공했다 |
| M04 | `s3` | KMS 키를 비활성화하면 SSE-KMS 객체 읽기 실패 | ⚠️ 다름 | 읽힘 — S3가 KMS 키 상태를 확인하지 않음 |
| M04 | `efs` | AZ별 마운트 타깃 IP가 해당 서브넷(10.30.x.x) 안에 있음 | ⚠️ 다름 | [('us-east-1a', '10.0.0.4', 'creating'), ('us-east-1b', '10.0.1.4', 'creating')] |
| M05 | `rds` | 호스트(macOS)에서 Endpoint 포트로 TCP 연결 | ⚠️ 다름 | 연결 불가(포트가 컨테이너 밖에 게시되지 않음) |
| M05 | `rds` | 강제 장애 조치 후 AZ가 바뀜 | ⚠️ 다름 | us-east-1a → us-east-1a |
| M05 | `elasticache` | 엔드포인트 포트에 실제 캐시 서버가 떠 있음(컨테이너 안 TCP) | ⚠️ 다름 | 컨테이너 안: CLOSED |
| M07 | `ecs` | RunTask 태스크가 RUNNING까지 전이 (실제로 이미지를 받아 실행하려 함) | ⚠️ 다름 | 전이 PROVISIONING → PENDING → STOPPED; stoppedReason=CannotPullContainerError: failed to resolve ref public.ecr.aws/nginx/nginx:latest: failed to do request: Get " |
| M08 | `route53` | 상태 확인이 실제로 대상을 검사함(존재하지 않는 도메인 → 실패여야 함) | ⚠️ 다름 | 관찰 8건 ['Success: HTTP Status Code 200, OK', 'Success: HTTP Status Code 200, OK'] — 존재하지 않는 대상인데 Success면 시뮬레이션된 결과 |
| M08 | `cloudfront` | 배포 도메인 이름(*.cloudfront.net) 발급 | ⚠️ 다름 | DomainName=127.0.0.1:40875 Status=InProgress — 에뮬레이터는 컨테이너 안의 로컬 포트를 준다 |
| M09 | `secretsmanager` | RotateSecret(Lambda ARN 지정) | ❌ | HTTP 400 AccessDeniedException: Secrets Manager cannot invoke the specified Lambda function. Ensure that the function policy grants access to the principal secretsmanager.amazonaws.com. |
| M09 | `ssm` | 공개 파라미터(리전 목록)가 들어 있음 | ⚠️ 다름 | 0개 |
| M09 | `acm` | Route 53에 검증 CNAME을 만들면 ISSUED로 전환(20초 대기) | ⚠️ 다름 | PENDING_VALIDATION |
| M09 | `cloudtrail` | S3 CreateBucket이 LookupEvents(이벤트 기록)에 나타남 | ⚠️ 다름 |  |
| M10 | `cloudwatch` | 기본 EC2 지표(AWS/EC2)가 저절로 생김 | ⚠️ 다름 | 0개 — 인스턴스가 실제로 돌지 않으므로 없을 수 있음 |
| M10 | `cloudformation` | (VPC 스택) 변경 세트 실행 후 UPDATE_COMPLETE, 서브넷 3개 | ⚠️ 다름 | UPDATE_ROLLBACK_COMPLETE, 서브넷 2 ['IgwAttach: NotImplemented: this emulator does not change the properties of an existing AWS::EC2::VPCGatewayAttachment in '] |
| M11 | `athena` | 쿼리 결과 파일이 작업 그룹 결과 위치(S3)에 저장됨 | ⚠️ 다름 | results/ 아래 0개, 버킷 전체 ['orders/dt=2026-11-01/p.json'] |
| M13 | `tagging` | 태그로 S3·SQS·DynamoDB·VPC를 한 번에 찾음 | ⚠️ 다름 | {'s3': False, 'sqs': True, 'dynamodb': False, 'ec2': False} |

## 서비스별 상세

<a id="svc-client-config"></a>

### M00 · client-config

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBucket(127.0.0.1) | ✅ |  |
| 동작 | boto3 + localhost 엔드포인트로 S3 HeadBucket | ✅ 동작 | boto3(Python)는 localhost여도 경로 방식으로 보내 성공한다 (JS/Java/Go SDK는 가상 호스트 방식이라 실패한다고 문서에 명시) |
| 동작 | 가상 호스트 방식(<bucket>.localhost)은 실패해야 함 | ✅ 동작 | EndpointConnectionError: Could not connect to the endpoint URL: "https://todayorder-probe-cfgbucket-abaf7654.localhost:9297/" |
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
| 동작 | IAM 사용자 액세스 키로 서명한 요청을 받아 줌 | ✅ 동작 | arn:aws:iam::000000000000:user/todayorder-probe-user-abaf7654 |
| 동작 | 권한 없는 사용자의 iam:CreateUser가 거부됨(암묵적 Deny) | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 s3:ListAllMyBuckets 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 sqs:ListQueues 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 dynamodb:ListTables 거부(암묵적 Deny) | ⚠️ 다름 | 허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다 |
| 동작 | 정책 없는 사용자의 ec2:DescribeVpcs 거부(암묵적 Deny) | ✅ 동작 | UnauthorizedOperation |
| 동작 | 정책 없는 사용자의 iam:ListUsers 거부(암묵적 Deny) | ✅ 동작 | AccessDenied |
| 동작 | 정책 없는 사용자의 kms:ListKeys 거부(암묵적 Deny) | ✅ 동작 | AccessDeniedException |
| 동작 | Allow iam:ListUsers 를 붙이면 허용됨 | ✅ 동작 | 허용 |
| 동작 | 명시적 Deny iam:ListUsers 가 Allow를 이김 | ✅ 동작 | AccessDenied |
| 동작 | 명시적 Deny(s3:*)가 ListBuckets를 막음 | ⚠️ 다름 | 허용됨 — 명시적 Deny도 집행되지 않는다 |

<a id="svc-sts"></a>

### M01 · sts

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | GetCallerIdentity | ✅ |  |
| 동작 | 계정 ID가 000000000000 | ✅ 동작 | arn:aws:iam::000000000000:user/emulator |
| API | CreateRole(사전) | ✅ |  |
| API | AssumeRole | ✅ |  |
| 동작 | AssumeRole 임시 자격 증명(SessionToken, Expiration 포함) | ✅ 동작 | AccessKeyId 접두사=EMUL (실제 AWS는 ASIA) |
| 동작 | 임시 자격 증명으로 호출하면 assumed-role ARN | ✅ 동작 | arn:aws:sts::000000000000:assumed-role/todayorder-probe-assume-abaf7654/probe |
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
| 동작 | 라우팅 테이블에 local 경로 + IGW 경로 | ✅ 동작 | [('10.0.0.0/16', 'local'), ('0.0.0.0/0', 'igw-00000000000000112')] |
| 동작 | VPC 생성 시 기본(main) 라우팅 테이블 자동 생성 | ✅ 동작 | 1개 |
| API | AllocateAddress | ✅ |  |
| API | CreateNatGateway | ✅ |  |
| 동작 | NAT 게이트웨이 pending→available | ✅ 동작 | 생성 직후 pending |
| API | CreateRoute(0.0.0.0/0 → NAT) | ✅ |  |
| 동작 | NAT 게이트웨이에 EIP 공인 IP가 붙음 | ✅ 동작 | [{'AllocationId': 'eipalloc-00000000000000115', 'NetworkInterfaceId': 'eni-00000000000000116', 'PrivateIp': '10.0.1.4',  |
| API | CreateEgressOnlyInternetGateway | ⛔ 501 | HTTP 501 NotImplemented: operation CreateEgressOnlyInternetGateway is scaffolded but not implemented in this emulator |
| API | CreateSecurityGroup(web) | ✅ |  |
| API | CreateSecurityGroup(app) | ✅ |  |
| API | CreateSecurityGroup(db) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(0.0.0.0/0:443 → web) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(SG 참조 web→app) | ✅ |  |
| API | AuthorizeSecurityGroupIngress(SG 참조 app→db) | ✅ |  |
| 동작 | SG 체이닝 규칙이 조회됨(db ← app 참조) | ✅ 동작 | ['sg-0000000000000011c'] |
| 동작 | 새 SG의 기본 아웃바운드 전체 허용 규칙 | ✅ 동작 | [{'IpProtocol': '-1', 'UserIdGroupPairs': [], 'IpRanges': [{'CidrIp': '0.0.0.0/0'}], 'Ipv6Ranges': [], 'PrefixListIds':  |
| API | DescribeSecurityGroupRules | ✅ |  |
| 동작 | DescribeSecurityGroupRules가 규칙을 반환 | ✅ 동작 | 2개 |
| 동작 | 같은 규칙 중복 추가 → InvalidPermission.Duplicate | ✅ 동작 | InvalidPermission.Duplicate: the specified rule "peer: 0.0.0.0/0, TCP, from port: 443, to port: 443, ALLOW" already exists |
| 동작 | 다른 SG가 참조 중인 SG 삭제 → DependencyViolation | ✅ 동작 | DependencyViolation: resource sg-0000000000000011c has a dependent object |
| API | CreateNetworkAcl | ✅ |  |
| API | CreateNetworkAclEntry(100 allow 443) | ✅ |  |
| API | CreateNetworkAclEntry(90 deny 203.0.113.0/24) | ✅ |  |
| API | CreateNetworkAclEntry(egress 100 allow 1024-65535) | ✅ |  |
| 동작 | NACL 규칙 번호·allow/deny·기본 * deny(32767) 조회 | ✅ 동작 | [(90, 'deny', False), (100, 'allow', False), (100, 'allow', True), (32767, 'deny', False), (32767, 'deny', True)] |
| 동작 | 같은 규칙 번호 중복 → NetworkAclEntryAlreadyExists | ✅ 동작 | NetworkAclEntryAlreadyExists: The network acl entry identified by 100 already exists. |
| API | ReplaceNetworkAclAssociation | ✅ |  |
| API | CreateVpcEndpoint(Gateway S3) | ✅ |  |
| 동작 | 게이트웨이 엔드포인트가 라우팅 테이블에 prefix list 경로 추가 | ✅ 동작 | [{'DestinationPrefixListId': 'pl-e9da6b72', 'GatewayId': 'vpce-00000000000000125', 'Origin': 'CreateRoute', 'State': 'active'}] |
| API | CreateVpcEndpoint(Interface SQS) | ✅ |  |
| 동작 | 인터페이스 엔드포인트 ENI·DNS 항목 | ✅ 동작 | ENI ['eni-00000000000000126'] DNS 2개 |
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
| 동작 | 서브넷이 남은 VPC 삭제 → DependencyViolation | ✅ 동작 | DependencyViolation: The vpc 'vpc-00000000000000106' has dependencies and cannot be deleted. |

<a id="svc-ec2-instances"></a>

### M03 · ec2-instances

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | SSM GetParameter(/aws/service/ami-amazon-linux-latest/al2023…) | ✅ |  |
| 동작 | 사용 가능한 AMI 확보 | ✅ 동작 | ami-0000000000000004c |
| API | CreateKeyPair | ✅ |  |
| 동작 | CreateKeyPair가 개인 키(KeyMaterial)를 반환 | ✅ 동작 | 71:e9:a4:83:47:8c:ea:09:7f:14:de:0e:3b:c |
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
| 동작 | ALB DNSName 발급 | ✅ 동작 | 127.0.0.1:42025 |
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
| 동작 | ALB 리스너가 실제로 HTTP를 처리(컨테이너 안에서 fixed-response 규칙 확인) | ✅ 동작 | DNSName=127.0.0.1:42025 → hello-from-alb HTTP200 |
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
| 동작 | Max 초과 Desired → ValidationError | ✅ 동작 | ValidationError: New SetDesiredCapacity value 10 is above max value 4 for the AutoScalingGroup: todayorder-probe-asg-abaf7654 |
| API | DescribeScalingActivities | ⛔ 501 | HTTP 501 NotImplemented: operation DescribeScalingActivities is scaffolded but not implemented in this emulator |
| 동작 | 인스턴스를 직접 종료하면 ASG가 대체 인스턴스를 띄움(자가 치유) | ⚠️ 다름 | 20초 후에도 종료된 인스턴스가 ASG에 ['InService/Healthy'] 로 남음 |

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
| 동작 | 버전 관리 켠 뒤 PutObject마다 VersionId 발급 | ✅ 동작 | e1a977e512112e3c074795ca858b4486 / 671e229e94ff57252b5467adc25547e3 |
| API | DeleteObject(버전 관리 버킷) | ✅ |  |
| 동작 | 삭제하면 삭제 마커(DeleteMarker=true)가 생김 | ✅ 동작 | VersionId=0cd86c64bc203aa85963230f138d1afc |
| 동작 | 삭제 마커가 최신이면 GetObject → NoSuchKey | ✅ 동작 | NoSuchKey: The specified key does not exist. |
| API | ListObjectVersions | ✅ |  |
| 동작 | ListObjectVersions: 버전 2개 + 삭제 마커 1개 | ✅ 동작 | Versions=2 DeleteMarkers=1 |
| API | GetObject(VersionId=첫 버전) | ✅ |  |
| 동작 | 이전 버전 내용 복구 가능 | ✅ 동작 |  |
| 동작 | 삭제 마커를 지우면 객체가 되살아남 | ✅ 동작 |  |
| API | PutBucketLifecycleConfiguration | ✅ |  |
| API | GetBucketLifecycleConfiguration | ✅ |  |
| 동작 | 수명 주기 규칙 왕복(전환은 시간이 지나도 실제로 일어나지 않음 — 확인 불가) | ✅ 동작 |  |
| 동작 | STANDARD_IA 전환 30일 미만 → InvalidArgument | ⚠️ 다름 | 기대 InvalidArgument, 실제로는 성공했다 |
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
| 동작 | 퍼블릭 액세스 차단 상태에서 퍼블릭 정책 → AccessDenied | ✅ 동작 | AccessDenied: User: arn:aws:iam::000000000000:user/emulator is not authorized to perform: s3:PutBucketPolicy on resource: "arn:aws:s3:::todayorder-probe-main-abaf7654" becaus |
| API | GetBucketOwnershipControls | ✅ |  |
| 동작 | 기본 객체 소유권(BucketOwnerEnforced)에서 ACL 설정 → AccessControlListNotSupported | ✅ 동작 | AccessControlListNotSupported: The bucket does not allow ACLs |
| API | PutBucketEncryption(SSE-S3) | ✅ |  |
| 동작 | 기본 암호화 SSE-S3 → HeadObject ServerSideEncryption=AES256 | ✅ 동작 | AES256 |
| API | PutObject(SSE-KMS) | ✅ |  |
| 동작 | SSE-KMS 객체 HeadObject에 aws:kms·키 ID | ✅ 동작 | aws:kms 5b58816d-2ee6-482e-8522-f82901412abf |
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
| 동작 | 기본 보존 기간이 객체에 적용됨 | ✅ 동작 | GOVERNANCE 2026-11-13 11:45:04+00:00 |
| 동작 | 보존 중인 객체 버전 삭제 → AccessDenied | ✅ 동작 | AccessDenied: Access Denied because object protected by object lock. |
| API | PutObject(StorageClass=GLACIER) | ✅ |  |
| 동작 | StorageClass=GLACIER 저장 | ✅ 동작 | GLACIER |
| 동작 | 복원 전 GLACIER 객체 읽기 → InvalidObjectState | ✅ 동작 | InvalidObjectState: The operation is not valid for the object's storage class |
| API | RestoreObject(Days=1, Standard) | ✅ |  |
| 동작 | 복원 요청 후 HeadObject Restore 헤더 | ✅ 동작 | ongoing-request="true" |
| API | PutObject(INTELLIGENT_TIERING) | ✅ |  |
| API | PutBucketAccelerateConfiguration | ✅ |  |
| API | PutBucketRequestPayment(Requester) | ✅ |  |

<a id="svc-efs"></a>

### M04 · efs

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateFileSystem(generalPurpose, Encrypted) | ✅ |  |
| 동작 | 파일 시스템 creating→available | ✅ 동작 | 생성 직후 creating |
| 동작 | 같은 CreationToken 재사용 → FileSystemAlreadyExists(멱등성) | ✅ 동작 | FileSystemAlreadyExists: File system 'fs-e220a8397b1dcdaf1' already exists with creation token 'todayorder-probe-efs-abaf7654' |
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
| 동작 | Endpoint 주소·포트 반환 | ✅ 동작 | 127.0.0.1:37367 |
| 동작 | MultiAZ·SecondaryAvailabilityZone 표시 | ✅ 동작 | MultiAZ=True AZ=us-east-1a Secondary=None |
| 동작 | Endpoint 포트에 실제 DB가 떠 있음(컨테이너 안 TCP) | ✅ 동작 | 컨테이너 안: OPEN |
| 동작 | Endpoint가 PostgreSQL 프로토콜로 응답(SSLRequest → 'S'/'N') | ✅ 동작 | 응답 'S' |
| 동작 | 호스트(macOS)에서 Endpoint 포트로 TCP 연결 | ⚠️ 다름 | 연결 불가(포트가 컨테이너 밖에 게시되지 않음) |
| API | CreateDBInstanceReadReplica | ✅ |  |
| 동작 | 읽기 복제본이 원본을 가리킴 | ✅ 동작 | Source=todayorder-probe-db-abaf7654; 원본 Replicas=['todayorder-probe-db-rr-abaf7654'] |
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
| 동작 | Aurora 클러스터 엔드포인트(쓰기)·리더 엔드포인트 | ✅ 동작 | 127.0.0.1 / todayorder-probe-aurora-abaf7654.cluster-ro-00000000000v.us-east-1.rds.amazonaws.com |
| API | CreateDBInstance(Aurora 클러스터 인스턴스) | ✅ |  |
| 동작 | 클러스터 멤버(쓰기 인스턴스)로 조회됨 | ✅ 동작 | [{'DBInstanceIdentifier': 'todayorder-probe-aurora-1-abaf7654', 'IsClusterWriter': True, 'DBClusterParameterGroupStatus' |
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
| 동작 | Streams 켜면 LatestStreamArn 발급 | ✅ 동작 | -abaf7654/stream/2026-11-12T11:41:54.667 |
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
| 동작 | 기본(쓰기)·리더 엔드포인트 반환 | ✅ 동작 | Primary=master.to-rg-abaf7654.000001.us-east-1.cache.amazonaws.com:6379 Reader=replica.to-rg-abaf7654.000001.us-east-1.cache.amazonaws.com members=2 |
| 동작 | 엔드포인트 포트에 실제 캐시 서버가 떠 있음(컨테이너 안 TCP) | ⚠️ 다름 | 컨테이너 안: CLOSED |
| API | TestFailover | ✅ |  |
| API | CreateCacheCluster(memcached 2노드) | ✅ |  |
| 동작 | Memcached 클러스터 available + 구성 엔드포인트 | ✅ 동작 | available {'Address': 'to-mc-abaf7654.000004.cfg.us-east-1.cache.amazonaws.com', 'Port': 11211} |
| API | CreateServerlessCache(valkey) | ✅ |  |

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
| 동작 | 롱 폴링: 빈 큐에서 WaitTimeSeconds=2 만큼 대기 | ✅ 동작 | 2.1s 대기 |
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
| 동작 | email 구독은 확인 대기 상태 | ✅ 동작 | 654:584289af-bca4-4ad3-96b2-98fd4c3c48f6 |
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
| 동작 | Pipes: 역할 신뢰 정책에 pipes.amazonaws.com 이 없으면 CREATE_FAILED | ✅ 동작 | CREATE_FAILED: Pipes cannot assume the execution role arn:aws:iam::000000000000:role/todayorder-probe-pipebad-abaf7654: its trust polic |
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
| 동작 | 실행 역할에 sqs:SendMessage 가 없으면 Task가 AccessDenied로 FAILED (IAM 평가됨) | ✅ 동작 | status=FAILED error=SQS.AmazonSQSException cause=User: arn:aws:iam::000000000000:role/todayorder-probe-sfnrole-abaf7654 is not authorized t |
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
| 동작 | 핸들러 예외 → FunctionError=Unhandled, errorType 반환 | ✅ 동작 | FunctionError=Unhandled payload={"errorMessage":"boom","errorType":"ValueError","requestId":"5e20e73e-198b-4181-b9f5-dccafc1a167d"," |
| 동작 | Invoke 후 /aws/lambda/<함수> 로그 그룹이 생김(실행 역할에 logs:* 권한이 있을 때) | ✅ 동작 |  |
| API | Invoke(DryRun) | ✅ |  |
| 동작 | DryRun은 204 반환(실행 없이 권한·파라미터만 검사) | ✅ 동작 | StatusCode=204 |
| API | Invoke(Event, 비동기) | ✅ |  |
| 동작 | 비동기 Invoke는 202 반환 | ✅ 동작 | StatusCode=202 |
| 동작 | 없는 함수 Invoke → ResourceNotFoundException | ✅ 동작 | ResourceNotFoundException: Function not found: arn:aws:lambda:us-east-1:000000000000:function:todayorder-probe-nope-abaf7654:$LATEST |
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
| 동작 | 함수 URL 발급 | ✅ 동작 | https://0e61738bf7ac4bf5997f684120a522f9.lambda-url.us-east-1.on.aws/ |
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
| 동작 | 배포된 REST API(MOCK)를 HTTPS로 실제 호출 | ✅ 동작 | 성공 URL=https://127.0.0.1:9297/_aws/execute-api/eocd2yo7iw/dev/orders |
| API | CreateApiKey | ✅ |  |
| API | CreateUsagePlan(throttle+quota) | ✅ |  |
| API | CreateUsagePlanKey | ✅ |  |
| API | CreateAuthorizer(COGNITO_USER_POOLS) | ✅ |  |

<a id="svc-apigatewayv2"></a>

### M07 · apigatewayv2

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateApi(HTTP) | ✅ |  |
| 동작 | HTTP API 엔드포인트 URL 발급 | ✅ 동작 | https://127.0.0.1:9297/_aws/execute-api/mp67t4dbd4 |
| API | CreateIntegration(HTTP_PROXY) | ✅ |  |
| API | CreateRoute(GET /orders) | ✅ |  |
| API | CreateStage($default, AutoDeploy) | ✅ |  |
| API | GetRoutes | ✅ |  |
| API | CreateAuthorizer(JWT) | ✅ |  |
| API | CreateFunction(API용) | ✅ |  |
| API | CreateApi(HTTP, Lambda 프록시) | ✅ |  |
| API | CreateIntegration(AWS_PROXY → Lambda, 2.0) | ✅ |  |
| 동작 | HTTP API → Lambda 프록시를 HTTPS로 호출하면 함수가 실행되어 응답 (AddPermission 없이도 성공) | ✅ 동작 | https://127.0.0.1:9297/_aws/execute-api/e77k44w5b0/orders → 200 {"echo": {"version": "2.0", "routeKey": "GET /orders", "rawPath": "/orders", "rawQueryStri |
| 동작 | 실행 역할에 logs 권한이 없으면 /aws/lambda/<함수> 로그 그룹이 생기지 않음(AWS와 동일) | ✅ 동작 | 생기지 않음 |
| API | CreateApi(WEBSOCKET) | ✅ |  |
| API | CreateRoute($connect) | ✅ |  |

<a id="svc-ecr"></a>

### M07 · ecr

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateRepository(scanOnPush, IMMUTABLE) | ✅ |  |
| 동작 | 저장소 URI 발급 | ✅ 동작 | 000000000000.dkr.ecr.us-east-1.amazonaws.com/todayorder-probe-api-abaf7654 |
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
| 동작 | RunTask 태스크가 RUNNING까지 전이 (실제로 이미지를 받아 실행하려 함) | ⚠️ 다름 | 전이 PROVISIONING → PENDING → STOPPED; stoppedReason=CannotPullContainerError: failed to resolve ref public.ecr.aws/nginx/nginx:latest: failed to do request: Get " |
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

<a id="svc-route53"></a>

### M08 · route53

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateHostedZone(퍼블릭) | ✅ |  |
| 동작 | 퍼블릭 호스팅 영역에 NS/SOA 기본 레코드와 위임 세트 | ✅ 동작 | NameServers=['ns-1575.awsdns-10.com', 'ns-1386.awsdns-19.net'] |
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
| 동작 | 영역 apex에 CNAME을 만들면 InvalidChangeBatch로 거부 | ✅ 동작 | InvalidChangeBatch: [RRSet of type CNAME with DNS name abaf7654.todayorder.example. is not permitted at apex in zone abaf7654.todayorder.example.] |
| API | ListResourceRecordSets | ✅ |  |
| 동작 | 레코드 목록에 생성한 레코드가 모두 보임 | ✅ 동작 | 15개, 유형 ['A', 'CNAME', 'NS', 'SOA'] |
| API | TestDNSAnswer(가중치) | ✅ |  |
| 동작 | TestDNSAnswer가 가중치 레코드 중 하나를 응답 | ✅ 동작 | RecordData=['192.0.2.1'] ResponseCode=NOERROR |
| 동작 | 실제 DNS 질의(dig) | ⏭️ | 에뮬레이터는 HTTPS API 포트 하나만 노출한다. 컨테이너에서 DNS(53) 포트를 내보내지 않으므로 dig로 확인 불가 |

<a id="svc-cloudfront"></a>

### M08 · cloudfront

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateOriginAccessControl | ✅ |  |
| API | CreateCachePolicy | ✅ |  |
| API | CreateDistribution(S3 오리진 + OAC) | ✅ |  |
| 동작 | 배포 도메인 이름(*.cloudfront.net) 발급 | ⚠️ 다름 | DomainName=127.0.0.1:40875 Status=InProgress — 에뮬레이터는 컨테이너 안의 로컬 포트를 준다 |
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
| 동작 | 다중 리전 키 ID는 mrk- 접두사 | ✅ 동작 | mrk-3154 |
| API | ReplicateKey(us-west-2) | ✅ |  |
| API | ScheduleKeyDeletion(7일) | ✅ |  |
| 동작 | 삭제 예약 후 KeyState=PendingDeletion | ✅ 동작 | PendingDeletion |
| 동작 | 삭제 대기 중인 키로 Encrypt하면 KMSInvalidStateException | ✅ 동작 | KMSInvalidStateException: arn:aws:kms:us-east-1:000000000000:key/3d533cd1-80d5-42be-83e3-e1048852bf63 is pending deletion. |
| API | CancelKeyDeletion | ✅ |  |
| 동작 | 삭제 대기 기간 7일 미만은 거부 | ✅ 동작 | ValidationException:  |

<a id="svc-secretsmanager"></a>

### M09 · secretsmanager

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateSecret | ✅ |  |
| 동작 | ARN 끝에 무작위 6자 접미사 | ✅ 동작 | todayorder-probe-db-abaf7654/password-MYc9FE |
| API | GetSecretValue | ✅ |  |
| API | PutSecretValue | ✅ |  |
| 동작 | 새 값 저장 시 AWSCURRENT → 새 버전, AWSPREVIOUS → 이전 버전 | ✅ 동작 | {'28f3c2e2-527a-4b62-8b35-a2d8506a39b9': ['AWSPREVIOUS'], '2b256c79-72cb-4c61-bf4e-93d9e70e5d66': ['AWSCURRENT']} |
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
| 동작 | WithDecryption 없이 조회하면 암호문이 반환됨 | ✅ 동작 | ASQ2ZWNjMzY0Yy00NTY5LTRiYzktYTkwNi1hNTEx |
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
| 동작 | DNS 검증용 CNAME 레코드(ResourceRecord) 제공 | ✅ 동작 | Status=PENDING_VALIDATION RR={'Name': '_07c06476d5e74dc4070b261267bf8313.api.abaf7654.todayorder.example.', 'Type': 'CNAME', 'Value': '_6fd1dc9b5998c98e88dfee8aba8bad1a.b069271fe3.acm-validations.aws. |
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
| 동작 | Config 전달 채널: 버킷 정책이 없으면 거부(버킷 정책을 평가함) | ✅ 동작 | InsufficientDeliveryPolicyException: Insufficient delivery policy to s3 bucket: todayorder-probe-nopolicy-abaf7654, unable to get s3 bucket acl. |
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

<a id="svc-cloudwatch"></a>

### M10 · cloudwatch

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | PutMetricData(사용자 지정 네임스페이스·차원) | ✅ |  |
| API | ListMetrics(네임스페이스) | ✅ |  |
| 동작 | 게시한 지표가 ListMetrics에 보임 | ✅ 동작 | 1개 |
| API | GetMetricStatistics | ✅ |  |
| 동작 | 데이터 포인트 집계(평균 200, 표본 3, 최댓값 300) | ✅ 동작 | [{'Timestamp': datetime.datetime(2026, 11, 12, 20, 43, tzinfo=tzlocal()), 'SampleCount': 3.0, 'Average': 200.0, 'Maximum': 300.0, 'Unit': 'Millisecond |
| API | GetMetricData | ✅ |  |
| 동작 | GetMetricData 합계 600 | ✅ 동작 | [600.0] |
| API | ListMetrics(AWS/EC2) | ✅ |  |
| 동작 | 기본 EC2 지표(AWS/EC2)가 저절로 생김 | ⚠️ 다름 | 0개 — 인스턴스가 실제로 돌지 않으므로 없을 수 있음 |
| API | PutMetricAlarm(SNS 액션) | ✅ |  |
| 동작 | 임계값 초과 데이터만으로 알람이 스스로 ALARM이 됨(25초 대기, Period=10) | ✅ 동작 | 처음 INSUFFICIENT_DATA → ALARM |
| API | DescribeAlarmHistory | ✅ |  |
| 동작 | 알람 상태 변경 이력이 기록됨 | ✅ 동작 | 1건 |
| 동작 | 알람 액션: SNS → 구독한 SQS 큐로 알림 도착 | ✅ 동작 | 1건 {"Version":"1.0","AlarmName":"todayorder-probe-latency-high-abaf7654","AWSAccountId":"000000000000", |
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
| 동작 | 지표 필터: ERROR 로그 2건 → CloudWatch 지표 ErrorCount 합계 2 | ✅ 동작 | [{'Timestamp': datetime.datetime(2026, 11, 12, 20, 43, tzinfo=tzlocal()), 'Sum': 2.0, 'Unit': 'None'}] |
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
| 동작 | 선언한 리소스가 EC2 API로 실제 조회됨(VPC·서브넷 2·IGW 연결·0.0.0.0/0 라우트·SG) | ✅ 동작 | vpc=vpc-00000000000000143 subnets=2 igw=1 routes=['local', 'igw-0000000000000014f'] sg=1 |
| 동작 | Outputs(Ref, Fn::GetAtt) 값 | ✅ 동작 | {'VpcId': 'vpc-00000000000000143', 'PublicSubnetA': 'subnet-0000000000000014b', 'VpcCidrOut': '10.20.0.0/16'} |
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

<a id="svc-firehose"></a>

### M11 · firehose

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBucket(대상) | ✅ |  |
| API | CreateDeliveryStream(S3, 버퍼 60초/1MB) | ✅ |  |
| 동작 | 전송 스트림 ACTIVE | ✅ 동작 |  |
| API | PutRecord | ✅ |  |
| API | PutRecordBatch | ✅ |  |
| 동작 | 버퍼 시간(60초) 안팎에 S3 객체가 실제로 생김 | ✅ 동작 | 3s 대기, 객체 ['orders/2026/11/12/11/todayorder-probe-orders-abaf7654-1-2026-11-12-11-43-08-0-4afabccc-9f6f-4bdc-a711-233fe70b60fa'] |

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

<a id="svc-backup"></a>

### M12 · backup

| 종류 | 오퍼레이션/동작 | 결과 | 상세 |
|---|---|---|---|
| API | CreateBackupVault | ✅ |  |
| API | CreateBackupPlan(일일 + 복사 액션) | ✅ |  |
| API | CreateBackupSelection(태그 기준) | ✅ |  |
| API | StartBackupJob(DynamoDB 테이블) | ✅ |  |
| 동작 | 백업 작업이 COMPLETED, 복구 지점 생성 | ✅ 동작 | State=COMPLETED RecoveryPoint=int:18e74989-a096-0bfb-0000-000000000007 |
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
