#!/usr/bin/env bash
# 사용법: scripts/emulator-reset.sh [포트]
#
# 에뮬레이터를 내렸다가 다시 띄워 "깨끗한 상태"로 만든다.
# 에뮬레이터에는 상태 초기화 API가 없고 모든 상태가 메모리에 있으므로, 재시작이 곧 초기화다.
# 재시작하면 자격 증명과 인증서가 새로 만들어진다. 파일 경로는 같으므로 이미 env.sh 를
# source 한 셸도 그대로 쓸 수 있다.
#
# 포트: 인자 > EMULATOR_PORT > (대화형 터미널일 때만) 9297.
# 비대화형 셸에서 둘 다 없으면 거부한다 (다른 사람의 에뮬레이터를 지우지 않도록).
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=scripts/_common.sh
. "$here/_common.sh"
PORT="$(resolve_destructive_port "${1:-}")"
validate_port "$PORT"
"$here/emulator-down.sh" "$PORT"
"$here/emulator-up.sh" "$PORT"
