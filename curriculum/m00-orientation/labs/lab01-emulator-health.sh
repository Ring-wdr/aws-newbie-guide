#!/usr/bin/env bash
# M00 lab01 — 에뮬레이터 기동·헬스 체크 (🟢)
# 에뮬레이터가 떠 있고, 이 셸의 AWS CLI가 실제 AWS가 아니라 에뮬레이터를 향하는지 확인한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

echo "== 1. 헬스 체크 (/__admin/health)"
health="$(curl -s --cacert "$AWS_CA_BUNDLE" "$AWS_ENDPOINT_URL/__admin/health")"
echo "$health"

echo "== 2. 에뮬레이터가 만든 파일 (~/.aws/emulator/$EMULATOR_PORT/)"
ls "$HOME/.aws/emulator/$EMULATOR_PORT"

echo "== 3. 누구로 요청하고 있나 (sts get-caller-identity)"
aws sts get-caller-identity
account="$(aws sts get-caller-identity --query Account --output text)"
arn="$(aws sts get-caller-identity --query Arn --output text)"

echo "== 4. CLI가 읽은 설정"
aws configure list

# ---- 단언
[ "$health" = "ok" ] || { echo "FAIL: 헬스 체크 응답이 ok가 아님: $health"; exit 1; }
[ "$account" = "000000000000" ] || { echo "FAIL: 계정이 000000000000이 아님: $account"; exit 1; }
[ "$arn" = "arn:aws:iam::000000000000:user/emulator" ] || { echo "FAIL: 예상치 못한 ARN: $arn"; exit 1; }
case "$AWS_ENDPOINT_URL" in https://127.0.0.1:*) ;; *) echo "FAIL: 엔드포인트가 127.0.0.1이 아님"; exit 1 ;; esac
echo "LAB01 OK"
