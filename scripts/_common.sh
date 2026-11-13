# shellcheck shell=bash
# scripts/*.sh 가 공유하는 함수 모음. 직접 실행하지 말고 source 해서 쓴다.

EMULATOR_IMAGE="${EMULATOR_IMAGE:-aws-emulator}"
EMULATOR_HOME_DIR="$HOME/.aws/emulator"
# shellcheck disable=SC2034 # 다른 스크립트에서 사용
EMULATOR_LABEL="org.aws-newbie-guide.emulator"

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { c_red "오류: $*" >&2; exit 1; }

repo_root() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel
}

# 포트 인자 검증: 1024~65535 사이 숫자
validate_port() {
  local p="$1"
  case "$p" in
    '' | *[!0-9]*) die "포트는 숫자여야 합니다: '$p'" ;;
  esac
  if [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
    die "포트는 1024~65535 사이여야 합니다: $p"
  fi
}

container_name() { printf 'aws-emulator-%s' "$1"; }

# docker 데몬에 접속할 수 있는지 확인하고, 안 되면 원인별 안내를 출력한다.
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI가 없습니다. scripts/install.sh 를 먼저 실행하세요."
  if ! docker info >/dev/null 2>&1; then
    if [ "$(uname -s)" = "Darwin" ] && command -v colima >/dev/null 2>&1; then
      die "Docker 데몬에 접속할 수 없습니다. Colima가 꺼져 있는 것 같습니다. 'colima start' 후 다시 실행하세요."
    fi
    die "Docker 데몬에 접속할 수 없습니다. Docker(또는 Colima)를 실행한 뒤 다시 시도하세요."
  fi
}

require_image() {
  docker image inspect "$EMULATOR_IMAGE" >/dev/null 2>&1 \
    || die "'$EMULATOR_IMAGE' 이미지가 없습니다. scripts/install.sh 를 먼저 실행하세요."
}

# 컨테이너 상태: running / exited / created / ... / 없으면 빈 문자열
container_state() {
  docker container inspect -f '{{.State.Status}}' "$(container_name "$1")" 2>/dev/null || true
}

# 컨테이너의 DNS 설정(--dns 값, 쉼표로 구분). --dns 없이 띄웠으면 host(Docker 기본 리졸버), 컨테이너가 없으면 '-'.
container_dns() {
  local dns
  dns="$(docker container inspect -f '{{join .HostConfig.Dns ","}}' "$(container_name "$1")" 2>/dev/null)" || { echo "-"; return 0; }
  echo "${dns:-host}"
}

health_ok() {
  local port="$1" ca="$EMULATOR_HOME_DIR/$1/ca.pem"
  [ -f "$ca" ] || return 1
  [ "$(curl -s --max-time 3 --cacert "$ca" "https://127.0.0.1:$port/__admin/health" 2>/dev/null)" = "ok" ]
}

# 상태를 지우는 스크립트(emulator-reset.sh, 모듈 verify.sh)용 포트 결정.
# - 인자로 포트를 주면 그 포트
# - 아니면 EMULATOR_PORT
# - 둘 다 없으면: 대화형 터미널(표준 입력이 터미널 — 학습자가 직접 친 명령)에서는 기본 9297,
#   비대화형(에이전트·CI·스크립트 파이프)에서는 거부. env.sh 도 같은 규칙을 쓴다.
#   → 병렬 에이전트가 export 를 잊어 다른 사람의 9297 을 지우는 사고를 막는다.
resolve_destructive_port() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  if [ -n "${EMULATOR_PORT:-}" ]; then printf '%s' "$EMULATOR_PORT"; return 0; fi
  if [ -t 0 ]; then printf '9297'; return 0; fi
  die "EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 상태를 지우는 작업의 기본 포트를 쓰지 않습니다. 'export EMULATOR_PORT=<포트>' 후 다시 실행하세요."
}
