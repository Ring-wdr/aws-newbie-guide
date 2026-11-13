# shellcheck shell=bash
# M00 verify.sh 가 bash·zsh 로 실행하는 도우미: env.sh 가 거부·중단된 뒤(또는 연결된 뒤) SDK 요청이 실제 AWS에
# 전달되지 않는지 확인한다. verify.sh 는 가능하면 sandbox-exec(루프백만 허용) 안에서 이 파일을 실행한다.
# 사용법: <bash|zsh> _envsh_refusal_check.sh <ROOT> <시나리오: noport|badport|nofiles|sigfail|interrupt|connected> [주 포트]
#
# 실제 ~/.aws 를 읽지 않도록 **임시 HOME** 에서 돈다(connected 는 지정한 포트의 에뮬레이터 폴더 하나만 링크한다).
# 그 HOME 에는 학습자 컴퓨터에 있을 법한 것을 흉내 낸다: 가짜 AWS_PROFILE·키·서비스별 엔드포인트 변수,
# 옛 방식 자격 증명 ~/.boto 와 AWS_CREDENTIAL_FILE.
#
# 안전망: 모든 HTTP(S) 요청을 루프백의 "TLS 종단 프록시"(_envsh_tls_trap.py)로 보낸다(NO_PROXY 비움 — 127.0.0.1 을
# 넣으면 botocore 가 클라이언트 전체를 프록시 없이 직접 연결한다). 프록시는 아무 데도 전달하지 않고, 받은 CONNECT 와
# "TLS 가 성립해 HTTP 요청까지 받았는지"를 기록한다. 단언하는 성질: **HTTP 요청이 하나도 전달되지 않는다.**
ROOT="$1"; SCEN="$2"; LIVE_PORT="${3:-}"
SANDBOX="$(mktemp -d)"
EMULATOR_REAL_DIR="$HOME/.aws/emulator"   # connected 시나리오에서 포트 폴더 하나만 링크한다(다른 것은 읽지 않음)
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
PY="$ROOT/.venv/bin/python"
fail_early() { rm -rf "$SANDBOX"; echo "RESULT FAIL: $1"; exit 1; }
[ -x "$PY" ] || fail_early "boto3 검사 불가: $PY 없음 (uv sync 를 먼저 실행)"
command -v openssl >/dev/null 2>&1 || fail_early "openssl 없음 (TLS 종단 프록시 인증서를 만들 수 없음)"

printf '[Credentials]\naws_access_key_id = AKIABOTOFAKEEXAMPLE1\naws_secret_access_key = dummy-not-a-real-key\n' >"$HOME/.boto"
printf 'AWSAccessKeyId=AKIAEC2FILEFAKEEXAM1\nAWSSecretKey=dummy-not-a-real-key\n' >"$SANDBOX/ec2cred"
export AWS_PROFILE=todayorder-real-profile-fake
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=dummy-not-a-real-key AWS_SESSION_TOKEN=dummy
export AWS_ENDPOINT_URL_S3=https://s3.todayorder.invalid   # 서비스별 덮어쓰기도 지워져야 한다
export AWS_CREDENTIAL_FILE="$SANDBOX/ec2cred"
unset BOTO_CONFIG HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy
export AWS_MAX_ATTEMPTS=1
orig_path="$PATH"
fake="$SANDBOX/fakebin"
mkdir -p "$fake"
KHOST=abcdefghijklmnopqrst.xyz.control-kinesis.us-east-1.amazonaws.com   # Kinesis --stream-id 가 만드는 호스트
MRAP=arn:aws:s3::123456789012:accesspoint/mfzwi23gnjvgw.mrap

fake_emulator_files() {  # 임시 HOME 안의 가짜 에뮬레이터 파일(포트 1025): "파일 없음" 단계를 넘어가게 한다
  mkdir -p "$HOME/.aws/emulator/1025"
  printf '[default]\naws_access_key_id = AKIAEMUFAKEEXAMPLE01\naws_secret_access_key = dummy\n' >"$HOME/.aws/emulator/1025/emulator_credentials"
  : >"$HOME/.aws/emulator/1025/ca.pem"
  : >"$HOME/.aws/emulator/1025/config"
}

start_trap_proxy() {  # TLS 종단 프록시를 띄우고 이 셸의 프록시 변수를 그쪽으로 (NO_PROXY 비움)
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$KHOST" \
    -keyout "$SANDBOX/k.pem" -out "$SANDBOX/c.pem" >/dev/null 2>&1 || fail_early "인증서 생성 실패"
  "$PY" "$ROOT/curriculum/m00-orientation/labs/_envsh_tls_trap.py" "$SANDBOX/trap.log" "$SANDBOX/trap.port" \
    "$SANDBOX/c.pem" "$SANDBOX/k.pem" &
  TRAP_PID=$!
  local n=0
  while [ ! -s "$SANDBOX/trap.port" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  [ -s "$SANDBOX/trap.port" ] || fail_early "프록시가 뜨지 않음"
  export HTTPS_PROXY="http://127.0.0.1:$(cat "$SANDBOX/trap.port")" HTTP_PROXY="http://127.0.0.1:$(cat "$SANDBOX/trap.port")" NO_PROXY=""
}

finish() {  # $1 = 성공 문구
  [ -n "${TRAP_PID:-}" ] && kill "$TRAP_PID" 2>/dev/null
  # 전역 단언: 어떤 HTTP 요청도 프록시까지 전달되지 않았다
  if [ -s "$SANDBOX/trap.log" ] && grep -q 'HTTP 요청 받음' "$SANDBOX/trap.log"; then
    bad="$bad [HTTP 요청이 전달됨: $(grep 'HTTP 요청 받음' "$SANDBOX/trap.log" | head -1)]"
  fi
  # MRAP 호스트로는 연결 시도조차 없어야 한다
  if [ -s "$SANDBOX/trap.log" ] && grep -q 'mrap\.accesspoint' "$SANDBOX/trap.log"; then bad="$bad [MRAP 호스트로 연결 시도]"; fi
  rm -rf "$SANDBOX"
  if [ -n "$bad" ]; then echo "RESULT FAIL:$bad"; exit 1; fi
  echo "RESULT OK ($1)"
  exit 0
}

expect() {  # expect <이름> <기대 문구(egrep)> -- aws 인자...
  local name="$1" want="$2" out
  shift 3
  out="$(aws "$@" --cli-connect-timeout 2 --cli-read-timeout 2 2>&1)" && bad="$bad [$name 성공해 버림]"
  grep -Eq "$want" <<<"$out" || bad="$bad [$name: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)]"
}

check_disconnected() {
  bad=""
  [ -z "${AWS_PROFILE:-}" ] || bad="$bad AWS_PROFILE"
  [ -z "${AWS_ACCESS_KEY_ID:-}" ] || bad="$bad AWS_ACCESS_KEY_ID"
  [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || bad="$bad AWS_SECRET_ACCESS_KEY"
  [ -z "${AWS_SESSION_TOKEN:-}" ] || bad="$bad AWS_SESSION_TOKEN"
  [ -z "${AWS_ENDPOINT_URL_S3:-}" ] || bad="$bad AWS_ENDPOINT_URL_S3"
  [ -z "${AWS_CREDENTIAL_FILE:-}" ] || bad="$bad AWS_CREDENTIAL_FILE"
  [ -z "${DR_AWS_ENDPOINT_URL:-}" ] || bad="$bad DR_AWS_ENDPOINT_URL"
  local var
  for var in AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE BOTO_CONFIG AWS_CA_BUNDLE; do
    case "$(eval "printf '%s' \"\${$var:-}\"")" in /dev/null/*) ;; *) bad="$bad $var" ;; esac
  done
  [ "${AWS_ENDPOINT_URL:-}" = "https://127.0.0.1:9" ] || bad="$bad AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-}"
  [ "${AWS_DISABLE_HOST_PREFIX_INJECTION:-}" = true ] || bad="$bad AWS_DISABLE_HOST_PREFIX_INJECTION"
  [ "${AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS:-}" = true ] || bad="$bad AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS"
  # aws configure 는 끊긴 경로(/dev/null/...)에 키를 쓰지 못해야 한다 (프록시와 무관하므로 먼저)
  if aws configure set aws_access_key_id AKIACONFIGUREEXAMPL1 >/dev/null 2>&1; then bad="$bad [aws configure 가 썼다]"; fi
  # 주 사이트가 끊긴 셸에서는 dr-env.sh 도 거부해야 한다
  if DR_EMULATOR_PORT=1026 . "$ROOT/scripts/dr-env.sh" </dev/null 2>/dev/null; then bad="$bad [dr-env.sh 통과]"; fi
  start_trap_proxy
  expect sts 'Unable to locate credentials|NoCredentials' -- sts get-caller-identity
  expect s3control 'Unable to locate credentials|NoCredentials' -- s3control list-access-points --account-id 000000000000
  expect s3-unsigned 'proxy|SSL|Could not connect' -- s3 ls --no-sign-request
  expect mrap-unsigned 'Multi-Region Access Point ARNs are disabled' -- s3api list-objects-v2 --bucket "$MRAP" --no-sign-request
  expect kinesis-unsigned 'SSL|proxy|Could not connect' -- kinesis describe-stream-summary --stream-name s --stream-id abcdefghijklmnopqrst-xyz-abc --no-sign-request
  # boto3: 자격 증명 없음(~/.boto·AWS_CREDENTIAL_FILE 이 있어도), MRAP·Kinesis 서명 없는 요청도 전달 안 됨
  local py
  py="$("$PY" - "$MRAP" <<'PYEOF' 2>&1 | tail -1
import sys, boto3
from botocore import UNSIGNED
from botocore.config import Config
s = boto3.session.Session()
cred = s.get_credentials()
cfg = Config(signature_version=UNSIGNED, connect_timeout=2, read_timeout=2, retries={"max_attempts": 1})
res = [f"cred={getattr(cred, 'method', 'none')}"]
for name, call in [
    ("mrap", lambda: s.client("s3", config=cfg).list_objects_v2(Bucket=sys.argv[1])),
    ("kinesis", lambda: s.client("kinesis", config=cfg).describe_stream_summary(StreamName="s", StreamId="abcdefghijklmnopqrst-xyz-abc")),
]:
    try:
        call(); res.append(f"{name}=성공")
    except Exception as e:
        res.append(f"{name}={type(e).__name__}")
print(" ".join(res))
PYEOF
)"
  case "$py" in
    "cred=none mrap=UnsupportedS3AccesspointConfigurationError kinesis="*) case "$py" in *성공*) bad="$bad [boto3: $py]" ;; esac ;;
    *) bad="$bad [boto3: $py]" ;;
  esac
  finish "거부 뒤: 서명 요청은 자격 증명 없음, ~/.boto·AWS_CREDENTIAL_FILE 무시, MRAP 로컬 거부, Kinesis stream-id 는 TLS 에서 끊겨 HTTP 요청 0건, configure 쓰기 실패, dr-env 거부"
}

case "$SCEN" in
  noport) unset EMULATOR_PORT ;;
  badport) export EMULATOR_PORT=notaport ;;
  nofiles) export EMULATOR_PORT=1025 ;;   # 임시 HOME 에는 에뮬레이터 파일이 없다
  sigfail)
    export EMULATOR_PORT=1025; fake_emulator_files
    printf '#!/bin/sh\necho "An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation" >&2\nexit 254\n' >"$fake/aws"
    chmod +x "$fake/aws"; PATH="$fake:$PATH" ;;
  interrupt)
    # env.sh 가 계정 확인(aws sts)을 기다리는 도중 Ctrl-C 가 온 상황: 가짜 aws 가 멈춰 있는 동안 셸에 SIGINT.
    export EMULATOR_PORT=1025; fake_emulator_files
    printf '#!/bin/sh\necho $$ >"%s/aws.pid"\nexec sleep 30\n' "$SANDBOX" >"$fake/aws"
    chmod +x "$fake/aws"; PATH="$fake:$PATH"
    trap 'PATH="$orig_path"; check_disconnected' INT
    ( n=0; while [ ! -s "$SANDBOX/aws.pid" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
      kill -INT "$(cat "$SANDBOX/aws.pid")" 2>/dev/null; kill -INT $$ ) &
    ;;
  connected)
    # 연결된 셸: 지정한 포트의 에뮬레이터 폴더 하나만 임시 HOME 에 링크해 env.sh 가 정상 연결되게 한다.
    [ -n "$LIVE_PORT" ] || fail_early "connected 시나리오에는 포트가 필요"
    mkdir -p "$HOME/.aws/emulator"
    ln -s "$EMULATOR_REAL_DIR/$LIVE_PORT" "$HOME/.aws/emulator/$LIVE_PORT" 2>/dev/null || fail_early "에뮬레이터 폴더 링크 실패"
    export EMULATOR_PORT="$LIVE_PORT"
    . "$ROOT/scripts/env.sh" </dev/null 2>/dev/null || fail_early "env.sh 가 포트 $LIVE_PORT 에 연결하지 못함"
    bad=""
    [ "${AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS:-}" = true ] || bad="$bad AWS_S3_DISABLE_MULTIREGION_ACCESS_POINTS"
    start_trap_proxy
    # 서명 요청(에뮬레이터의 가짜 키)이 SDK 가 만든 AWS 호스트로 가도 전달되지 않아야 한다
    expect mrap-signed 'Multi-Region Access Point ARNs are disabled' -- s3api list-objects-v2 --bucket "$MRAP"
    expect kinesis-signed 'SSL|proxy|Could not connect' -- kinesis describe-stream-summary --stream-name s --stream-id abcdefghijklmnopqrst-xyz-abc
    grep -q "CONNECT $KHOST:443.*HTTP 요청 없음" "$SANDBOX/trap.log" 2>/dev/null \
      || bad="$bad [Kinesis 기록이 예상과 다름: $(tr '\n' ' ' <"$SANDBOX/trap.log" 2>/dev/null | cut -c1-120)]"
    finish "연결 상태: MRAP 로컬 거부, Kinesis stream-id 서명 요청은 에뮬레이터 인증서만 믿어 TLS 에서 끊김(HTTP 요청 0건)"
    ;;
esac
. "$ROOT/scripts/env.sh" </dev/null && fail_early "env.sh 가 통과해 버림"
[ "$SCEN" = interrupt ] && fail_early "인터럽트가 오지 않음"
PATH="$orig_path"
check_disconnected
