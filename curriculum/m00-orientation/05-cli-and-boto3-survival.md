# M00-05. AWS CLI 생존 기술과 boto3 기본기
> 도메인: – (도구) · 예상 시간: 45분 · 실습 등급: 🟢

## 왜 필요한가

AWS 응답은 길다. `describe-instances` 한 번에 수백 줄이 나온다. 필요한 값 하나를 뽑아 셸 변수에 담고, 1,000개가 넘는 목록을 끝까지 읽고, "테이블이 만들어질 때까지" 기다리는 일을 못 하면 이후 모듈의 실습 스크립트를 읽을 수도 쓸 수도 없다. TodayOrder의 첫 업무 — "영수증 버킷에 파일이 몇 개 있는지 세어 주세요" — 를 CLI와 Python 양쪽으로 해 보자.

## 핵심 개념

### AWS CLI 명령 구조

```
aws <서비스> <오퍼레이션> [파라미터] [--query ...] [--output ...] [페이지네이션 옵션]
aws s3api list-objects-v2 --bucket todayorder-m00-cli --query 'Contents[].Key' --output text
```

- `aws s3` 는 사람이 쓰기 좋게 만든 **고수준 명령**(`cp`, `ls`, `sync`, `mb`, `rb`), `aws s3api` 는 S3 API와 1:1인 **저수준 명령**이다. 다른 서비스는 대부분 저수준 명령만 있다.
- `aws help`, `aws s3api help`, `aws s3api list-objects-v2 help` — 오프라인 매뉴얼. 파라미터 이름과 예제가 다 들어 있다.

### 출력 다루기

| 옵션 | 역할 | 언제 |
|---|---|---|
| `--query '<JMESPath>'` | **클라이언트 쪽**에서 응답 JSON을 걸러 낸다 | 필요한 필드만 보거나 값 하나를 뽑을 때 |
| `--filters` / `--filter` 등 | **서버 쪽** 필터 (서비스마다 지원 여부·이름이 다르다) | 결과가 많아 전송 자체를 줄이고 싶을 때 |
| `--output json\|table\|text\|yaml` | 출력 형식 | 사람이 볼 땐 `table`, 셸 변수에 담을 땐 `text` |

JMESPath 기본 문법: `Contents[]`(배열 펼치기), `Contents[0:3]`(슬라이스), `{Key: Key, Size: Size}`(새 객체로), `[Key, Size]`(배열로), `length(Contents)`(함수), `Contents[?Size > \`100\`]`(조건 필터).

### 페이지네이션

목록 API는 한 번에 일부만 준다(S3 `ListObjectsV2`는 최대 1,000개). 남은 것이 있으면 응답에 **다음 토큰**(`NextContinuationToken`, `NextToken`, `Marker` 등 서비스마다 이름이 다름)이 있다.

| CLI 옵션 | 의미 |
|---|---|
| (기본) | CLI가 **자동으로** 모든 페이지를 따라가 합쳐 준다 |
| `--max-items N` | 합쳐서 최대 N개만 보여 주고, 이어 읽을 `NextToken` 을 준다 |
| `--starting-token T` | 그 `NextToken`부터 이어서 |
| `--page-size N` | API 한 번 호출에 N개씩 (총 개수는 그대로, 호출 횟수만 늘어남 — 타임아웃 회피용) |
| `--no-paginate` | 첫 페이지만 |

### boto3의 네 가지 도구

| 도구 | 무엇 | 예 |
|---|---|---|
| **client** | AWS API와 1:1인 저수준 인터페이스. 응답은 dict | `boto3.client("s3").list_objects_v2(Bucket=...)` |
| **paginator** | 다음 토큰을 대신 따라가 준다 | `s3.get_paginator("list_objects_v2").paginate(...)` |
| **waiter** | 원하는 상태가 될 때까지 폴링 | `ddb.get_waiter("table_exists").wait(TableName=...)` |
| **resource** | 객체 지향 고수준 인터페이스 (`bucket.objects.all()`) | AWS가 **신규 기능 추가를 중단**했다. 새 코드는 client를 권장 |

오류는 `botocore.exceptions.ClientError` 하나로 오고, `e.response["Error"]["Code"]` 로 분기한다.

### 이 저장소의 boto3 예제 규칙: 안전 장치 먼저

boto3 코드에는 엔드포인트가 없다. 그래서 `source scripts/env.sh`를 잊은 셸에서 실행하면 boto3는 **실제 AWS 주소**(`https://s3.amazonaws.com` 등)로 요청하고, `~/.aws`에 실제 자격 증명이 있으면 그대로 쓴다. 이를 막으려고 모든 sdk 예제는 **클라이언트를 만들기 전에** 저장소의 안전 장치를 부른다.

```python
from emulator_guard import require_emulator

def main() -> None:
    require_emulator()          # 에뮬레이터가 아니면 여기서 종료 (종료 코드 1)
    s3 = boto3.client("s3")     # 그다음에 클라이언트
```

`require_emulator()`는 ① 네트워크 호출 없이 `AWS_ENDPOINT_URL`(과 서비스별 `AWS_ENDPOINT_URL_*`)을 **URL로 해석해서** scheme이 `https`, 호스트가 정확히 `127.0.0.1`, 사용자 정보(`@`) 없음, 숫자 포트, 경로 없음인지 본다. 그래서 `https://127.0.0.1:9320@s3.amazonaws.com`(앞부분만 보면 127.0.0.1 같지만 실제 호스트는 `s3.amazonaws.com`) 같은 값도 거부된다. ② 통과하면 그 엔드포인트로만 STS를 불러 계정이 `000000000000`인지 확인한다. `emulator_guard`는 이 저장소의 작은 패키지(`src/emulator_guard/`)로, `uv sync`가 설치해 두므로 `uv run python ...`에서 바로 import 된다. env.sh 없이 실행하면:

```
[emulator_guard] AWS_ENDPOINT_URL 이 로컬 에뮬레이터(https://127.0.0.1:<포트>)가 아닙니다: '설정 안 됨'. 이대로 실행하면 실제 AWS로 요청이 갈 수 있어 중단합니다.
                 먼저 저장소 루트에서 'source scripts/env.sh' 를 실행하세요 (에뮬레이터: scripts/emulator-up.sh).
```

**에뮬레이터 두 개(두 "리전")를 함께 쓸 때** — M12의 다중 리전 DR처럼 — 는 `scripts/dr-env.sh`가 두 번째 에뮬레이터의 접속 정보를 `DR_AWS_*` 변수로 만들고, Python에서는 사이트마다 검사된 클라이언트 공장을 받는다. 코드에 엔드포인트를 쓰지 않는다.

```python
from emulator_guard import emulator_site

primary = emulator_site(real_aws_region="ap-northeast-2")    # AWS_*    (scripts/env.sh)
dr = emulator_site("DR_", real_aws_region="ap-northeast-1")  # DR_AWS_* (scripts/dr-env.sh)
dr.client("dynamodb").put_item(...)                          # 각 사이트의 엔드포인트·키·인증서로 고정된 클라이언트
```

`real_aws_region`은 실제 AWS에서 돌릴 때(아래 opt-out)만 쓰인다. 서비스별 `AWS_ENDPOINT_URL_*`이 있다면 그 포트도 `AWS_ENDPOINT_URL`과 같아야 한다(다른 사람의 에뮬레이터로 새는 것을 막기 위해).

나중에 **자기 AWS 계정에서** 같은 예제를 직접 돌려 보고 싶다면 `TODAYORDER_ALLOW_REAL_AWS=1`을 설정한다. 그러면 검사를 건너뛰고 경고만 출력한다(요금 주의, 기본값은 꺼짐). `emulator_site()`는 이때 엔드포인트 없이 `real_aws_region` 리전의 세션을 쓴다. `verify.sh`는 "env.sh 없이 실행하면 네트워크 호출 전에 거부되는지"와 가드 자체 시험(`uv run python -m emulator_guard.selftest`: URL 우회 사례, 두 번째 사이트, opt-out)을 매번 확인한다. 이때 `DR_AWS_*`는 쓰이지 않아 **두 번째 사이트도 주 사이트와 같은 환경을 따른다**(env.sh를 source 한 셸이면 두 사이트 모두 주 에뮬레이터로 간다). 실제 AWS에서 두 리전을 쓰려면 env.sh 없이 새 셸에서 실행하고 `real_aws_region`만 다르게 준다.

## 직접 해 보기

[lab04-cli-survival.sh](./labs/lab04-cli-survival.sh)는 버킷에 주문 파일 7개를 올리고 아래를 차례로 해 본다.

**1) `--query`로 필요한 필드만**

```bash
aws s3api list-objects-v2 --bucket todayorder-m00-cli --query 'Contents[].{Key: Key, Size: Size}' --max-items 2
```

```
[
    {
        "Key": "orders/A-1001.txt",
        "Size": 8
    },
    {
        "Key": "orders/A-1002.txt",
        "Size": 8
    }
]
```

**2) 사람이 볼 때는 `table`, 셸 변수에는 `text`**

```bash
aws s3api list-objects-v2 --bucket todayorder-m00-cli --query 'Contents[0:3].[Key, Size]' --output table
aws s3api list-objects-v2 --bucket todayorder-m00-cli --query 'length(Contents)' --output text
```

```
----------------------------
|       ListObjectsV2      |
+---------------------+----+
|  orders/A-1001.txt  |  8 |
|  orders/A-1002.txt  |  8 |
|  orders/A-1003.txt  |  8 |
+---------------------+----+
7
```

방금 본 것: `count=$(aws ... --output text)` 처럼 바로 변수에 담을 수 있다. 첫 업무의 답은 7개.

**3) 3개씩 끊어 읽기**

```bash
aws s3api list-objects-v2 --bucket todayorder-m00-cli --max-items 3 --query '{Keys: Contents[].Key, NextToken: NextToken}'
```

```
{
    "Keys": [
        "orders/A-1001.txt",
        "orders/A-1002.txt",
        "orders/A-1003.txt"
    ],
    "NextToken": "eyJDb250aW51YXRpb25Ub2tlbiI6IG51bGwsICJib3RvX3RydW5jYXRlX2Ftb3VudCI6IDN9"
}
```

```bash
aws s3api list-objects-v2 --bucket todayorder-m00-cli --max-items 3 --starting-token <위 NextToken> --query 'Contents[].Key'
```

```
[
    "orders/A-1004.txt",
    "orders/A-1005.txt",
    "orders/A-1006.txt"
]
```

방금 본 것: `NextToken`은 CLI가 만든 토큰이다(base64를 풀면 `{"ContinuationToken": null, "boto_truncate_amount": 3}`). S3가 준 토큰이 아니라 "첫 페이지에서 3개를 건너뛰라"는 CLI의 메모라서, 다른 도구에 넘기면 안 된다.

> ⚠️ 함정: **페이지네이션되는 목록 명령**(S3 `list-objects-v2`, API Gateway `get-resources`, 대부분의 `list-*`/`describe-*`)의 결과를 `--query ... --output text`로 받으면, CLI가 페이지마다 쿼리를 적용해 한 줄씩 찍기 때문에 값 앞뒤에 `None` 줄이 섞일 수 있다. 실제로 이 실습을 만들 때 그렇게 받은 토큰을 `--starting-token`에 넘겨 `InvalidArgument: The continuation token provided is incorrect` 를 받았다. 목록 결과를 셸 변수에 담을 때는 `--output json`으로 받아 가공하거나(`| tr -d '"'`), 첫 페이지만 필요하면 `--no-paginate`를 붙이자.

**4) 같은 일을 boto3로** — [sdk/client_resource_paginator_waiter.py](./sdk/client_resource_paginator_waiter.py)

```bash
uv run python curriculum/m00-orientation/sdk/client_resource_paginator_waiter.py
```

```
[client] 한 번 호출: 3건, IsTruncated=True
[paginator] 페이지별 건수: [3, 3, 1] → 합계 7
[resource] 첫 키 orders/A-1001.txt, 마지막 키 orders/A-1007.txt
[waiter] create_table 응답의 상태: CREATING
[waiter] 기다린 뒤 상태: ACTIVE
SDK client_resource_paginator_waiter OK
```

방금 본 것:
- client 한 번 호출은 `MaxKeys=3` 만큼만 주고 `IsTruncated=True` 로 "더 있다"고 알린다. paginator는 3+3+1 세 번 호출해 7개를 모두 읽었다.
- `create_table` **응답**의 상태는 CLI([lab03](./labs/lab03-validation-error.sh))든 boto3든 항상 `CREATING`이다. 에뮬레이터는 1초 안에 `ACTIVE`가 되는 경우가 많아서, 만든 직후 `describe_table`을 부르면 실행할 때마다 `CREATING`이 나오기도 하고 `ACTIVE`가 나오기도 한다(경쟁 상태). 실제 AWS에서는 보통 수 초 동안 `CREATING`이다. 그래서 상태를 가정하지 말고 **항상 waiter로 기다리는 습관**이 중요하다. CLI에서는 `aws dynamodb wait table-exists`, `aws s3api wait bucket-exists` 가 같은 역할을 한다.

**5) 같은 S3 왕복을 boto3로** — [sdk/s3_roundtrip.py](./sdk/s3_roundtrip.py) (lab02의 Python 버전)

```bash
uv run python curriculum/m00-orientation/sdk/s3_roundtrip.py
```

```
계정: 000000000000  ARN: arn:aws:iam::000000000000:user/emulator
S3 엔드포인트: https://127.0.0.1:9297  리전: us-east-1
업로드: s3://todayorder-m00-receipts-sdk/receipts/2026/11/A-1002.json  ETag="a1ee2522cbe3b2ea84829021e960e586"
목록: ['receipts/2026/11/A-1002.json']
내려받음: {'orderId': 'A-1002', 'total': 8900, 'currency': 'KRW'}  (ContentType=application/json, 55 bytes)
없는 키: NoSuchKey (HTTP 404)
정리 완료
SDK s3_roundtrip OK
```

방금 본 것: 코드에는 엔드포인트도 키도 없다(`boto3.client("s3")`). 환경 변수가 대상을 정한다. 그래서 **같은 코드가 실제 AWS에서도 그대로 동작한다** — 이 커리큘럼의 모든 boto3 예제의 규칙이다. 다만 맨 앞의 `require_emulator()`가 "지금은 에뮬레이터"임을 먼저 확인한다.

## 실제 AWS에서는

- 페이지네이션·쿼리·waiter는 실제 AWS에서도 똑같이 동작한다. 실제 계정에서는 목록이 수천~수만 개일 수 있으므로 `--max-items`/paginator가 필수다.
- 실제 S3 버킷 이름은 **전 세계에서 유일**해야 한다. `todayorder-m00-cli` 같은 이름은 이미 누가 쓰고 있을 수 있어 `BucketAlreadyExists`가 날 수 있다. 에뮬레이터는 내 것만 있으니 충돌하지 않는다.
- 실제 AWS에서 이 실습을 해 보려면: S3 Standard 저장과 요청은 프리 티어 범위 안의 소량이면 비용이 거의 없지만, 끝나면 반드시 `aws s3 rb s3://<버킷> --force` 로 지운다.

## 시험 포인트

- 시험은 CLI 문법을 묻지 않는다. 다만 "대량 목록은 페이지 단위로 온다", "상태가 바뀌는 리소스는 기다려야 한다"는 감각은 모든 실습의 기초다.
- S3 `ListObjectsV2`는 한 번에 최대 1,000개 — "버킷에 객체가 수백만 개, 목록을 빠르게" 같은 문제에서는 목록 API 대신 **S3 Inventory** 같은 기능을 고르는 이유가 된다(M04).

## 스스로 확인

1. `--page-size 100 --max-items 250`은 API를 몇 번 호출하고, 몇 개를 보여 주는가?
2. `--query`와 `--filters`의 차이는? 1만 개 인스턴스 중 `running`만 보고 싶을 때 무엇을 쓰는 게 나은가?
3. boto3로 DynamoDB 테이블을 만든 직후 `put_item` 을 바로 호출하는 코드가 에뮬레이터에서는 통과했다. 실제 AWS에서도 안전한가?

<details><summary>답</summary>

1. 최대 3번 호출(100+100+50, 세 번째는 100을 요청해 앞 50만 사용)해 250개를 보여 주고, 이어 읽을 `NextToken`을 준다.
2. `--query`는 응답을 받은 뒤 내 컴퓨터에서 거른다. `--filters`는 서버가 걸러서 보낸다. 대량이면 `--filters Name=instance-state-name,Values=running`처럼 서버 쪽 필터가 낫다(필요하면 `--query`로 필드만 추가로 고른다).
3. 아니다. 실제 AWS에서는 테이블이 `CREATING` 상태인 동안 쓰기가 실패할 수 있다. `get_waiter("table_exists")`로 ACTIVE를 기다린 뒤 쓴다.

</details>
