#!/usr/bin/env bash
# 사용법: scripts/clock-check.sh [포트]
#
# 이 컴퓨터의 시계와 에뮬레이터(컨테이너 = Colima VM)의 시계 차이를 잰다. 컨테이너 안에서 date 를 실행해
# VM 커널 시계를 직접 읽고, 그게 안 되면(docker 없음 등) 에뮬레이터 헬스 응답의 HTTP Date 헤더를 쓴다.
# (Date 헤더는 에뮬레이터가 캐시한 값이라, VM 시계가 뒤로 점프하면 실제 시계를 따라가지 않았다 — 20분 뒤로
#  돌린 시험에서 헤더로는 157초 차이만 보였다.) AWS 서명(SigV4)은 서명 시각이 서버 시계와 15분 넘게
# 차이 나면 거부되므로(에뮬레이터도 같다), 노트북이 잠들었다 깬 뒤 VM 시계가 뒤처지면
# 모든 요청이 SignatureDoesNotMatch / RequestTimeTooSkewed 로 실패한다.
#
# 종료 코드: 0 = 정상 — 차이가 14분보다 작음(아무것도 출력하지 않음. 60초를 넘으면 측정값만 참고로 출력)
#           3 = 14분(840초) 이상 어긋남 — SigV4 허용 범위(15분)에 닿아 서명이 거부될 수 있는 수준(해결 방법 출력)
#           2 = 측정하지 못함 (에뮬레이터가 꺼져 있음·포트 오류 등 — 이유를 한 줄 출력)
#           호출하는 쪽(env.sh·dr-env.sh)은 3 만 "시계 어긋남"으로 본다.
# env.sh / dr-env.sh 는 에뮬레이터가 **서명을 거부했을 때만**(SignatureDoesNotMatch 등) 원인 진단용으로 부른다.
# (EMULATOR_CLOCK_FAKE_NOW: 테스트용으로 "현재 시각(epoch 초)"을 바꿔 끼운다)
set -uo pipefail

PORT="${1:-${EMULATOR_PORT:-9297}}"
cannot() { printf '[clock-check] 측정하지 못했습니다: %s\n' "$1" >&2; exit 2; }
case "$PORT" in '' | *[!0-9]*) cannot "포트가 숫자가 아닙니다: '$PORT'" ;; esac
CA="$HOME/.aws/emulator/$PORT/ca.pem"
[ -f "$CA" ] || cannot "포트 $PORT 의 에뮬레이터가 떠 있지 않습니다 ($CA 없음). 먼저 scripts/emulator-up.sh $PORT"

# 1순위: 컨테이너의 커널 시계 (컨테이너는 VM 커널 시계를 그대로 쓴다)
server_epoch=""
if command -v docker >/dev/null 2>&1; then
  server_epoch="$(docker exec "aws-emulator-$PORT" date -u +%s 2>/dev/null)" || server_epoch=""
fi
case "$server_epoch" in '' | *[!0-9]*) server_epoch="" ;; esac
if [ -z "$server_epoch" ]; then
  # 2순위: HTTP Date 헤더
  server_date="$(curl -sI --max-time 3 --cacert "$CA" "https://127.0.0.1:$PORT/__admin/health" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)"
  [ -n "$server_date" ] || cannot "포트 $PORT 의 에뮬레이터가 응답하지 않습니다 (scripts/emulator-status.sh 로 확인)"
  # GNU date(Linux) → BSD date(macOS) 순서로 HTTP 날짜를 epoch 초로 바꾼다.
  server_epoch="$(LC_ALL=C date -u -d "$server_date" +%s 2>/dev/null \
    || LC_ALL=C date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "$server_date" +%s 2>/dev/null)" \
    || cannot "에뮬레이터 시각을 해석하지 못했습니다: '$server_date'"
fi
now="${EMULATOR_CLOCK_FAKE_NOW:-$(date -u +%s)}"
skew=$((now - server_epoch))
abs=${skew#-}
THRESHOLD=840
if [ "$abs" -lt "$THRESHOLD" ]; then
  if [ "$abs" -gt 60 ]; then
    printf '[clock-check] 참고: 이 컴퓨터와 포트 %s 의 에뮬레이터 시계가 %s초 다릅니다 (서명 허용 범위 15분 안이라 이 차이로 거부되지는 않음).\n' "$PORT" "$skew" >&2
  fi
  exit 0
fi

if [ "$skew" -gt 0 ]; then dir="에뮬레이터(VM) 시계가 ${abs}초 느립니다"; else dir="에뮬레이터(VM) 시계가 ${abs}초 빠릅니다"; fi
printf '\033[33m[clock-check] 시계 어긋남: 이 컴퓨터와 포트 %s 의 에뮬레이터 시계가 다릅니다 — %s.\033[0m\n' "$PORT" "$dir" >&2
cat >&2 <<'EOF'
              AWS 서명(SigV4)은 15분 넘게 어긋나면 거부됩니다. 노트북이 잠들었다 깨면 Colima VM 시계가 뒤처질 수 있습니다.
              보통은 Colima(Lima 2.x)의 게스트 에이전트가 몇 초 안에 맥 시각으로 맞추므로, 잠시 뒤 다시 해 보세요.
              그래도 그대로면 (VM·에뮬레이터를 끄지 않음. 컨테이너는 VM 커널 시계를 그대로 써서 즉시 반영되고,
              에뮬레이터를 재시작할 필요 없음 — VM 시계를 일부러 ±20분 바꿔 시험함):
                colima ssh -- sudo systemctl restart systemd-timesyncd   # 즉시 NTP 재동기화 (인터넷 필요)
                colima ssh -- sudo date -u -s "@$(date -u +%s)"          # 오프라인이면: 맥의 시각을 VM에 그대로 설정
              최후 수단: colima restart (VM 재시작 — 에뮬레이터가 꺼지고 상태가 사라짐. 그 뒤 scripts/emulator-up.sh)
              확인:  bash scripts/clock-check.sh  (아무것도 출력하지 않으면 정상)
              Docker Desktop 이라면 Docker Desktop 을 재시작하세요. Linux(VM 없음)에서는 호스트 시계(NTP)를 확인하세요.
EOF
exit 3
