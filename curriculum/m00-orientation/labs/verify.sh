#!/usr/bin/env bash
# M00 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# 모든 lab 과 sdk 예제를 순서대로 실행하고, lab 은 한 번 더 실행해 멱등성을 확인한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m00-orientation/labs/verify.sh
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

cd "$ROOT"
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
