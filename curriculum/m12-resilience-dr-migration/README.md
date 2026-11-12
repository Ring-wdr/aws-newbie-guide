# M12. 고가용성·DR·마이그레이션

> 시나리오: TodayOrder 12단계 — "한 리전의 가용 영역에서 전원 장애" 뉴스를 본 팀장이 묻는다. "우리는 AZ 하나가 죽으면? 리전이 죽으면? 아직 사무실에 있는 DB는 언제 옮기지?"
> 도메인: D2 (시험 비중 26%) · 예상 시간: 약 4시간

## 목표

- 가용성 숫자를 읽고, 아키텍처 그림에서 단일 장애점(SPOF)을 찾아 AZ 단위로 고칠 수 있다.
- RTO/RPO 요구를 듣고 DR 4전략(백업·복원, 파일럿 라이트, 웜 스탠바이, 다중 사이트) 중 가장 비용 효율적인 것을 고를 수 있다.
- AWS Backup(볼트·계획·선택·복사·Vault Lock)과 Elastic Disaster Recovery의 용도를 설명하고, 온디맨드 백업을 실행할 수 있다.
- 7R로 이전 방식을 고르고, Application Discovery Service·MGN·DMS/SCT·Migration Hub·DataSync·Snow의 용도를 구분할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [가용성 숫자 읽기, 단일 장애점 찾기, AZ·리전 단위 설계](./01-availability-and-spof.md) | 55분 | 🟢 |
| 2 | [RTO/RPO와 DR 4전략 — 에뮬레이터 두 개로 "리전 장애" 겪어 보기](./02-rto-rpo-dr-strategies.md) | 60분 | 🟡 |
| 3 | [AWS Backup, 스냅샷 교차 리전 복사, Elastic Disaster Recovery](./03-aws-backup-and-dr-services.md) | 55분 | 🟢 / 🟡 |
| 4 | [마이그레이션: 7R, Application Discovery Service, DMS/SCT, MGN, Migration Hub, Snow/DataSync](./04-migration.md) | 55분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 워크시트: TodayOrder v1 SPOF 찾기 (모범 답안 포함) | (레슨 문서 안) | 1 | — |
| 단일 장애점 찾기와 고치기 (NAT·서버·RDS) | [labs/lab01-spof-hunt.sh](./labs/lab01-spof-hunt.sh) | 1 | 🟢 구성 수준 |
| 워크시트: 시나리오별 DR 전략 고르기 (모범 답안 포함) | (레슨 문서 안) | 2 | — |
| 다중 리전 DR: 에뮬레이터 두 개로 파일럿 라이트 + 장애 조치 런북 | [labs/lab02-multi-region-dr.sh](./labs/lab02-multi-region-dr.sh) | 2 | 🟡 |
| AWS Backup 볼트·계획·선택, 온디맨드 백업과 복구 지점, 복사, 복원, Vault Lock | [labs/lab03-aws-backup.sh](./labs/lab03-aws-backup.sh) | 3 | 🟢 (복원 데이터 🟡) |
| DMS 복제 인스턴스·엔드포인트·작업 구성 | [labs/lab04-dms-config.sh](./labs/lab04-dms-config.sh) | 4 | 🟡 |
| boto3: SPOF 감사 도구 | [sdk/spof_audit.py](./sdk/spof_audit.py) | 1 | 🟢 |
| boto3: 리전을 모르는 주문 앱 | [sdk/order_app.py](./sdk/order_app.py) | 2 | 🟢 |
| boto3: 서울 → 도쿄 데이터 복제 (두 에뮬레이터) | [sdk/dr_replicate.py](./sdk/dr_replicate.py) | 2 | 🟡 |
| boto3: 태그 기반 온디맨드 백업 | [sdk/backup_tagged_tables.py](./sdk/backup_tagged_tables.py) | 3 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297 DR_EMULATOR_PORT=9298   # 둘 다 명시. 비대화형 실행에서는 DR_EMULATOR_PORT 가 없으면 거부
curriculum/m12-resilience-dr-migration/labs/verify.sh
```

`verify.sh`는 **에뮬레이터 두 개**를 다룬다. 주 리전 `$EMULATOR_PORT`와 DR 리전 `$DR_EMULATOR_PORT`를 둘 다 재시작해 깨끗하게 만든다. **`DR_EMULATOR_PORT`는 명시해야 한다**: 비대화형(에이전트·CI)에서 없으면 아무것도 지우기 전에 거부하고, 터미널에서 직접 실행할 때만 `EMULATOR_PORT + 1`을 쓴다(연속된 포트는 다른 사람의 에뮬레이터일 수 있어서). 두 포트가 같아도 거부한다. 그다음 sdk 예제의 안전 장치를 확인한다. env.sh 없이 실행하면 네트워크 호출 전에 거부되는지, 그리고 DR 엔드포인트가 실제 AWS 주소면 `dr_replicate.py`가 DR 클라이언트를 만들기 전에 거부되는지 본다. 이어서 모든 lab을 **두 번씩** 실행하고 sdk 예제를 실행한다. 끝나면 성공·실패와 관계없이 **DR 리전 에뮬레이터를 끈다**. 마지막 줄이 `MODULE m12 OK`면 통과.

### 두 번째 에뮬레이터("DR 리전")를 쓰는 방법

| | 주 리전 "서울" | DR 리전 "도쿄" |
|---|---|---|
| 포트 | `EMULATOR_PORT` | `DR_EMULATOR_PORT` — 명시 필수 (대화형 터미널에서만 생략 시 `EMULATOR_PORT + 1`) |
| 셸 연결 | `source scripts/env.sh` → `AWS_ENDPOINT_URL` 등 | `source labs/dr-env.sh` → `DR_AWS_ENDPOINT_URL`, `DR_AWS_CA_BUNDLE`, `DR_AWS_SHARED_CREDENTIALS_FILE`, `DR_AWS_CONFIG_FILE` (모두 `~/.aws/emulator/<포트>/`에서) |
| CLI | `aws …` | `dr_aws …` (dr-env.sh가 정의하는 함수) |
| boto3 | 평소처럼 (환경 변수) | `dr_replicate.py`가 `DR_…` 값을 잠시 `AWS_…` 이름으로 바꿔 끼우고 `require_emulator()`를 다시 통과한 뒤 클라이언트 생성 |
| 안전 장치 | env.sh: 계정 `000000000000` 확인 / `require_emulator()` | dr-env.sh: 같은 확인 / 같은 `require_emulator()` |

두 에뮬레이터 모두 **기술적으로는 `us-east-1`**이다. "서울/도쿄"는 이름일 뿐이며, 리전 간 네트워크·관리형 복제(CRR, Aurora Global 등)는 재현하지 않는다. 장애 조치는 `EMULATOR_PORT`를 바꿔 `source scripts/env.sh`를 다시 하는 것으로 흉내 낸다(레슨 2의 런북).

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

| 오퍼레이션 / 동작 | 증상 | 이 모듈의 대응 |
|---|---|---|
| 리전 분리 | 없음. 모든 리전 이름이 같은 저장소 | 포트가 다른 두 번째 에뮬레이터로 "DR 리전" 흉내(lab02) |
| Backup `CreateBackupSelection` | 신뢰 정책이 `backup.amazonaws.com`이 아닌 역할(또는 없는 역할)은 `InvalidParameterValueException: IAM Role cannot be assumed by AWS Backup` (AWS와 같음) | lab03에서 거부를 먼저 보여 줌 |
| Backup `StartBackupJob` | 신뢰 정책이 틀린 역할, **존재하지 않는 역할·리소스 ARN**으로도 `COMPLETED` | lab은 올바른 역할·리소스만 사용. 문서에 차이 명시 |
| Backup `StartRestoreJob` | `COMPLETED`, 새 DynamoDB 테이블이 생기지만 **항목은 복원되지 않음**(0개) | 복원은 🟡. lab은 0개임을 출력(데이터가 생기면 "문서 갱신 필요" 안내) |
| Backup `ListCopyJobs`, `ListBackupPlans`, `ListRestoreJobs`, `ListRecoveryPointsByResource`, `GetRecoveryPointRestoreMetadata`, `ListProtectedResources`, `DescribeRegionSettings` | `501 NotImplemented` | 작업 ID로 `describe-*` 조회. 계획 ID는 볼트 태그에 적어 두고 정리에 사용 |
| Backup `StartCopyJob`/`DescribeCopyJob` | 동작(같은 에뮬레이터 안의 다른 볼트로 COMPLETED) | 다른 리전 볼트 대신 같은 리전 두 번째 볼트 |
| Backup Vault Lock | 집행됨: 잠긴 볼트의 복구 지점 삭제 → `InvalidRequestException … (Backup vault configured with Lock)` | lab03에서 거버넌스 모드로 시연 후 해제 |
| Backup `CreateBackupPlan` 같은 이름 | `AlreadyExistsException` | 위의 계획 ID 태그로 이전 계획 삭제 후 생성 |
| DMS `TestConnection`, `DescribeConnections`, `DescribeTableStatistics`, `StopReplicationTask`, `DeleteReplicationInstance`, `DeleteEndpoint`, `DescribeReplicationSubnetGroups` | `501 NotImplemented` | 작업은 시작하지 않음(시작하면 `running`에서 멈출 수 없음). 복제 인스턴스·엔드포인트·서브넷 그룹은 "있으면 재사용" |
| DMS `StartReplicationTask` | 원본이 없는데도 `running`, 데이터 이동 없음. `running` 작업은 삭제 거부(`InvalidResourceStateFault`) | lab에서 시작하지 않음 |
| DMS `CreateEndpoint`·`CreateReplicationTask` 검증 | 없는 엔진 이름(`foodb`)·JSON이 아닌 테이블 매핑도 받아들임 | 문서에 명시 |
| EC2 `ReplaceRouteTableAssociation` | `501 NotImplemented` | `disassociate-route-table` + `associate-route-table`로 대체(lab01) |
| Auto Scaling `--target-group-arns` | ASG 인스턴스가 대상 그룹에 **자동 등록되지 않음**, `DescribeLoadBalancerTargetGroups` 501 | lab01이 `register-targets`로 수동 등록 |
| ELB 등록 해제 | 해제한 대상이 `draining`으로 남음(실제도 지연 시간 동안 draining) | 감사기는 draining 대상을 세지 않음 |
| RDS Multi-AZ | `modify-db-instance --multi-az`로 `MultiAZ=True`가 되지만 `SecondaryAvailabilityZone` 없음, 장애 조치 재현 안 됨 | 구성 수준 감사만(🟢 구성) |
| Elastic Disaster Recovery / MGN | `InitializeService` 후 `DescribeSourceServers`는 빈 목록(복제할 실제 서버 없음) | 개념으로만 다룸 |
| Application Discovery Service | `DescribeAgents` 501 | 개념으로만 다룸 |

## 설계 대비 대체 사유

- CURRICULUM의 실습 4개를 모두 구현했다: 🟢 AWS Backup(lab03), 🟢 SPOF 워크시트(레슨 1 워크시트 + lab01), 🟡 DMS 구성(lab04), 🟡 다중 리전 DR(lab02).
- AWS Backup은 🟢로 확정했다(볼트·계획·선택·온디맨드 백업 COMPLETED·복구 지점·복사·Vault Lock 집행). 단 **복원 결과에 데이터가 없어** 복원 부분만 🟡로 표시했다. 신뢰 정책 검사는 `StartBackupJob`이 아니라 `CreateBackupSelection`에서 일어남을 확인했다.
- SPOF 찾기는 워크시트(손)에 더해, 같은 구성을 에뮬레이터에 만들고 boto3 감사 도구로 찾고 고치는 lab01로 보강했다(구성 정보 기반이라 🟢).
- DR 리전 포트는 추측하지 않는다: `dr-env.sh`·lab02·`verify.sh`는 비대화형 실행에서 `DR_EMULATOR_PORT`가 없으면 거부한다. lab02는 단독 실행 후 DR 에뮬레이터를 켜 둔 채 끝나므로 끄는 명령을 안내한다.
- 다중 리전 DR(lab02)은 `docker pause`로 주 리전 장애를 흉내 낸다. 학습자 자신의 에뮬레이터 컨테이너(`aws-emulator-$EMULATOR_PORT`)만 잠시 멈추며, 스크립트가 중간에 실패해도 `trap`으로 반드시 되살린다.
- 레슨 4의 서비스 중 Migration Hub·Application Discovery Service는 2025-11-07부터 신규 고객에게 제공되지 않고(후속: AWS Transform), Snowball Edge는 기존 고객 전용이 되었다. 시험 대비를 위해 용도는 다루되 이 사실을 레슨에 명시했다.
