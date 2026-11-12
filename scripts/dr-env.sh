# shellcheck shell=bash
# 두 번째 에뮬레이터("DR 리전" 등 두 번째 사이트) 연결. scripts/env.sh 를 먼저 source 한 셸에서 source 한다.
#
#   export EMULATOR_PORT=9297 && source scripts/env.sh       # 주 사이트 (예: "서울")
#   scripts/emulator-up.sh 9298                              # 두 번째 에뮬레이터
#   source scripts/dr-env.sh                                 # 두 번째 사이트 (예: "도쿄")
#
# 포트: DR_EMULATOR_PORT 가 있으면 그 포트. 없으면 **터미널에서 직접 source 할 때만** EMULATOR_PORT + 1
#       (학습자 9297 → 9298). 비대화형(AI 에이전트·CI)에서는 DR_EMULATOR_PORT 가 없으면 거부한다 —
#       에이전트 포트는 연달아 배정되므로 +1 이 다른 에이전트의 에뮬레이터일 수 있기 때문이다.
# 에뮬레이터는 리전을 나누지 않으므로 "포트가 다른 두 에뮬레이터 = 서로 독립된 두 리전"으로 흉내 낸다.
#
# 내보내는 변수 (~/.aws/emulator/<포트>/ 의 파일로 만든다. env.sh 와 같은 규칙):
#   DR_EMULATOR_PORT  DR_AWS_ENDPOINT_URL  DR_AWS_CA_BUNDLE  DR_AWS_SHARED_CREDENTIALS_FILE  DR_AWS_CONFIG_FILE
# 기본 변수(AWS_ENDPOINT_URL 등)는 건드리지 않는다 — 이 셸의 aws CLI 는 여전히 주 사이트를 향한다.
#   CLI  : dr_aws <명령...>               (이 명령에만 두 번째 사이트의 엔드포인트·자격 증명·CA를 끼운다)
#   boto3: from emulator_guard import emulator_site; dr = emulator_site("DR_"); dr.client("s3")
# 안전 장치: 포트 검증, 주 사이트와 다른 포트인지, 계정 000000000000 확인. 실패하면 0이 아닌 값으로 반환한다.

if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_dr_env_dir="${${(%):-%x}:A:h}"'
else
  _dr_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_dr_env_fail() {
  printf '\033[31m[dr-env.sh] %s\033[0m\n' "$1" >&2
  [ -n "${2:-}" ] && printf '            %s\n' "$2" >&2
  return 1
}

# 두 번째 사이트로 aws CLI 를 보낸다. 실제 자격 증명 변수는 이 명령에서도 비운다.
dr_aws() {
  if [ -z "${DR_AWS_ENDPOINT_URL:-}" ]; then
    printf '[dr_aws] DR_AWS_ENDPOINT_URL 이 없습니다. source scripts/dr-env.sh 를 먼저 실행하세요.\n' >&2
    return 1
  fi
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE \
    AWS_ENDPOINT_URL="$DR_AWS_ENDPOINT_URL" AWS_CA_BUNDLE="$DR_AWS_CA_BUNDLE" \
    AWS_SHARED_CREDENTIALS_FILE="$DR_AWS_SHARED_CREDENTIALS_FILE" AWS_CONFIG_FILE="$DR_AWS_CONFIG_FILE" \
    aws --endpoint-url "$DR_AWS_ENDPOINT_URL" "$@"
}

_dr_env_clear() {
  unset DR_AWS_ENDPOINT_URL DR_AWS_CA_BUNDLE DR_AWS_SHARED_CREDENTIALS_FILE DR_AWS_CONFIG_FILE
}

_dr_env_main() {
  # 어떤 실패 경로에서도 이전 연결 정보가 남지 않도록 먼저 지운다 (DR_EMULATOR_PORT 는 입력이므로 둔다).
  _dr_env_clear
  if [ -z "${EMULATOR_PORT:-}" ] || [ -z "${AWS_ENDPOINT_URL:-}" ]; then
    _dr_env_fail "scripts/env.sh 를 먼저 source 하세요 (주 사이트 연결이 없습니다)."
    return 1
  fi
  if [ -z "${DR_EMULATOR_PORT:-}" ] && [ ! -t 0 ]; then
    _dr_env_fail "DR_EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 'EMULATOR_PORT + 1' 기본값을 쓰지 않습니다." \
      "'export DR_EMULATOR_PORT=<자기 두 번째 포트>' 후 다시 source 하세요. (터미널에서 직접 실행하면 EMULATOR_PORT + 1 을 씁니다)"
    return 1
  fi
  local port="${DR_EMULATOR_PORT:-$((EMULATOR_PORT + 1))}"
  case "$port" in
    '' | *[!0-9]*) _dr_env_fail "DR_EMULATOR_PORT 값이 숫자가 아닙니다: '$port'"; return 1 ;;
  esac
  if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    _dr_env_fail "DR_EMULATOR_PORT 는 1024~65535 사이여야 합니다: $port"
    return 1
  fi
  if [ "$port" = "$EMULATOR_PORT" ]; then
    _dr_env_fail "두 번째 사이트 포트($port)가 주 사이트 포트와 같습니다. 서로 다른 에뮬레이터여야 합니다."
    return 1
  fi
  local dir="$HOME/.aws/emulator/$port"
  if [ ! -f "$dir/emulator_credentials" ] || [ ! -f "$dir/ca.pem" ]; then
    _dr_env_fail "포트 $port 의 에뮬레이터 파일($dir)이 없습니다. 두 번째 에뮬레이터가 꺼져 있습니다." \
      "먼저 실행하세요: scripts/emulator-up.sh $port"
    return 1
  fi
  export DR_EMULATOR_PORT="$port"
  export DR_AWS_ENDPOINT_URL="https://127.0.0.1:$port"
  export DR_AWS_CA_BUNDLE="$dir/ca.pem"
  export DR_AWS_SHARED_CREDENTIALS_FILE="$dir/emulator_credentials"
  export DR_AWS_CONFIG_FILE="$dir/config"

  local account errfile errtext
  errfile="$(mktemp)"
  account="$(dr_aws sts get-caller-identity --cli-connect-timeout 3 --cli-read-timeout 10 \
    --query Account --output text 2>"$errfile")" || account=""
  errtext="$(cat "$errfile")"
  rm -f "$errfile"
  if [ "$account" != "000000000000" ]; then
    _dr_env_clear
    case "$errtext" in
      *SignatureDoesNotMatch* | *RequestTimeTooSkewed* | *InvalidSignatureException*)
        # 서명 거부일 때만 시계를 의심한다. clock-check 가 15분 창에 가까운 차이를 확인하면 시계 어긋남으로 결론.
        if ! bash "$_dr_env_dir/clock-check.sh" "$port"; then
          _dr_env_fail "안전 장치: 시계 어긋남 때문에 두 번째 에뮬레이터가 서명을 거부했습니다 (위 [clock-check] 안내 참고)."
          return 1
        fi
        _dr_env_fail "안전 장치: 두 번째 에뮬레이터가 서명을 거부했습니다 ($(printf '%s' "$errtext" | tr '\n' ' ' | cut -c1-160))." \
          "에뮬레이터를 재시작했다면 dr-env.sh 를 다시 source 하세요."
        return 1
        ;;
    esac
    _dr_env_fail "안전 장치: 두 번째 사이트 요청이 에뮬레이터로 간다는 것을 확인하지 못했습니다 (Account='${account:-응답 없음}')." \
      "scripts/emulator-status.sh 로 포트 $port 의 에뮬레이터를 확인하세요."
    return 1
  fi
  printf '[dr-env.sh] 두 번째 사이트 = 포트 %s 의 에뮬레이터: %s (Account 000000000000)\n' "$port" "$DR_AWS_ENDPOINT_URL" >&2
}

_dr_env_main
_dr_env_rc=$?
unset -f _dr_env_main _dr_env_fail _dr_env_clear
unset _dr_env_dir
if [ "$_dr_env_rc" -ne 0 ]; then
  unset _dr_env_rc
  # shellcheck disable=SC2317 # 직접 실행된 경우에만 exit 에 도달한다
  return 1 2>/dev/null || exit 1
fi
unset _dr_env_rc
