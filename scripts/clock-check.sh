#!/usr/bin/env bash
# 사용법: scripts/clock-check.sh [포트]
#
# 이 컴퓨터의 시계와 에뮬레이터(컨테이너 = Colima VM)의 시계 차이를 잰다. 에뮬레이터 헬스 응답의
# HTTP Date 헤더와 로컬 시각을 비교한다. AWS 서명(SigV4)은 서명 시각이 서버 시계와 15분 넘게
# 차이 나면 거부되므로(에뮬레이터도 같다), 노트북이 잠들었다 깬 뒤 VM 시계가 뒤처지면
# 모든 요청이 SignatureDoesNotMatch / RequestTimeTooSkewed 로 실패한다.
#
# 종료 코드: 3 = 14분(840초) 이상 어긋남 — SigV4 허용 범위(15분)에 닿아 서명이 거부될 수 있는 수준(해결 방법 출력)
#           0 = 그보다 작음(60초를 넘으면 측정값만 참고로 출력) 또는 측정 불가
# env.sh / dr-env.sh 는 에뮬레이터가 **서명을 거부했을 때만**(SignatureDoesNotMatch 등) 원인 진단용으로 부른다.
# (EMULATOR_CLOCK_FAKE_NOW: 테스트용으로 "현재 시각(epoch 초)"을 바꿔 끼운다)
set -uo pipefail

PORT="${1:-${EMULATOR_PORT:-9297}}"
case "$PORT" in '' | *[!0-9]*) echo "포트가 숫자가 아닙니다: $PORT" >&2; exit 0 ;; esac
CA="$HOME/.aws/emulator/$PORT/ca.pem"
[ -f "$CA" ] || exit 0

server_date="$(curl -sI --max-time 3 --cacert "$CA" "https://127.0.0.1:$PORT/__admin/health" 2>/dev/null \
  | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)"
[ -n "$server_date" ] || exit 0

# GNU date(Linux) → BSD date(macOS) 순서로 HTTP 날짜를 epoch 초로 바꾼다.
server_epoch="$(LC_ALL=C date -u -d "$server_date" +%s 2>/dev/null \
  || LC_ALL=C date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "$server_date" +%s 2>/dev/null)" || exit 0
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
              AWS 서명(SigV4)은 15분 넘게 어긋나면 거부됩니다. 노트북이 잠들었다 깬 뒤 Colima VM 시계가
              뒤처지는 경우가 흔합니다 (VM의 systemd-timesyncd 는 주기적으로만 맞추므로 수십 분 걸릴 수 있음).
              해결 (VM·에뮬레이터를 끄지 않음 — 컨테이너는 VM 커널 시계를 그대로 쓰므로 즉시 반영해야 함.
                    ※ 실제 잠자기 후 어긋난 시계로는 아직 검증하지 못한 방법이다. 안 되면 colima restart — 에뮬레이터 상태가 사라짐):
                colima ssh -- sudo systemctl restart systemd-timesyncd   # 즉시 NTP 재동기화 (인터넷 필요)
                colima ssh -- sudo date -u -s "@$(date -u +%s)"          # 오프라인이면: 맥의 시각을 VM에 그대로 설정
              확인:  date -u; colima ssh -- date -u
              Docker Desktop 이라면 Docker Desktop 을 재시작하세요. Linux(VM 없음)에서는 호스트 시계(NTP)를 확인하세요.
EOF
exit 3
