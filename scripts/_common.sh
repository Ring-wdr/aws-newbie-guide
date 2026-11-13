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
  # join 대신 range: Ubuntu 패키지의 docker CLI(29.1)는 join 에 '[]interface {}' 형식 오류를 낸다.
  dns="$(docker container inspect -f '{{range $i, $d := .HostConfig.Dns}}{{if $i}},{{end}}{{$d}}{{end}}' "$(container_name "$1")" 2>/dev/null)" || { echo "-"; return 0; }
  echo "${dns:-host}"
}

# 명령을 제한 시간(초) 안에서만 실행하고 표준 출력을 파일에 남긴다. 반환: 명령의 종료 코드, 시간 초과면 124.
# macOS 에는 timeout 이 없다. 하위 셸에서 set -m 을 켜 명령을 자기 프로세스 그룹으로 띄우고, 시간이 지나면
# 그룹 전체에 TERM, 0.5초 뒤에도 남아 있으면 KILL 을 보낸 뒤 wait 로 거둔다(TERM 을 무시하는 자식도 끝난다).
# 출력은 파이프가 아니라 파일로 받는다 — 그룹을 떠난 손자(ssh 제어 연결 등)가 파이프를 쥐고 있어도 기다리지 않는다.
# 하위 셸의 stderr 를 버려 작업 제어 메시지("Terminated" 등)가 보이지 않는다. bash 3.2(macOS 기본)에서 시험함.
# Ctrl-C·TERM·HUP: 명령은 자기 그룹에 있어 터미널의 Ctrl-C 를 받지 못한다. 그래서 set -m 은 띄우는 순간에만 켜고
# 바로 끈다(대기용 sleep 이 호출한 셸과 같은 포그라운드 그룹에 남아 Ctrl-C 가 이 하위 셸에 닿는다). 하위 셸의 trap 이
# 명령의 그룹을 KILL 하고 거둔 뒤 130 으로 끝난다. trap 은 하위 셸 안에만 있어 호출한 셸의 trap 을 바꾸지 않는다.
# 반환 130 = 중단됨 — 호출한 쪽은 자신도 130 으로 끝내야 한다(bash 는 자식이 신호를 처리하고 끝나면 계속 진행한다).
run_limited() {  # <초> <출력 파일> <명령...>
  local limit="$1" out="$2"
  shift 2
  (
    set +e   # 호출한 스크립트의 set -e 를 끈다 — 거둔 명령의 0 이 아닌 상태(137 등)로 하위 셸이 먼저 끝나지 않게
    pid=""
    trap '[ -n "$pid" ] && { kill -KILL -- "-$pid"; wait "$pid"; } 2>/dev/null; exit 130' INT TERM HUP
    set -m
    "$@" >"$out" 2>/dev/null </dev/null &
    pid=$!
    set +m
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$i" -ge $((limit * 10)) ]; then
        kill -TERM -- "-$pid" 2>/dev/null
        j=0
        while kill -0 "$pid" 2>/dev/null && [ "$j" -lt 5 ]; do sleep 0.1; j=$((j + 1)); done
        kill -KILL -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        exit 124
      fi
      sleep 0.1
      i=$((i + 1))
    done
    wait "$pid"
  ) 2>/dev/null
}

# VM 시계가 지금 반복해서 옮겨지고 있으면(clock-check.sh --stability 종료 코드 4) 경고만 보여 준다.
# 안정(0)·확인 못 함(2, Docker Desktop·Linux 등)은 조용히 넘어간다. 호출한 스크립트를 실패시키지 않는다.
warn_if_clock_unstable() {
  local out rc=0
  out="$(bash "$(dirname "${BASH_SOURCE[0]}")/clock-check.sh" --stability 2>&1)" || rc=$?
  if [ "$rc" -eq 4 ]; then printf '%s\n' "$out" >&2; fi
  [ "$rc" -ne 130 ] || exit 130   # Ctrl-C 로 중단됐으면 호출한 스크립트도 멈춘다
  return 0
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
