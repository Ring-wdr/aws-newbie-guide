# shellcheck shell=bash
# M12 다중 리전 DR 실습용: 두 번째 에뮬레이터("DR 리전", 이 실습에서는 "도쿄")의 접속 정보를
# DR_ 접두사 환경 변수로 내보낸다. scripts/env.sh 를 먼저 source 한 셸에서 source 한다.
#
#   export EMULATOR_PORT=9312            # 주 리전("서울") — scripts/env.sh 가 쓰는 포트
#   source scripts/env.sh
#   source curriculum/m12-resilience-dr-migration/labs/dr-env.sh   # DR 리전("도쿄")
#
# 포트 규칙: DR_EMULATOR_PORT 가 있으면 그 포트, 없으면 EMULATOR_PORT + 1.
#   (학습자 기본값: 9297 → 9298. 에이전트 9312 → 9313)
#
# 두 에뮬레이터 모두 기술적으로는 us-east-1 이다. 에뮬레이터는 리전을 나누지 않으므로
# "포트가 다른 두 에뮬레이터 = 서로 독립된 두 리전"으로 흉내 낸다.
#
# 내보내는 변수 (scripts/env.sh 가 주 리전에 대해 하는 것과 같은 규칙으로 ~/.aws/emulator/<포트>/ 에서 만든다)
#   DR_EMULATOR_PORT  DR_AWS_ENDPOINT_URL  DR_AWS_CA_BUNDLE  DR_AWS_SHARED_CREDENTIALS_FILE  DR_AWS_CONFIG_FILE
# AWS_ENDPOINT_URL 등 기본 변수는 건드리지 않는다 — 이 셸의 aws CLI 는 여전히 주 리전을 향한다.
# DR 쪽에 CLI 를 쓰려면 아래 dr_aws 함수를 쓴다.

_dr_env_fail() {
  printf '\033[31m[dr-env.sh] %s\033[0m\n' "$1" >&2
  [ -n "${2:-}" ] && printf '            %s\n' "$2" >&2
  return 1
}

_dr_env_main() {
  if [ -z "${EMULATOR_PORT:-}" ] || [ -z "${AWS_ENDPOINT_URL:-}" ]; then
    _dr_env_fail "scripts/env.sh 를 먼저 source 하세요 (주 리전 연결이 없습니다)."
    return 1
  fi
  local port="${DR_EMULATOR_PORT:-$((EMULATOR_PORT + 1))}"
  case "$port" in
    '' | *[!0-9]*) _dr_env_fail "DR_EMULATOR_PORT 값이 숫자가 아닙니다: '$port'"; return 1 ;;
  esac
  if [ "$port" = "$EMULATOR_PORT" ]; then
    _dr_env_fail "DR 리전 포트($port)가 주 리전 포트와 같습니다. 서로 다른 에뮬레이터여야 합니다."
    return 1
  fi
  local dir="$HOME/.aws/emulator/$port"
  if [ ! -f "$dir/emulator_credentials" ] || [ ! -f "$dir/ca.pem" ]; then
    _dr_env_fail "포트 $port 의 에뮬레이터 파일($dir)이 없습니다. DR 리전 에뮬레이터가 꺼져 있습니다." \
      "먼저 실행하세요: scripts/emulator-up.sh $port"
    return 1
  fi
  export DR_EMULATOR_PORT="$port"
  export DR_AWS_ENDPOINT_URL="https://127.0.0.1:$port"
  export DR_AWS_CA_BUNDLE="$dir/ca.pem"
  export DR_AWS_SHARED_CREDENTIALS_FILE="$dir/emulator_credentials"
  export DR_AWS_CONFIG_FILE="$dir/config"

  # 안전 장치: DR 쪽도 계정 000000000000 (에뮬레이터)인지 확인한다.
  local account
  account="$(dr_aws sts get-caller-identity --cli-connect-timeout 3 --cli-read-timeout 10 \
    --query Account --output text 2>/dev/null)" || account=""
  if [ "$account" != "000000000000" ]; then
    _dr_env_fail "안전 장치: DR 리전 요청이 에뮬레이터로 간다는 것을 확인하지 못했습니다 (Account='${account:-응답 없음}')." \
      "scripts/emulator-status.sh 로 포트 $port 의 에뮬레이터를 확인하세요."
    return 1
  fi
  printf '[dr-env.sh] DR 리전("도쿄") = 포트 %s 의 에뮬레이터: %s (Account 000000000000, 기술적으로는 us-east-1)\n' \
    "$port" "$DR_AWS_ENDPOINT_URL" >&2
}

# DR 리전 에뮬레이터에 aws CLI 를 보낸다. 엔드포인트·자격 증명·CA 를 이 명령에만 바꿔 끼운다.
dr_aws() {
  AWS_ENDPOINT_URL="$DR_AWS_ENDPOINT_URL" AWS_CA_BUNDLE="$DR_AWS_CA_BUNDLE" \
    AWS_SHARED_CREDENTIALS_FILE="$DR_AWS_SHARED_CREDENTIALS_FILE" AWS_CONFIG_FILE="$DR_AWS_CONFIG_FILE" \
    aws --endpoint-url "$DR_AWS_ENDPOINT_URL" "$@"
}

_dr_env_main
_dr_env_rc=$?
unset -f _dr_env_main _dr_env_fail
if [ "$_dr_env_rc" -ne 0 ]; then
  unset _dr_env_rc
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi
unset _dr_env_rc
