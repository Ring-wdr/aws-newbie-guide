#!/usr/bin/env bash
# M12 lab02 — 에뮬레이터 두 개로 "리전 2개" 흉내 내기: 파일럿 라이트 + 장애 조치 런북 (🟡)
#
#   주 리전 "서울" = $EMULATOR_PORT 의 에뮬레이터 (scripts/env.sh)
#   DR 리전 "도쿄" = $DR_EMULATOR_PORT 의 에뮬레이터 (labs/dr-env.sh)
#     비대화형 실행에서는 DR_EMULATOR_PORT 필수. 대화형 터미널에서만 생략 가능(EMULATOR_PORT+1)
#   ※ 둘 다 기술적으로는 us-east-1 이다. 리전을 흉내 낼 뿐, 실제 리전 간 네트워크·복제는 없다.
#
# 흐름: 양쪽 정리 → 서울 bootstrap → 도쿄 파일럿 라이트 → 주문 3건 → 동기화 → 주문 2건 더(미동기화)
#       → 서울 "장애"(docker pause) → 헬스 체크 실패 → EMULATOR_PORT 를 도쿄로 바꿔 장애 조치
#       → 도쿄에서 주문 확인·신규 주문 → 서울 복구(unpause) → RPO/RTO 단언
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
MOD="$ROOT/curriculum/m12-resilience-dr-migration"
APP="$MOD/sdk/order_app.py"
SYNC="$MOD/sdk/dr_replicate.py"
PRIMARY_PORT="$EMULATOR_PORT"
# DR 포트: 이 lab 은 그 에뮬레이터의 리소스를 지우므로, 비대화형에서는 추측하지 않는다.
if [ -z "${DR_EMULATOR_PORT:-}" ] && [ ! -t 0 ]; then
  echo "오류: DR_EMULATOR_PORT 가 설정되지 않았습니다. 비대화형 실행에서는 'EMULATOR_PORT+1' 기본값을 쓰지 않습니다." >&2
  echo "      'export DR_EMULATOR_PORT=<DR 리전 포트>' 후 다시 실행하세요." >&2
  exit 1
fi
DR_PORT="${DR_EMULATOR_PORT:-$((PRIMARY_PORT + 1))}"
SEOUL_BUCKET="todayorder-receipts-seoul"
TOKYO_BUCKET="todayorder-receipts-tokyo"
TABLE="todayorder-orders"
PARAM="/todayorder/receipts-bucket"
cd "$ROOT"

# DR 리전 에뮬레이터가 꺼져 있으면 켠다 (이미 떠 있으면 그대로).
"$ROOT/scripts/emulator-up.sh" "$DR_PORT" >/dev/null
export DR_EMULATOR_PORT="$DR_PORT"
source "$MOD/labs/dr-env.sh"

# 서울을 pause 한 채로 스크립트가 중간에 죽어도 반드시 되살린다.
PRIMARY_CONTAINER="aws-emulator-$PRIMARY_PORT"
trap 'docker unpause "$PRIMARY_CONTAINER" >/dev/null 2>&1 || true' EXIT

# 주어진 aws 명령(aws 또는 dr_aws)으로 그 리전의 실습 리소스를 지운다 (멱등).
wipe_site() {
  local cli="$1" b
  "$cli" dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
  for b in "$SEOUL_BUCKET" "$TOKYO_BUCKET"; do
    "$cli" s3 rb "s3://$b" --force >/dev/null 2>&1 || true
  done
  "$cli" ssm delete-parameter --name "$PARAM" >/dev/null 2>&1 || true
  local i
  for i in $(seq 60); do
    "$cli" dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1 || return 0
    sleep 1
  done
  echo "FAIL: $TABLE 삭제가 끝나지 않음"; return 1
}
# 주어진 포트의 에뮬레이터를 "현재 리전"으로 삼아 앱을 실행한다 — 런북의 'EMULATOR_PORT 바꾸기' 그 자체.
app_at() {
  local port="$1"; shift
  (export EMULATOR_PORT="$port"; source "$ROOT/scripts/env.sh" 2>/dev/null; uv run --quiet python "$APP" "$@")
}
healthy() {
  [ "$(curl -s --max-time 3 --cacert "$HOME/.aws/emulator/$1/ca.pem" "https://127.0.0.1:$1/__admin/health" 2>/dev/null)" = "ok" ]
}

wipe_site aws
wipe_site dr_aws

echo "== 1. 서울(주 리전) 준비: 테이블·버킷·설정"
app_at "$PRIMARY_PORT" bootstrap "$SEOUL_BUCKET"

echo "== 2. 도쿄(DR 리전) 파일럿 라이트: 같은 앱으로 '불씨'만 만들어 둔다 (서버는 없음)"
app_at "$DR_PORT" bootstrap "$TOKYO_BUCKET"

echo "== 3. 평소 영업: 서울에 주문 3건"
for n in 1001 1002 1003; do app_at "$PRIMARY_PORT" place "A-$n" "${n}0"; done

echo "== 4. 정기 복제: 서울 → 도쿄"
uv run --quiet python "$SYNC" sync

echo "== 5. 복제 이후에도 주문은 계속 들어온다 (아직 도쿄에 없음)"
for n in 1004 1005; do app_at "$PRIMARY_PORT" place "A-$n" "${n}0"; done
uv run --quiet python "$SYNC" status

echo "== 6. 서울 리전 장애 발생 (docker pause $PRIMARY_CONTAINER)"
docker pause "$PRIMARY_CONTAINER" >/dev/null
t0=$(date +%s)
if healthy "$PRIMARY_PORT"; then echo "FAIL: pause 했는데 헬스 체크가 통과함"; exit 1; fi
echo "서울 헬스 체크: 응답 없음 → 런북 시작"

echo "== 7. 장애 조치: EMULATOR_PORT=$DR_PORT 로 바꿔 도쿄에서 앱 실행"
healthy "$DR_PORT" || { echo "FAIL: 도쿄도 응답 없음"; exit 1; }
tokyo_list="$(app_at "$DR_PORT" list)"
echo "$tokyo_list"
app_at "$DR_PORT" place A-1006 10060
t1=$(date +%s)
echo "장애 감지 → 도쿄에서 첫 주문 처리까지: $((t1 - t0))초 (이 실습 환경의 RTO. 실제는 DNS 전환·확장 시간이 더해진다)"

echo "== 8. 서울 복구 (docker unpause)"
docker unpause "$PRIMARY_CONTAINER" >/dev/null
for _ in $(seq 30); do healthy "$PRIMARY_PORT" && break; sleep 1; done
healthy "$PRIMARY_PORT" || { echo "FAIL: 서울이 복구되지 않음"; exit 1; }
echo "서울 헬스 체크: ok — 하지만 이제 '진짜 데이터'는 도쿄에 있다(A-1006). 페일백 전에 역방향 동기화가 필요하다"

# ---- 단언
seoul_ids="$(aws dynamodb scan --table-name "$TABLE" --query 'Items[].orderId.S' --output json | tr -d ' \n')"
tokyo_ids="$(dr_aws dynamodb scan --table-name "$TABLE" --query 'Items[].orderId.S' --output json | tr -d ' \n')"
sorted() { tr -d '[]"' <<<"$1" | tr ',' '\n' | sort | paste -sd, -; }
echo "서울: $(sorted "$seoul_ids")"
echo "도쿄: $(sorted "$tokyo_ids")"
[ "$(sorted "$seoul_ids")" = "A-1001,A-1002,A-1003,A-1004,A-1005" ] || { echo "FAIL: 서울 주문 목록"; exit 1; }
[ "$(sorted "$tokyo_ids")" = "A-1001,A-1002,A-1003,A-1006" ] || { echo "FAIL: 도쿄 주문 목록"; exit 1; }
grep -q '주문 3건' <<<"$tokyo_list" || { echo "FAIL: 장애 조치 직후 도쿄 주문 수"; exit 1; }
[ "$(dr_aws ssm get-parameter --name "$PARAM" --query Parameter.Value --output text)" = "$TOKYO_BUCKET" ] \
  || { echo "FAIL: 도쿄 설정 파라미터"; exit 1; }
dr_aws s3api head-object --bucket "$TOKYO_BUCKET" --key _dr/last-sync.json >/dev/null \
  || { echo "FAIL: 체크포인트 없음"; exit 1; }
echo "잃은 주문(RPO): A-1004, A-1005 — 마지막 동기화 이후 서울에만 쓰인 2건"
echo "LAB02 OK"
echo "참고: DR 리전 에뮬레이터(포트 $DR_PORT)는 켜 둔 채로 끝납니다. 다 썼으면 끄세요: scripts/emulator-down.sh $DR_PORT"
