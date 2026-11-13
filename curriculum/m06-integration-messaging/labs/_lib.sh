# shellcheck shell=bash
# M06 lab 들이 함께 쓰는 작은 도우미. 각 lab 이 env.sh 를 source 한 다음 이 파일을 source 한다.
# (verify.sh 는 lab*.sh 만 실행하므로 이 파일은 직접 실행되지 않는다)

ACCOUNT=000000000000
REGION=us-east-1

# CLI waiter(`aws kinesis wait stream-exists`·`stream-not-exists`, 10초 간격) 대신 같은 조건을 1초 간격으로 확인하는
# 함수(wait_kinesis_stream_active, wait_kinesis_stream_gone). 이유는 scripts/lab-wait.sh 머리말.
source "$(git rev-parse --show-toplevel)/scripts/lab-wait.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# poll <상한 초> <설명> <명령...> — 명령이 성공할 때까지 1초 간격으로 다시 시도한다.
# 명령은 현재 셸에서 실행되므로(함수도 가능) 변수 변경이 유지된다.
# 상한을 넘기면 실패한다. "몇 초 뒤에 된다"를 가정하지 않기 위한 도구.
poll() {
  local limit="$1" desc="$2" start=$SECONDS
  shift 2
  until "$@"; do
    if ((SECONDS - start >= limit)); then
      echo "FAIL: $desc — ${limit}초 안에 조건이 충족되지 않음" >&2
      return 1
    fi
    sleep 1
  done
}

queue_arn() { echo "arn:aws:sqs:$REGION:$ACCOUNT:$1"; }

# fresh_queue <이름> [attributes JSON] — 같은 이름의 큐가 있으면 지우고 새로 만든 뒤 URL 을 출력한다.
# SQS 는 큐를 지운 뒤 60초 동안 같은 이름의 생성을 거부할 수 있다(QueueDeletedRecently) → 재시도.
fresh_queue() {
  local name="$1" attrs="${2:-}" url start=$SECONDS out
  local -a extra=()
  [ -n "$attrs" ] && extra=(--attributes "$attrs")
  if url="$(aws sqs get-queue-url --queue-name "$name" --query QueueUrl --output text 2>/dev/null)"; then
    aws sqs delete-queue --queue-url "$url"
  fi
  until out="$(aws sqs create-queue --queue-name "$name" ${extra[@]+"${extra[@]}"} --query QueueUrl --output text 2>&1)"; do
    grep -q QueueDeletedRecently <<<"$out" || { echo "$out" >&2; return 1; }
    ((SECONDS - start < 90)) || { echo "FAIL: $name 재생성 90초 초과" >&2; return 1; }
    sleep 2
  done
  echo "$out"
}

# 큐에 보이는 메시지 수 (ApproximateNumberOfMessages)
visible_count() {
  aws sqs get-queue-attributes --queue-url "$1" --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text
}

# ensure_role <역할 이름> <서비스 주체> — 신뢰 정책만 가진 역할을 (없으면) 만든다.
ensure_role() {
  local name="$1" service="$2"
  if ! aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam create-role --role-name "$name" --assume-role-policy-document \
      "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$service\"},\"Action\":\"sts:AssumeRole\"}]}" \
      >/dev/null
  fi
}

# JSON 을 보기 좋게 출력 (jq 대신 저장소의 Python 사용 — 추가 설치 불필요)
pretty() { uv run --quiet --project "$(git rev-parse --show-toplevel)" python -m json.tool --no-ensure-ascii; }

# set_queue_policy <큐 URL> <한 줄 JSON 정책> — Policy 속성은 "JSON 안의 JSON 문자열"이라 따옴표를 이스케이프한다
set_queue_policy() {
  local escaped
  escaped="$(printf '%s' "$2" | tr -d '\n' | sed 's/"/\\"/g')"
  aws sqs set-queue-attributes --queue-url "$1" --attributes "{\"Policy\":\"$escaped\"}"
}

# zip_function <파이썬 파일> <zip 출력 경로> — 핸들러 파일 하나를 Lambda 배포 패키지로 묶는다 (zip 명령 대신 Python 사용)
zip_function() {
  uv run --quiet --project "$(git rev-parse --show-toplevel)" python -c \
    'import sys, zipfile, os; z = zipfile.ZipFile(sys.argv[2], "w"); z.write(sys.argv[1], os.path.basename(sys.argv[1])); z.close()' "$1" "$2"
}

# fresh_function <함수 이름> <핸들러 파일> <핸들러> <역할 ARN> [추가 create-function 인자...]
# 같은 이름의 함수가 있으면 지우고 새로 만든 뒤 Active 가 될 때까지 기다린다.
fresh_function() {
  local name="$1" file="$2" handler="$3" role="$4" zip
  shift 4
  zip="$(mktemp -d)/fn.zip"
  zip_function "$file" "$zip"
  aws lambda delete-function --function-name "$name" >/dev/null 2>&1 || true
  # 역할을 막 만든 직후에는 실제 AWS 에서 InvalidParameterValueException(역할을 맡을 수 없음)이 날 수 있다 → 재시도
  local start=$SECONDS out
  until out="$(aws lambda create-function --function-name "$name" --runtime python3.12 --handler "$handler" \
      --role "$role" --zip-file "fileb://$zip" "$@" --query State --output text 2>&1)"; do
    grep -q 'cannot be assumed\|InvalidParameterValue' <<<"$out" && ((SECONDS - start < 60)) || { echo "$out" >&2; return 1; }
    sleep 2
  done
  aws lambda wait function-active-v2 --function-name "$name"
}
