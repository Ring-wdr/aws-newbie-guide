#!/usr/bin/env bash
# 사용법: scripts/emulator-down.sh [포트 | --all]
# 포트: 인자 > EMULATOR_PORT > (대화형 터미널일 때만) 9297. 비대화형 셸에서 둘 다 없으면 거부한다.
#
# 해당 포트의 에뮬레이터 컨테이너를 정상 종료(SIGTERM)하고 지운다.
# 그리고 ~/.aws/emulator/<포트>/ 의 자격 증명·인증서 파일을 지운다 (이 디렉터리만 건드린다).
# 모든 리소스는 메모리에만 있으므로 함께 사라진다.
set -euo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

require_docker

stop_one() {
  local port="$1" name
  name="$(container_name "$port")"
  if [ -z "$(container_state "$port")" ]; then
    echo "실행 중인 에뮬레이터가 없습니다: $name"
    return 0
  fi
  docker stop -t 15 "$name" >/dev/null 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  # 비정상 종료로 파일이 남았다면 정리한다 (이 디렉터리 밖은 절대 건드리지 않는다).
  rm -rf "${EMULATOR_HOME_DIR:?}/$port"
  c_grn "종료했습니다: $name"
}

if [ "${1:-}" = "--all" ]; then
  ports="$(docker ps -a --filter "label=$EMULATOR_LABEL=1" \
    --format "{{.Label \"$EMULATOR_LABEL.port\"}}")"
  if [ -z "$ports" ]; then
    echo "실행 중인 에뮬레이터가 없습니다."
    exit 0
  fi
  for p in $ports; do stop_one "$p"; done
else
  PORT="$(resolve_destructive_port "${1:-}")"
  validate_port "$PORT"
  stop_one "$PORT"
fi
