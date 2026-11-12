# shellcheck shell=bash
# M10 실습 공용 도우미. 각 lab 이 scripts/env.sh 다음에 source 한다.
#   source "$(dirname "$0")/_lib.sh"

# fail "메시지" — 단언 실패
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# wait_until <상한초> <간격초> <설명> <명령...>
# 명령이 성공(종료 코드 0)할 때까지 폴링한다. 상한을 넘기면 마지막 출력을 보여 주고 실패한다.
# "몇 초 뒤"를 가정하지 않고 상태가 될 때까지 기다리기 위한 함수다.
wait_until() {
  local limit="$1" interval="$2" what="$3"
  shift 3
  local start out
  start=$(date +%s)
  while true; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if [ $(($(date +%s) - start)) -ge "$limit" ]; then
      echo "FAIL: ${limit}초 안에 '$what' 상태가 되지 않음. 마지막 관찰: $out" >&2
      exit 1
    fi
    sleep "$interval"
  done
}

# stack_status <스택이름> — 현재 상태 (없으면 NONE)
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE
}

# wait_stack <스택이름> [상한초] — *_COMPLETE / *_FAILED 가 될 때까지 2초 간격으로 폴링하고 상태를 출력한다.
# CLI의 `aws cloudformation wait stack-create-complete`(30초 간격)를 쓰지 않는 이유는 README "에뮬레이터 제약" 참고.
wait_stack() {
  local name="$1" limit="${2:-180}" start s
  start=$(date +%s)
  while true; do
    s="$(stack_status "$name")"
    case "$s" in
      *_IN_PROGRESS) ;;
      *) echo "$s"; return 0 ;;
    esac
    if [ $(($(date +%s) - start)) -ge "$limit" ]; then
      echo "FAIL: ${limit}초 안에 스택 $name 이 끝나지 않음 (마지막 상태 $s)" >&2
      exit 1
    fi
    sleep 2
  done
}

# delete_stack_if_exists <스택이름> — 남아 있으면 지우고 사라질 때까지 기다린다 (멱등성).
delete_stack_if_exists() {
  local name="$1"
  [ "$(stack_status "$name")" = NONE ] && return 0
  aws cloudformation update-termination-protection --stack-name "$name" \
    --no-enable-termination-protection >/dev/null 2>&1 || true
  aws cloudformation delete-stack --stack-name "$name"
  wait_until 180 2 "스택 $name 삭제" bash -c "! aws cloudformation describe-stacks --stack-name '$name' >/dev/null 2>&1"
}

# py — 저장소의 uv 가상 환경 Python (JSON 가공용). 시스템 python3 버전에 기대지 않는다.
py() {
  uv run --quiet --project "$(git rev-parse --show-toplevel)" python "$@"
}
export -f py
