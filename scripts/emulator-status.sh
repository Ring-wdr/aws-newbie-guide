#!/usr/bin/env bash
# 사용법: scripts/emulator-status.sh
#
# 이 저장소의 스크립트로 띄운 에뮬레이터 컨테이너 목록과 헬스 체크, DNS 설정, 메모리 사용량을 보여 준다.
# DNS 열: 127.0.0.1 = 컨테이너 안 이름 해석 차단(기본값), host = Docker 기본 리졸버(EMULATOR_DNS=host 로 띄움).
set -euo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

require_docker

if command -v colima >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
  colima list 2>/dev/null | sed 's/^/  /' || true
  echo
fi

names="$(docker ps -a --filter "label=$EMULATOR_LABEL=1" --format '{{.Names}}' | sort)"
if [ -z "$names" ]; then
  echo "실행 중인 에뮬레이터가 없습니다. 시작: scripts/emulator-up.sh [포트]"
  exit 0
fi

oom_hint=""
printf '%-20s %-6s %-10s %-8s %-10s %s\n' "CONTAINER" "PORT" "STATE" "HEALTH" "DNS" "MEMORY(USED / LIMIT)"
for name in $names; do
  port="${name#aws-emulator-}"
  state="$(container_state "$port")"
  health="-"
  mem="-"
  if [ "$state" != "running" ]; then
    detail="$(docker container inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}}' "$name" 2>/dev/null || echo '')"
    case "$detail" in
      *" true") state="OOM(137)"; oom_hint="$oom_hint $port" ;;
      *) state="$state(${detail%% *})" ;;
    esac
  fi
  if [ "$state" = "running" ]; then
    if health_ok "$port"; then health="ok"; else health="FAIL"; fi
    mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$name" 2>/dev/null || echo '-')"
  fi
  printf '%-20s %-6s %-10s %-8s %-10s %s\n' "$name" "$port" "$state" "$health" "$(container_dns "$port")" "$mem"
done
for p in $oom_hint; do
  c_red "포트 $p: 메모리 상한을 넘어 강제 종료됨(종료 코드 137). 리소스는 사라졌습니다 → scripts/emulator-reset.sh $p (반복되면 EMULATOR_MEMORY=3g)"
done
warn_if_clock_unstable   # VM 시계가 몇 초씩 반복해서 옮겨지는 중이면 경고 (M00 레슨 3 문제 해결)
