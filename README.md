# aws-newbie-guide

**aws-emulator로 직접 만져 보며 배우는 AWS SAA-C03** — 백엔드 주니어/신입 개발자를 위한 실습형 커리큘럼.

AWS 계정도, 요금도 필요 없다. 내 노트북에서 도는 [aws-emulator](https://github.com/aws/aws-emulator)에 AWS CLI와 Python(boto3)으로 요청을 보내고, 돌아오는 응답을 눈으로 확인하면서 개념을 익힌다.

## 누구를 위한 것인가

- HTTP·SQL·Linux 기본은 알지만 AWS는 처음인 백엔드 개발자
- SAA-C03(AWS Certified Solutions Architect – Associate)을 "외워서"가 아니라 "이해해서" 따고 싶은 사람

## 어떻게 공부하나

1. [M00 오리엔테이션](./curriculum/m00-orientation/)을 따라 실습 환경을 만든다.
2. 모듈을 순서대로 진행한다. 레슨마다 `왜 필요한가 → 핵심 개념 → 직접 해 보기 → 실제 AWS에서는 → 시험 포인트 → 스스로 확인`.
3. 모듈 끝의 퀴즈를 풀고, 마지막에 [M14](./curriculum/m14-capstone-exam/)의 캡스톤과 모의고사로 마무리한다. 시험 직전에는 [통합 치트시트](./curriculum/m14-capstone-exam/cheatsheet.md)(요구 사항 → 서비스, 도메인별) 한 장으로 복습한다.

## 빠른 시작

macOS + [Homebrew](https://brew.sh) 기준 (Linux·WSL은 [M00 레슨 3](./curriculum/m00-orientation/03-environment-setup.md) 참고).

<!-- external-host-ok: 저장소를 받는 설치 안내 -->
```bash
git clone https://github.com/Ring-wdr/aws-newbie-guide.git && cd aws-newbie-guide
scripts/install.sh            # Colima·docker·AWS CLI·uv·jq·python3 확인/설치, 에뮬레이터 이미지 빌드, boto3 설치
scripts/emulator-up.sh        # 에뮬레이터 시작 (https://127.0.0.1:9297, 컨테이너의 외부 이름 해석은 기본으로 차단)
source scripts/env.sh         # 이 셸을 에뮬레이터에 연결 (에뮬레이터가 아니면 연결을 거부하고 이 셸을 AWS에서 분리하는 안전 장치 포함)
aws sts get-caller-identity   # "Account": "000000000000" 이면 준비 완료
```

끝나면 `scripts/emulator-down.sh`. 에뮬레이터가 무엇을 재현하고 무엇을 못 하는지는 각 모듈 README의 **"에뮬레이터 제약"**(모듈 저자가 직접 확인한 최신 관찰)과 서비스별 탐침 결과인 [docs/FIDELITY.md](./docs/FIDELITY.md).

## 가이드 사이트로 보기

같은 내용을 인터랙티브 사이트로도 볼 수 있다. 레슨·치트시트·퀴즈는 이 저장소의 Markdown에서 그대로 만들어지고, 여기에 채점되는 퀴즈, 65문항 모의고사(타이머·응시 기록), 모듈별 진행 추적, M00\~M13 모듈마다 하나씩의 설명용 모형이 더해진다.

```bash
scripts/guide-up.sh           # 사이트를 빌드해 이 컴퓨터에서만 연다 (http://127.0.0.1:4321)
```

- Node 24 이상과 pnpm이 필요하다. 처음 한 번은 패키지와, 다이어그램을 그리는 데 쓰는 헤드리스 Chromium을 받느라 인터넷에 접속한다. 열린 사이트는 외부로 아무 요청도 보내지 않고, 진행 표시는 브라우저에만 저장된다.
- 사이트는 명령을 보여 주고 복사하게 할 뿐 실행하지 않는다. 실습은 위의 빠른 시작처럼 터미널에서 한다.
- 화면의 "모형"은 개념을 설명하는 계산일 뿐 에뮬레이터나 AWS의 실행 결과가 아니다.
- Markdown만으로도 전부 학습할 수 있다. GitHub에서 읽거나 편집기로 열면 된다.

## 로드맵

각 모듈은 `README.md`(목표·레슨·실습 등급·에뮬레이터 제약) → 레슨 → `labs/` → `cheatsheet.md` → `quiz.md` 순서다. 모듈마다 `labs/verify.sh`가 깨끗한 에뮬레이터에서 모든 실습을 다시 돌려 검증한다.

| 모듈 | 주제 | 시험 도메인 | 바로 가기 |
|---|---|---|---|
| [M00](./curriculum/m00-orientation/) | 오리엔테이션과 실습 환경 (에뮬레이터, CLI·boto3, 글로벌 인프라) | – | [치트시트](./curriculum/m00-orientation/cheatsheet.md) · [퀴즈](./curriculum/m00-orientation/quiz.md) |
| [M01](./curriculum/m01-iam-identity/) | IAM과 계정 관리 (정책 평가, 역할·STS, Organizations·SCP, 연동) | 보안 | [치트시트](./curriculum/m01-iam-identity/cheatsheet.md) · [퀴즈](./curriculum/m01-iam-identity/quiz.md) |
| [M02](./curriculum/m02-vpc-networking/) | VPC 네트워킹 (3-티어 VPC, SG·NACL, 엔드포인트, 하이브리드 연결) | 보안 · 복원력 | [치트시트](./curriculum/m02-vpc-networking/cheatsheet.md) · [퀴즈](./curriculum/m02-vpc-networking/quiz.md) |
| [M03](./curriculum/m03-compute-scaling/) | 컴퓨트와 확장 (EC2, 구매 옵션, EBS, ELB, Auto Scaling) | 복원력 · 성능 · 비용 | [치트시트](./curriculum/m03-compute-scaling/cheatsheet.md) · [퀴즈](./curriculum/m03-compute-scaling/quiz.md) |
| [M04](./curriculum/m04-storage/) | 스토리지 (S3 클래스·보안·복제, EFS·FSx, 하이브리드 이전) | 보안 · 성능 · 비용 | [치트시트](./curriculum/m04-storage/cheatsheet.md) · [퀴즈](./curriculum/m04-storage/quiz.md) |
| [M05](./curriculum/m05-databases/) | 데이터베이스 (RDS·Aurora, DynamoDB, 캐시, 목적별 DB) | 복원력 · 성능 | [치트시트](./curriculum/m05-databases/cheatsheet.md) · [퀴즈](./curriculum/m05-databases/quiz.md) |
| [M06](./curriculum/m06-integration-messaging/) | 애플리케이션 통합 (SQS, SNS, EventBridge, Step Functions, Kinesis) | 복원력 | [치트시트](./curriculum/m06-integration-messaging/cheatsheet.md) · [퀴즈](./curriculum/m06-integration-messaging/quiz.md) |
| [M07](./curriculum/m07-serverless-containers/) | 서버리스와 컨테이너 (Lambda, API Gateway, Cognito, ECS) | 복원력 · 성능 | [치트시트](./curriculum/m07-serverless-containers/cheatsheet.md) · [퀴즈](./curriculum/m07-serverless-containers/quiz.md) |
| [M08](./curriculum/m08-dns-edge/) | DNS와 엣지 (Route 53, CloudFront, Global Accelerator, WAF) | 복원력 · 성능 | [치트시트](./curriculum/m08-dns-edge/cheatsheet.md) · [퀴즈](./curriculum/m08-dns-edge/quiz.md) |
| [M09](./curriculum/m09-security-encryption/) | 보안 서비스와 암호화 (KMS, Secrets Manager, ACM, CloudTrail·Config, 위협 탐지) | 보안 | [치트시트](./curriculum/m09-security-encryption/cheatsheet.md) · [퀴즈](./curriculum/m09-security-encryption/quiz.md) |
| [M10](./curriculum/m10-monitoring-iac/) | 모니터링·운영·IaC (CloudWatch, CloudFormation, Systems Manager) | 복원력 | [치트시트](./curriculum/m10-monitoring-iac/cheatsheet.md) · [퀴즈](./curriculum/m10-monitoring-iac/quiz.md) |
| [M11](./curriculum/m11-analytics/) | 데이터 분석 (Firehose, Glue, Athena, AI/ML 서비스) | 성능 | [치트시트](./curriculum/m11-analytics/cheatsheet.md) · [퀴즈](./curriculum/m11-analytics/quiz.md) |
| [M12](./curriculum/m12-resilience-dr-migration/) | 고가용성·DR·마이그레이션 (SPOF, DR 4전략, AWS Backup, DMS) | 복원력 | [치트시트](./curriculum/m12-resilience-dr-migration/cheatsheet.md) · [퀴즈](./curriculum/m12-resilience-dr-migration/quiz.md) |
| [M13](./curriculum/m13-cost-optimization/) | 비용 최적화 (과금 구조, 구매 옵션, 데이터 전송, 비용 도구) | 비용 | [치트시트](./curriculum/m13-cost-optimization/cheatsheet.md) · [퀴즈](./curriculum/m13-cost-optimization/quiz.md) |
| [M14](./curriculum/m14-capstone-exam/) | 종합: Well-Architected 리뷰, 캡스톤(한 번에 짓고 시험하고 지우기), 모의고사 65문항 | 전체 | [통합 치트시트](./curriculum/m14-capstone-exam/cheatsheet.md) · [모의고사](./curriculum/m14-capstone-exam/mock-exam/questions.md) |

권장 일정은 8주(주 10~12시간, 8주차가 M14). 자세한 내용은 [커리큘럼 총 설계서](./docs/CURRICULUM.md).

### 끝났다면 — 완료 기준

1. 모든 모듈의 `labs/verify.sh`가 통과하고 각 퀴즈 80% 이상.
2. [캡스톤 자기 점검표](./curriculum/m14-capstone-exam/capstone-self-check.md) 완료.
3. [모의고사](./curriculum/m14-capstone-exam/mock-exam/questions.md) 정답률 72% 이상(자체 기준 — 실제 합격선 720점은 환산 점수라 1:1이 아니다). 시험 접수와 마지막 1주 계획은 [M14 레슨 4](./curriculum/m14-capstone-exam/04-exam-logistics-and-study-plan.md).

## 알아 둘 것: 에뮬레이터는 AWS가 아니다

aws-emulator는 생각보다 많은 것을 실제처럼 해낸다 — Lambda 코드가 실행되고, SNS 메시지가 SQS에 도착하고, CloudFormation이 (대부분의) 리소스를 만든다. 하지만 서버가 실제로 부팅되지는 않고, 자동 조정·장애 조치·다중 리전은 재현하지 않으며, IAM 권한 평가는 서비스마다 다르다. 그래서 모든 실습에 등급을 붙였고, 근거는 각 모듈 README의 "에뮬레이터 제약"과 [충실도 보고서](./docs/FIDELITY.md)에 있다.

| 등급 | 뜻 |
|---|---|
| 🟢 재현 | 실제처럼 동작한다. 끝까지 실행하고 확인한다 |
| 🟡 부분 | 리소스는 만들어지지만 동작의 일부 또는 전부가 일어나지 않는다. 나머지는 설명으로 보충 |
| 🔴 개념 | 에뮬레이터로 볼 수 없다. 다이어그램·워크시트·문제로 학습 |

## 문서

- [커리큘럼 총 설계서](./docs/CURRICULUM.md) — 모듈·레슨·실습 전체 설계
- [작성 규칙](./docs/AUTHORING.md) — 레슨·실습 형식과 검증 기준
- [에이전트 역할과 브랜치](./docs/AGENTS.md) — 누가 무엇을 어느 브랜치에서 만드는가
- [가이드 사이트 설계](./docs/GUIDE-SITE.md) — Markdown 원고를 인터랙티브 사이트로 보여 주는 방식과 검증 기준

## 라이선스 / 고지

학습용 자료이며 AWS와 무관한 비공식 가이드다. 퀴즈와 모의고사는 모두 자체 제작 문제다.
