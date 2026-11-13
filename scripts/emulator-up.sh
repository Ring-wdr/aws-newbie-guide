#!/usr/bin/env bash
# 사용법: scripts/emulator-up.sh [포트]   (기본 9297)
#
# 포트별로 이름이 붙은 에뮬레이터 컨테이너(aws-emulator-<포트>)를 백그라운드로 띄우고,
# 헬스 체크가 통과할 때까지 기다린다. 이미 떠 있으면 아무것도 바꾸지 않는다.
#
# 환경 변수로 바꿀 수 있는 값
#   EMULATOR_MEMORY       컨테이너 메모리 상한 (기본 2g, 스왑 없음)
#   EMULATOR_TELEMETRY    on 으로 두면 텔레메트리를 끄지 않는다 (기본: 끔)
#   EMULATOR_IDLE_TIMEOUT 지정한 초 동안 API 호출이 없으면 에뮬레이터가 스스로 종료
#   EMULATOR_DNS          컨테이너가 쓸 DNS 서버 IP (docker run --dns). 기본값 127.0.0.1: 컨테이너 안의
#                         이름 해석이 모두 실패해 바깥으로 DNS 질의가 나가지 않는다(M00 레슨 3).
#                         host 로 두면 --dns 를 붙이지 않아 Docker 기본 리졸버를 쓴다(격리 해제, 문제 해결용).
#                         비워 두거나 설정하지 않으면 기본값(127.0.0.1)이다.
set -euo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

PORT="${1:-${EMULATOR_PORT:-9297}}"
validate_port "$PORT"
NAME="$(container_name "$PORT")"
# 기본 2g(공식 가이드와 같음). 동기 Lambda Invoke 한 번마다 약 7 MiB가 회수되지 않고 쌓여서
# 1g 에서는 약 120번 호출 후 OOM(137)으로 죽었다(측정과 대처: M00 레슨 3 문제 해결). 병렬 에이전트는 줄일 수 있다.
MEMORY="${EMULATOR_MEMORY:-2g}"
DNS="${EMULATOR_DNS:-127.0.0.1}"
# 점으로 구분한 네 자리가 각각 0~255 이고 앞에 0이 붙지 않은 IPv4 주소인지 (999.999.999.999 · 127.0.0.01 거부)
is_ipv4() {
  local IFS=. o
  # shellcheck disable=SC2086 # 점으로 나누려고 일부러 따옴표를 뺀다
  set -- $1
  [ $# -eq 4 ] || return 1
  for o in "$@"; do
    [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$o" -le 255 ] || return 1
  done
}
if [ "$DNS" = "host" ]; then
  DNS=""   # 격리 해제: Docker 기본 리졸버
elif ! [[ "$DNS" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ! is_ipv4 "$DNS"; then
  die "EMULATOR_DNS 는 IPv4 주소이거나 host 여야 합니다 (기본 127.0.0.1, 격리 해제는 host): '$DNS'"
fi

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
    running_dns="$(container_dns "$PORT")"
    if [ "$running_dns" != "${DNS:-host}" ]; then
      # 다시 띄울 때도 요청한 값이 그대로 쓰이도록 EMULATOR_DNS 를 명령에 넣어 보여 준다
      # (그냥 emulator-reset.sh 를 실행하면 기본값 127.0.0.1 로 다시 뜬다).
      c_ylw "이 컨테이너의 DNS 설정($running_dns)이 요청한 값(${DNS:-host})과 다릅니다. 컨테이너를 그대로 둡니다."
      c_ylw "요청한 값으로 바꾸려면 (재시작 — 만든 리소스가 모두 사라짐): EMULATOR_DNS=${DNS:-host} scripts/emulator-reset.sh $PORT"
    fi
    warn_if_clock_unstable
    print_next
    exit 0
  fi
  c_ylw "$NAME 컨테이너는 떠 있지만 아직 헬스 체크가 통과하지 않았습니다. 기다립니다..."
elif [ -n "$state" ]; then
  # 비정상 종료 등으로 남은 컨테이너: 마지막 로그를 보여 주고 지운다.
  if [ "$(docker container inspect -f '{{.State.OOMKilled}}' "$NAME" 2>/dev/null)" = "true" ]; then
    c_ylw "이전 컨테이너 $NAME 는 메모리 상한($MEMORY 기준이 아닐 수 있음)을 넘어 OOM(137)으로 죽었습니다. 자주 반복되면 EMULATOR_MEMORY=3g 로 띄우세요."
  fi
  c_ylw "멈춘 컨테이너 $NAME (상태: $state)를 정리하고 새로 띄웁니다. 마지막 로그:"
  docker logs --tail 5 "$NAME" 2>&1 | sed 's/^/    /' || true
  docker rm -f "$NAME" >/dev/null
  state=""
fi

if [ -z "$state" ]; then
  mkdir -p "$EMULATOR_HOME_DIR"

  run_args=(
    run -d --name "$NAME" --pull never   # 로컬에서 빌드한 이미지만 쓴다(레지스트리에서 받지 않음)
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
  if [ -n "$DNS" ]; then
    run_args+=(--dns "$DNS")
  fi
  emu_args=(-p "$PORT")
  if [ "${EMULATOR_TELEMETRY:-off}" != "on" ]; then
    emu_args+=(--telemetry off)
  fi
  if [ -n "${EMULATOR_IDLE_TIMEOUT:-}" ]; then
    emu_args+=(--idle-timeout "$EMULATOR_IDLE_TIMEOUT")
  fi

  echo "에뮬레이터를 시작합니다: $NAME (포트 $PORT, 메모리 상한 $MEMORY, DNS ${DNS:-host(Docker 기본 리졸버)})"
  if ! docker "${run_args[@]}" "$EMULATOR_IMAGE" "${emu_args[@]}" >/dev/null; then
    die "컨테이너를 시작하지 못했습니다. 포트 $PORT 를 다른 프로그램이 쓰고 있지 않은지 확인하세요 (lsof -i :$PORT)."
  fi
fi

# 헬스 체크 대기 (최대 60초)
for _ in $(seq 60); do
  if health_ok "$PORT"; then
    c_grn "준비 완료: https://127.0.0.1:$PORT  (헬스 체크: ok)"
    warn_if_clock_unstable   # VM 시계가 몇 초씩 반복해서 옮겨지는 중이면 경고 (M00 레슨 3 문제 해결)
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
