# M14 퀴즈 — 모의고사로 대신한다

M14의 퀴즈는 **[SAA-C03 형식 모의고사 65문항](./mock-exam/questions.md)**이다. 모든 문항은 이 커리큘럼을 위해 새로 만든 것이며, 13개 모듈 전체와 시험 범위 서비스를 다룬다.

| | |
|---|---|
| 문제 | [mock-exam/questions.md](./mock-exam/questions.md) — 단일 응답 55 · 복수 응답 10, 도메인 D1 20 · D2 17 · D3 15 · D4 13 |
| 답안지 | [mock-exam/answer-sheet.txt](./mock-exam/answer-sheet.txt)를 복사해 한 줄에 `번호 답` |
| 채점 | `uv run python curriculum/m14-capstone-exam/mock-exam/grade.py my-answers.txt` — 도메인별 점수, 틀린 문항, `?` 표시 후 맞힌 문항 |
| 정답·해설 | [mock-exam/answer-key.md](./mock-exam/answer-key.md) — 정답 근거, **보기마다** 틀린 이유, 복습할 레슨 링크 |
| 시간 | 130분 한 번에 |
| 통과 기준 | 정답률 **72% 이상**(47문항 이상) — [CURRICULUM §7](../../docs/CURRICULUM.md#7-완료-기준)의 자체 기준. 실제 시험의 720점은 환산 점수라 1:1로 대응하지 않는다 |

푼 뒤에는 [레슨 04](./04-exam-logistics-and-study-plan.md)의 오답 노트 템플릿과 마지막 1주 계획으로 이어 간다.

모듈별로 짧게 복습하고 싶다면 각 모듈의 퀴즈(10~13문항)를 다시 푼다: [M01](../m01-iam-identity/quiz.md) · [M02](../m02-vpc-networking/quiz.md) · [M03](../m03-compute-scaling/quiz.md) · [M04](../m04-storage/quiz.md) · [M05](../m05-databases/quiz.md) · [M06](../m06-integration-messaging/quiz.md) · [M07](../m07-serverless-containers/quiz.md) · [M08](../m08-dns-edge/quiz.md) · [M09](../m09-security-encryption/quiz.md) · [M10](../m10-monitoring-iac/quiz.md) · [M11](../m11-analytics/quiz.md) · [M12](../m12-resilience-dr-migration/quiz.md) · [M13](../m13-cost-optimization/quiz.md)
