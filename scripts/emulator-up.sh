#!/usr/bin/env bash
# 사용법: scripts/emulator-up.sh [포트]   (기본 9297)
#
# 포트별로 이름이 붙은 에뮬레이터 컨테이너(aws-emulator-<포트>)를 백그라운드로 띄우고,
# 헬스 체크가 통과할 때까지 기다린다. 이미 떠 있으면 아무것도 바꾸지 않는다.
#
# 환경 변수로 바꿀 수 있는 값
#   EMULATOR_MEMORY       컨테이너 메모리 상한 (기본 1g, 스왑 없음)
#   EMULATOR_TELEMETRY    on 으로 두면 텔레메트리를 끄지 않는다 (기본: 끔)
#   EMULATOR_IDLE_TIMEOUT 지정한 초 동안 API 호출이 없으면 에뮬레이터가 스스로 종료
set -euo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

PORT="${1:-${EMULATOR_PORT:-9297}}"
validate_port "$PORT"
NAME="$(container_name "$PORT")"
MEMORY="${EMULATOR_MEMORY:-1g}"

require_docker
require_image

print_next() {
  local root envsh
  root="$(repo_root 2>/dev/null || echo '<저장소 루트>')"
  envsh="$root/scripts/env.sh"
  [ "$PWD" = "$root" ] && envsh="scripts/env.sh"
  echo
  echo "다음 명령으로 현재 셸을 이 에뮬레이터에 연결하세요:"
  echo "  export EMULATOR_PORT=$PORT"
  echo "  source $envsh"
}

state="$(container_state "$PORT")"
if [ "$state" = "running" ]; then
  if health_ok "$PORT"; then
    c_grn "이미 실행 중입니다: $NAME (https://127.0.0.1:$PORT)"
    print_next
    exit 0
  fi
  c_ylw "$NAME 컨테이너는 떠 있지만 아직 헬스 체크가 통과하지 않았습니다. 기다립니다..."
elif [ -n "$state" ]; then
  # 비정상 종료 등으로 남은 컨테이너: 마지막 로그를 보여 주고 지운다.
  c_ylw "멈춘 컨테이너 $NAME (상태: $state)를 정리하고 새로 띄웁니다. 마지막 로그:"
  docker logs --tail 5 "$NAME" 2>&1 | sed 's/^/    /' || true
  docker rm -f "$NAME" >/dev/null
  state=""
fi

if [ -z "$state" ]; then
  mkdir -p "$EMULATOR_HOME_DIR"

  run_args=(
    run -d --name "$NAME"
    --label "$EMULATOR_LABEL=1" --label "$EMULATOR_LABEL.port=$PORT"
    --memory="$MEMORY" --memory-swap="$MEMORY"
    -p "127.0.0.1:$PORT:$PORT"
    -e HOME="$HOME"
    -v "$EMULATOR_HOME_DIR:$EMULATOR_HOME_DIR"
  )
  # Linux에서는 마운트한 파일이 내 사용자 소유가 되도록 UID/GID를 맞춘다.
  # (macOS의 Colima·Docker Desktop은 파일 공유 계층이 소유자를 알아서 맞춰 준다)
  if [ "$(uname -s)" = "Linux" ]; then
    run_args+=(--user "$(id -u):$(id -g)")
  fi
  emu_args=(-p "$PORT")
  if [ "${EMULATOR_TELEMETRY:-off}" != "on" ]; then
    emu_args+=(--telemetry off)
  fi
  if [ -n "${EMULATOR_IDLE_TIMEOUT:-}" ]; then
    emu_args+=(--idle-timeout "$EMULATOR_IDLE_TIMEOUT")
  fi

  echo "에뮬레이터를 시작합니다: $NAME (포트 $PORT, 메모리 상한 $MEMORY)"
  if ! docker "${run_args[@]}" "$EMULATOR_IMAGE" "${emu_args[@]}" >/dev/null; then
    die "컨테이너를 시작하지 못했습니다. 포트 $PORT 를 다른 프로그램이 쓰고 있지 않은지 확인하세요 (lsof -i :$PORT)."
  fi
fi

# 헬스 체크 대기 (최대 60초)
for _ in $(seq 60); do
  if health_ok "$PORT"; then
    c_grn "준비 완료: https://127.0.0.1:$PORT  (헬스 체크: ok)"
    print_next
    exit 0
  fi
  if [ "$(container_state "$PORT")" != "running" ]; then
    c_red "컨테이너가 시작 직후 종료되었습니다. 로그:" >&2
    docker logs --tail 20 "$NAME" >&2 || true
    exit 1
  fi
  sleep 1
done

c_red "60초 안에 헬스 체크가 통과하지 않았습니다. 로그:" >&2
docker logs --tail 20 "$NAME" >&2 || true
exit 1
