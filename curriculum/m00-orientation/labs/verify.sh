#!/usr/bin/env bash
# M00 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# 모든 lab 과 sdk 예제를 순서대로 실행하고, lab 은 한 번 더 실행해 멱등성을 확인한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m00-orientation/labs/verify.sh
#   DR_EMULATOR_PORT=9298 curriculum/m00-orientation/labs/verify.sh   # 두 번째 에뮬레이터(미리 up)로 두 사이트 시험까지
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m00-orientation"
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

# env.sh 의 시계 어긋남 진단: 서명 거부를 흉내 내는 가짜 aws 와 "20분 뒤" 시각으로 env.sh 를 source 한다.
# (실제 에뮬레이터·VM 시계는 건드리지 않는다)
envsh_clock_diag() {
  local fake out
  fake="$(mktemp -d)"
  printf '#!/bin/sh\necho "An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation" >&2\nexit 254\n' >"$fake/aws"
  chmod +x "$fake/aws"
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_FAKE_NOW="$1" bash -c "source '$ROOT/scripts/env.sh'" 2>&1)" && { rm -rf "$fake"; echo "env.sh 가 통과해 버림"; return 1; }
  rm -rf "$fake"
  echo "$out"
  grep -q "$2" <<<"$out"
}
envsh_clock_skewed() { envsh_clock_diag "$(($(date -u +%s) + 1200))" '\[clock-check\] 시계 어긋남'; }
envsh_sig_no_skew() { envsh_clock_diag "$(date -u +%s)" '서명을 거부했습니다'; }

# 두 번째 사이트(dr-env.sh + emulator_site("DR_")) 실시간 시험은 DR_EMULATOR_PORT 에 에뮬레이터가 떠 있을 때만.
guard_selftest() {
  if [ -n "${DR_EMULATOR_PORT:-}" ]; then
    # shellcheck source=scripts/dr-env.sh
    source "$ROOT/scripts/dr-env.sh" || return 1
  fi
  uv run --quiet python -m emulator_guard.selftest --live
}

cd "$ROOT"
run "안전 장치 자체 시험 (URL 파싱 우회 차단·두 번째 사이트 API·opt-out)" guard_selftest
[ -n "${DR_EMULATOR_PORT:-}" ] || echo "SKIP  두 번째 사이트 실시간 시험 (DR_EMULATOR_PORT 미설정 — 설정하고 그 포트에 에뮬레이터를 띄우면 시험)"
run "env.sh: 서명 거부 + 시계 20분 어긋남 → 시계 어긋남 안내" envsh_clock_skewed
run "env.sh: 서명 거부 + 시계 정상 → 서명 거부 안내" envsh_sig_no_skew
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
for round in 1 2; do
  for lab in "$MOD_DIR"/labs/lab*.sh; do
    run "$(basename "$lab") (실행 $round)" bash "$lab"
  done
done
for py in "$MOD_DIR"/sdk/*.py; do
  run "sdk/$(basename "$py")" uv run --quiet python "$py"
done

echo "----"
echo "통과 $pass · 실패 $fail"
if [ "$fail" -ne 0 ]; then
  echo "MODULE m00 FAIL"
  exit 1
fi
echo "MODULE m00 OK"
