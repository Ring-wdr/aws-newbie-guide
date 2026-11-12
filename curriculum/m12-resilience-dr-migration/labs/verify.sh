#!/usr/bin/env bash
# M12 모듈 검증: 에뮬레이터 두 개를 다룬다.
#   주 리전 "서울" = $EMULATOR_PORT            → 재시작(깨끗한 상태)
#   DR 리전 "도쿄" = $DR_EMULATOR_PORT (기본 EMULATOR_PORT+1) → 재시작, 끝나면(성공·실패 모두) 끈다
# 그다음 sdk 안전 장치 확인 → 모든 lab 을 두 번씩(멱등성) → sdk 예제 순서로 실행한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297, DR 은 9298)
#   curriculum/m12-resilience-dr-migration/labs/verify.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m12-resilience-dr-migration"
LOG_DIR="$(mktemp -d)"

# 1) 깨끗한 에뮬레이터 두 개 (EMULATOR_PORT 가 없으면 비대화형 셸에서는 거부된다)
"$ROOT/scripts/emulator-reset.sh"
export EMULATOR_PORT="${EMULATOR_PORT:-9297}"
export DR_EMULATOR_PORT="${DR_EMULATOR_PORT:-$((EMULATOR_PORT + 1))}"
trap 'rm -rf "$LOG_DIR"; "$ROOT/scripts/emulator-down.sh" "$DR_EMULATOR_PORT" >/dev/null 2>&1 || true' EXIT
"$ROOT/scripts/emulator-reset.sh" "$DR_EMULATOR_PORT"
source "$ROOT/scripts/env.sh"
source "$MOD_DIR/labs/dr-env.sh"

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
# 네트워크 호출 전에 종료 코드 1로 멈춰야 한다. (M00 verify.sh 의 guard_refuses 와 같다)
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

# DR 쪽 안전 장치: 주 리전은 정상인데 DR_AWS_ENDPOINT_URL 이 실제 AWS(도쿄 리전) 주소를 가리키면,
# DR 클라이언트를 만들기 전에 같은 emulator_guard 가 거부해야 한다. 혹시 실제 AWS로 나가는 요청이 있으면
# 닫힌 프록시 포트로 보내 즉시 실패하게 한다(127.0.0.1 은 프록시를 거치지 않으므로 주 리전 확인은 정상 동작).
guard_refuses_dr() {
  local out rc
  out="$(env -u TODAYORDER_ALLOW_REAL_AWS DR_AWS_ENDPOINT_URL=https://dynamodb.ap-northeast-1.amazonaws.com \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1 UV_OFFLINE=1 \
    uv run --quiet python "$1" status 2>&1)"
  rc=$?
  echo "$out"
  [ "$rc" -eq 1 ] || { echo "종료 코드가 1이 아님: $rc"; return 1; }
  grep -q "^\[emulator_guard\] AWS_ENDPOINT_URL 이 로컬 에뮬레이터(https://127.0.0.1:<포트>)가 아닙니다: 'https://dynamodb.ap-northeast-1" <<<"$out" || return 1
  ! grep -qE 'Traceback|연결하지 못했습니다' <<<"$out"
}

cd "$ROOT"
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
run "안전 장치: DR 엔드포인트가 실제 AWS 이면 sdk/dr_replicate.py 가 DR 클라이언트 생성 전 거부" \
  guard_refuses_dr "$MOD_DIR/sdk/dr_replicate.py"

for round in 1 2; do
  for lab in "$MOD_DIR"/labs/lab*.sh; do
    run "$(basename "$lab") (실행 $round)" bash "$lab"
  done
done

# sdk 예제: 의존 순서대로 (주문 앱 → DR 복제 → SPOF 감사(lab01 이 남긴 VPC) → 태그 기반 백업)
for py in order_app.py dr_replicate.py spof_audit.py backup_tagged_tables.py; do
  run "sdk/$py" uv run --quiet python "$MOD_DIR/sdk/$py"
done

echo "----"
echo "통과 $pass · 실패 $fail  (DR 리전 에뮬레이터 포트 $DR_EMULATOR_PORT 는 종료합니다)"
if [ "$fail" -ne 0 ]; then
  echo "MODULE m12 FAIL"
  exit 1
fi
echo "MODULE m12 OK"
