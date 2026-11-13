#!/usr/bin/env bash
# M04 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# 모든 lab 과 sdk 예제를 실행한다. lab 은 번호 순서로 한 번, 역순으로 한 번 더 실행해 멱등성·순서 무관성을 확인한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m04-storage/labs/verify.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m04-storage"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 1) 깨끗한 에뮬레이터 (EMULATOR_PORT 가 없으면 비대화형 셸에서는 거부된다)
"$ROOT/scripts/emulator-reset.sh"
export EMULATOR_PORT="${EMULATOR_PORT:-9297}"
source "$ROOT/scripts/env.sh"

pass=0
fail=0
run() {
  local label="$1"
  shift
  if "$@" >"$LOG_DIR/out" 2>&1; then
    echo "PASS  $label"
    pass=$((pass + 1))
  else
    echo "FAIL  $label"
    sed 's/^/      | /' "$LOG_DIR/out" | tail -20
    fail=$((fail + 1))
  fi
}

# boto3 예제의 안전 장치(emulator_guard) 확인: env.sh 없이(AWS_ENDPOINT_URL 없음) 실행하면
# 네트워크 호출 전에 종료 코드 1로 멈춰야 한다. 더미 키만 쓰고, 사용자의 ~/.aws 설정은 읽지 않게
# /dev/null 로 막고, 혹시 나가는 요청이 있으면 즉시 실패하도록 프록시를 닫힌 포트로 보낸다.
guard_refuses() {
  local out rc
  out="$(env -u AWS_ENDPOINT_URL -u AWS_CA_BUNDLE -u AWS_PROFILE -u AWS_SESSION_TOKEN -u TODAYORDER_ALLOW_REAL_AWS \
    AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=dummy-not-a-real-key \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY= UV_OFFLINE=1 \
    uv run --quiet python "$1" 2>&1)"
  rc=$?
  echo "$out"
  [ "$rc" -eq 1 ] || { echo "종료 코드가 1이 아님: $rc"; return 1; }
  # 첫 단계(환경 변수 검사, 네트워크 없음)의 메시지여야 한다. STS 연결 실패 메시지면 네트워크를 시도한 것이다.
  grep -q '^\[emulator_guard\] AWS_ENDPOINT_URL 이 로컬 에뮬레이터' <<<"$out" || return 1
  ! grep -qE 'Traceback|연결하지 못했습니다' <<<"$out"
}

cd "$ROOT"
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
labs=("$MOD_DIR"/labs/lab*.sh)
# 1회차는 번호 순서, 2회차는 역순 — 멱등성(두 번 실행)과 순서 무관성을 함께 확인한다.
for lab in "${labs[@]}"; do
  run "$(basename "$lab") (실행 1)" bash "$lab"
done
for ((i = ${#labs[@]} - 1; i >= 0; i--)); do
  run "$(basename "${labs[$i]}") (실행 2, 역순)" bash "${labs[$i]}"
done
for py in "$MOD_DIR"/sdk/*.py; do
  run "sdk/$(basename "$py")" uv run --quiet python "$py"
done

# 에뮬레이터로 관찰할 수 없어 실행하지 않는 항목 (lab 안에서 "도달 불가/501" 자체는 확인한다)
echo "SKIP  액세스 포인트 경유 접근·계정 수준 퍼블릭 액세스 차단 (S3 Control 이 에뮬레이터에 도달하지 않음 — lab07)"
echo "SKIP  EFS 를 NFS 로 마운트해 파일 쓰기 (마운트 불가 — lab10 은 구성까지)"
echo "SKIP  KMS 키 비활성화 시 SSE-KMS 객체 읽기 실패 (에뮬레이터는 읽힘 — M09 에서 Decrypt 로 시연)"
echo "SKIP  수명 주기 전환 실제 발생 (에뮬레이터는 전환하지 않음 — lab02 는 구성까지)"
echo "SKIP  Storage Gateway 볼륨·테이프, DataSync 실제 복사 (501/복사 없음 — lab11 은 구성까지)"
echo "----"
echo "통과 $pass · 실패 $fail"
if [ "$fail" -ne 0 ]; then
  echo "MODULE m04 FAIL"
  exit 1
fi
echo "MODULE m04 OK"
