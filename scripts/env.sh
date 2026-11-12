# shellcheck shell=bash
# 사용법 (bash, zsh 공통):
#   source scripts/env.sh                       # 기본 포트 9297
#   EMULATOR_PORT=9301 source scripts/env.sh    # 다른 포트
#
# 현재 셸의 AWS CLI·boto3가 로컬 aws-emulator만 바라보도록 환경 변수를 설정한다.
# 마지막에 안전 장치를 실행해, 요청이 에뮬레이터(계정 000000000000)로 가는 것이
# 확인되지 않으면 0이 아닌 값으로 반환한다. 실습 스크립트는 set -e 상태에서 이 파일을
# source 하므로, 안전 장치가 실패하면 실습은 실제 AWS에 요청을 보내기 전에 멈춘다.

_emu_env_fail() {
  printf '\033[31m[env.sh] %s\033[0m\n' "$1" >&2
  [ -n "${2:-}" ] && printf '         %s\n' "$2" >&2
  return 1
}

_emu_env_main() {
  local port="${EMULATOR_PORT:-9297}"
  case "$port" in
    '' | *[!0-9]*) _emu_env_fail "EMULATOR_PORT 값이 숫자가 아닙니다: '$port'"; return 1 ;;
  esac
  local dir="$HOME/.aws/emulator/$port"

  # 1) 실제 AWS 자격 증명을 줄 수 있는 변수를 모두 지운다.
  #    (환경 변수 자격 증명은 파일보다 우선하므로, 남겨 두면 실제 키로 서명된다)
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_IGNORE_CONFIGURED_ENDPOINT_URLS \
    AWS_USE_FIPS_ENDPOINT AWS_USE_DUALSTACK_ENDPOINT
  #    서비스별 엔드포인트 덮어쓰기(AWS_ENDPOINT_URL_S3 등)도 지운다.
  local v
  for v in $(env | sed -n 's/^\(AWS_ENDPOINT_URL_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done

  # 2) 에뮬레이터 연결 설정
  export EMULATOR_PORT="$port"
  export AWS_ENDPOINT_URL="https://127.0.0.1:$port"
  export AWS_SHARED_CREDENTIALS_FILE="$dir/emulator_credentials"
  export AWS_CONFIG_FILE="$dir/config"
  export AWS_CA_BUNDLE="$dir/ca.pem"
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_DISABLE_HOST_PREFIX_INJECTION=true
  export AWS_REGION=us-east-1
  export AWS_DEFAULT_REGION=us-east-1
  # CLI 출력이 less 같은 페이저로 넘어가 스크립트가 멈추는 것을 막는다.
  export AWS_PAGER=""

  # 3) 안전 장치
  if [ ! -f "$AWS_SHARED_CREDENTIALS_FILE" ] || [ ! -f "$AWS_CA_BUNDLE" ]; then
    _emu_env_fail "포트 $port 의 에뮬레이터 파일($dir)이 없습니다. 에뮬레이터가 꺼져 있습니다." \
      "먼저 실행하세요: scripts/emulator-up.sh $port"
    return 1
  fi
  if ! command -v aws >/dev/null 2>&1; then
    _emu_env_fail "aws CLI를 찾을 수 없습니다." "scripts/install.sh 를 실행하세요."
    return 1
  fi
  case "$AWS_ENDPOINT_URL" in
    https://127.0.0.1:*) ;;
    *) _emu_env_fail "엔드포인트가 로컬 에뮬레이터가 아닙니다: $AWS_ENDPOINT_URL"; return 1 ;;
  esac
  local account
  # --endpoint-url 을 명시해, 환경 변수를 무시하는 오래된 CLI에서도 실제 AWS로 나가지 않게 한다.
  account="$(aws sts get-caller-identity --endpoint-url "$AWS_ENDPOINT_URL" \
    --cli-connect-timeout 3 --cli-read-timeout 10 \
    --query Account --output text 2>/dev/null)" || account=""
  if [ "$account" != "000000000000" ]; then
    _emu_env_fail "안전 장치: 요청이 에뮬레이터로 간다는 것을 확인하지 못했습니다 (Account='${account:-응답 없음}')." \
      "실제 AWS에 요청을 보낼 위험이 있어 중단합니다. 'scripts/emulator-status.sh' 로 포트 $port 의 에뮬레이터가 떠 있는지 확인하세요."
    return 1
  fi
  printf '[env.sh] 포트 %s 의 에뮬레이터에 연결됨: %s (Account 000000000000, us-east-1)\n' "$port" "$AWS_ENDPOINT_URL" >&2
  return 0
}

_emu_env_main
_emu_env_rc=$?
unset -f _emu_env_main _emu_env_fail
if [ "$_emu_env_rc" -ne 0 ]; then
  unset _emu_env_rc
  # source 된 경우 return, 실수로 직접 실행한 경우 exit
  # shellcheck disable=SC2317 # 직접 실행된 경우에만 exit 에 도달한다
  return 1 2>/dev/null || exit 1
fi
unset _emu_env_rc
