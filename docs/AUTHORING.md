# 작성 규칙 (모듈 저자용)

모든 모듈은 이 규칙을 따른다. 검증 에이전트는 이 문서를 기준으로 PR을 심사한다. 원고를 화면으로 보여 주는 가이드 사이트(`site/`)의 규칙과 검증 항목은 [GUIDE-SITE.md](./GUIDE-SITE.md)에 따로 있다.

## 1. 디렉터리 구조

```
curriculum/mNN-<slug>/
├── README.md              # 모듈 개요: 목표, 시나리오 단계, 레슨 목록, 실습 등급표, 예상 시간, "에뮬레이터 제약", "설계 대비 대체 사유"
├── 01-<lesson-slug>.md    # 레슨 (개념 + 실습 안내가 한 문서에)
├── 02-...md
├── labs/
│   ├── lab01-<slug>.sh    # 실습을 처음부터 끝까지 재현하는 스크립트. 번호는 모듈 내 일련번호이며, 레슨 문서가 자신의 lab 파일을 링크한다
│   ├── ...
│   └── verify.sh          # 모듈의 모든 lab을 깨끗한 에뮬레이터에서 실행·검증
├── sdk/
│   └── <name>.py          # boto3 예제 (uv run 으로 실행)
├── cheatsheet.md          # 비교표·한계값·시험 포인트 요약
└── quiz.md                # 시나리오형 문제 10문항 이상 + 해설
```

공용 파일(`scripts/`, `tools/`, `src/`, `docs/`, 루트 `README.md`, `pyproject.toml`)은 **자기 역할이 아니면 수정하지 않는다.** 필요하면 PR 본문에 요청 사항으로 적는다.

## 2. 레슨 문서 형식

```markdown
# M03-05. 로드 밸런서
> 도메인: D2, D3 · 예상 시간: 50분 · 실습 등급: 🟡

## 왜 필요한가        ← TodayOrder 시나리오의 문제 상황 2~4문장
## 핵심 개념          ← 주니어 눈높이. 비유 1개 이하, Mermaid 다이어그램 권장
## 직접 해 보기       ← 명령 → 실제 출력 → "방금 본 것" 해설의 반복
## 실제 AWS에서는     ← 에뮬레이터와 다른 점, 재현 안 되는 동작. 🟡/🔴 실습은 "실제 AWS에서 해 보려면" 메모 필수
                         (프리 티어 해당 여부, 과금 주의, 정리(삭제) 명령)
## 시험 포인트        ← 불릿 3~7개. "X가 나오면 Y" 형태
## 스스로 확인        ← 서술형 질문 2~3개 (답은 <details>)
```

- 문서는 **한국어**. 서비스명·API명·CLI는 영문 원문 유지 (예: "보안 그룹(Security Group)" 첫 등장 시 병기).
- 한 레슨은 20~60분 분량. 길어지면 나눈다.
- 다이어그램은 Mermaid (GitHub에서 렌더링됨). 이미지 파일을 만들지 않는다.
- 용어는 처음 나올 때 한 줄로 정의한다. 독자는 HTTP·SQL·Linux 기본은 알지만 AWS는 처음이다.

## 3. 실습 규칙 (가장 중요)

1. **실제 실행한 출력만 싣는다.** 문서의 명령 블록과 출력 블록은 에뮬레이터에서 실행한 결과를 그대로(길면 `...`로 생략 표시) 싣는다. 임의로 만든 ID·출력 금지.
2. **등급은 실행 결과로 정한다.** `docs/FIDELITY.md`를 먼저 보고, 직접 실행해 🟢/🟡/🔴를 확정한다. `501 NotImplemented`나 AWS와 다른 동작을 만나면 숨기지 말고 그대로 보여 주고 "실제 AWS에서는"에 차이를 쓴다.
3. **미구현을 만나면** 우회 실습으로 대체하고(예: 설정값 조회, 정책·설정 JSON 작성, 워크시트), 모듈 README의 "에뮬레이터 제약" 절에 오퍼레이션명과 증상을 기록한다.
4. **스크립트는 멱등·자급자족.** 각 `labNN-*.sh`는 `set -euo pipefail`, `source "$(git rev-parse --show-toplevel)/scripts/env.sh"`로 시작하고, 깨끗한 에뮬레이터에서 단독 실행 가능해야 한다(앞 lab에 의존하면 스크립트 안에서 선행 리소스를 직접 만든다). 같은 에뮬레이터에서 **두 번 연속 실행해도, 다른 lab 뒤에 실행해도** 통과해야 한다 — 시작할 때 자신이 만들 리소스가 남아 있으면 지우고 시작하거나, 끝날 때 정리한다. 끝에 핵심 결과를 단언(assert)한다.
5. **`verify.sh`** 는 `$EMULATOR_PORT`의 에뮬레이터를 재시작해(`scripts/emulator-reset.sh`) 깨끗한 상태로 만든 뒤, 그 하나의 에뮬레이터에서 모듈의 모든 lab과 sdk 예제를 순서대로 실행한다. 전부 통과하면 `MODULE mNN OK`를 출력하며 0으로 종료한다. 🔴 등 실행 불가 항목은 `SKIP(사유)`로 표시한다.
   - **순서**: 두 번째 실행은 첫 번째와 **다른 순서(역순)** 로 돌려, lab 사이의 숨은 의존을 잡는다. (M00~M13 모두 이 방식이다. M14는 단계별 시나리오로 검증한다.)
   - **두 번째 에뮬레이터**가 필요한 모듈은 `DR_EMULATOR_PORT`가 지정되지 않은 비대화형 실행을 **아무것도 리셋하기 전에** 거부하고, 지정된 포트의 에뮬레이터도 `emulator-reset.sh`로 재시작한 뒤 `scripts/dr-env.sh`를 source한다. 미리 띄워 둔 두 번째 에뮬레이터를 쓰기만 하는 모듈(M00)도, `DR_EMULATOR_PORT`가 지정됐는데 그 포트에 에뮬레이터가 없으면 아무것도 리셋하기 전에 원인을 알리고 실패한다.
   - **포트**: `scripts/env.sh`는 `EMULATOR_PORT`를 읽는다(학습자 기본값 9297). 에이전트는 반드시 [AGENTS.md](./AGENTS.md)에 배정된 포트를 `export EMULATOR_PORT=<port>`로 지정하고 작업한다. 스크립트 안에 포트를 하드코딩하지 않는다.
6. **리소스 이름**은 `todayorder-` 접두사. 리전은 `us-east-1` 고정. 계정 ID는 `000000000000`.
7. **boto3 예제**는 타입 힌트와 `if __name__ == "__main__":`을 갖춘 실행 가능한 단일 파일. 엔드포인트·자격 증명을 코드에 하드코딩하지 않는다(환경 변수로 주입 — 실제 AWS에서도 그대로 동작하는 코드여야 한다). 모든 예제는 boto3 클라이언트를 만들기 **전에** `from emulator_guard import require_emulator` 의 `require_emulator()`를 호출한다(엔드포인트가 에뮬레이터가 아니면 종료. 학습자가 의도적으로 실제 AWS에서 돌릴 때만 `TODAYORDER_ALLOW_REAL_AWS=1`). 모듈 `verify.sh`는 M00 `labs/verify.sh`의 `guard_refuses` 함수를 그대로 복사해 자기 `sdk/*.py`마다 실행한다. 에뮬레이터 두 개(다중 리전 흉내)를 쓰는 예제는 셸에서 `source scripts/env.sh && source scripts/dr-env.sh`, 코드에서 `emulator_site()` / `emulator_site("DR_")`가 돌려준 사이트의 `.client()`만 쓴다. `endpoint_url=`을 코드에 쓰거나 `AWS_*` 환경 변수를 바꿔 끼우지 않는다.
8. **정책을 실제처럼 쓴다.** SNS→SQS·S3→SQS(큐 정책), Step Functions·Pipes·Glue·Backup(역할 신뢰 정책·권한), CloudFront OAC·Config(버킷 정책)는 정책이 없으면 실패하거나 조용히 아무 일도 일어나지 않는다. 반대로 에뮬레이터가 검사하지 않는 권한(예: API Gateway→Lambda의 `AddPermission`)도 실제 AWS에 필요하면 스크립트에 넣는다.
9. **리소스 엔드포인트(RDS·ALB·CloudFront)는 컨테이너 안에만 있다.** 호스트에서 접속하는 실습을 설계하지 않는다. 꼭 필요하면 `docker exec aws-emulator-$EMULATOR_PORT ...`로 보여 주되 선택 과제로 둔다.
10. **시간에 기대지 않는다.** 비동기 상태는 waiter/폴링으로 기다리고(넉넉한 상한 시간을 두고, 실패하면 마지막으로 관찰한 상태를 출력) "몇 초 뒤"를 단언하지 않는다. AWS CLI의 `wait`는 확인 간격이 길어(RDS·Route 53 30초, CloudFront 60초, EC2 15초 등) 에뮬레이터에서는 한 간격을 통째로 버리기 쉬우므로, 실습 스크립트는 `scripts/lab-wait.sh`의 래퍼(1초 간격, CLI와 같거나 더 엄격한 성공 조건, 실패 상태를 보면 즉시 실패)를 쓴다. 레슨에서 학습자가 입력하는 명령은 `aws ... wait`를 그대로 두고, 실습 스크립트가 다른 이유를 한 줄로 적는다. 이미 빠른 것(Lambda, ELB `load-balancer-available`, DynamoDB `table-exists`, S3 `bucket-exists`)은 CLI `wait`를 써도 된다. 에뮬레이터의 타이밍(TTL 수 초, Firehose 버퍼 무시 등)을 실제 AWS의 특성처럼 설명하지 않는다.
11. **외부 호스트에 닿지 않는다.** 이미지 URI·URL·엔드포인트·발급자 등 호스트 자리에는 예약 이름(`.invalid`·`.test`·`.example`·`.localhost`, RFC 2606의 `example.com`·`example.net`·`example.org`)이나 루프백만 쓴다(메일 주소는 `example.com`). 에뮬레이터가 실제로 접속을 시도할 수 있는 값(컨테이너 이미지 URI, JWT/OIDC 발급자, 웹훅 URL)에는 실제 호스트명을 넣지 않는다. AWS가 정한 예시값이나 가드가 거부해야 하는 주소처럼 의도적인 예외는 그 줄이나 윗줄에 `# external-host-ok: <이유>`를 단다. 정적 검사(`tools/probe/no_external_hosts.py`)는 M00 `verify.sh`에서 `tools`·`scripts`·`src`·`curriculum/` 전체를 검사해 표시 없는 호스트가 있으면 실패한다(탐침은 시작할 때 `tools/probe`만 검사한다). Markdown 출력 블록처럼 줄에 주석을 달 수 없으면 여는 코드 펜스 바로 윗줄에 `<!-- external-host-ok: <이유> -->`를 단다(표시 하나는 블록 하나에만 적용된다). 에뮬레이터 컨테이너는 기본으로 이름 해석이 막힌 채(`--dns 127.0.0.1`, 해제는 `EMULATOR_DNS=host`) 뜨며, 실습은 이 상태에서 통과해야 한다. S3 다중 리전 액세스 포인트 ARN, Kinesis의 `StreamId`(`--stream-id`), sign-in 서비스의 제어 작업은 SDK가 엔드포인트 설정을 무시하고 AWS 호스트 이름을 직접 만들므로 실습에서 쓰지 않는다. TLS 검증을 끄는 옵션(`--no-verify-ssl`, `verify=False`)도 쓰지 않는다 — 위 형태의 요청이 실제 AWS에 전달되지 않게 막는 마지막 장치가 TLS 검증이다. 에뮬레이터가 돌려준 주소에 접속할 때는 정확히 `127.0.0.1`(필요하면 `:포트`)인지 정규식으로 먼저 확인한다 — `127.*`나 `https://127.0.0.1:*` 같은 접두어 비교는 `127.0.0.1.nip.io`와 `https://127.0.0.1:<포트>@<다른 호스트>/`를 통과시킨다(ElastiCache·Aurora 리더 엔드포인트는 실제 AWS 형식 이름이다).
12. **만든 직후 쓰지 않는다.** 생성 API가 `CREATING`/`pending`을 돌려주는 리소스(DataSync 작업, VPC, 마운트 타깃, DynamoDB 테이블 등)는 준비 상태를 폴링한 뒤 다음 호출을 한다. VM에 부하가 걸리면 "보통은 즉시"가 깨진다.
13. **CloudFormation은 `aws cloudformation wait` 대신 `describe-stacks`를 2초 간격으로 폴링**한다(에뮬레이터는 조회가 올 때만 스택을 진행시킨다). 레슨에는 실제 AWS에서는 `wait`가 정상 도구임을 밝힌다.
14. **Lambda 호출 수를 아낀다.** 동기 호출마다 에뮬레이터 메모리가 약 7 MiB 늘고 회수되지 않는다.
15. 실제 AWS 자격 증명·계정을 절대 사용하지 않는다. 모든 실행 전 `aws sts get-caller-identity`의 Account가 `000000000000`인지 env 스크립트가 보장한다. `scripts/env.sh`는 먼저 셸을 AWS에서 분리한 뒤(자격 증명·프로필·`~/.boto` 등 옛 경로를 끄고, 설정 파일과 인증서 묶음을 만들 수 없는 경로로, 엔드포인트를 닫힌 로컬 포트로 돌린다) 계정 확인이 통과해야만 에뮬레이터에 연결한다. 거부되거나 분리 단계 이후에 중단되면 셸은 분리된 채 남고(분리 단계에 들어가기 전의 짧은 준비 구간에서 중단되면 원래 상태 그대로다), `scripts/dr-env.sh`도 그 셸에서는 거부한다. 분리된 셸에서 서명 요청은 보내기 전에 실패하고, SDK가 호스트 이름을 직접 만드는 기능(규칙 11)은 연결을 시도하더라도 TLS 검증에서 끊겨 HTTP 요청이 전달되지 않는다(TLS 검증을 끄지 않는 한).

## 4. 내용 정확성

- 한계값·수치(예: Lambda 15분, SQS 메시지 1 MiB, S3 객체 50 TB — 한계값은 자주 바뀐다)는 확신이 없으면 AWS 공식 문서로 확인한다. 확인 못 한 수치는 쓰지 않는다.
- SAA-C03 범위를 벗어난 깊이(예: 특정 API의 모든 파라미터)는 피한다. 시험이 묻는 것은 "선택"이다.
- 퀴즈는 **자체 제작**만. 실제 시험 문제·덤프 문제를 옮기지 않는다. 문항마다 정답 근거와 오답이 틀린 이유를 쓴다.
- 폐기·개명된 서비스명에 주의 (예: AWS SSO → IAM Identity Center, OAI → OAC 권장).

## 5. Git 규칙

- 브랜치: [AGENTS.md](./AGENTS.md)에 지정된 **역할 브랜치명**을 그대로 쓴다. `main`에 직접 푸시 금지.
- 커밋: `<type>(mNN): 한국어 요약` (type: feat, docs, fix, chore, test). 레슨/실습 단위로 나눠 커밋.
- PR: 제목 `[mNN] 모듈명`, 본문에 ① 레슨·실습 목록과 확정 등급 ② `verify.sh` 실행 결과 마지막 20줄 ③ 발견한 에뮬레이터 제약 ④ 공용 파일 변경 요청을 적는다.
- 커밋 메시지 끝: 커밋을 만든 모델의 `Co-Authored-By` 줄(서브에이전트는 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, 메인 세션은 자기 모델 이름) · PR 본문 끝: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

## 6. 검증 통과 기준 (검증 에이전트 체크리스트)

- [ ] 깨끗한 에뮬레이터에서 `verify.sh`가 0으로 종료한다.
- [ ] 모든 sdk 예제가 클라이언트 생성 전에 `require_emulator()`(두 번째 에뮬레이터를 쓰면 `emulator_site()` / `emulator_site("DR_")`)를 호출하고, 셸 스크립트는 `scripts/env.sh`를 source한다(실제 AWS로 나갈 경로가 없다). `verify.sh`는 sdk 예제마다 `guard_refuses`를 돌린다.
- [ ] 문서에 실린 출력이 실제 실행 결과와 일치한다(표본 3개 이상 대조). 실행마다 바뀌는 값(무작위 ID, ARN 접미사, 타임스탬프, 액세스 키 ID)은 비교에서 제외하고 구조·필드·상태 값·오류 코드와 메시지를 대조한다.
- [ ] 🟡/🔴 실습에 "실제 AWS에서 해 보려면" 메모가 있다.
- [ ] CURRICULUM.md가 요구한 레슨·실습이 모두 있거나, 대체 사유가 README에 있다.
- [ ] 개념 설명에 사실 오류가 없다(시험 포인트·한계값 중심으로 점검).
- [ ] 퀴즈 10문항 이상, 해설 포함, 정답이 맞다. 정답 보기 글자가 고르게 분포한다(한 글자가 40%를 넘지 않는다).
- [ ] 모든 Mermaid 블록이 실제 파서로 파싱된다(저장소에 파서가 없으므로 검증자가 mermaid-cli로 확인한다). 예약되지 않은 도메인·실제 계정 ID가 없다.
- [ ] 에뮬레이터 특이 동작을 AWS의 동작처럼 서술한 곳이 없다.
- [ ] 이 문서의 형식·Git 규칙을 지켰고, 역할 밖 파일을 수정하지 않았다.
- [ ] 모든 상대 링크가 유효하다.

판정은 PR 코멘트로 남긴다: 첫 줄 `VERDICT: PASS` 또는 `VERDICT: CHANGES_REQUESTED`, 이어서 근거 목록.
