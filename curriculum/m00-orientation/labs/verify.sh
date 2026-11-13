#!/usr/bin/env bash
# M00 모듈 검증: $EMULATOR_PORT 의 에뮬레이터를 재시작(깨끗한 상태)한 뒤
# 모든 lab 과 sdk 예제를 실행하고, lab 은 역순으로 한 번 더 실행해 멱등성·순서 무관성을 확인한다.
#
#   export EMULATOR_PORT=9297     # 학습자는 생략 가능(대화형 터미널이면 9297)
#   curriculum/m00-orientation/labs/verify.sh
#   DR_EMULATOR_PORT=9298 curriculum/m00-orientation/labs/verify.sh   # 두 번째 에뮬레이터(미리 up)로 두 사이트 시험까지
#     (지정했는데 그 포트에 에뮬레이터가 없으면 아무것도 리셋하지 않고 원인·해결 방법을 출력하며 멈춘다)
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
MOD_DIR="$ROOT/curriculum/m00-orientation"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# 0) DR_EMULATOR_PORT 를 지정했다면 두 사이트 시험을 요청한 것이다. M12 verify.sh 처럼 두 번째 사이트를
#    빠뜨리고 넘어가지 않고, 아무것도 리셋하기 전에 원인과 해결 방법을 알리고 멈춘다.
#    (M12 와 달리 이 스크립트는 두 번째 에뮬레이터를 직접 띄우거나 지우지 않는다 — 미리 띄워 둔 것을 쓴다)
if [ -n "${DR_EMULATOR_PORT:-}" ]; then
  # shellcheck source=scripts/_common.sh
  . "$ROOT/scripts/_common.sh"
  validate_port "$DR_EMULATOR_PORT"
  if [ "$DR_EMULATOR_PORT" = "${EMULATOR_PORT:-9297}" ]; then
    die "DR_EMULATOR_PORT 가 EMULATOR_PORT 와 같습니다($DR_EMULATOR_PORT). 서로 다른 에뮬레이터여야 합니다."
  fi
  if [ "$(container_state "$DR_EMULATOR_PORT")" != "running" ] || ! health_ok "$DR_EMULATOR_PORT"; then
    die "DR_EMULATOR_PORT=$DR_EMULATOR_PORT 에 에뮬레이터가 떠 있지 않아 두 사이트 시험을 할 수 없습니다. 먼저 'scripts/emulator-up.sh $DR_EMULATOR_PORT' 로 띄우거나, 두 사이트 시험 없이 돌리려면 'unset DR_EMULATOR_PORT' 후 다시 실행하세요."
  fi
fi

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

# env.sh 의 시계 어긋남 진단: 서명 거부를 흉내 내는 가짜 aws 와 "20분 뒤" 시각으로 env.sh 를 source 한다.
# (실제 에뮬레이터·VM 시계는 건드리지 않는다)
envsh_clock_diag() {  # $1=가짜 현재 시각 $2=가짜 aws 의 stderr 문구 $3=종료 코드 $4=기대 문구 $5=있으면 안 되는 문구
  local fake out
  fake="$(mktemp -d)"
  printf '#!/bin/sh\n[ -n "%s" ] && echo "%s" >&2\nexit %s\n' "$2" "$2" "$3" >"$fake/aws"
  chmod +x "$fake/aws"
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_FAKE_NOW="$1" bash -c "source '$ROOT/scripts/env.sh'" 2>&1)" && { rm -rf "$fake"; echo "env.sh 가 통과해 버림"; return 1; }
  rm -rf "$fake"
  echo "$out"
  grep -q "$4" <<<"$out" || return 1
  [ -z "${5:-}" ] || ! grep -q "$5" <<<"$out"
}
SIGERR="An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation"
now_plus() { echo "$(($(date -u +%s) + $1))"; }
envsh_sig_skew20() { envsh_clock_diag "$(now_plus 1200)" "$SIGERR" 254 '\[clock-check\] 시계 어긋남'; }
envsh_sig_skew2() { envsh_clock_diag "$(now_plus 120)" "$SIGERR" 254 '서명을 거부했습니다' '시계 어긋남 때문에'; }
envsh_nosig_skew20() { envsh_clock_diag "$(now_plus 1200)" "" 255 '확인하지 못했습니다' '시계 어긋남'; }

# dr-env.sh: 비대화형에서 DR_EMULATOR_PORT 없으면 거부하고, 실패하면 이전 DR_AWS_* 를 남기지 않는다.
drenv_refuses_without_port() {
  local out
  out="$(env -u DR_EMULATOR_PORT DR_AWS_ENDPOINT_URL=https://127.0.0.1:1 bash -c \
    "source '$ROOT/scripts/env.sh' 2>/dev/null; source '$ROOT/scripts/dr-env.sh'; echo rc=\$?; echo \"left=\${DR_AWS_ENDPOINT_URL:-}\"" </dev/null 2>&1)"
  echo "$out"
  grep -q 'DR_EMULATOR_PORT 가 설정되지 않았습니다' <<<"$out" && grep -q '^rc=1$' <<<"$out" && grep -q '^left=$' <<<"$out"
}
drenv_bad_port_clears() {
  local out
  out="$(DR_EMULATOR_PORT=notaport DR_AWS_ENDPOINT_URL=https://127.0.0.1:1 bash -c \
    "source '$ROOT/scripts/env.sh' 2>/dev/null; source '$ROOT/scripts/dr-env.sh'; echo rc=\$?; echo \"left=\${DR_AWS_ENDPOINT_URL:-}\"" </dev/null 2>&1)"
  echo "$out"
  grep -q '^rc=1$' <<<"$out" && grep -q '^left=$' <<<"$out"
}

# DR_EMULATOR_PORT 를 지정했는데 그 포트에 에뮬레이터 컨테이너가 없으면, 아무것도 리셋하기 전에 원인·해결 방법을 내고 멈춘다.
# (포트 1024 에는 이 저장소의 에뮬레이터 컨테이너가 있을 수 없다 — emulator-up.sh 는 포트를 이름에 쓰므로 aws-emulator-1024 가 없다)
verify_refuses_missing_dr() {
  local out
  if docker container inspect aws-emulator-1024 >/dev/null 2>&1; then echo "aws-emulator-1024 가 있어 시험할 수 없음"; return 1; fi
  out="$(DR_EMULATOR_PORT=1024 bash "$MOD_DIR/labs/verify.sh" </dev/null 2>&1)" && { echo "통과해 버림"; return 1; }
  echo "$out"
  grep -q "DR_EMULATOR_PORT=1024 에 에뮬레이터가 떠 있지 않아" <<<"$out" && grep -q "scripts/emulator-up.sh 1024" <<<"$out" \
    && ! grep -q "종료했습니다\|시작합니다" <<<"$out"
}

# emulator-up.sh 의 EMULATOR_DNS 검증: 잘못된 값은 docker 를 건드리기 전에 거부한다 (포트 1024 — 컨테이너를 띄우지 않음)
# docker 대신 호출만 기록하고 실패하는 가짜를 앞에 둔다 — 검증이 깨져도 컨테이너가 뜨지 않는다.
emulator_dns_validation() {
  local v out fake rc=0
  fake="$(mktemp -d)"
  printf '#!/bin/sh\necho "$*" >>"%s/calls"\nexit 1\n' "$fake" >"$fake/docker"
  chmod +x "$fake/docker"
  for v in 999.999.999.999 127.0.0.01 127.0.0.1. 1.2.3 256.0.0.1 'host ' localhost; do
    if out="$(PATH="$fake:$PATH" EMULATOR_DNS="$v" "$ROOT/scripts/emulator-up.sh" 1024 2>&1)"; then
      echo "허용해 버림: '$v'"; rc=1; break
    fi
    grep -q "EMULATOR_DNS 는 IPv4 주소이거나 host 여야 합니다" <<<"$out" || { echo "다른 이유로 실패: '$v' → $out"; rc=1; break; }
  done
  if [ -s "$fake/calls" ]; then echo "검증 전에 docker 를 불렀다: $(head -1 "$fake/calls")"; rc=1; fi
  rm -rf "$fake"
  [ "$rc" -eq 0 ] && echo "잘못된 값 7개 모두 docker 호출 전에 거부"
  return "$rc"
}

# env.sh 가 거부·중단된 뒤(또는 연결된 뒤) SDK 요청이 실제 AWS에 전달되지 않는지 본다. 도우미(_envsh_refusal_check.sh)는
# **임시 HOME**(가짜 ~/.boto·AWS_CREDENTIAL_FILE·프로필·키 포함)에서 bash(있으면 /bin/bash 3.2 도)·zsh 로 돌고,
# 모든 HTTP(S) 요청을 루프백의 TLS 종단 프록시로 보내 "HTTP 요청이 하나도 전달되지 않는다"를 단언한다(NO_PROXY 비움).
# 시나리오: 거부 4가지(포트 없음·포트 오류·파일 없음·서명 거부), 계정 확인 도중 SIGINT, 연결 상태(이 포트의 에뮬레이터).
# 확인 대상에는 SDK 가 엔드포인트를 무시하고 AWS 호스트명을 직접 만드는 S3 MRAP ARN·Kinesis --stream-id 가 들어 있다.
# macOS 에서는 sandbox-exec 로 루프백 밖 연결을 막은 채 실행한다 — 시험이 실패해도 실제로 새어 나갈 수 없다.
envsh_refusal_disconnects() {
  local sh sc out rc=0 shells="bash" wrap="" sb="" sigint_default=""
  command -v perl >/dev/null 2>&1 && sigint_default="perl -e \$SIG{INT}=q(DEFAULT);exec(@ARGV)or(die)"
  [ -x /bin/bash ] && [ "$(command -v bash)" != /bin/bash ] && shells="$shells /bin/bash"
  command -v zsh >/dev/null 2>&1 && shells="$shells zsh"
  if command -v sandbox-exec >/dev/null 2>&1; then
    sb="$(mktemp)"
    printf '(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n' >"$sb"
    wrap="sandbox-exec -f $sb"
  else
    echo "참고: sandbox-exec 없음 — 루프백 프록시 안전망만으로 실행"
  fi
  for sh in $shells; do
    for sc in noport badport nofiles sigfail interrupt connected; do
      # verify.sh 를 백그라운드(&·nohup — 에이전트가 흔히 쓰는 방식)로 띄우면 SIGINT 가 "무시" 상태로 물려받아지고,
      # bash 는 시작할 때 무시된 신호에 trap 을 걸 수 없어 interrupt 시나리오가 늘 실패한다(zsh 는 걸 수 있다).
      # perl 이 있으면 이 셸만 SIGINT 를 기본 동작으로 되돌려 실행한다.
      out="$($wrap $sigint_default "$sh" "$MOD_DIR/labs/_envsh_refusal_check.sh" "$ROOT" "$sc" "$EMULATOR_PORT" 2>/dev/null | grep '^RESULT')"
      echo "$sh $sc: $out"
      [[ "$out" == "RESULT OK"* ]] || rc=1
    done
  done
  [ -n "$sb" ] && rm -f "$sb"
  return "$rc"
}

# macOS 기본 bash 3.2 는 if 조건 안의 함수에서 source 된 파일이 실패하면 set -e 무시 상태를 잃는다.
# env.sh·dr-env.sh 가 '_main || rc=$?' 로 부르지 않으면 호출한 셸 전체가 끝나 버린다(#25 이전 동작).
# 거부하는 값(포트 오류)으로 source 시켜, 거부는 하되 호출한 셸은 계속 도는지 본다.
sourced_refusal_is_contained() {
  local sh out rc=0 shells="bash"
  [ -x /bin/bash ] && [ "$(command -v bash)" != /bin/bash ] && shells="$shells /bin/bash"
  for sh in $shells; do
    out="$(EMULATOR_PORT=notaport "$sh" -c 'set -euo pipefail
      f() { source "$1/scripts/env.sh" || return 1; echo "통과해 버림"; }
      if f "$1"; then :; else echo "env.sh 거부됨"; fi
      echo "env.sh 뒤 계속"' _ "$ROOT" </dev/null 2>/dev/null)"
    echo "$sh: $(tr '\n' ' ' <<<"$out")"
    grep -q "env.sh 거부됨" <<<"$out" && grep -q "env.sh 뒤 계속" <<<"$out" || rc=1
    out="$(DR_EMULATOR_PORT=notaport "$sh" -c 'set -euo pipefail
      source "$1/scripts/env.sh"
      f() { source "$1/scripts/dr-env.sh" || return 1; echo "통과해 버림"; }
      if f "$1"; then :; else echo "dr-env.sh 거부됨"; fi
      echo "dr-env.sh 뒤 계속"' _ "$ROOT" </dev/null 2>/dev/null)"
    echo "$sh: $(tr '\n' ' ' <<<"$out")"
    grep -q "dr-env.sh 거부됨" <<<"$out" && grep -q "dr-env.sh 뒤 계속" <<<"$out" || rc=1
  done
  return "$rc"
}

# clock-check.sh: 에뮬레이터가 없으면 조용히 0 이 아니라 "측정하지 못했습니다" + 종료 코드 2
clock_check_cannot_measure() {
  local out rc
  out="$(bash "$ROOT/scripts/clock-check.sh" 1024 2>&1)"; rc=$?
  echo "rc=$rc $out"
  [ "$rc" -eq 2 ] && grep -q "측정하지 못했습니다" <<<"$out"
}

# clock-check.sh --stability: VM 저널 대신 가짜 기록(EMULATOR_CLOCK_FAKE_JOURNAL)을 읽힌다 (실제 VM 시계는 건드리지 않음).
# 기록 형식은 'journalctl -t lima-guestagent -o short-unix' 그대로이고, 보정량은 실제로 관찰한 값의 형태를 따른다.
fake_synctime() {  # $1=파일 $2=첫 시각(epoch) $3=개수 $4=간격(초) $5=보정량(Go 표기, 예: 2.05s·100.06ms·-15m5.9s)
  local i
  for ((i = 0; i < $3; i++)); do
    printf '%s.443075 colima lima-guestagent[436]: time="x" level=info msg="SyncTime: system time synchronized with host (drift was %s)"\n' \
      "$(($2 + i * $4))" "$5" >>"$1"
  done
}
clock_stability_fires() {
  local f out rc now
  f="$(mktemp)"; now="$(date -u +%s)"
  fake_synctime "$f" "$((now - 125))" 12 10 2.054861792s   # 2초씩, 10초마다 (관찰된 형태)
  out="$(EMULATOR_CLOCK_FAKE_JOURNAL="$f" bash "$ROOT/scripts/clock-check.sh" --stability 2>&1)"; rc=$?
  rm -f "$f"
  echo "rc=$rc $out"
  [ "$rc" -eq 4 ] && grep -q "VM 시계 불안정: 최근 180초 동안 Colima VM 시계가 12번" <<<"$out" \
    && grep -q "systemctl stop systemd-timesyncd" <<<"$out" && grep -q "systemctl start systemd-timesyncd" <<<"$out"
}
clock_stability_quiet() {
  local f out rc now
  f="$(mktemp)"; now="$(date -u +%s)"
  fake_synctime "$f" "$((now - 1000))" 20 10 2.03s        # 창(180초) 밖의 불안정 — 지금은 멈춤
  fake_synctime "$f" "$((now - 170))" 15 10 100.6ms       # 문턱(0.5초) 아래의 작은 보정
  fake_synctime "$f" "$((now - 60))" 1 10 -15m5.947595153s # 잠자기 뒤 한 번 크게 따라잡기
  fake_synctime "$f" "$((now - 30))" 2 10 1.5s            # 0.5초 이상이지만 2번뿐
  out="$(EMULATOR_CLOCK_FAKE_JOURNAL="$f" bash "$ROOT/scripts/clock-check.sh" --stability 2>&1)"; rc=$?
  rm -f "$f"
  echo "rc=$rc $out"
  # 따라잡기는 정확히 1번이어야 한다 — 100.6ms 를 100.6초로 잘못 읽으면 "16번"이 된다
  [ "$rc" -eq 0 ] && ! grep -q "불안정" <<<"$out" && grep -q "크게(1분 이상) 맞춘 기록이 1번 있습니다" <<<"$out"
}
clock_stability_summary() {
  local f out rc now
  f="$(mktemp)"; now="$(date -u +%s)"
  fake_synctime "$f" "$((now - 250))" 20 10 -2.2s          # 맥 시계가 NTP 보다 앞선 경우(반대 방향)도 센다
  out="$(EMULATOR_CLOCK_FAKE_JOURNAL="$f" bash "$ROOT/scripts/clock-check.sh" --stability --summary --last 300 2>&1)"; rc=$?
  rm -f "$f"
  echo "unstable: rc=$rc $out"
  [ "$rc" -eq 0 ] && grep -q "이번 실행 동안(300초) Colima VM 시계가 20번" <<<"$out" || return 1
  out="$(EMULATOR_CLOCK_FAKE_JOURNAL=/nonexistent/journal bash "$ROOT/scripts/clock-check.sh" --stability --summary --last 300 2>&1)"; rc=$?
  echo "cannot measure + --summary: rc=$rc '$out'"
  [ "$rc" -eq 0 ] && [ -z "$out" ] || return 1
  out="$(EMULATOR_CLOCK_FAKE_JOURNAL=/nonexistent/journal bash "$ROOT/scripts/clock-check.sh" --stability 2>&1)"; rc=$?
  echo "cannot measure: rc=$rc"
  [ "$rc" -eq 2 ]
}

# colima ssh 가 멈춰도(잠자기 뒤 낡은 ssh 연결 등) clock-check·emulator-up·status 가 같이 멈추지 않는지:
# TERM 을 무시하고 자는 가짜 colima(자식도 TERM 무시)와 'colima' 컨텍스트를 답하는 가짜 docker 를 앞에 둔다.
# 제한 시간 2초(EMULATOR_CLOCK_SSH_TIMEOUT). 가짜는 8초만 자고, 확인 하나가 틀리면 바로 멈춘다 — 제한 시간 처리가
# 망가져도 이 시험은 약 10초 안에 FAIL 한다. 다른 사람(동시에 도는 다른 verify.sh)의 프로세스를 건드리지 않도록
# 남은 프로세스는 이번 가짜가 pid 파일에 적은 pid 로만 확인하고 정리한다(이름 패턴으로 찾거나 죽이지 않는다).
clock_stability_ssh_timeout() {
  local fake out rc t0 el q left=""
  fake="$(mktemp -d)"
  printf '#!/bin/sh\necho $$ >>"%s/pids"\ntrap "" TERM\nsleep 8 &\necho $! >>"%s/pids"\nwait $!\n' "$fake" "$fake" >"$fake/colima"
  printf '#!/bin/sh\necho colima\n' >"$fake/docker"
  chmod +x "$fake/colima" "$fake/docker"
  _sst_done() {  # $1=결과. 이번 가짜의 pid 만 확인·정리한다
    sleep 1
    if [ -f "$fake/pids" ]; then
      for q in $(cat "$fake/pids"); do
        if kill -0 "$q" 2>/dev/null; then left="$left $q"; kill -KILL "$q" 2>/dev/null; fi
      done
    fi
    rm -rf "$fake"
    if [ -n "$left" ]; then echo "남은 프로세스(이번 가짜의 pid):$left"; return 1; fi
    return "$1"
  }
  t0=$SECONDS
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_SSH_TIMEOUT=2 bash "$ROOT/scripts/clock-check.sh" --stability 2>&1)"; rc=$?; el=$((SECONDS - t0))
  echo "직접: rc=$rc ${el}초 $out"
  { [ "$rc" -eq 2 ] && [ "$el" -le 5 ] && grep -q "2초 안에 응답하지 않았습니다" <<<"$out"; } || { _sst_done 1; return 1; }
  t0=$SECONDS
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_SSH_TIMEOUT=2 bash "$ROOT/scripts/clock-check.sh" --stability --summary 2>&1)"; rc=$?; el=$((SECONDS - t0))
  echo "--summary: rc=$rc ${el}초 '$out'"
  { [ "$rc" -eq 0 ] && [ "$el" -le 5 ] && [ -z "$out" ]; } || { _sst_done 1; return 1; }
  # emulator-up·status 가 부르는 경고 함수 (docker 없이 시험하려고 함수만 부른다)
  t0=$SECONDS
  out="$(PATH="$fake:$PATH" EMULATOR_CLOCK_SSH_TIMEOUT=2 bash -c ". '$ROOT/scripts/_common.sh'; warn_if_clock_unstable; echo rc=\$?" 2>&1)"; el=$((SECONDS - t0))
  echo "warn_if_clock_unstable: ${el}초 '$out'"
  { [ "$out" = "rc=0" ] && [ "$el" -le 5 ]; } || { _sst_done 1; return 1; }
  _sst_done 0
}

# 두 번째 사이트(dr-env.sh + emulator_site("DR_")) 실시간 시험은 DR_EMULATOR_PORT 에 에뮬레이터가 떠 있을 때만.
# 하위 셸에서 실행해, dr-env.sh 가 실패해도(bash 3.2 의 set -e 처리 포함) verify.sh 전체가 아니라 이 항목만 FAIL 이 되게 한다.
guard_selftest() (
  if [ -n "${DR_EMULATOR_PORT:-}" ]; then
    # shellcheck source=scripts/dr-env.sh
    source "$ROOT/scripts/dr-env.sh" || exit 1
  fi
  uv run --quiet python -m emulator_guard.selftest --live
)

# 탐침·스크립트·가드·커리큘럼(M00~M14) 코드가 바깥 호스트(이미지 레지스트리·URL·구독 엔드포인트)를 가리키지 않는지 정적으로 검사
no_external_hosts() {
  uv run --quiet python tools/probe/no_external_hosts.py
}

cd "$ROOT"
run "외부 호스트 정적 검사 (tools·scripts·src·curriculum 전체에 예약 이름·루프백 이외 주소 없음)" no_external_hosts
run "안전 장치 자체 시험 (URL 파싱 우회 차단·두 번째 사이트 API·opt-out)" guard_selftest
[ -n "${DR_EMULATOR_PORT:-}" ] || echo "SKIP  두 번째 사이트 실시간 시험 (DR_EMULATOR_PORT 미설정 — 설정하고 그 포트에 에뮬레이터를 띄우면 시험)"
run "env.sh: 서명 거부 + 시계 20분 어긋남 → 시계 어긋남 안내" envsh_sig_skew20
run "env.sh: 서명 거부 + 시계 2분 차이(허용 범위 안) → 서명 거부 안내, 시계 탓 안 함" envsh_sig_skew2
run "env.sh: 응답 없음(서명 오류 아님) + 시계 20분 차이 → 시계 탓 안 함" envsh_nosig_skew20
run "dr-env.sh: 비대화형 + DR_EMULATOR_PORT 없음 → 거부, 이전 DR_AWS_* 지움" drenv_refuses_without_port
run "dr-env.sh: 잘못된 포트 → 거부, 이전 DR_AWS_* 지움" drenv_bad_port_clears
[ -n "${DR_EMULATOR_PORT:-}" ] || run "verify.sh: DR_EMULATOR_PORT 에 에뮬레이터 없음 → 리셋 전에 원인·해결 방법 안내" verify_refuses_missing_dr
run "emulator-up.sh: 잘못된 EMULATOR_DNS(999.999.999.999·127.0.0.01 등) → docker 호출 전 거부" emulator_dns_validation
run "env.sh: 거부·Ctrl-C·연결 상태에서 HTTP 요청이 실제 AWS에 전달되지 않음 — ~/.boto 무시, MRAP 로컬 거부, Kinesis stream-id 는 TLS 에서 끊김, dr-env 거부 (임시 HOME, bash·zsh)" envsh_refusal_disconnects
run "env.sh·dr-env.sh: if 조건 안에서 source 해 거부돼도 호출한 셸이 끝나지 않음 (macOS bash 3.2)" sourced_refusal_is_contained
run "clock-check.sh: 에뮬레이터 없음 → '측정하지 못했습니다' + 종료 코드 2" clock_check_cannot_measure
run "clock-check.sh --stability: 10초마다 2초씩 보정 12번 → 불안정(종료 코드 4) + 해결·되돌리기 명령" clock_stability_fires
run "clock-check.sh --stability: 창 밖·0.5초 미만·잠자기 따라잡기·2번뿐 → 안정(0), 따라잡기는 참고만" clock_stability_quiet
run "clock-check.sh --stability --summary: 불안정이면 '이번 실행 동안' 안내 + 0, 확인 못 하면 조용히 0 (--summary 없으면 2)" clock_stability_summary
run "clock-check.sh --stability: colima ssh 가 멈추면(TERM 무시) 제한 시간 뒤 '확인하지 못함'(2)·--summary·경고 함수는 조용히, 남는 프로세스 없음" clock_stability_ssh_timeout
for py in "$MOD_DIR"/sdk/*.py; do
  run "안전 장치: env.sh 없이 sdk/$(basename "$py") 실행 → 네트워크 호출 전 거부" guard_refuses "$py"
done
# 1회차는 번호 순서, 2회차는 역순 — "두 번 연속 실행해도, 다른 lab 뒤에 실행해도" 통과하는지 확인한다.
labs=("$MOD_DIR"/labs/lab*.sh)
for lab in "${labs[@]}"; do
  run "$(basename "$lab") (실행 1)" bash "$lab"
done
for ((i = ${#labs[@]} - 1; i >= 0; i--)); do
  run "$(basename "${labs[$i]}") (실행 2, 역순)" bash "${labs[$i]}"
done
for py in "$MOD_DIR"/sdk/*.py; do
  run "sdk/$(basename "$py")" uv run --quiet python "$py"
done

echo "----"
echo "통과 $pass · 실패 $fail"
# 이번 실행 동안 VM 시계가 반복해서 옮겨졌다면 알린다 (안정·확인 불가면 아무것도 출력하지 않음, 언제나 0)
bash "$ROOT/scripts/clock-check.sh" --stability --summary --last "$SECONDS" || true
if [ "$fail" -ne 0 ]; then
  echo "MODULE m00 FAIL"
  exit 1
fi
echo "MODULE m00 OK"
