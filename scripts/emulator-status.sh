#!/usr/bin/env bash
# 사용법: scripts/emulator-status.sh
#
# 이 저장소의 스크립트로 띄운 에뮬레이터 컨테이너 목록과 헬스 체크, 메모리 사용량을 보여 준다.
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

printf '%-20s %-6s %-10s %-8s %s\n' "CONTAINER" "PORT" "STATE" "HEALTH" "MEMORY(USED / LIMIT)"
for name in $names; do
  port="${name#aws-emulator-}"
  state="$(container_state "$port")"
  health="-"
  mem="-"
  if [ "$state" = "running" ]; then
    if health_ok "$port"; then health="ok"; else health="FAIL"; fi
    mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$name" 2>/dev/null || echo '-')"
  fi
  printf '%-20s %-6s %-10s %-8s %s\n' "$name" "$port" "$state" "$health" "$mem"
done
