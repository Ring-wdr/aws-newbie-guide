#!/usr/bin/env bash
# M00 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# 모든 lab 과 sdk 예제를 실행하고, lab 은 역순으로 한 번 더 실행해 멱등성·순서 무관성을 확인한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m00-orientation/labs/verify.sh
#   DR_EMULATOR_PORT=9298 curriculum/m00-orientation/labs/verify.sh   # 두 번째 에뮬레이터(미리 up)로 두 사이트 시험까지
#     (지정했는데 그 포트에 에뮬레이터가 없으면 아무것도 리셋하지 않고 원인·해결 방법을 출력하며 멈춘다)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m00-orientation"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 0) DR_EMULATOR_PORT 를 지정했다면 두 사이트 시험을 요청한 것이다. M12 verify.sh 처럼 두 번째 사이트를
#    빠뜨리고 넘어가지 않고, 아무것도 리셋하기 전에 원인과 해결 방법을 알리고 멈춘다.
#    (M12 와 달리 이 스크립트는 두 번째 에뮬레이터를 직접 띄우거나 지우지 않는다 — 미리 띄워 둔 것을 쓴다)
if [ -n "${DR_EMULATOR_PORT:-}" ]; then
  # shellcheck source=scripts/_common.sh
  . "$ROOT/scripts/_common.sh"
  validate_port "$DR_EMULATOR_PORT"
  if [ "$DR_EMULATOR_PORT" = "${EMULATOR_PORT:-9297}" ]; then
    die "DR_EMULATOR_PORT 가 EMULATOR_PORT 와 같습니다($DR_EMULATOR_PORT). 서로 다른 에뮬레이터여야 합니다."
  fi
  if [ "$(container_state "$DR_EMULATOR_PORT")" != "running" ] || ! health_ok "$DR_EMULATOR_PORT"; then
    die "DR_EMULATOR_PORT=$DR_EMULATOR_PORT 에 에뮬레이터가 떠 있지 않아 두 사이트 시험을 할 수 없습니다. 먼저 'scripts/emulator-up.sh $DR_EMULATOR_PORT' 로 띄우거나, 두 사이트 시험 없이 돌리려면 'unset DR_EMULATOR_PORT' 후 다시 실행하세요."
  fi
fi

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
envsh_clock_diag() {  # $1=가짜 현재 시각 $2=가짜 aws 의 stderr 문구 $3=종료 코드 $4=기대 문구 $5=있으면 안 되는 문구
  local fake out
  fake="$(mktemp -d)"
  printf '#!/bin/sh\n[ -n "%s" ] && echo "%s" >&2\nexit %s\n' "$2" "$2" "$3" >"$fake/aws"
  chmod +x "$fake/aws"
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_FAKE_NOW="$1" bash -c "source '$ROOT/scripts/env.sh'" 2>&1)" && { rm -rf "$fake"; echo "env.sh 가 통과해 버림"; return 1; }
  rm -rf "$fake"
  echo "$out"
  grep -q "$4" <<<"$out" || return 1
  [ -z "${5:-}" ] || ! grep -q "$5" <<<"$out"
}
SIGERR="An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation"
now_plus() { echo "$(($(date -u +%s) + $1))"; }
envsh_sig_skew20() { envsh_clock_diag "$(now_plus 1200)" "$SIGERR" 254 '\[clock-check\] 시계 어긋남'; }
envsh_sig_skew2() { envsh_clock_diag "$(now_plus 120)" "$SIGERR" 254 '서명을 거부했습니다' '시계 어긋남 때문에'; }
envsh_nosig_skew20() { envsh_clock_diag "$(now_plus 1200)" "" 255 '확인하지 못했습니다' '시계 어긋남'; }

# dr-env.sh: 비대화형에서 DR_EMULATOR_PORT 없으면 거부하고, 실패하면 이전 DR_AWS_* 를 남기지 않는다.
drenv_refuses_without_port() {
  local out
  out="$(env -u DR_EMULATOR_PORT DR_AWS_ENDPOINT_URL=https://127.0.0.1:1 bash -c \
    "source '$ROOT/scripts/env.sh' 2>/dev/null; source '$ROOT/scripts/dr-env.sh'; echo rc=\$?; echo \"left=\${DR_AWS_ENDPOINT_URL:-}\"" </dev/null 2>&1)"
  echo "$out"
  grep -q 'DR_EMULATOR_PORT 가 설정되지 않았습니다' <<<"$out" && grep -q '^rc=1$' <<<"$out" && grep -q '^left=$' <<<"$out"
}
drenv_bad_port_clears() {
  local out
  out="$(DR_EMULATOR_PORT=notaport DR_AWS_ENDPOINT_URL=https://127.0.0.1:1 bash -c \
    "source '$ROOT/scripts/env.sh' 2>/dev/null; source '$ROOT/scripts/dr-env.sh'; echo rc=\$?; echo \"left=\${DR_AWS_ENDPOINT_URL:-}\"" </dev/null 2>&1)"
  echo "$out"
  grep -q '^rc=1$' <<<"$out" && grep -q '^left=$' <<<"$out"
}

# 두 번째 사이트(dr-env.sh + emulator_site("DR_")) 실시간 시험은 DR_EMULATOR_PORT 에 에뮬레이터가 떠 있을 때만.
# 하위 셸에서 실행해, dr-env.sh 가 실패해도(bash 3.2 의 set -e 처리 포함) verify.sh 전체가 아니라 이 항목만 FAIL 이 되게 한다.
guard_selftest() (
  if [ -n "${DR_EMULATOR_PORT:-}" ]; then
    # shellcheck source=scripts/dr-env.sh
    source "$ROOT/scripts/dr-env.sh" || exit 1
  fi
  uv run --quiet python -m emulator_guard.selftest --live
)

# 탐침·스크립트·가드·커리큘럼(M00~M14) 코드가 바깥 호스트(이미지 레지스트리·URL·구독 엔드포인트)를 가리키지 않는지 정적으로 검사
no_external_hosts() {
  uv run --quiet python tools/probe/no_external_hosts.py
}

cd "$ROOT"
run "외부 호스트 정적 검사 (tools·scripts·src·curriculum 전체에 예약 이름·루프백 이외 주소 없음)" no_external_hosts
run "안전 장치 자체 시험 (URL 파싱 우회 차단·두 번째 사이트 API·opt-out)" guard_selftest
[ -n "${DR_EMULATOR_PORT:-}" ] || echo "SKIP  두 번째 사이트 실시간 시험 (DR_EMULATOR_PORT 미설정 — 설정하고 그 포트에 에뮬레이터를 띄우면 시험)"
run "env.sh: 서명 거부 + 시계 20분 어긋남 → 시계 어긋남 안내" envsh_sig_skew20
run "env.sh: 서명 거부 + 시계 2분 차이(허용 범위 안) → 서명 거부 안내, 시계 탓 안 함" envsh_sig_skew2
run "env.sh: 응답 없음(서명 오류 아님) + 시계 20분 차이 → 시계 탓 안 함" envsh_nosig_skew20
run "dr-env.sh: 비대화형 + DR_EMULATOR_PORT 없음 → 거부, 이전 DR_AWS_* 지움" drenv_refuses_without_port
run "dr-env.sh: 잘못된 포트 → 거부, 이전 DR_AWS_* 지움" drenv_bad_port_clears
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
