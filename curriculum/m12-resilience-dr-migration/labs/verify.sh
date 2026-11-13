#!/usr/bin/env bash
# M12 모듈 검증: 에뮬레이터 두 개를 다룬다.
#   주 리전 "서울" = $EMULATOR_PORT            → 재시작(깨끗한 상태)
#   DR 리전 "도쿄" = $DR_EMULATOR_PORT → 재시작, 끝나면(성공·실패 모두) 끈다
#     (대화형 터미널에서만 생략 가능: 기본 EMULATOR_PORT+1. 비대화형에서는 반드시 지정 — 아니면 거부)
# 그다음 sdk 안전 장치 확인 → 모든 lab 을 두 번(1회차 번호 순, 2회차 역순 — 멱등성·순서 무관성) → sdk 예제 순서로 실행한다.
#
#   export EMULATOR_PORT=9297 DR_EMULATOR_PORT=9298
#   (학습자가 터미널에서 직접 실행하면 생략 가능: 9297, DR 9298)
#   curriculum/m12-resilience-dr-migration/labs/verify.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m12-resilience-dr-migration"

# 0) 포트 확인 — 아무것도 지우기 전에. 두 포트를 **기본값까지 정한 뒤** 비교한다.
#    - 주 포트: EMULATOR_PORT. 없으면 대화형 터미널에서만 9297(emulator-reset.sh 와 같은 규칙), 비대화형이면 거부
#    - DR 포트: DR_EMULATOR_PORT. 없으면 대화형 터미널에서만 주 포트 + 1, 비대화형이면 거부
#      (EMULATOR_PORT+1 은 다른 에이전트·사람의 에뮬레이터일 수 있으므로 추측해서 지우지 않는다)
if [ -z "${EMULATOR_PORT:-}" ] && [ ! -t 0 ]; then
  echo "오류: EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 기본 포트를 쓰지 않습니다. 'export EMULATOR_PORT=<포트>' 후 다시 실행하세요." >&2
  exit 1
fi
if [ -z "${DR_EMULATOR_PORT:-}" ] && [ ! -t 0 ]; then
  echo "오류: DR_EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 DR 리전 포트를 추측하지 않습니다." >&2
  echo "      이 스크립트는 그 포트의 에뮬레이터를 재시작·종료합니다. 'export DR_EMULATOR_PORT=<포트>' 후 다시 실행하세요." >&2
  exit 1
fi
export EMULATOR_PORT="${EMULATOR_PORT:-9297}"
export DR_EMULATOR_PORT="${DR_EMULATOR_PORT:-$((EMULATOR_PORT + 1))}"
if [ "$DR_EMULATOR_PORT" = "$EMULATOR_PORT" ]; then
  echo "오류: DR_EMULATOR_PORT 가 EMULATOR_PORT 와 같습니다($DR_EMULATOR_PORT). 서로 다른 에뮬레이터여야 합니다." >&2
  exit 1
fi

# 1) 깨끗한 에뮬레이터 두 개. 임시 폴더는 포트 확인을 통과한 뒤에 만든다(거부 경로에서 남지 않게).
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT
"$ROOT/scripts/emulator-reset.sh"
trap 'rm -rf "$LOG_DIR"; "$ROOT/scripts/emulator-down.sh" "$DR_EMULATOR_PORT" >/dev/null 2>&1 || true' EXIT
"$ROOT/scripts/emulator-reset.sh" "$DR_EMULATOR_PORT"
source "$ROOT/scripts/env.sh"
source "$ROOT/scripts/dr-env.sh"

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
# DR 클라이언트를 만들기 전에 emulator_site("DR_") 가 거부해야 한다. 혹시 실제 AWS로 나가는 요청이 있으면
# 닫힌 프록시 포트로 보내 즉시 실패하게 한다(127.0.0.1 은 프록시를 거치지 않으므로 주 리전 확인은 정상 동작).
guard_refuses_dr() {
  local out rc
  # external-host-ok: 가드가 거부해야 하는 실제 AWS 주소(가드 자체 시험). 요청은 나가지 않는다 — 거부되고, 혹시 나가도 닫힌 프록시(127.0.0.1:9)로 막힌다
  out="$(env -u TODAYORDER_ALLOW_REAL_AWS DR_AWS_ENDPOINT_URL=https://dynamodb.ap-northeast-1.amazonaws.com \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1 UV_OFFLINE=1 \
    uv run --quiet python "$1" status 2>&1)"
  rc=$?
  echo "$out"
  [ "$rc" -eq 1 ] || { echo "종료 코드가 1이 아님: $rc"; return 1; }
  # external-host-ok: 위 거부 메시지에 담긴 주소를 확인할 뿐 접속하지 않는다
  grep -q "^\[emulator_guard\] DR_AWS_ENDPOINT_URL 이 로컬 에뮬레이터(https://127.0.0.1:<포트>)가 아닙니다: 'https://dynamodb.ap-northeast-1" <<<"$out" || return 1
  ! grep -qE 'Traceback|연결하지 못했습니다' <<<"$out"
}

cd "$ROOT"
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
run "안전 장치: DR 엔드포인트가 실제 AWS 이면 sdk/dr_replicate.py 가 DR 클라이언트 생성 전 거부" \
  guard_refuses_dr "$MOD_DIR/sdk/dr_replicate.py"

# 1회차는 번호 순서, 2회차는 역순 — "두 번 연속 실행해도, 다른 lab 뒤에 실행해도" 통과하는지 확인한다.
labs=("$MOD_DIR"/labs/lab*.sh)
for lab in "${labs[@]}"; do
  run "$(basename "$lab") (실행 1)" bash "$lab"
done
for ((i = ${#labs[@]} - 1; i >= 0; i--)); do
  run "$(basename "${labs[$i]}") (실행 2, 역순)" bash "${labs[$i]}"
done

# sdk 예제: 의존 순서대로 (주문 앱 → DR 복제 → SPOF 감사(lab01 이 남긴 VPC) → 태그 기반 백업)
# (역순 2회차는 lab01 로 끝나므로 SPOF 감사가 볼 VPC 는 바로 앞 실행이 남긴 것이다)
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
