#!/usr/bin/env bash
# 사용법: scripts/clock-check.sh [포트]                      시계 어긋남(서명 거부 수준) 확인
#         scripts/clock-check.sh --stability [--last <초>]   VM 시계가 "지금 흔들리고 있는지" 확인 (아래 "안정성 모드")
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
#
# 안정성 모드 (--stability): 차이가 작아도 VM 시계가 몇 초씩 **반복해서** 앞뒤로 옮겨지면 에뮬레이터가 막 만든
# 리소스를 잠깐 "아직 준비 안 됨"으로 본다(Kinesis 스트림 ACTIVE → CREATING, DynamoDB 테이블 ACTIVE 직후
# PutItem·BatchWriteItem 의 ResourceNotFoundException). 원인: Colima(Lima 2.x)의 게스트 에이전트는 10초마다 VM 시계를
# 맥 시각으로 맞추고(차이가 0.1초를 넘을 때), VM 안의 systemd-timesyncd 는 인터넷 NTP 시각으로 맞춘다. 맥 시계가
# NTP 와 0.1초 넘게 다르면 둘이 10초마다 서로 되돌린다. 0.1~0.14초짜리 작은 보정은 흔하고(관찰: 약 31시간치 저널에 743번, 그중 724번이 어느 새벽 5시간 남짓에 몰림)
# 영향이 없었다. 문제는 한 번에 0.5초 이상일 때다(시험: DynamoDB 는 1초 이상에서, Kinesis 는 2초에서 준비 상태가
# 되돌아감. 관찰: 맥 시계가 2초 틀어진 45분 동안 270번). 서명은 15분까지 허용되므로 위의 기본 모드로는 보이지 않는다. 이 모드는 VM 저널에서 게스트 에이전트의 보정 기록("SyncTime: ... drift was X")을 센다.
#   --last <초>  최근 몇 초를 볼지 (기본 180)
#   --summary    검증 스크립트의 요약용: 불안정할 때만 "이번 실행 동안 …"을 출력하고, 언제나 0 으로 끝난다
#                (확인하지 못해도 조용히 0). 모듈 verify.sh 는 실패 요약 바로 앞에 한 줄로 부른다:
#                  bash "$ROOT/scripts/clock-check.sh" --stability --summary --last "$SECONDS" || true
#                ($SECONDS = bash 가 그 스크립트를 시작한 뒤 지난 초 → "이번 실행 동안". --summary 는 0 으로 끝나지만
#                 set -e 인 verify.sh 가 어떤 경우에도 여기서 멈추지 않게 || true 를 붙인다)
#   colima ssh 는 제한 시간(기본 3초, EMULATOR_CLOCK_SSH_TIMEOUT) 안에 끝나지 않으면 "확인하지 못함"(2, --summary 는 조용히 0).
# 종료 코드: 0 = 안정(아무것도 출력하지 않음. 잠자기 뒤 한 번 크게 맞춘 것은 참고로만 출력)
#           4 = 불안정 — 0.5초 이상(60초 미만) 보정이 3번 이상(설명과 해결 방법 출력)
#           2 = 확인하지 못함 (Colima VM 이 아님·colima ssh 실패·시간 초과 — 이유를 한 줄 출력)
#           (--summary 는 언제나 0)
# 부르는 곳: emulator-up.sh·emulator-status.sh(_common.sh 의 warn_if_clock_unstable — 경고만), 15개 모듈(M00~M14)의
# labs/verify.sh(--stability --summary — M01~M14 는 실패할 때만, M00 은 통과할 때에도). env.sh·dr-env.sh 는 이 모드를
# 부르지 않는다(lab 마다 source 되므로 colima ssh 비용을 붙이지 않는다). 기본 모드의 종료 코드 0·3·2 는 그대로다.
# (EMULATOR_CLOCK_FAKE_JOURNAL: 테스트용으로 VM 저널 대신 읽을 파일. 'journalctl -o short-unix' 형식)
set -uo pipefail

# shellcheck source=scripts/_common.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"   # run_limited (제한 시간 실행)

stability() {
  local last=180 since now journal ctx profile summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --last) last="${2:-}"; shift 2 || shift ;;
      --summary) summary=1; shift ;;
      *) printf '[clock-check] 알 수 없는 인자: %s (사용법: clock-check.sh --stability [--last <초>] [--summary])\n' "$1" >&2; exit 2 ;;
    esac
  done
  case "$last" in '' | *[!0-9]*) printf '[clock-check] --last 는 초 단위 숫자여야 합니다: %s\n' "$last" >&2; exit 2 ;; esac
  # 너무 큰 값(bash 정수 범위를 넘는 자릿수 포함)은 30일로 줄인다
  if [ "${#last}" -gt 7 ] || [ "$last" -gt 2592000 ]; then last=2592000; fi
  [ "$last" -ge 1 ] || last=1
  now="${EMULATOR_CLOCK_FAKE_NOW:-$(date -u +%s)}"
  since=$((now - last))
  if [ -n "${EMULATOR_CLOCK_FAKE_JOURNAL:-}" ]; then
    journal="$(cat "$EMULATOR_CLOCK_FAKE_JOURNAL" 2>/dev/null)" || { [ "$summary" -eq 1 ] && exit 0; exit 2; }
  else
    cannot_s() {
      [ "$summary" -eq 1 ] && exit 0
      printf '[clock-check] VM 시계 안정성을 확인하지 못했습니다: %s\n' "$1" >&2
      exit 2
    }
    command -v colima >/dev/null 2>&1 || cannot_s "colima 가 없습니다 (Colima VM 에서만 확인합니다)"
    ctx="$(docker context show 2>/dev/null)" || ctx=""
    case "$ctx" in
      colima) profile=default ;;
      colima-*) profile="${ctx#colima-}" ;;
      *) cannot_s "docker 컨텍스트가 Colima 가 아닙니다('${ctx:-없음}')" ;;
    esac
    # 게스트 에이전트의 보정 기록만 읽는다. 기본 사용자가 저널 그룹에 없을 수 있어 sudo -n 을 먼저 시도한다.
    # colima ssh 는 잠자기 뒤 낡은 ssh 연결 등으로 멈출 수 있다 — emulator-up·status 가 같이 멈추지 않게
    # 제한 시간(기본 3초, EMULATOR_CLOCK_SSH_TIMEOUT)을 넘기면 "확인하지 못함"으로 본다.
    local tmo="${EMULATOR_CLOCK_SSH_TIMEOUT:-3}" jf rc=0
    case "$tmo" in '' | *[!0-9]* | 0) tmo=3 ;; esac
    jf="$(mktemp "${TMPDIR:-/tmp}/clock-check.XXXXXX")" || cannot_s "임시 파일을 만들지 못했습니다"
    # Ctrl-C·TERM·HUP 로 끝나도 임시 파일을 남기지 않는다. 신호마다 exit 를 걸어 두어야 EXIT trap 이 언제나 돈다
    # (bash 는 trap 없는 TERM·HUP 로 죽을 때 EXIT trap 을 건너뛸 수 있다).
    trap 'rm -f "$jf"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    run_limited "$tmo" "$jf" colima ssh -p "$profile" -- sh -c "sudo -n journalctl -t lima-guestagent --since @$since -o short-unix -q --no-pager 2>/dev/null || journalctl -t lima-guestagent --since @$since -o short-unix -q --no-pager" || rc=$?
    journal="$(cat "$jf" 2>/dev/null)"
    rm -f "$jf"
    [ "$rc" -ne 130 ] || exit 130   # Ctrl-C·TERM·HUP 로 중단됨 (--summary 도 중단은 그대로 알린다)
    if [ "$rc" -eq 124 ]; then
      cannot_s "colima ssh 가 ${tmo}초 안에 응답하지 않았습니다 (colima status 로 VM 상태 확인. 계속되면 colima ssh -- true 로 접속을 확인)"
    elif [ "$rc" -ne 0 ]; then
      cannot_s "colima ssh 로 VM 저널을 읽지 못했습니다 (colima status 로 VM 상태 확인)"
    fi
  fi
  # 한 줄에 하나씩: <epoch> <보정량(초, 부호 포함)>. Go 의 시간 표기(1.99s, 100.06ms, -15m5.9s, 1h2m3s)를 초로 바꾼다.
  local rows
  rows="$(printf '%s\n' "$journal" | awk -v since="$since" -v now="$now" '
    /SyncTime: system time synchronized with host \(drift was / {
      t = $1 + 0; if (t < since || t > now + 5) next
      d = $0; sub(/.*drift was /, "", d); sub(/\).*/, "", d)
      sign = 1; if (substr(d, 1, 1) == "-") { sign = -1; d = substr(d, 2) }
      total = 0
      while (match(d, /^[0-9.]+(h|ms|us|µs|ns|m|s)/)) {
        tok = substr(d, 1, RLENGTH); d = substr(d, RLENGTH + 1)
        num = tok; unit = tok; sub(/[a-zµ]+$/, "", num); sub(/^[0-9.]+/, "", unit)
        f = (unit == "h") ? 3600 : (unit == "m") ? 60 : (unit == "s") ? 1 : (unit == "ms") ? 0.001 : (unit == "ns") ? 1e-9 : 1e-6
        total += num * f
      }
      printf "%d %.3f\n", t, sign * total
    }')"
  local n_unstable n_big lastt typ
  n_unstable="$(printf '%s\n' "$rows" | awk '{a = $2 < 0 ? -$2 : $2} NF == 2 && a >= 0.5 && a < 60 {n++} END {print n + 0}')"
  n_big="$(printf '%s\n' "$rows" | awk '{a = $2 < 0 ? -$2 : $2} NF == 2 && a >= 60 {n++} END {print n + 0}')"
  if [ "$n_unstable" -lt 3 ]; then
    if [ "$n_big" -gt 0 ] && [ "$summary" -eq 0 ]; then
      printf '[clock-check] 참고: 최근 %s초 동안 VM 시계를 크게(1분 이상) 맞춘 기록이 %s번 있습니다 — 맥이 잠들었다 깬 뒤의 정상적인 따라잡기입니다.\n' "$last" "$n_big" >&2
    fi
    exit 0
  fi
  lastt="$(printf '%s\n' "$rows" | awk '{a = $2 < 0 ? -$2 : $2} NF == 2 && a >= 0.5 && a < 60 {t = $1} END {print t}')"
  typ="$(printf '%s\n' "$rows" | awk '{a = $2 < 0 ? -$2 : $2} NF == 2 && a >= 0.5 && a < 60 {print a}' | sort -n | awk '{v[NR] = $1} END {print v[int((NR + 1) / 2)]}')"
  if [ "$summary" -eq 1 ]; then
    printf '\033[33m[clock-check] 참고: 이번 실행 동안(%s초) Colima VM 시계가 %s번 옮겨졌습니다 (한 번에 약 %s초). 위 실패가 "준비됨(ACTIVE) 직후 ResourceNotFoundException" 또는 "ACTIVE 였다가 CREATING" 이라면 이것 때문일 수 있습니다.\033[0m\n' \
      "$last" "$n_unstable" "$typ" >&2
  else
    printf '\033[33m[clock-check] VM 시계 불안정: 최근 %s초 동안 Colima VM 시계가 %s번 옮겨졌습니다 (한 번에 약 %s초, 마지막 %s초 전).\033[0m\n' \
      "$last" "$n_unstable" "$typ" "$((now - lastt))" >&2
  fi
  cat >&2 <<'EOF'
              맥 시계와 VM 의 NTP(systemd-timesyncd) 시각이 0.5초 넘게 달라, Colima 게스트 에이전트(10초마다 맥 시각으로)와
              timesyncd(NTP 시각으로)가 VM 시계를 번갈아 옮기고 있습니다(0.5초 미만의 작은 보정은 세지 않습니다). 서명(15분 허용)에는 문제가 없지만, 그 순간
              에뮬레이터는 막 만든 리소스를 "아직 준비 안 됨"으로 볼 수 있습니다 — 예: Kinesis 스트림 ACTIVE → CREATING,
              DynamoDB 테이블 ACTIVE 직후 PutItem 의 ResourceNotFoundException. 그 실패는 다시 실행하면 대개 통과합니다.
              VM 이 맥 시계만 따르게 하면 멈춥니다 (VM·에뮬레이터·만든 리소스는 그대로. 다음 VM 재시작 때 원래대로 돌아감):
                colima ssh -- sudo systemctl stop systemd-timesyncd
              되돌리기:  colima ssh -- sudo systemctl start systemd-timesyncd
              확인: 3분쯤 뒤  bash scripts/clock-check.sh --stability  (아무것도 출력하지 않으면 안정)
EOF
  [ "$summary" -eq 1 ] && exit 0
  exit 4
}
if [ "${1:-}" = "--stability" ]; then
  shift
  stability "$@"
fi

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
              확인:  bash scripts/clock-check.sh  (아무것도 출력하지 않고 끝나면 정상)
              Docker Desktop 이라면 Docker Desktop 을 재시작하세요. Linux(VM 없음)에서는 호스트 시계(NTP)를 확인하세요.
EOF
exit 3
