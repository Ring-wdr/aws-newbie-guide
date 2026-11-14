#!/usr/bin/env bash
# M14 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
#   1) sdk 예제의 안전 장치(env.sh 없이 실행하면 네트워크 호출 전 거부)
#   2) 모의고사 형식 점검(정답표·문제·해설 일치, 도메인·정답 분포)과 채점기 자가 시험, Well-Architected Tool lab07 두 번
#   3) 캡스톤 1회차: lab01~05 → 감사 → lab01~05 다시(이미 있는 환경에서 멱등) → 감사 → lab06 정리
#   4) 캡스톤 2회차: 깨끗해진 상태에서 lab05 하나로 전체를 한 번에 짓기 → 감사 → lab06 → lab06 다시(빈 상태에서 멱등)
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m14-capstone-exam/labs/verify.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m14-capstone-exam"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 깨끗한 에뮬레이터 (EMULATOR_PORT 가 없으면 비대화형 셸에서는 거부된다)
"$ROOT/scripts/emulator-reset.sh"
export EMULATOR_PORT="${EMULATOR_PORT:-9297}"
source "$ROOT/scripts/env.sh"

pass=0
fail=0
run() {
  local label="$1"
  shift
  if "$@" >"$LOG_DIR/out" 2>&1; then
    echo "PASS  $label"
    pass=$((pass + 1))
  else
    echo "FAIL  $label"
    sed 's/^/      | /' "$LOG_DIR/out" | tail -20
    fail=$((fail + 1))
  fi
}

# boto3 예제의 안전 장치(emulator_guard) 확인 — M00 verify.sh 와 같은 시험.
# env.sh 없이(AWS_ENDPOINT_URL 없음) 실행하면 네트워크 호출 전에 종료 코드 1로 멈춰야 한다. 더미 키만 쓰고,
# 사용자의 ~/.aws 설정은 읽지 않게 /dev/null 로 막고, 혹시 나가는 요청이 있으면 즉시 실패하도록 프록시를 닫힌 포트로 보낸다.
guard_refuses() {
  local out rc
  out="$(env -u AWS_ENDPOINT_URL -u AWS_CA_BUNDLE -u AWS_PROFILE -u AWS_SESSION_TOKEN -u TODAYORDER_ALLOW_REAL_AWS \
    AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=dummy-not-a-real-key \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY= UV_OFFLINE=1 \
    uv run --quiet python "$1" 2>&1)"
  rc=$?
  echo "$out"
  [ "$rc" -eq 1 ] || { echo "종료 코드가 1이 아님: $rc"; return 1; }
  # 첫 단계(환경 변수 검사, 네트워크 없음)의 메시지여야 한다. STS 연결 실패 메시지면 네트워크를 시도한 것이다.
  grep -q '^\[emulator_guard\] AWS_ENDPOINT_URL 이 로컬 에뮬레이터' <<<"$out" || return 1
  ! grep -qE 'Traceback|연결하지 못했습니다' <<<"$out"
}

GRADE="$MOD_DIR/mock-exam/grade.py"
grader_full_marks() {  # 정답표를 답안으로 넣으면 65/65
  uv run --quiet python "$GRADE" --key >"$LOG_DIR/key.txt"
  uv run --quiet python "$GRADE" "$LOG_DIR/key.txt" | tee "$LOG_DIR/g1"
  grep -q '전체 65/65 = 100.0%' "$LOG_DIR/g1"
}
grader_partial() {  # 앞 47문항만 정답 + 48번은 오답 + 나머지 무응답 → 47/65 = 72.3% 통과, 48번은 틀린 문항 목록에
  head -47 "$LOG_DIR/key.txt" >"$LOG_DIR/partial.txt"
  echo "48 A  # 정답은 B" >>"$LOG_DIR/partial.txt"
  uv run --quiet python "$GRADE" "$LOG_DIR/partial.txt" | tee "$LOG_DIR/g2"
  grep -q '전체 47/65 = 72.3%' "$LOG_DIR/g2" && grep -q '판정: 통과' "$LOG_DIR/g2" && grep -qE '^ +48번 D1 1\.1 내 답 A +정답 B' "$LOG_DIR/g2"
}
grader_blank_sheet() {  # 빈 답안지 → 0점, 미달
  uv run --quiet python "$GRADE" "$MOD_DIR/mock-exam/answer-sheet.txt" | tee "$LOG_DIR/g3"
  grep -q '전체 0/65' "$LOG_DIR/g3" && grep -q '판정: 미달' "$LOG_DIR/g3"
}
grader_warns() {  # 같은 번호 두 번 · 66번 · 글자 없는 답 → 경고 3개(표준 오류), 빈 답안지 → 경고 0개
  printf '1 C\n1 B\n66 A\n2 Z\n' >"$LOG_DIR/odd.txt"
  uv run --quiet python "$GRADE" "$LOG_DIR/odd.txt" 2>"$LOG_DIR/g4" >/dev/null
  uv run --quiet python "$GRADE" "$MOD_DIR/mock-exam/answer-sheet.txt" 2>"$LOG_DIR/g5" >/dev/null
  cat "$LOG_DIR/g4"
  [ "$(grep -c '^경고:' "$LOG_DIR/g4")" = 3 ] && grep -q '1번이 두 번' "$LOG_DIR/g4" && grep -q '66번은 없는 문항' "$LOG_DIR/g4" \
    && grep -q '2번 답에 A~F 글자가 없다' "$LOG_DIR/g4" && [ ! -s "$LOG_DIR/g5" ]
}

cd "$ROOT"
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
run "모의고사 형식 점검 (65문항, 도메인 20/17/15/13, 정답표·문제·해설 일치, 단일 응답 정답 글자 30% 이하, 정답이 가장 긴 보기 30% 이하)" uv run --quiet python "$GRADE" --stats
run "채점기: 정답표 그대로 → 65/65" grader_full_marks
run "채점기: 47문항 정답 → 72.3% 통과, 틀린 문항 표시" grader_partial
run "채점기: 빈 답안지 → 0점 미달" grader_blank_sheet
run "채점기: 중복 번호·없는 번호·글자 없는 답 → 경고" grader_warns

AUDIT=(uv run --quiet python "$MOD_DIR/sdk/capstone_audit.py")
L="$MOD_DIR/labs"
run "lab07-well-architected-tool.sh (1)" bash "$L/lab07-well-architected-tool.sh"
run "lab07-well-architected-tool.sh (2, 멱등)" bash "$L/lab07-well-architected-tool.sh"
echo "-- 캡스톤 1회차: 계층별로 짓기 → 같은 환경에서 다시 → 정리"
for pass_no in 1 2; do
  for lab in "$L"/lab0[1-5]-*.sh; do
    run "$(basename "$lab") (1회차-$pass_no)" bash "$lab"
  done
  run "sdk/capstone_audit.py (1회차-$pass_no)" "${AUDIT[@]}"
done
run "lab06-teardown.sh (1회차)" bash "$L/lab06-teardown.sh"
echo "-- 캡스톤 2회차: 정리된 에뮬레이터에서 lab05 하나로 전체 짓기 → 정리 → 빈 상태에서 정리 다시"
run "lab05-smoke-test.sh (2회차, 전 계층 자동 구축)" bash "$L/lab05-smoke-test.sh"
run "sdk/capstone_audit.py (2회차)" "${AUDIT[@]}"
run "lab06-teardown.sh (2회차)" bash "$L/lab06-teardown.sh"
run "lab06-teardown.sh (2회차, 빈 상태에서 다시)" bash "$L/lab06-teardown.sh"

echo "SKIP  대상 추적 조정 정책·ASG 자가 치유 (PutScalingPolicy 501, 종료해도 교체 안 됨 — 레슨 02 설계 문서에 정책 JSON)"
echo "SKIP  RDS Multi-AZ 장애 조치·실제 SQL 접속 (장애 조치 재현 안 됨, 엔드포인트가 컨테이너 안 — 구성만 단언)"
echo "SKIP  ALB HTTPS 요청·WAF (ALB 주소가 컨테이너 안 — 리스너·인증서 구성만 단언, 레슨 02에 다이어그램)"
echo "SKIP  DynamoDB·RDS 대상 Config 규칙 (이 에뮬레이터의 Config 는 S3 버킷만 기록 — sdk/capstone_audit.py 가 직접 점검)"
echo "----"
echo "통과 $pass · 실패 $fail"
if [ "$fail" -ne 0 ]; then
  # 이번 실행 동안 VM 시계가 반복해서 옮겨졌다면 실패 원인 후보로 알린다 (안정·확인 불가면 아무것도 출력하지 않음, 언제나 0)
  bash "$ROOT/scripts/clock-check.sh" --stability --summary --last "$SECONDS" || true
  echo "MODULE m14 FAIL"
  exit 1
fi
echo "MODULE m14 OK"
