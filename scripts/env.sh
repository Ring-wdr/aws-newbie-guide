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
# 순서: 맨 먼저 이 셸을 AWS에서 끊고(_emu_env_neutralize), 계정 확인이 통과한 **뒤에만** 에뮬레이터 변수를
# export 한다. 그래서 거부하든, 도중에 Ctrl-C 로 끊든, 셸은 "끊긴 상태"로 남는다. 끊긴 상태:
#   - AWS_CONFIG_FILE·AWS_SHARED_CREDENTIALS_FILE·BOTO_CONFIG·AWS_CA_BUNDLE 이 /dev/null/ 아래(만들 수 없는 경로)를
#     가리킨다. 설정·자격 증명이 항상 "없음"이고, aws configure 도 거기에 쓰지 못한다([Errno 20] Not a directory).
#   - 실제 자격 증명·프로필·엔드포인트 변수를 지우고, 옛 방식 자격 증명(AWS_CREDENTIAL_FILE, ~/.boto·/etc/boto.cfg)도 끈다.
#   - AWS_ENDPOINT_URL 은 닫힌 루프백 포트(https://127.0.0.1:9). 인스턴스 메타데이터·호스트 접두사·S3 다중 리전
#     액세스 포인트(MRAP) ARN 을 끈다.
# 보장하는 것: 서명이 필요한 요청은 자격 증명이 없어 보내기 전에 실패한다. 나머지는 닫힌 로컬 포트로 간다.
# 예외(남은 것): SDK 가 엔드포인트 설정을 무시하고 호스트명을 직접 만드는 기능 — 예: Kinesis --stream-id
# (*.control-kinesis.<리전>.amazonaws.com) — 의 서명 없는 요청(--no-sign-request)은 실제 AWS 호스트에 DNS 조회와
# TCP·TLS 연결을 시도한다. 신뢰하는 인증서 묶음이 없어(AWS_CA_BUNDLE=/dev/null/...) TLS 단계에서 끊기므로 HTTP 요청은
# 보내지 않는다(--no-verify-ssl 을 붙이면 이 마지막 단계도 꺼진다).
# 연결된 상태에서도 MRAP 은 끄고, 같은 기능은 에뮬레이터 인증서(ca.pem)만 믿으므로 TLS 단계에서 끊긴다.
# env.sh 는 ~/.aws 의 config·credentials 를 읽지도 고치지도 않는다(aws CLI 자체는 ~/.aws/cli/cache 에 캐시를 쓴다).
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

# 이 셸을 AWS에서 끊는다 (조용히). env.sh 가 맨 먼저 부르고, 성공했을 때만 에뮬레이터 값으로 덮어쓴다.
# Ctrl-C 대비 순서: (1) 지울 서비스별 변수 목록을 먼저 구한다(상태를 바꾸지 않음) (2) export **한 번**으로
# 설정·자격 증명·CA·엔드포인트를 끊긴 값으로 바꾼다 (3) 그다음에 지운다. (1) 도중에 멈추면 원래 상태 그대로이고,
# (2) 뒤 어디서 멈추든 설정·자격 증명 파일과 CA 가 /dev/null 이라 실제 AWS에 요청이 전달되지 않는다.
_emu_env_neutralize() {
  local v per_service
  per_service="$(env | sed -n 's/^\(AWS_ENDPOINT_URL_[A-Za-z0-9_]*\)=.*/\1/p')"
  # /dev/null 은 파일이라 그 아래 경로는 어떤 프로그램도 만들 수 없다 → 설정·자격 증명·CA 가 항상 "없음".
  export AWS_CONFIG_FILE=/dev/null/aws-emulator-disconnected/config \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null/aws-emulator-disconnected/credentials \
    AWS_CA_BUNDLE=/dev/null/aws-emulator-disconnected/ca.pem \
    BOTO_CONFIG=/dev/null/aws-emulator-disconnected/boto \
    AWS_ENDPOINT_URL=https://127.0.0.1:9 \
    AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS=true \
    AWS_EC2_METADATA_DISABLED=true \
    AWS_DISABLE_HOST_PREFIX_INJECTION=true \
    AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 \
    AWS_PAGER=""
  #  - BOTO_CONFIG: botocore 의 옛 방식 공급자가 기본값 ~/.boto·/etc/boto.cfg 대신 이 경로만 본다
  #  - AWS_CA_BUNDLE: 어떤 서버 인증서도 믿지 않는다 → SDK 가 직접 만든 AWS 호스트로 가도 TLS 에서 끊긴다
  #  - AWS_ENDPOINT_URL: discard 포트(닫혀 있음). 리전은 정해 둬 리전 오류 대신 자격 증명·연결 단계에서 실패하게
  #  - AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS: MRAP ARN 은 엔드포인트를 무시하고 *.s3-global.amazonaws.com 으로 간다
  # 실제 AWS 자격 증명·프로필을 줄 수 있는 변수를 지운다 (환경 변수 자격 증명은 파일보다 우선한다).
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_IGNORE_CONFIGURED_ENDPOINT_URLS \
    AWS_USE_FIPS_ENDPOINT AWS_USE_DUALSTACK_ENDPOINT AWS_CREDENTIAL_FILE
  # 서비스별 엔드포인트 덮어쓰기(AWS_ENDPOINT_URL_S3 등)도 지운다.
  for v in $(printf '%s\n' "$per_service"); do   # 명령 치환은 bash·zsh 모두 단어로 나눈다
    unset "$v"
  done
}

_emu_env_disconnected_notice() {
  printf '\033[31m[env.sh] 이 셸은 AWS에서 끊겼습니다: 실제 자격 증명·프로필 변수와 ~/.boto 같은 옛 방식 자격 증명을 끄고, 엔드포인트를 닫힌 로컬 포트(127.0.0.1:9)로, 인증서 묶음을 빈 경로로 돌렸습니다 — 서명이 필요한 aws 요청은 보내기 전에 실패하고, 실제 AWS에는 요청이 전달되지 않습니다(예외·자세히: M00 레슨 3). 에뮬레이터는 원인을 고친 뒤 다시 source scripts/env.sh, 실제 AWS는 새 셸을 여세요.\033[0m\n' >&2
}

_emu_env_main() {
  # 0) 무엇보다 먼저 끊는다. 아래 어디서 거부되거나 Ctrl-C 로 멈춰도 셸은 이 상태로 남는다.
  _emu_env_neutralize
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
  # 1) 에뮬레이터 연결 값 (아직 export 하지 않는다 — 확인이 통과한 뒤 2)에서 export)
  local ep="https://127.0.0.1:$port" creds="$dir/emulator_credentials" conf="$dir/config" ca="$dir/ca.pem"

  # 1-1) 안전 장치
  if [ ! -f "$creds" ] || [ ! -f "$ca" ]; then
    _emu_env_fail "포트 $port 의 에뮬레이터 파일($dir)이 없습니다. 에뮬레이터가 꺼져 있습니다." \
      "먼저 실행하세요: scripts/emulator-up.sh $port"
    return 1
  fi
  if ! command -v aws >/dev/null 2>&1; then
    _emu_env_fail "aws CLI를 찾을 수 없습니다." "scripts/install.sh 를 실행하세요."
    return 1
  fi
  case "$ep" in
    https://127.0.0.1:*) ;;
    *) _emu_env_fail "엔드포인트가 로컬 에뮬레이터가 아닙니다: $ep"; return 1 ;;
  esac
  local account errfile errtext
  errfile="$(mktemp)"
  # 확인 명령에만 에뮬레이터 값을 붙인다. --endpoint-url 도 명시해, 환경 변수를 무시하는 오래된 CLI에서도
  # 실제 AWS로 나가지 않게 한다.
  account="$(AWS_ENDPOINT_URL="$ep" AWS_SHARED_CREDENTIALS_FILE="$creds" AWS_CONFIG_FILE="$conf" AWS_CA_BUNDLE="$ca" \
    aws sts get-caller-identity --endpoint-url "$ep" \
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
  # 2) 확인이 통과했다 — 이제서야 에뮬레이터 연결 설정을 export 한다 (export 한 번).
  #    (끊긴 상태의 BOTO_CONFIG·AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS·AWS_EC2_METADATA_DISABLED·
  #     AWS_DISABLE_HOST_PREFIX_INJECTION·리전·페이저는 그대로 둔다)
  export EMULATOR_PORT="$port" AWS_SHARED_CREDENTIALS_FILE="$creds" AWS_CONFIG_FILE="$conf" \
    AWS_CA_BUNDLE="$ca" AWS_ENDPOINT_URL="$ep"
  printf '[env.sh] 포트 %s 의 에뮬레이터에 연결됨: %s (Account 000000000000, us-east-1)\n' "$port" "$AWS_ENDPOINT_URL" >&2
  return 0
}

# '|| rc=$?' 로 부른다: macOS 기본 bash 3.2 는 if 조건 안의 함수에서 source 될 때 set -e 무시 상태를 잃어,
# 실패 안내 뒤 호출한 셸 전체를 끝내 버린다(M00 verify.sh 가 FAIL 줄 없이 멈춘 원인).
_emu_env_rc=0
_emu_env_main || _emu_env_rc=$?
# 어떤 이유로 거부했든(포트 오류·파일 없음·서명 거부·응답 없음…) 이 셸을 AWS에서 끊는다.
# (_emu_env_main 이 맨 먼저 끊어 두었으므로 여기서는 알리기만 한다. 주 사이트가 끊겼으니 남아 있던 두 번째
#  사이트 연결(DR_AWS_*)도 지운다 → dr_aws·emulator_site("DR_") 도 거부된다. 성공 경로는 DR 을 건드리지 않는다.)
if [ "$_emu_env_rc" -ne 0 ]; then
  unset DR_AWS_ENDPOINT_URL DR_AWS_CA_BUNDLE DR_AWS_SHARED_CREDENTIALS_FILE DR_AWS_CONFIG_FILE
  _emu_env_disconnected_notice
fi
unset -f _emu_env_main _emu_env_fail _emu_env_neutralize _emu_env_disconnected_notice
unset _emu_env_dir
if [ "$_emu_env_rc" -ne 0 ]; then
  unset _emu_env_rc
  # source 된 경우 return, 실수로 직접 실행한 경우 exit
  # shellcheck disable=SC2317 # 직접 실행된 경우에만 exit 에 도달한다
  return 1 2>/dev/null || exit 1
fi
unset _emu_env_rc
