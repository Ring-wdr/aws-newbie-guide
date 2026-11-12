# M03. 컴퓨트와 확장

> 시나리오: TodayOrder 3단계 — "API 서버를 띄운다. 트래픽이 늘면? 서버가 죽으면?" M02에서 만든 네트워크 위에 주문 API 서버를 올리고, 로드 밸런서와 Auto Scaling 그룹으로 무중단 구조를 만든다. 그리고 같은 서버를 더 싸게 사는 법(구매 옵션)을 고른다.
> 도메인: D2, D3, D4 · 예상 시간: 약 7시간 (레슨 5.5시간 + 실습·퀴즈)

## 목표

- 워크로드에 맞는 **인스턴스 패밀리·구매 옵션·EBS 유형**을 근거와 함께 고를 수 있다.
- AMI·사용자 데이터·IMDSv2·키 페어의 역할을 설명하고, 인스턴스 수명 주기(pending → running → stopped → terminated)를 CLI로 다룰 수 있다.
- **ALB + 대상 그룹 + ASG** 무중단 구조를 CLI로 구성하고, ALB/NLB/GWLB를 구분할 수 있다.
- 조정 정책(대상 추적·단계·단순·예약·예측)을 JSON으로 쓰고, "이 지표 값이면 몇 대?"를 손으로 계산할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [EC2 기본: AMI, 인스턴스 유형, 키 페어, 사용자 데이터, IMDSv2](./01-ec2-basics.md) | 50분 | 🟢 |
| 2 | [구매 옵션: 온디맨드, Savings Plans, 예약, 스팟, 전용, 용량 예약](./02-purchase-options.md) | 50분 | 🟡 |
| 3 | [EBS와 인스턴스 스토어 (+ AMI 읽기)](./03-ebs-and-instance-store.md) | 55분 | 🟢 / 🔴 |
| 4 | [배치 그룹, ENI·탄력적 IP, 최대 절전](./04-placement-eni-hibernation.md) | 40분 | 🟡 |
| 5 | [로드 밸런서: ALB·NLB·GWLB, 대상 그룹, 헬스 체크, 스티키 세션, 교차 영역](./05-load-balancers.md) | 55분 | 🟡 |
| 6 | [Auto Scaling: 시작 템플릿, 조정 정책, 쿨다운, 수명 주기 후크](./06-auto-scaling.md) | 60분 | 🟢 / 🔴 |
| 7 | [그 밖의 컴퓨트 한눈에](./07-other-compute.md) | 25분 | 🟡 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 인스턴스 시작·상태 전이 관찰 (부팅·사용자 데이터 실행은 없음) | [labs/lab01-instance-lifecycle.sh](./labs/lab01-instance-lifecycle.sh) | 1 | 🟢 |
| 구매 옵션 API: 스팟 요청, RI·Savings Plans 상품 읽기, 용량 예약, 전용 인스턴스·호스트 | [labs/lab02-purchase-options.sh](./labs/lab02-purchase-options.sh) | 2 | 🟡 |
| EBS 볼륨·스냅샷·암호화·다중 연결·무중단 변경 / 스냅샷에서 볼륨 복원 | [labs/lab03-ebs-volumes-snapshots.sh](./labs/lab03-ebs-volumes-snapshots.sh) | 3 | 🟢 / 🔴 |
| AMI 읽기 (`describe-images`) — AMI 생성·등록·복사(501)의 대체 | [labs/lab04-ami-read.sh](./labs/lab04-ami-read.sh) | 1, 3 | 🔴 → 읽기 실습 |
| 배치 그룹·ENI 이동·EIP 이동·최대 절전 | [labs/lab05-placement-eni-eip.sh](./labs/lab05-placement-eni-eip.sh) | 4 | 🟡 |
| ALB + 대상 그룹 + 리스너 규칙, 대상 그룹 속성, NLB | [labs/lab06-alb-target-group.sh](./labs/lab06-alb-target-group.sh) | 5 | 🟡 |
| (선택 과제) 리스너 규칙 동작을 `docker exec … curl`로 컨테이너 안에서 확인 | [labs/lab07-alb-rules-in-container.sh](./labs/lab07-alb-rules-in-container.sh) | 5 | 🟡 |
| 시작 템플릿(버전) + ASG 생성·희망 용량 변경·인스턴스 새로 고침 | [labs/lab08-launch-template-asg.sh](./labs/lab08-launch-template-asg.sh) | 6 | 🟢 |
| 조정 정책·예약 작업·수명 주기 후크 JSON 작성(501) + 자가 치유 없음 관찰 | [labs/lab09-scaling-policies-and-healing.sh](./labs/lab09-scaling-policies-and-healing.sh), [labs/policies/](./labs/policies/) | 6 | 🔴 → JSON·워크시트 |
| 그 밖의 컴퓨트: Beanstalk·Lightsail·Batch | [labs/lab10-other-compute.sh](./labs/lab10-other-compute.sh) | 7 | 🟡 |
| boto3: "이 지표 값이면 몇 대?" 워크시트 채점기 | [sdk/scaling_worksheet.py](./sdk/scaling_worksheet.py) | 6 | 🟢 (로컬 계산) |
| boto3: 태그 없는 리소스 찾기 (서비스별 describe/list 응답의 태그) | [sdk/untagged_resources.py](./sdk/untagged_resources.py) | 1, 6 | 🟢 |

모든 lab은 [labs/_lib.sh](./labs/_lib.sh)의 `m03_network`로 **M03 전용 최소 VPC**(10.30.0.0/16, `us-east-1a`·`us-east-1b` 서브넷, IGW)를 찾거나 만든다. M02의 스크립트에 의존하지 않으며, 어떤 순서로 실행해도 된다.

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m03-compute-scaling/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만들고, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전 거부)를 확인한 뒤, 모든 lab을 **정순으로 한 번, 역순으로 한 번**(멱등성·순서 무관 확인) 실행하고 sdk 예제를 실행한다. 마지막 줄이 `MODULE m03 OK`면 통과. 전체 10분 안팎 걸린다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

에뮬레이터 1.0.322에서 이 모듈의 저자가 직접 확인한 것이다([FIDELITY.md](../../docs/FIDELITY.md)에 없던 것은 ★).

| 오퍼레이션 / 동작 | 증상 | 대응 |
|---|---|---|
| 인스턴스 부팅·사용자 데이터 실행·SSH | 상태만 바뀌고 부팅하지 않는다. 사용자 데이터는 저장만 된다 | 상태 전이와 저장된 값을 관찰. 실행 결과는 "실제 AWS에서는" |
| `DescribeInstanceStatus` | 501 | 레슨 1에서 501을 그대로 보여 줌 |
| `ModifyInstanceAttribute`(인스턴스 유형 변경) | 501 | 시작 템플릿 새 버전으로 표현(lab08) |
| ★ `DeleteKeyPair` | 501. 키 페어를 지울 수 없다 | lab01은 두 번째 실행부터 기존 키 페어 재사용(`InvalidKeyPair.Duplicate`를 보여 줌) |
| ★ 종료된 인스턴스의 루트 볼륨 | `DeleteOnTermination=true`인데 삭제되지 않고 `in-use`로 남는다. 다른 데이터 볼륨도 종료 시 분리되지 않는다 | lab03은 볼륨을 먼저 떼고 인스턴스를 종료. 태그 감사(sdk)는 이 "유령 루트 볼륨"을 제외 |
| `CreateImage`, `RegisterImage`, ★ `CopyImage` | 501 | 기존 AMI 읽기 실습(lab04) |
| 스냅샷에서 볼륨 복원(`CreateVolume --snapshot-id`) | `InvalidSnapshot.NotFound` (방금 `completed`인 스냅샷인데도) | 🔴. 개념·"실제 AWS에서 해 보려면" |
| ★ `ModifySnapshotTier`(아카이브), `GetEbsDefaultKmsKeyId` | 501 | 개념으로 |
| ★ EBS IOPS:GiB 비율 | 검사하지 않음(gp3 10 GiB에 20,000 IOPS, io2 10 GiB에 100,000 IOPS 허용) | 레슨 3 표로 실제 한도를 설명 |
| ★ `run-instances --block-device-mappings`(루트 볼륨 크기·암호화) | 무시되고 AMI 기본값(8 GiB, 비암호화)으로 생성 | 레슨 4에 명시 |
| ★ 최대 절전 | 루트 볼륨 암호화 조건을 검사하지 않음. 상태 사유가 `Client.UserInitiatedShutdown` | 설정·거부 동작만 실습 |
| ★ 배치 그룹 | 분산 그룹의 AZ당 7대 제한, 클러스터 그룹의 T 유형 금지를 검사하지 않음(파티션 8개 거부는 재현) | 레슨 4 표로 설명 |
| ★ EIP | IGW 없는 VPC에서도 연결됨. 이미 연결된 EIP를 `--allow-reassociation` 없이 재연결해도 허용 | lab은 실제 AWS와 같은 방식(`--allow-reassociation`)으로 작성 |
| ★ 스팟·RI·용량 예약 | 스팟 중단 없음. RI 가격표가 결제 방식별 할인을 반영하지 않음(선결제 ÷ 8760 = No Upfront 시간당). 용량 예약을 지정해 띄워도 `AvailableInstanceCount`가 줄지 않음 | 🟡. 가격 숫자는 실제가 아님을 명시 |
| ALB 엔드포인트 | 컨테이너 안(`127.0.0.1:<포트>`)에만 열림. 호스트에서 연결 불가 | `docker exec` 선택 과제(lab07) |
| 대상 헬스 체크 | 실제 HTTP 검사 없음. 인스턴스가 running이면 healthy, 중지하면 `unhealthy/Target.Timeout` | 레슨 5에 명시 |
| ★ ALB host-header 조건 | 규칙은 저장되지만 요청에 매칭되지 않음(default로 전달). path·http-header·query-string 조건은 동작 | lab07에서 그대로 보여 주고 단언 |
| ★ ALB 리디렉션 | `Location` 호스트가 원래 호스트가 아니라 `elasticloadbalancingv2.amazonaws.com` | 상태 코드(301)만 단언 |
| ★ NLB `--subnet-mappings`의 EIP | 주소가 응답에 표시되지 않음 | 개념으로 |
| Auto Scaling `PutScalingPolicy`(전 유형), `PutScheduledUpdateGroupAction`, `PutLifecycleHook`, `DescribeScalingActivities` | 501 | 정책 JSON 작성 + CLI 파라미터 검증 + 워크시트(lab09, sdk) |
| ★ Auto Scaling `DescribePolicies`, `DescribeScheduledActions`, `DescribeLifecycleHooks`, `SetInstanceHealth`, `TerminateInstanceInAutoScalingGroup`, `EnterStandby`, `PutWarmPool`, `CreateOrUpdateTags` | 501 | 개념으로 |
| 자가 치유 | 인스턴스를 종료해도 ASG가 `InService/Healthy`로 들고 있고 교체하지 않음 | lab09에서 관찰·단언 |
| ★ ASG ↔ 대상 그룹 | `--target-group-arns`를 줘도 인스턴스가 대상 그룹에 등록되지 않음 | lab08에서 관찰 |
| ★ ASG 축소 시 종료 대상 | 기본 종료 정책(오래된 템플릿 버전 우선)과 달리 새로 뜬 인스턴스를 종료 | 워크시트 12번으로 실제 규칙을 학습 |
| ★ ASG 혼합 인스턴스 정책 | 저장되지만 첫 번째 유형의 온디맨드로만 띄움 | 개념으로 |
| ★ 시작 템플릿 → ASG 인스턴스 | 템플릿의 `TagSpecifications`·`MetadataOptions`가 ASG 인스턴스에 반영되지 않음(ASG 태그의 `PropagateAtLaunch`는 반영) | 레슨 6에 명시 |
| ★ 인스턴스 새로 고침 | **동작한다**(전체 교체, `Successful`) | 🟢 실습으로 추가(lab08) |
| ★ Elastic Beanstalk 환경 | `Ready/Green`까지 가고 리소스 이름이 기록되지만 실제 ASG·ELB는 없음. 카탈로그에 없는 솔루션 스택 이름도 허용 | 🟡 |
| EC2 `DescribeTags`, Tagging API `GetResources` | 501 / EC2 리소스를 못 찾음 | sdk는 서비스별 describe/list 응답의 `Tags` 사용 |
| ★ 일시적 SigV4 오류 | 호스트(Mac)가 잠자기에서 깨어난 직후 한동안 `SignatureDoesNotMatch` / env.sh 안전 장치 실패가 났다(시계 차이로 추정). 잠시 후 저절로 회복 | 실패하면 `scripts/emulator-status.sh` 확인 후 다시 실행 |

## 설계 대비 대체 사유

CURRICULUM.md M03의 레슨 7개와 실습을 모두 구현했다. 등급과 구성이 달라진 곳:

- **인스턴스 시작·상태 전이(🟢)**: 그대로. 추가로 `DeleteKeyPair` 501을 발견해 lab01을 키 페어 재사용 방식으로 만들었다.
- **EBS 볼륨·스냅샷(🟢) / AMI·스냅샷 복원(🔴)**: AMI 읽기를 별도 lab04로 분리했다(레슨 1·3 공용). `CopyImage`도 501임을 확인했다.
- **ALB(🟡)**: 구성은 lab06, `docker exec` 규칙 확인은 별도 **선택 과제 lab07**로 분리했다. lab07은 docker를 쓸 수 없으면 `SKIP`으로 끝난다. host-header 조건이 동작하지 않는다는 점을 새로 확인해 단언에 넣었다.
- **시작 템플릿 + ASG(🟢)**: 그대로. **인스턴스 새로 고침이 동작**해 롤링 교체 실습을 추가했다.
- **조정 정책·예약 작업·수명 주기 후크·자가 치유(🔴)**: 정책 JSON 7개(`labs/policies/`)를 쓰고, AWS CLI의 파라미터 검증을 "문법 채점기"로 써서(모양이 맞으면 501, 틀리면 `ParamValidation`) 확인한다. 값의 의미는 레슨 6 워크시트(12문항)와 `sdk/scaling_worksheet.py`로 채점한다.
- **boto3 태그 없는 리소스 찾기(🟢)**: 그대로(`DescribeTags`·Tagging API 미사용). 에뮬레이터가 남기는 "유령 루트 볼륨"을 감사에서 제외한다.
- **추가**: lab02(구매 옵션 API, 🟡), lab05(배치 그룹·ENI·EIP·최대 절전, 🟡), lab10(Beanstalk·Lightsail·Batch, 🟡). 레슨 2·4·7의 내용을 직접 만져 보게 하려는 보강이다.
- 레슨 2의 할인율(Savings Plans 최대 66%/72%, RI 최대 72%/66%, 스팟 최대 90%)과 레슨 3의 EBS 한도(gp3 64 TiB·80,000 IOPS·2,000 MiB/s, io2 Block Express 256,000 IOPS 등)는 2026-11 AWS 문서·가격 페이지로 확인했다. gp3 한도는 최근 상향된 값이다.
