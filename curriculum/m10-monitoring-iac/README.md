# M10. 모니터링·운영·IaC

> 시나리오: 새벽 3시, TodayOrder 주문 API가 느려졌는데 고객 문의가 쌓인 뒤에야 알았다. 숫자를 모으고(지표), 기준을 넘으면 사람을 깨우고(알람), 원인을 찾고(로그), 인프라를 다시 똑같이 세울 수 있게(CloudFormation) 만든다.
> 도메인: D2 (복원력) · 예상 시간: 약 4시간 30분

## 목표

- 사용자 지정 지표를 게시·조회하고, 알람이 데이터로 ALARM이 되어 SNS로 알림을 보내는 경로를 구성할 수 있다. 복합 알람으로 알람 피로를 줄일 수 있다.
- 로그 그룹의 보존 기간·지표 필터·구독 필터·Logs Insights의 쓰임을 구분하고, 구조화 로그를 보낼 수 있다.
- CloudFormation 템플릿으로 2-AZ 3-티어 VPC를 만들고, Outputs·변경 세트·드리프트·롤백·삭제를 설명할 수 있다.
- Systems Manager(Session Manager·Run Command·Patch Manager)와 운영 지원 서비스(Trusted Advisor, Health, Service Quotas, Compute Optimizer 등)를 요구 사항에 맞게 고를 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [CloudWatch 지표와 알람](./01-cloudwatch-metrics-alarms.md) | 55분 | 🟢 |
| 2 | [CloudWatch Logs와 X-Ray 개요](./02-cloudwatch-logs.md) | 50분 | 🟢 |
| 3 | [CloudFormation: 인프라를 코드로](./03-cloudformation.md) | 60분 | 🟢 (드리프트 🟡, VPC 스택 변경 세트 🔴) |
| 4 | [Systems Manager: 서버를 SSH 없이 다루기](./04-systems-manager.md) | 35분 | 🔴 / 🟡 / 🟢 |
| 5 | [운영 지원 서비스 한눈에](./05-operations-support.md) | 35분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 사용자 지정 지표 게시·조회, 지표 수학, AWS/EC2 기본 지표 없음 관찰 | [labs/lab01-custom-metrics.sh](./labs/lab01-custom-metrics.sh) | 1 | 🟢 |
| 알람이 데이터로 스스로 ALARM → SNS → SQS 도착, `set-alarm-state`, 복합 알람 | [labs/lab02-alarm-sns-sqs.sh](./labs/lab02-alarm-sns-sqs.sh) | 1 | 🟢 |
| 로그 그룹·보존 기간·이벤트·지표 필터·Logs Insights | [labs/lab03-logs-metric-filter-insights.sh](./labs/lab03-logs-metric-filter-insights.sh) | 2 | 🟢 |
| CloudFormation으로 2-AZ 3-티어 VPC 재현 (EC2 API로 실재 확인, Outputs·Export, 롤백, 삭제) | [labs/lab04-cfn-vpc-3tier.sh](./labs/lab04-cfn-vpc-3tier.sh) · [templates/vpc-3tier.yaml](./labs/templates/vpc-3tier.yaml) | 3 | 🟢 (드리프트 🟡 · 변경 세트 🔴) |
| 앱 스택(S3·SQS·DynamoDB)으로 변경 세트·드리프트·종료 보호 | [labs/lab05-cfn-changeset-drift.sh](./labs/lab05-cfn-changeset-drift.sh) · [app-stack.yaml](./labs/templates/app-stack.yaml) · [app-stack-v2.yaml](./labs/templates/app-stack-v2.yaml) | 3 | 🟢 (드리프트 🟡) |
| Systems Manager 관찰: Session Manager 501, Run Command Pending, Parameter Store | [labs/lab06-ssm-observe.sh](./labs/lab06-ssm-observe.sh) | 4 | 🔴 / 🟡 / 🟢 |
| 운영 지원 서비스 설정값 읽기 (Service Quotas 등) | [labs/lab07-ops-services-read.sh](./labs/lab07-ops-services-read.sh) | 5 | 🟡 |
| boto3: 구조화 로그 전송기 (배치 전송 + EMF 지표 + Insights 확인) | [sdk/structured_logger.py](./sdk/structured_logger.py) | 2 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m10-monitoring-iac/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤, sdk 예제의 안전 장치를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성) sdk 예제를 실행한다. 4분쯤 걸린다. 마지막 줄이 `MODULE m10 OK`면 통과. lab 스크립트는 공용 도우미 [labs/_lib.sh](./labs/_lib.sh)(폴링·단언 함수)를 쓴다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

<!-- widget: progress-tracker -->

## 에뮬레이터 제약

에뮬레이터 1.0.322, 포트 9310에서 직접 확인한 것.

| 오퍼레이션 / 동작 | 증상 | 대응 |
|---|---|---|
| `AWS/EC2` 기본 지표 | 없다(인스턴스가 부팅하지 않음) | lab01은 "0개"를 관찰만. 기본 지표·CloudWatch 에이전트는 개념 |
| 알람 평가 타이밍 | 10초 Period 고해상도 알람이 몇 초 만에 ALARM | 실습은 상태를 폴링(상한 120초). 실제 AWS의 타이밍으로 설명하지 않음 |
| Logs Insights `pct()` | `Failed` | 실습은 `count/avg/max/filter/sort` 만 사용 |
| CloudFormation: CLI `wait stack-create-complete` | 3-티어 VPC 스택이 항상 `ROLLBACK_COMPLETE` (`AppDefault … was still CREATE_IN_PROGRESS when the wait for it to be created ran out`). 원인: 에뮬레이터는 스택을 **`describe-stacks`로 조회할 때만** 다음 단계로 진행시키고, 다른 리소스를 기다리는 리소스(NAT 게이트웨이를 기다리는 `AppDefault` 경로)에는 **약 10초의 마감**이 있다. 생성 직후 그 안에 스택 조회가 한 번도 오지 않으면 NAT가 이미 available이어도 경로가 "wait ran out"으로 실패한다. CLI 웨이터는 0초와 30초에 조회하므로 이 VPC 스택에서는 항상 마감을 놓치고 롤백된다. 기다리는 리소스가 없는 앱 스택(lab05)에서는 `wait`가 정상 동작한다(확인함). `describe-stacks`를 2초 간격으로 부르면 1~3초 만에 `CREATE_COMPLETE`. 실제 AWS에서는 `wait`가 정상 도구 | `_lib.sh`의 `wait_stack`이 2초 간격 폴링 |
| CloudFormation: VPC 스택 변경 세트 실행 | 서브넷만 추가해도 `IgwAttach: NotImplemented: this emulator does not change the properties of an existing AWS::EC2::VPCGatewayAttachment in place` → `UPDATE_ROLLBACK_COMPLETE` | lab04에서 실패와 롤백을 그대로 보여 주고(🔴), 변경 세트 실습은 앱 스택(lab05, 🟢) |
| CloudFormation: 드리프트 감지 | S3(버전 관리)·SQS(가시성 타임아웃) 속성 차이는 정확. 그러나 IGW·라우팅 테이블·연결·경로·NAT·EIP·DynamoDB 테이블은 실제로 있어도 `DELETED`, 보안 그룹 인바운드 규칙 추가는 `IN_SYNC`(놓침) | 드리프트는 🟡. 단언은 S3·SQS의 `MODIFIED`로만 |
| SSM `StartSession`, `DescribePatchBaselines`, `ListCommandInvocations`, `ListDocuments`, `DescribeMaintenanceWindows` | `501 NotImplemented` | 🔴 개념 + "실제 AWS에서 해 보려면" |
| SSM `SendCommand`(태그 대상) | 받아 주지만 대상 0개로 `Pending` 유지. 인스턴스 ID를 직접 주면 `InvalidInstanceId` | 🟡 관찰만 |
| SSM `DescribeInstanceInformation` | 항상 빈 목록(SSM Agent 없음) | 관찰만 |
| `support DescribeTrustedAdvisorChecks`, `health DescribeEvents` | `SubscriptionRequiredException` (실제 AWS의 Basic 플랜과 같은 동작) | 오류 자체를 학습 포인트로 |

## 설계 대비 대체 사유

- CURRICULUM.md의 M10 실습을 모두 구현했다. 등급 조정:
  - "CloudFormation으로 M02 VPC 재현(Outputs, 드리프트, 롤백)" 🟢 → (M02와 똑같은 VPC가 아니라 같은 요구의 2-AZ 3-티어 VPC — 아래 차이 표) 생성·EC2 API 확인·Outputs·롤백·삭제는 🟢, **드리프트는 🟡**(위 표: VPC 리소스 오판). 정확한 드리프트 시연은 lab05의 앱 스택으로 옮겼다.
  - VPC 스택 변경 세트는 CURRICULUM 지시대로 앱 스택으로 대체했고, VPC 스택에서의 501 롤백은 "정직한 실패 예"로 lab04에 남겼다(🔴).
- M02 모듈은 다른 저자가 병렬로 작성 중이라, 같은 요구(10.0.0.0/16, 서브넷 6개, IGW, NAT, 라우팅 테이블, SG 체인)를 이 모듈의 템플릿 [vpc-3tier.yaml](./labs/templates/vpc-3tier.yaml)로 독립 설계했다. 그래서 M02의 VPC를 그대로 재현한 것이 아니라 **같은 요구를 만족하는 자기 2-AZ 3-티어 VPC**다. M02([README "CIDR 계획"](../m02-vpc-networking/README.md#cidr-계획))와 다른 점:

  | 항목 | M02 (CLI, `labs/_lib.sh`) | M10 (CloudFormation, `vpc-3tier.yaml`) |
  |---|---|---|
  | 서브넷 CIDR (퍼블릭 / 앱 / DB, a·b) | `10.0.0.0/24`·`10.0.1.0/24` / `10.0.10.0/24`·`10.0.11.0/24` / `10.0.20.0/24`·`10.0.21.0/24` | `10.0.1.0/24`·`10.0.2.0/24` / `10.0.11.0/24`·`10.0.12.0/24` / `10.0.21.0/24`·`10.0.22.0/24` |
  | NAT 게이트웨이 | AZ마다 1개 (`todayorder-nat-a`·`-b`) | AZ a에 1개 (비용 절감용) |
  | 앱 라우팅 테이블 | AZ별 2개 (`app-rt-a → nat-a`, `app-rt-b → nat-b`) | 1개 (두 앱 서브넷 → AZ a의 NAT) |
  | 보안 그룹 | `todayorder-alb-sg` → `todayorder-app-sg` → `todayorder-db-sg` | 논리 ID `WebSg` → `AppSg` → `DbSg` (`GroupName` 미지정 — CloudFormation이 `<스택>-WebSg-<무작위>` 형식으로 이름을 붙인다) |
  | 리소스 `Name` 태그 | 모든 리소스에 `todayorder-…` | VPC(`${EnvName}-vpc`)에만 |
- 추가(보강): lab06(SSM 관찰), lab07(운영 지원 서비스 설정값 읽기) — 레슨 4·5에 손으로 만져 볼 거리를 주려는 것. sdk 예제에 EMF(로그에서 지표 추출)를 넣었다(에뮬레이터에서 동작 확인).
