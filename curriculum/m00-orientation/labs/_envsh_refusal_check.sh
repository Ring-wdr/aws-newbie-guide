# shellcheck shell=bash
# M00 verify.sh 가 bash·zsh 로 실행하는 도우미: env.sh 거부 뒤 셸이 AWS에서 끊기는지 확인한다(직접 실행할 일은 없다).
# 사용법: <bash|zsh> refusal-check.sh <ROOT> <시나리오: noport|badport|nofiles|sigfail> [주 포트]
# 가짜 "기존" 자격 증명을 넣은 셸에서 env.sh 가 거부한 뒤, 그 셸의 aws 가 이 컴퓨터 안에서 실패하는지 본다.
ROOT="$1"; SCEN="$2"; LIVE_PORT="${3:-}"
export AWS_PROFILE=todayorder-real-profile-fake
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=dummy-not-a-real-key AWS_SESSION_TOKEN=dummy
export AWS_ENDPOINT_URL_S3=https://s3.todayorder.invalid   # 서비스별 덮어쓰기도 지워져야 한다
orig_path="$PATH"
case "$SCEN" in
  noport) unset EMULATOR_PORT ;;
  badport) export EMULATOR_PORT=notaport ;;
  nofiles) export EMULATOR_PORT=1024 ;;   # ~/.aws/emulator/1024 는 만들지 않는다
  sigfail)
    export EMULATOR_PORT="$LIVE_PORT"
    fake="$(mktemp -d)"
    printf '#!/bin/sh\necho "An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation" >&2\nexit 254\n' >"$fake/aws"
    chmod +x "$fake/aws"
    PATH="$fake:$PATH" ;;
esac
. "$ROOT/scripts/env.sh" </dev/null && { echo "RESULT env.sh 가 통과해 버림"; exit 1; }
PATH="$orig_path"
[ -n "${fake:-}" ] && rm -rf "$fake"
bad=""
[ -z "${AWS_PROFILE:-}" ] || bad="$bad AWS_PROFILE"
[ -z "${AWS_ACCESS_KEY_ID:-}" ] || bad="$bad AWS_ACCESS_KEY_ID"
[ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || bad="$bad AWS_SECRET_ACCESS_KEY"
[ -z "${AWS_SESSION_TOKEN:-}" ] || bad="$bad AWS_SESSION_TOKEN"
[ -z "${AWS_ENDPOINT_URL_S3:-}" ] || bad="$bad AWS_ENDPOINT_URL_S3"
case "${AWS_CONFIG_FILE:-}" in "$HOME/.aws/emulator/.disconnected/"*) ;; *) bad="$bad AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-}" ;; esac
case "${AWS_SHARED_CREDENTIALS_FILE:-}" in "$HOME/.aws/emulator/.disconnected/"*) ;; *) bad="$bad AWS_SHARED_CREDENTIALS_FILE" ;; esac
[ "${AWS_ENDPOINT_URL:-}" = "https://127.0.0.1:9" ] || bad="$bad AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-}"
[ ! -e "$HOME/.aws/emulator/.disconnected" ] || bad="$bad .disconnected-생성됨"
# 혹시 밖으로 나가는 요청이 있으면 닫힌 프록시로 보내 즉시 실패하게 한다
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1
signed="$(aws sts get-caller-identity --cli-connect-timeout 2 --cli-read-timeout 2 2>&1)"; src=$?
unsigned="$(aws s3 ls --no-sign-request --cli-connect-timeout 2 --cli-read-timeout 2 2>&1)"; urc=$?
case "$signed" in *"Unable to locate credentials"*|*NoCredentials*) ;; *) bad="$bad signed[$src]:$(printf '%s' "$signed" | tr '\n' ' ' | cut -c1-120)" ;; esac
case "$unsigned" in *"https://127.0.0.1:9/"*) ;; *) bad="$bad unsigned[$urc]:$(printf '%s' "$unsigned" | tr '\n' ' ' | cut -c1-120)" ;; esac
if [ -n "$bad" ]; then echo "RESULT FAIL:$bad"; exit 1; fi
echo "RESULT OK (signed: 자격 증명 없음으로 로컬 실패, unsigned: 127.0.0.1:9 연결 실패)"
