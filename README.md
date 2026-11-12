# aws-newbie-guide

**aws-emulator로 직접 만져 보며 배우는 AWS SAA-C03** — 백엔드 주니어/신입 개발자를 위한 실습형 커리큘럼.

AWS 계정도, 요금도 필요 없다. 내 노트북에서 도는 [aws-emulator](https://github.com/aws/aws-emulator)에 AWS CLI와 Python(boto3)으로 요청을 보내고, 돌아오는 응답을 눈으로 확인하면서 개념을 익힌다.

## 누구를 위한 것인가

- HTTP·SQL·Linux 기본은 알지만 AWS는 처음인 백엔드 개발자
- SAA-C03(AWS Certified Solutions Architect – Associate)을 "외워서"가 아니라 "이해해서" 따고 싶은 사람

## 어떻게 공부하나

1. [M00 오리엔테이션](./curriculum/m00-orientation/)을 따라 실습 환경을 만든다. *(환경 구축 PR 병합 후 열림)*
2. 모듈을 순서대로 진행한다. 레슨마다 `개념 → 직접 해 보기 → 실제 AWS에서는 → 시험 포인트`.
3. 모듈 끝의 퀴즈를 풀고, 마지막에 캡스톤과 모의고사로 마무리한다.

## 로드맵

| 모듈 | 주제 | 시험 도메인 |
|---|---|---|
| M00 | 오리엔테이션과 실습 환경 | – |
| M01 | IAM과 계정 관리 | 보안 |
| M02 | VPC 네트워킹 | 보안 · 복원력 |
| M03 | 컴퓨트와 확장 (EC2, ELB, Auto Scaling) | 복원력 · 성능 · 비용 |
| M04 | 스토리지 (S3, EBS, EFS, FSx…) | 보안 · 성능 · 비용 |
| M05 | 데이터베이스 (RDS, Aurora, DynamoDB…) | 복원력 · 성능 |
| M06 | 애플리케이션 통합 (SQS, SNS, EventBridge…) | 복원력 |
| M07 | 서버리스와 컨테이너 (Lambda, API Gateway, ECS…) | 복원력 · 성능 |
| M08 | DNS와 엣지 (Route 53, CloudFront…) | 복원력 · 성능 |
| M09 | 보안 서비스와 암호화 (KMS, Secrets Manager…) | 보안 |
| M10 | 모니터링·운영·IaC (CloudWatch, CloudFormation…) | 복원력 |
| M11 | 데이터 분석 (Kinesis, Glue, Athena…) | 성능 |
| M12 | 고가용성·DR·마이그레이션 | 복원력 |
| M13 | 비용 최적화 | 비용 |
| M14 | 캡스톤 + 모의고사 | 전체 |

권장 일정은 8주(주 10~12시간). 자세한 내용은 [커리큘럼 총 설계서](./docs/CURRICULUM.md).

## 알아 둘 것: 에뮬레이터는 AWS가 아니다

aws-emulator는 API의 생성·조회·수정·삭제 동작을 잘 흉내 내지만, IAM 권한 평가, 실제 서버 부팅, Lambda 실행, 다중 리전 같은 것은 재현하지 않는다. 그래서 모든 실습에 등급을 붙였다.

| 등급 | 뜻 |
|---|---|
| 🟢 재현 | 실제처럼 동작한다. 끝까지 실행하고 확인한다 |
| 🟡 부분 | 리소스는 만들어지지만 실제 동작은 일어나지 않는다. 나머지는 설명으로 보충 |
| 🔴 개념 | 에뮬레이터로 볼 수 없다. 다이어그램·워크시트·문제로 학습 |

## 문서

- [커리큘럼 총 설계서](./docs/CURRICULUM.md) — 모듈·레슨·실습 전체 설계
- [작성 규칙](./docs/AUTHORING.md) — 레슨·실습 형식과 검증 기준
- [에이전트 역할과 브랜치](./docs/AGENTS.md) — 누가 무엇을 어느 브랜치에서 만드는가

## 라이선스 / 고지

학습용 자료이며 AWS와 무관한 비공식 가이드다. 퀴즈와 모의고사는 모두 자체 제작 문제다.
