# M10 치트시트

## 무엇으로 무엇을 보나

| 질문 | 서비스 |
|---|---|
| 숫자가 얼마고 추세가 어떤가 | CloudWatch **지표** |
| 기준을 넘으면 알리거나 조치 | CloudWatch **알람** (→ SNS, Auto Scaling, EC2 동작, OpsItem) |
| 그때 무슨 일이 있었나 (앱 로그) | CloudWatch **Logs** (+ Logs Insights) |
| 요청 하나가 어디서 느렸나 | **X-Ray** (새 계측은 OpenTelemetry/ADOT 권장) |
| 누가 어떤 API를 호출했나 (감사) | **CloudTrail** (M09) |
| 리소스 설정이 규칙을 지키나 / 설정 변경 이력 | **AWS Config** (M09) |
| 인프라를 코드로 반복 생성 | **CloudFormation** |
| 서버 접속·명령·패치 | **Systems Manager** |

## CloudWatch 지표

| 항목 | 값 |
|---|---|
| 지표 정체성 | 네임스페이스 + 지표 이름 + 차원(최대 30개). 차원 조합이 다르면 다른 지표 |
| 해상도 | 표준 1분 / 고해상도 1초(`StorageResolution=1`) |
| 고해상도 알람 Period | 10초·30초 (또는 60초 배수) |
| 보존 | <60초: 3시간 · 1분: 15일 · 5분: 63일 · 1시간: 455일(15개월) |
| 삭제 | 불가. 새 데이터가 없으면 15개월 뒤 만료 |
| EC2 기본 모니터링 | 5분, 무료 · 세부 모니터링 1분, 유료 |
| EC2 기본 지표에 **없는 것** | **메모리, 디스크 사용률/여유 공간**, 프로세스 → **CloudWatch 에이전트** |

## 알람

| 설정 | 의미 |
|---|---|
| Period × EvaluationPeriods, DatapointsToAlarm | "최근 N개 중 M개 위반이면 ALARM" |
| TreatMissingData | `missing`(보류) · `notBreaching` · `breaching`(끊기면 장애) · `ignore` |
| 상태 | `OK` / `ALARM` / `INSUFFICIENT_DATA`. 액션은 상태가 **바뀔 때** (예외: **Auto Scaling 액션은 그 상태에 머무는 동안 1분마다 반복**) |
| 액션 종류 | SNS · Lambda · Auto Scaling · EC2 동작(중지·종료·재부팅·복구) · SSM OpsItem/Incident Manager |
| 복합 알람 | `ALARM("a") AND ALARM("b")` — 알람 피로 감소. 지울 때 복합 알람 먼저. **EC2·Auto Scaling 액션 불가** |
| `set-alarm-state` | 알림 경로 테스트용, 다음 평가에서 원래대로 |
| 지표 수학 | `100*errors/requests` 에 알람 |

## CloudWatch Logs

| 항목 | 값 |
|---|---|
| 구조 | 로그 그룹(설정 단위) > 로그 스트림(출처) > 로그 이벤트 |
| 보존 기간 | 기본 **무기한**. 허용 값: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653일 |
| 지표 필터 | 로그 패턴 → 지표. **만든 뒤의 로그에만** 적용 |
| 구독 필터 | 실시간 전달 → Kinesis Data Streams / Data Firehose / Lambda / (OpenSearch) |
| 내보내기 | S3로 일괄 내보내기(실시간 아님) |
| Logs Insights | `fields`, `filter`, `stats ... by`, `sort`, `limit` — 비동기 쿼리 |
| 필터 패턴 | `ERROR` · `"payment failed"` · `{ $.status >= 500 }` |
| EMF | 로그 JSON 안의 `_aws.CloudWatchMetrics` 블록 → 지표 자동 생성 |

## CloudFormation

| 기능 | 언제 |
|---|---|
| 파라미터 / 매핑 / 조건 | 환경별 값 / 리전별 조회표 / 조건부 리소스 |
| Outputs + Export / `Fn::ImportValue` | 스택 간 값 공유 (Export 이름은 리전에서 유일, import 중이면 삭제 불가) |
| 변경 세트 | 실행 전 변경 미리보기, **Replacement** 확인 |
| 드리프트 감지 | 스택 밖에서 바뀐 것 찾기 (고치지는 않음) |
| 롤백 | 생성 실패 → `ROLLBACK_COMPLETE`(삭제만 가능), 업데이트 실패 → `UPDATE_ROLLBACK_COMPLETE` |
| StackSets | 여러 계정 × 여러 리전 배포 |
| 중첩 스택 | 템플릿 재사용·500개 리소스 한도 넘기 |
| DeletionPolicy | `Retain` / `Snapshot` / `Delete` / `RetainExceptOnCreate` |
| UpdateReplacePolicy | 교체될 때 옛 리소스 `Retain` / `Snapshot` |
| CreationPolicy + cfn-signal | 부트스트랩 완료 신호까지 생성 완료를 미룸 |
| 롤백 트리거 | 배포 직후 CloudWatch 알람이 울리면 롤백 |
| 종료 보호 / 스택 정책 | 스택 삭제 방지 / 특정 리소스 업데이트 방지 |
| 한도 | 템플릿당 리소스 500 · 파라미터 200 · 출력 200 · 본문 51,200바이트(S3 URL이면 1 MB) |

내장 함수: `!Ref` · `!GetAtt` · `!Sub` · `!Join` · `!Select` · `!Split` · `!FindInMap` · `!ImportValue` · `!Cidr` · `!If` · `!Equals`

## Systems Manager

| 기능 | 키워드 |
|---|---|
| Session Manager | 인바운드 포트·SSH 키·배스천 없이 셸, 세션 로그 |
| Run Command | 여러 인스턴스에 명령 |
| Patch Manager + Maintenance Windows | OS 패치 자동화 |
| Parameter Store | 설정·비밀 계층 저장 (SecureString = KMS) |
| Automation / State Manager | 런북 자동화 / 원하는 상태 유지 |
| 관리형 노드 조건 | SSM Agent + `AmazonSSMManagedInstanceCore` + SSM 엔드포인트 경로(NAT 또는 VPC 엔드포인트 `ssm`·`ssmmessages`·`ec2messages`) |

## 운영 지원 서비스

| 서비스 | 한 줄 |
|---|---|
| Trusted Advisor | 비용·보안·성능·내결함성·한도 점검 (전체 점검·API는 Business Support+ / Enterprise / Unified Operations — 옛 Business·Developer 플랜은 2027-01-01 종료) |
| Health Dashboard | AWS 이벤트가 **내 리소스**에 미치는 영향 (+EventBridge) |
| Service Quotas | 한도 조회·증가 요청 (EIP 기본 5/리전) |
| Compute Optimizer | 적정 크기 권고 (옵트인) |
| License Manager | 라이선스 사용량 추적·강제 |
| Service Catalog | 승인된 템플릿 셀프서비스 |
| Proton | 플랫폼 팀 템플릿으로 앱 배포 표준화 — **2026-10-07 지원 종료**(시험 범위 목록에는 남아 있음) |
| Managed Grafana / Managed Prometheus | 관리형 대시보드 / PromQL 지표 저장 |
| Well-Architected Tool | 6개 기둥 검토 |

## 에뮬레이터에서 기억할 것

- `AWS/EC2` 지표 없음 · 알람은 데이터로 실제 전이 · SNS 알림은 큐 정책이 있어야 SQS에 도착.
- CloudFormation은 2초 간격 `describe-stacks` 폴링으로 기다린다(CLI `wait`로 기다리면 NAT 경로가 실패).
- VPC 스택 변경 세트는 501 롤백 · 드리프트는 S3·SQS만 믿을 것.
- Session Manager·Patch Manager 501.
