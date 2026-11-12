# M00 치트시트

## 매일 쓰는 명령

```bash
scripts/install.sh                     # 처음 한 번 (여러 번 실행해도 안전) · --rebuild: 에뮬레이터 업데이트
scripts/emulator-up.sh [포트]          # 시작 (기본 9297)
source scripts/env.sh                  # 셸 연결 + 안전 장치  (다른 포트: EMULATOR_PORT=9298 source scripts/env.sh)
aws sts get-caller-identity            # Account 000000000000 이면 에뮬레이터
scripts/emulator-status.sh             # 상태·메모리
scripts/emulator-reset.sh [포트]       # 재시작 = 모든 리소스 삭제
scripts/emulator-down.sh [포트|--all]  # 끄기
colima stop                            # VM까지 끄기 (다음에 colima start)
```

## 에뮬레이터 핵심 사실

| 항목 | 값 |
|---|---|
| 엔드포인트 | `https://127.0.0.1:<포트>` (모든 서비스 공통, `localhost` 쓰지 말 것) |
| 계정 / 리전 | `000000000000` / 이 커리큘럼은 `us-east-1` 고정 |
| 자격 증명·인증서 | `~/.aws/emulator/<포트>/` — 시작할 때마다 새로 생성 |
| 헬스 체크 | `curl --cacert ~/.aws/emulator/<포트>/ca.pem https://127.0.0.1:<포트>/__admin/health` → `ok` |
| 상태 | 메모리에만. 재시작 = 초기화. 초기화 API는 없음 |
| 미구현 | HTTP 501, 오류 코드 `NotImplemented` |
| IAM | 서비스마다 평가 여부가 다름 → **보안 검증에 쓰지 말 것** |
| 텔레메트리 | 이 저장소 스크립트는 기본 끔. 켜기: `EMULATOR_TELEMETRY=on scripts/emulator-up.sh` |
| 이미지 | AWS가 배포하지 않음. `scripts/docker/Dockerfile`로 로컬 빌드 |

## 충실도 등급

| 🟢 재현 | 🟡 부분 | 🔴 개념 |
|---|---|---|
| 실제처럼 동작, 끝까지 검증 | 리소스는 생기지만 동작은 안 일어남 | 501이거나 의미 없음 → 개념·워크시트 |

## 글로벌 인프라 한눈에

| 요구 | 답 |
|---|---|
| AZ 하나가 죽어도 서비스 유지 | 여러 AZ에 분산 (Multi-AZ) |
| 리전 하나가 죽어도 서비스 유지 | 다중 리전 DR (M12) |
| 데이터는 국내에만 | 리전 선택 (규정 준수가 1순위 기준) |
| 특정 대도시 사용자에게 한 자릿수 ms | Local Zones |
| 5G 모바일 단말 초저지연 | Wavelength Zones |
| 내 데이터 센터에서 AWS 서비스 | Outposts |
| 정적 콘텐츠를 전 세계에 빠르게 | CloudFront (엣지 로케이션) |
| 계정 간 같은 물리 AZ 지정 | AZ 이름 말고 **AZ ID** (`use1-az1`) |

리전은 **최소 3개 AZ**를 가진다. 리전끼리는 독립적이다.

## 공동 책임 모델

| AWS (OF the cloud) | 고객 (IN the cloud) |
|---|---|
| 물리 시설·하드웨어·네트워크·하이퍼바이저 | IAM 사용자·정책, 보안 그룹·NACL |
| 관리형 서비스의 기반 OS·엔진 패치 (RDS, Lambda 런타임) | EC2 게스트 OS·앱 패치 |
| | 데이터 암호화 설정, 데이터 분류·백업 정책 |

관리형일수록(EC2 → RDS → Lambda·S3·DynamoDB) AWS 몫이 커진다. IAM과 데이터는 언제나 고객 몫.

## AWS CLI

| 하고 싶은 것 | 방법 |
|---|---|
| 필드 고르기 | `--query 'Items[].{Id: id, Name: name}'` |
| 값 하나를 변수에 | `x=$(aws ... --query 'A.B' --output text)` |
| 사람이 보기 좋게 | `--output table` |
| 목록 일부만 / 이어서 | `--max-items N` → `NextToken` → `--starting-token` (토큰은 `--output json` 으로 받기) |
| API 호출 단위 줄이기 | `--page-size N` |
| 상태가 될 때까지 대기 | `aws dynamodb wait table-exists --table-name T` |
| 무슨 일이 일어나나 | `--debug` (stderr) |
| 매뉴얼 | `aws <서비스> <오퍼레이션> help` |

종료 코드: `0` 성공 · `252` 문법 오류 · `253` 환경·설정 오류 · `254` 서비스가 오류 응답 · `255` 그 밖의 오류.

## boto3

```python
import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")                                     # 엔드포인트·키는 환경 변수에서
for page in s3.get_paginator("list_objects_v2").paginate(Bucket="b"):
    ...
boto3.client("dynamodb").get_waiter("table_exists").wait(TableName="t")
try:
    s3.get_object(Bucket="b", Key="none")
except ClientError as e:
    e.response["Error"]["Code"]                             # "NoSuchKey"
```

resource 인터페이스(`boto3.resource`)는 신규 기능 추가가 중단됐다 — 새 코드는 client.

## 요청 해부

- 자격 증명 탐색: **환경 변수 → 공유 자격 증명 파일 → 설정 파일 → 컨테이너/EC2 메타데이터** (앞이 이긴다)
- SigV4: 비밀 키는 보내지 않는다. `Credential=<키 ID>/<날짜>/<리전>/<서비스>/aws4_request`. 시계가 15분 넘게 어긋나면 거부
- 키 접두사: `AKIA` 장기 키 · `ASIA` 임시 키 (STS) · `EMULATOR` 에뮬레이터 키
- ARN: `arn:aws:<서비스>:<리전>:<계정>:<리소스>` (IAM처럼 글로벌 서비스는 리전 칸이 빔)

## 숫자 감각 (자주 바뀐다 — 확신이 없으면 공식 문서)

| 항목 | 값 |
|---|---|
| S3 객체 최대 크기 | 50 TB |
| S3 `ListObjectsV2` 한 번에 | 최대 1,000개 |
| SQS 메시지 최대 크기 | 1 MiB |
| DynamoDB 테이블 이름 | 3~255자 |
