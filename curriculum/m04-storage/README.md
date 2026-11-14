# M04. 스토리지

> 시나리오: TodayOrder 4단계 — 상품 이미지·영수증·홍보 영상을 저장해야 한다. 서버 디스크를 벗어나 **어디에, 얼마에, 얼마나 안전하게** 둘지 정한다.
> 도메인: D1, D3, D4 · 예상 시간: 약 7시간 (레슨 6시간 + 워크시트·퀴즈 1시간)

## 목표

- 객체·블록·파일 스토리지를 구분하고, 요구 사항에 맞는 서비스(S3·EBS·EFS·FSx)를 고를 수 있다.
- S3 스토리지 클래스를 검색 시간·최소 보관 기간·최소 과금 크기로 비교하고, 수명 주기 규칙과 비용을 손으로 계산할 수 있다.
- 버전 관리·객체 잠금·복제로 데이터를 지키고, 버킷 정책·퍼블릭 액세스 차단·암호화·미리 서명된 URL로 접근을 통제할 수 있다.
- 멀티파트 업로드와 이벤트 알림을 구성하고, 하이브리드·이전 서비스(Storage Gateway, DataSync, Snow, Transfer Family)의 용도를 구분할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [S3 기본: 버킷, 객체, 키, 일관성, 내구성 vs 가용성](./01-s3-fundamentals.md) | 40분 | 🟢 |
| 2 | [스토리지 클래스와 수명 주기 (+ 비용 워크시트)](./02-storage-classes-and-lifecycle.md) | 55분 | 🟢 구성 / 전환은 워크시트 |
| 3 | [버전 관리, MFA Delete, 객체 잠금, 복제(CRR/SRR)](./03-versioning-lock-replication.md) | 60분 | 🟢 / MFA Delete 🟡 |
| 4 | [S3 보안: 버킷 정책, ACL, 퍼블릭 액세스 차단, 암호화, 미리 서명된 URL, 액세스 포인트](./04-s3-security.md) | 60분 | 🟢 / 액세스 포인트 🔴 |
| 5 | [S3 성능·기능: 멀티파트, Transfer Acceleration, 이벤트 알림, 정적 웹 호스팅, 요청자 지불](./05-s3-performance-and-features.md) | 50분 | 🟢 |
| 6 | [파일 스토리지(EFS, FSx 4종)와 블록·파일·객체의 선택](./06-file-storage-efs-fsx.md) | 45분 | 🟡 |
| 7 | [하이브리드·이전: Storage Gateway, DataSync, Snow, Transfer Family](./07-hybrid-and-migration.md) | 40분 | 🟡 / 일부 🔴 |

EBS 볼륨 유형(gp3/io2/st1/sc1)과 스냅샷은 M03 레슨 3에서 다룬다. 이 모듈은 "블록·파일·객체 중 무엇을 고르나"만 다룬다(레슨 6).

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 객체 CRUD·접두사·메타데이터·강한 일관성 | [labs/lab01-s3-object-basics.sh](./labs/lab01-s3-object-basics.sh) | 1 | 🟢 |
| 스토리지 클래스·Glacier 복원·수명 주기 규칙(저장되는 규칙/거부되는 규칙) | [labs/lab02-lifecycle-and-classes.sh](./labs/lab02-lifecycle-and-classes.sh) | 2 | 🟢 (전환 자체는 일어나지 않음 → 워크시트) |
| 비용 워크시트 W1~W6 (정답 포함) | [02 레슨 "비용 워크시트"](./02-storage-classes-and-lifecycle.md#비용-워크시트-손으로-풀기) | 2 | 🔴 (손으로 계산) |
| 버전 관리·삭제 마커·객체 잠금(거버넌스/규정 준수/법적 보존)·MFA Delete | [labs/lab03-versioning-object-lock.sh](./labs/lab03-versioning-object-lock.sh) | 3 | 🟢 / MFA Delete 🟡 |
| 복제(대상 버킷에 실제 복사, 삭제 마커 복제 옵션) | [labs/lab04-replication.sh](./labs/lab04-replication.sh) | 3 | 🟢 |
| 기본 보안값·BPA·버킷 정책 명시적 Deny·SSE-S3/KMS/C | [labs/lab05-bucket-security.sh](./labs/lab05-bucket-security.sh) | 4 | 🟢 (KMS 키 의존성 시연은 M09) |
| 미리 서명된 URL(GET/PUT)을 curl로 검증 | [labs/lab06-presigned-url.sh](./labs/lab06-presigned-url.sh) | 4 | 🟢 |
| 액세스 포인트·계정 수준 BPA (S3 Control 도달 불가 관찰 + 대체 실습) | [labs/lab07-s3-control-unreachable.sh](./labs/lab07-s3-control-unreachable.sh) | 4 | 🔴 |
| 멀티파트 업로드 | [labs/lab08-multipart-upload.sh](./labs/lab08-multipart-upload.sh) | 5 | 🟢 |
| 이벤트 알림 → SQS 실제 도착 + 웹 호스팅·가속·요청자 지불 설정 | [labs/lab09-event-notifications.sh](./labs/lab09-event-notifications.sh) | 5 | 🟢 (웹 호스팅·가속·요청자 지불은 설정 저장만) |
| EFS 파일 시스템·마운트 타깃·액세스 포인트 | [labs/lab10-efs-file-system.sh](./labs/lab10-efs-file-system.sh) | 6 | 🟡 |
| Storage Gateway·DataSync·Transfer Family 구성 | [labs/lab11-hybrid-transfer.sh](./labs/lab11-hybrid-transfer.sh) | 7 | 🟡 / 일부 🔴(501) |
| boto3: 영수증 업로드 서비스 (presigned PUT/GET, 업로드 검증) | [sdk/receipt_upload_service.py](./sdk/receipt_upload_service.py) | 4 | 🟢 |
| boto3: 수명 주기 규칙 점검기 (현재·이전 버전 전환의 거부 규칙과 비용 함정 찾기) | [sdk/lifecycle_lint.py](./sdk/lifecycle_lint.py) | 2 | 🟢 |

`labs/_lib.sh`는 lab 공용 함수(버전까지 지우는 `purge_bucket`, 오류 단언 `expect_error`)다. 단독 실행용이 아니다.

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m04-storage/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만들고, sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전에 거부)를 확인한다. 그다음 모든 lab을 **번호 순서로 한 번, 역순으로 한 번** 실행해 멱등성과 순서 무관성을 함께 확인하고, sdk 예제를 실행한다. 관찰할 수 없는 동작은 `SKIP(사유)`로 표시한다. 마지막 줄이 `MODULE m04 OK`면 통과.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

<!-- widget: progress-tracker -->

## 에뮬레이터 제약

에뮬레이터 1.0.322에서 직접 확인한 것이다. 재생성된 [FIDELITY.md](../../docs/FIDELITY.md)의 "M04 스토리지" 사실 표에도 같은 내용이 있다(Storage Gateway·DataSync의 일부 501 오퍼레이션처럼 표에 없는 세부는 이 모듈의 관찰).

| 오퍼레이션 / 동작 | 증상 | 실습 대응 |
|---|---|---|
| S3에 대한 IAM 사용자 정책 **(M01과 같은 관찰)** | 객체·버킷 단위 데이터 요청(`GetObject`·`PutObject`·`ListObjectsV2`)은 정책이 없으면 암묵적 Deny, 명시적 Deny도 집행한다. 계정 수준·버킷 설정 요청(`ListBuckets`·`CreateBucket`·`DeleteBucket`·`PutBucketVersioning`)은 정책 없이도 통과 | 레슨 4 "실제 AWS에서는" |
| 수명 주기 전환 | 규칙은 저장되지만 시간이 지나도 클래스가 바뀌지 않음 | lab02는 구성까지, 비용은 워크시트 |
| `PutBucketLifecycleConfiguration` 검증 | **AWS 현재 규칙과 같게 동작한다.** STANDARD_IA·ONEZONE_IA를 30일 전에 전환하는 규칙(IA 10일·0일, One Zone-IA 7일 — FIDELITY 탐침과 같은 값. 편집자가 One Zone-IA 0·1일도 받아 주는 것을 확인)과 이전 버전 IA 10일 전환을 받아 준다. 2026-07-16 AWS 발표로 현재 버전의 "Standard에 30일 머문 뒤 전환" 제한이 없어졌으므로 이것은 차이가 아니다(이전 버전은 발표가 언급하지 않아 미확인). 없어진 것은 전환 전 대기뿐이고 **최소 보관 기간 요금은 남아 있다** — IA·One Zone-IA에 들어간 객체를 30일이 되기 전에 삭제·덮어쓰기·전환하면 30일을 채운 만큼 청구된다. 또 2024-09부터 수명 주기 전환은 기본적으로 **128 KB 미만 객체를 옮기지 않는다**(`TransitionDefaultMinimumObjectSize: all_storage_classes_128K`. 에뮬레이터에서는 전환이 일어나지 않아 확인 불가). 한 규칙 안에서 최소 보관 기간보다 빠른 연쇄 전환(Glacier IR 4일 → Deep Archive 20일, Glacier IR 0일 → Deep Archive 30일, 이전 버전 Glacier IR 5일 → Deep Archive 20일), 거꾸로 된 전환, 없는 클래스, 중복 규칙 ID, 0일 만료는 거부한다. 다만 전환보다 빠르거나 같은 만료는 거부하지 않고 저장한다(AWS는 거부 — 레슨 2) | lab02 10~12단계(IA 10일 전환·연쇄 전환·역방향 전환), `sdk/lifecycle_lint.py`(이전 버전 연쇄 전환). 그 밖의 항목은 lab이 시험하지 않는 직접 관찰 |
| Glacier 복원 | Standard 복원이 1초 안팎에 완료(FIDELITY `s3`. 실제 Standard는 3–5시간). 복원 전 `GetObject`는 `InvalidObjectState`로 AWS와 같다 | 폴링으로 기다리고, 시간은 단언하지 않음 |
| MFA Delete | 아무 MFA 코드나 받아 저장하고, 켠 뒤에도 MFA 없이 버전 영구 삭제가 통과함 | lab03에서 🟡로 관찰만 |
| 객체 잠금 버킷의 버전 관리 일시 중지 | `Suspended`로 바뀜(AWS는 거부) | 레슨 3 "실제 AWS에서는" |
| `PutBucketReplication` 검증 | 존재하지 않는 역할, 버전 관리 없는 대상, 없는 대상 버킷도 받아 줌. 버전 관리 없는 **원본**만 거부 | lab04는 실제처럼 역할·버전 관리를 만듦 |
| SSE-KMS + 키 비활성화 | 키가 `Disabled`여도 객체가 읽힘 | 키 의존성 시연은 M09 |
| SSE-KMS 응답의 `SSEKMSKeyId` | 요청에 쓴 별칭(`alias/...`)을 그대로 돌려줌(AWS는 키 ARN) | lab05 단언에서 둘 다 허용 |
| SSE-C 차단 | 새 버킷 기본 암호화 설정에 `BlockedEncryptionTypes: SSE-C`가 보이지만(AWS 2026-04 기본값과 같음) **집행하지 않아** SSE-C 업로드가 통과함(AWS는 403) | lab05는 차단 목록을 먼저 비움 |
| 퍼블릭 정책 + BPA 해제 | `IsPublic: true`가 되어도 익명 GET은 403 | 실습하지 않음, 레슨 4에 기록 |
| S3 Control (`s3control`) | SDK가 `000000000000.127.0.0.1`로 보내 **도달 불가** | lab07 🔴 + 버킷 수준 BPA·정책 JSON 대체 실습 |
| 웹 사이트·가속 엔드포인트 | 설정은 저장되지만 엔드포인트 없음 | lab09는 설정 확인만 |
| EFS 마운트 타깃 | 같은 AZ의 **다른 서브넷**에 두 번째 마운트 타깃을 만들면 충돌 없이 만들어진다(AWS는 `MountTargetConflict`). `MountTargetConflict`는 **같은 서브넷**으로 다시 만들 때만 난다. 마운트 타깃의 AZ 표시(`AvailabilityZoneName`, 오류 메시지의 AZ)와 IP가 서브넷의 AZ·CIDR과 다를 수 있다 | lab10은 AZ를 출력하지 않고 같은 서브넷으로 충돌 재현 |
| EFS 마운트 | NFS 서버가 없어 마운트 불가 | 🟡, "실제 AWS에서 해 보려면" |
| Storage Gateway | 임의 활성화 키로 게이트웨이가 생기고 NFS 파일 공유는 AVAILABLE. `CreateSMBFileShare`·`CreateCachediSCSIVolume`·`CreateTapes`·`ListTapes`·`ListVolumes`는 **501** | lab11 🟡/🔴 |
| DataSync | S3→S3 작업 실행이 `SUCCESS`인데 **0개 전송**(실제 복사 없음). `CreateLocationNfs`·`ListTaskExecutions`는 **501** | lab11은 "복사 안 됨"까지 단언 |
| FSx | Lustre 파일 시스템이 AVAILABLE까지 생성되지만 `ImportPath`(S3 연결)가 저장되지 않음 | 실습하지 않음(레슨 6은 개념) |

## 설계 대비 대체 사유

CURRICULUM.md M04의 레슨 7개와 실습 9개를 모두 구현했다. 차이는 다음과 같다.

- **수명 주기 규칙 구성**: 그대로(🟢 구성). CURRICULUM의 "잘못된 규칙도 받아 줌"은 근거였던 "IA 30일 미만 전환 금지"가 2026-07에 AWS에서 폐지되어 더 이상 맞지 않는다. 에뮬레이터는 현재 AWS 규칙대로 IA 10일 전환은 받고, 최소 보관 기간 위반 연쇄 전환과 역방향 전환은 거부한다(lab02 10~12단계). "저장되지만 돈이 새는 규칙"은 레슨 2의 워크시트(정답 포함)와 `sdk/lifecycle_lint.py`로 다룬다.
- **CRUD·버전 관리·삭제 마커**: lab01(CRUD)과 lab03(버전 관리)으로 나눴다. 레슨 3의 객체 잠금(거버넌스·규정 준수·법적 보존)과 MFA Delete 관찰을 lab03에 추가했다. MFA Delete는 집행되지 않아 🟡이다.
- **복제·이벤트 알림**: 레슨이 다르므로(3, 5) lab04와 lab09로 나눴다. 둘 다 🟢 그대로다.
- **버킷 정책·BPA·SSE**: lab05(🟢)로 구현했다. KMS 키를 끄는 시연은 하지 않는다(CURRICULUM 지시). 미리 서명된 URL은 lab06으로 따로 뒀다.
- **액세스 포인트·계정 수준 BPA**: 🔴. lab07이 "도달 불가"를 관찰하고, 버킷 수준 BPA와 액세스 포인트 위임 정책(JSON) 작성으로 대체한다.
- **EFS**: 🟡 그대로(lab10).
- **추가**: lab11(레슨 7 하이브리드 서비스 구성, 🟡/일부 🔴), `sdk/lifecycle_lint.py`. 둘 다 대체가 아니라 보강이다.
- **S3 Select**: CURRICULUM 지시대로 레슨 5에 한 줄만 썼다(신규 고객 불가 → Athena).
- **Snow 패밀리**: 2025-11-07부터 신규 고객에게 제공되지 않는다는 현황을 레슨 7에 반영했다. 시험 맥락의 정답은 함께 설명한다.
