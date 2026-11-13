# shellcheck shell=bash
# 사용법 (bash, zsh 공통):
#   source scripts/env.sh                       # 터미널에서 직접: 기본 포트 9297
#   EMULATOR_PORT=9301 source scripts/env.sh    # 다른 포트
#
# 포트 규칙: EMULATOR_PORT 가 있으면 그 포트. 없으면 표준 입력이 터미널일 때(학습자가 터미널에서
# 직접 source 하거나 lab 스크립트를 실행할 때)만 9297 을 쓰고, 비대화형(AI 에이전트·CI 등)에서는
# 거부한다 — 다른 사람의 9297 에뮬레이터를 건드리지 않기 위해서다.
#
# 현재 셸의 AWS CLI·boto3가 로컬 aws-emulator만 바라보도록 환경 변수를 설정한다.
# 마지막에 안전 장치를 실행해, 요청이 에뮬레이터(계정 000000000000)로 가는 것이
# 확인되지 않으면 0이 아닌 값으로 반환한다. 실습 스크립트는 set -e 상태에서 이 파일을
# source 하므로, 안전 장치가 실패하면 실습은 실제 AWS에 요청을 보내기 전에 멈춘다.
#
# 거부(실패)하면 어떤 이유든 이 셸을 AWS에서 끊는다: 실제 자격 증명·프로필·엔드포인트 변수를 지우고,
# AWS_CONFIG_FILE·AWS_SHARED_CREDENTIALS_FILE 을 ~/.aws/emulator/ 아래의 없는 파일로, AWS_ENDPOINT_URL 을
# 닫힌 루프백 포트로 돌려 둔다. 그래서 거부 뒤에 친 aws 명령은 ~/.aws 의 실제 설정을 쓰지 않고 이 컴퓨터
# 안에서 실패한다. ~/.aws 의 실제 파일은 읽지도 고치지도 않는다. 실제 AWS를 쓰려면 새 셸을 연다.
# (boto3 예제의 TODAYORDER_ALLOW_REAL_AWS=1 같은 해제 스위치는 env.sh 에 없다 — env.sh 는 에뮬레이터 전용이다.)

# 이 파일이 있는 scripts/ 디렉터리 (bash·zsh 공통. zsh 문법은 bash 가 파싱하지 않도록 eval 로 감싼다)
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_emu_env_dir="${${(%):-%x}:A:h}"'
else
  _emu_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_emu_env_fail() {
  printf '\033[31m[env.sh] %s\033[0m\n' "$1" >&2
  [ -n "${2:-}" ] && printf '         %s\n' "$2" >&2
  return 1
}

# 실제 AWS 자격 증명·프로필·엔드포인트를 줄 수 있는 변수를 모두 지운다.
# (환경 변수 자격 증명은 파일보다 우선하므로, 남겨 두면 실제 키로 서명된다)
_emu_env_scrub() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_IGNORE_CONFIGURED_ENDPOINT_URLS \
    AWS_USE_FIPS_ENDPOINT AWS_USE_DUALSTACK_ENDPOINT AWS_ENDPOINT_URL
  # 서비스별 엔드포인트 덮어쓰기(AWS_ENDPOINT_URL_S3 등)도 지운다.
  local v
  for v in $(env | sed -n 's/^\(AWS_ENDPOINT_URL_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
}

# 거부했을 때: 이 셸에서 친 aws·boto3 가 실제 AWS에 닿지 못하게 해 둔다.
_emu_env_disconnect() {
  _emu_env_scrub
  local off="$HOME/.aws/emulator/.disconnected"   # 만들지 않는 경로: 설정·자격 증명이 "없음"이 된다
  export AWS_CONFIG_FILE="$off/config"
  export AWS_SHARED_CREDENTIALS_FILE="$off/credentials"
  export AWS_ENDPOINT_URL="https://127.0.0.1:9"   # discard 포트(닫혀 있음): 서명 없는 요청도 밖으로 나가지 않는다
  export AWS_EC2_METADATA_DISABLED=true           # 인스턴스 메타데이터에서도 자격 증명을 찾지 않는다
  export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1   # 리전도 정해 둬서 실패 이유가 항상 "자격 증명 없음"이 되게 한다
  export AWS_PAGER=""
  unset AWS_CA_BUNDLE
  printf '\033[31m[env.sh] 이 셸은 AWS에서 끊겼습니다: 실제 자격 증명·프로필 변수를 지웠고, aws 명령은 이 컴퓨터 안에서 실패합니다. 에뮬레이터는 원인을 고친 뒤 다시 source scripts/env.sh, 실제 AWS는 새 셸을 여세요.\033[0m\n' >&2
}

_emu_env_main() {
  if [ -z "${EMULATOR_PORT:-}" ] && [ ! -t 0 ]; then
    _emu_env_fail "EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 기본 포트(9297)를 쓰지 않습니다." \
      "'export EMULATOR_PORT=<포트>' 후 다시 실행하세요. (터미널에서 직접 실행하면 9297 을 씁니다)"
    return 1
  fi
  local port="${EMULATOR_PORT:-9297}"
  case "$port" in
    '' | *[!0-9]*) _emu_env_fail "EMULATOR_PORT 값이 숫자가 아닙니다: '$port'"; return 1 ;;
  esac
  local dir="$HOME/.aws/emulator/$port"

  # 1) 실제 AWS 자격 증명을 줄 수 있는 변수를 모두 지운다.
  _emu_env_scrub

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
  local account errfile errtext
  errfile="$(mktemp)"
  # --endpoint-url 을 명시해, 환경 변수를 무시하는 오래된 CLI에서도 실제 AWS로 나가지 않게 한다.
  account="$(aws sts get-caller-identity --endpoint-url "$AWS_ENDPOINT_URL" \
    --cli-connect-timeout 3 --cli-read-timeout 10 \
    --query Account --output text 2>"$errfile")" || account=""
  errtext="$(cat "$errfile")"
  rm -f "$errfile"
  if [ "$account" != "000000000000" ]; then
    # 원인 진단 1: 메모리 초과(OOM)로 컨테이너가 죽었는가 (Lambda 를 많이 호출하면 메모리가 계속 늘어난다)
    local cstate=""
    if command -v docker >/dev/null 2>&1; then
      cstate="$(docker container inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "aws-emulator-$port" 2>/dev/null)" || cstate=""
    fi
    case "$cstate" in
      *" true")
        _emu_env_fail "포트 $port 의 에뮬레이터가 메모리 상한을 넘어 강제 종료됐습니다 (컨테이너 상태: $cstate — 종료 코드 137/OOMKilled). 만든 리소스는 모두 사라졌습니다." \
          "scripts/emulator-reset.sh $port 로 다시 띄우세요. 자주 반복되면 EMULATOR_MEMORY=3g scripts/emulator-reset.sh $port (M00 레슨 3 문제 해결)."
        return 1
        ;;
      exited*)
        _emu_env_fail "포트 $port 의 에뮬레이터 컨테이너가 종료돼 있습니다 (상태: $cstate)." "scripts/emulator-reset.sh $port 로 다시 띄우세요."
        return 1
        ;;
    esac
    # 원인 진단 2: 서명 거부일 때만 시계를 의심한다. clock-check 가 SigV4 허용 범위(15분)에 가까운
    # 차이를 확인하면 시계 어긋남으로 결론 내리고, 그보다 작으면 측정값만 참고로 보여 준다.
    case "$errtext" in
      *SignatureDoesNotMatch* | *RequestTimeTooSkewed* | *InvalidSignatureException*)
        if bash "$_emu_env_dir/clock-check.sh" "$port"; [ $? -eq 3 ]; then   # 3 = 시계 어긋남 (2 = 측정 못 함은 시계 탓으로 보지 않는다)
          _emu_env_fail "안전 장치: 시계 어긋남 때문에 에뮬레이터가 서명을 거부했습니다 (위 [clock-check] 안내대로 VM 시계를 맞춘 뒤 다시 source 하세요)."
          return 1
        fi
        _emu_env_fail "안전 장치: 에뮬레이터가 서명을 거부했습니다 ($(printf '%s' "$errtext" | tr '\n' ' ' | cut -c1-160))." \
          "에뮬레이터를 재시작했다면 'source scripts/env.sh' 를 다시, 노트북이 잠들었었다면 bash scripts/clock-check.sh $port 로 시계를 확인하세요."
        return 1
        ;;
    esac
    _emu_env_fail "안전 장치: 요청이 에뮬레이터로 간다는 것을 확인하지 못했습니다 (Account='${account:-응답 없음}')." \
      "실제 AWS에 요청을 보낼 위험이 있어 중단합니다. 'scripts/emulator-status.sh' 로 포트 $port 의 에뮬레이터가 떠 있는지 확인하세요."
    return 1
  fi
  printf '[env.sh] 포트 %s 의 에뮬레이터에 연결됨: %s (Account 000000000000, us-east-1)\n' "$port" "$AWS_ENDPOINT_URL" >&2
  return 0
}

# '|| rc=$?' 로 부른다: macOS 기본 bash 3.2 는 if 조건 안의 함수에서 source 될 때 set -e 무시 상태를 잃어,
# 실패 안내 뒤 호출한 셸 전체를 끝내 버린다(M00 verify.sh 가 FAIL 줄 없이 멈춘 원인).
_emu_env_rc=0
_emu_env_main || _emu_env_rc=$?
# 어떤 이유로 거부했든(포트 오류·파일 없음·서명 거부·응답 없음…) 이 셸을 AWS에서 끊는다.
[ "$_emu_env_rc" -eq 0 ] || _emu_env_disconnect
unset -f _emu_env_main _emu_env_fail _emu_env_scrub _emu_env_disconnect
unset _emu_env_dir
if [ "$_emu_env_rc" -ne 0 ]; then
  unset _emu_env_rc
  # source 된 경우 return, 실수로 직접 실행한 경우 exit
  # shellcheck disable=SC2317 # 직접 실행된 경우에만 exit 에 도달한다
  return 1 2>/dev/null || exit 1
fi
unset _emu_env_rc
