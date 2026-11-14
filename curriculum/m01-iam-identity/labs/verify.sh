#!/usr/bin/env bash
# M01 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# sdk 예제의 안전 장치를 확인하고, 모든 lab 을 두 번(1회차 번호 순, 2회차 역순 — 멱등성·순서 무관성) 실행하고, sdk 예제를 실행한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m01-iam-identity/labs/verify.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m01-iam-identity"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 1) 깨끗한 에뮬레이터 (EMULATOR_PORT 가 없으면 비대화형 셸에서는 거부된다)
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

# boto3 예제의 안전 장치(emulator_guard) 확인: env.sh 없이(AWS_ENDPOINT_URL 없음) 실행하면
# 네트워크 호출 전에 종료 코드 1로 멈춰야 한다. 더미 키만 쓰고, 사용자의 ~/.aws 설정은 읽지 않게
# /dev/null 로 막고, 혹시 나가는 요청이 있으면 즉시 실패하도록 프록시를 닫힌 포트로 보낸다.
# (M00 verify.sh 의 guard_refuses 를 그대로 가져왔다)
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

cd "$ROOT"
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
# 1회차는 번호 순서, 2회차는 역순 — "두 번 연속 실행해도, 다른 lab 뒤에 실행해도" 통과하는지 확인한다.
labs=("$MOD_DIR"/labs/lab*.sh)
for lab in "${labs[@]}"; do
  run "$(basename "$lab") (실행 1)" bash "$lab"
done
for ((i = ${#labs[@]} - 1; i >= 0; i--)); do
  run "$(basename "${labs[$i]}") (실행 2, 역순)" bash "${labs[$i]}"
done
# 학습자 답 채점 모드도 한 번 확인 (정답을 넣으면 만점이어야 한다)
run "lab04 채점 모드 (MY_ANSWERS = 정답)" env MY_ANSWERS="A D D A D I I I I A" bash "$MOD_DIR/labs/lab04-policy-worksheet.sh"
run "lab06 채점 모드 (MY_ANSWERS = 정답)" env MY_ANSWERS="D A D A I A I I A D" bash "$MOD_DIR/labs/lab06-scp-worksheet.sh"
for py in "$MOD_DIR"/sdk/*.py; do
  run "sdk/$(basename "$py")" uv run --quiet python "$py"
done

echo "----"
echo "통과 $pass · 실패 $fail"
if [ "$fail" -ne 0 ]; then
  # 이번 실행 동안 VM 시계가 반복해서 옮겨졌다면 실패 원인 후보로 알린다 (안정·확인 불가면 아무것도 출력하지 않음, 언제나 0)
  bash "$ROOT/scripts/clock-check.sh" --stability --summary --last "$SECONDS" || true
  echo "MODULE m01 FAIL"
  exit 1
fi
echo "MODULE m01 OK"
