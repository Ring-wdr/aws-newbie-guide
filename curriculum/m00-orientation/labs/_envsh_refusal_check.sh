# shellcheck shell=bash
# M00 verify.sh 가 bash·zsh 로 실행하는 도우미: env.sh 가 거부되거나 중단된 뒤 셸이 AWS에서 끊겨 있는지 확인한다.
# 사용법: <bash|zsh> _envsh_refusal_check.sh <ROOT> <시나리오: noport|badport|nofiles|sigfail|interrupt>
#
# 실제 ~/.aws 를 절대 읽지 않도록 **임시 HOME** 에서 돈다. 그 HOME 에는 학습자 컴퓨터에 있을 법한 것을 흉내 낸다:
# 가짜 AWS_PROFILE·키·서비스별 엔드포인트 변수, 옛 방식 자격 증명 ~/.boto 와 AWS_CREDENTIAL_FILE.
# 확인하는 성질: 거부(또는 Ctrl-C) 뒤 그 셸의 aws 요청이 이 컴퓨터(127.0.0.1) 밖으로 나가지 않고 로컬에서 실패한다.
# 바깥으로 나가는 요청이 있으면 닫힌 프록시(127.0.0.1:9)로 보내 즉시 실패하게 하고, 그 흔적이 있으면 실패로 본다.
ROOT="$1"; SCEN="$2"
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
# uv·pip 캐시 등은 원래 위치를 쓰게 한다(임시 HOME 이라 다시 받지 않도록) — 우리는 .venv 의 python 을 직접 쓴다.
PY="$ROOT/.venv/bin/python"
printf '[Credentials]\naws_access_key_id = AKIABOTOFAKEEXAMPLE1\naws_secret_access_key = dummy-not-a-real-key\n' >"$HOME/.boto"
printf 'AWSAccessKeyId=AKIAEC2FILEFAKEEXAM1\nAWSSecretKey=dummy-not-a-real-key\n' >"$SANDBOX/ec2cred"
export AWS_PROFILE=todayorder-real-profile-fake
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=dummy-not-a-real-key AWS_SESSION_TOKEN=dummy
export AWS_ENDPOINT_URL_S3=https://s3.todayorder.invalid   # 서비스별 덮어쓰기도 지워져야 한다
export AWS_CREDENTIAL_FILE="$SANDBOX/ec2cred"
unset BOTO_CONFIG
orig_path="$PATH"
fake="$SANDBOX/fakebin"
mkdir -p "$fake"

# 가짜 에뮬레이터 파일(임시 HOME 안, 포트 1025): sigfail·interrupt 시나리오가 "파일 없음" 단계를 넘어가게 한다.
fake_emulator_files() {
  mkdir -p "$HOME/.aws/emulator/1025"
  printf '[default]\naws_access_key_id = AKIAEMUFAKEEXAMPLE01\naws_secret_access_key = dummy\n' >"$HOME/.aws/emulator/1025/emulator_credentials"
  : >"$HOME/.aws/emulator/1025/ca.pem"
  : >"$HOME/.aws/emulator/1025/config"
}

check_state() {
  local bad="" src
  [ -z "${AWS_PROFILE:-}" ] || bad="$bad AWS_PROFILE"
  [ -z "${AWS_ACCESS_KEY_ID:-}" ] || bad="$bad AWS_ACCESS_KEY_ID"
  [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || bad="$bad AWS_SECRET_ACCESS_KEY"
  [ -z "${AWS_SESSION_TOKEN:-}" ] || bad="$bad AWS_SESSION_TOKEN"
  [ -z "${AWS_ENDPOINT_URL_S3:-}" ] || bad="$bad AWS_ENDPOINT_URL_S3"
  [ -z "${AWS_CREDENTIAL_FILE:-}" ] || bad="$bad AWS_CREDENTIAL_FILE"
  case "${AWS_CONFIG_FILE:-}" in /dev/null/*) ;; *) bad="$bad AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-}" ;; esac
  case "${AWS_SHARED_CREDENTIALS_FILE:-}" in /dev/null/*) ;; *) bad="$bad AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-}" ;; esac
  case "${BOTO_CONFIG:-}" in /dev/null/*) ;; *) bad="$bad BOTO_CONFIG=${BOTO_CONFIG:-}" ;; esac
  [ "${AWS_ENDPOINT_URL:-}" = "https://127.0.0.1:9" ] || bad="$bad AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-}"
  [ "${AWS_DISABLE_HOST_PREFIX_INJECTION:-}" = true ] || bad="$bad AWS_DISABLE_HOST_PREFIX_INJECTION"
  export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1
  # 서명 요청·서명 없는 요청·호스트 접두사를 쓰는 서비스(s3control) 모두 로컬에서 실패해야 한다.
  try_local() {  # $1=이름, 나머지=aws 인자 (zsh 는 변수를 단어로 나누지 않으므로 인자를 그대로 넘긴다)
    local name="$1" out rc
    shift
    out="$(aws "$@" --cli-connect-timeout 2 --cli-read-timeout 2 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] || bad="$bad [$name 성공해 버림]"
    case "$out" in
      *"Unable to locate credentials"* | *NoCredentials* | *'"https://127.0.0.1:9/'*) ;;
      *) bad="$bad [$name: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)]" ;;
    esac
    case "$out" in *[Pp]roxy*) bad="$bad [$name: 루프백 밖으로 나가려 함]" ;; esac
  }
  try_local sts sts get-caller-identity
  try_local s3-unsigned s3 ls --no-sign-request
  try_local s3control s3control list-access-points --account-id 000000000000
  # boto3 도 자격 증명을 찾지 못해야 한다 (~/.boto·AWS_CREDENTIAL_FILE 이 있어도)
  if [ -x "$PY" ]; then
    src="$("$PY" -c 'import boto3; c=boto3.session.Session().get_credentials(); print(getattr(c,"method","none"))' 2>&1 | tail -1)"
    [ "$src" = none ] || bad="$bad [boto3 자격 증명: $src]"
  fi
  # aws configure 는 끊긴 경로(/dev/null/...)에 키를 쓰지 못해야 한다
  if aws configure set aws_access_key_id AKIACONFIGUREEXAMPL1 >/dev/null 2>&1; then bad="$bad [aws configure 가 썼다]"; fi
  # 주 사이트가 끊긴 셸에서는 dr-env.sh 도 거부해야 한다
  if DR_EMULATOR_PORT=1026 . "$ROOT/scripts/dr-env.sh" </dev/null 2>/dev/null; then bad="$bad [dr-env.sh 통과]"; fi
  rm -rf "$SANDBOX"
  if [ -n "$bad" ]; then echo "RESULT FAIL:$bad"; exit 1; fi
  echo "RESULT OK (거부 뒤 aws·boto3 요청이 로컬에서 실패, ~/.boto·AWS_CREDENTIAL_FILE 무시, configure 쓰기 실패, dr-env 거부)"
  exit 0
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
    trap 'PATH="$orig_path"; check_state' INT
    ( n=0; while [ ! -s "$SANDBOX/aws.pid" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
      kill -INT "$(cat "$SANDBOX/aws.pid")" 2>/dev/null; kill -INT $$ ) &
    ;;
esac
. "$ROOT/scripts/env.sh" </dev/null && { rm -rf "$SANDBOX"; echo "RESULT env.sh 가 통과해 버림"; exit 1; }
if [ "$SCEN" = interrupt ]; then rm -rf "$SANDBOX"; echo "RESULT FAIL: 인터럽트가 오지 않음"; exit 1; fi
PATH="$orig_path"
check_state
