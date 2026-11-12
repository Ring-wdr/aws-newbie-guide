# shellcheck shell=bash
# M09 lab 공용 도우미. 각 lab 이 env.sh 다음에 source 한다. (verify.sh 는 lab*.sh 만 실행하므로 이 파일은 단독 실행되지 않는다)

ROOT="$(git rev-parse --show-toplevel)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# assert_eq <실제> <기대> <설명>
assert_eq() { [ "$1" = "$2" ] || fail "$3 (기대: '$2', 실제: '$1')"; }

# poll <상한 초> <설명> <명령...> — 명령이 성공할 때까지 1초 간격으로 다시 시도한다.
poll() {
  local limit="$1" desc="$2" start=$SECONDS out
  shift 2
  until out="$("$@" 2>&1)"; do
    if ((SECONDS - start >= limit)); then
      fail "$desc: ${limit}초 안에 조건을 만족하지 못했다. 마지막 관찰: ${out:-없음}"
    fi
    sleep 1
  done
}

# expect_error <변수 이름> <명령...> — 명령이 실패해야 정상인 경우. stderr 를 변수에 담는다.
# 명령이 성공해 버리면 변수에 "(성공함)" 이 들어간다.
expect_error() {
  local __var="$1" __out
  shift
  if __out="$("$@" 2>&1 >/dev/null)"; then __out="(성공함)"; fi
  printf -v "$__var" '%s' "$__out"
}

# JSON 가공용 파이썬 (저장소의 uv 환경 — 학습자 PC에 jq 가 없어도 된다)
# 사용법: <JSON 을 내는 명령> | py '<파이썬 코드>' [인자...]   (json·sys 는 미리 import 됨)
py() {
  uv run --quiet --project "$ROOT" python -c "import json, sys
$1" "${@:2}"
}

# reset_alias <alias/이름> — 별칭과, 별칭이 가리키던 키(삭제 대기 7일로 예약)를 치운다.
# KMS 키는 바로 지울 수 없다(최소 7일 대기). 다시 실행할 때마다 새 키를 만들고 옛 키는 삭제 예약한다.
reset_alias() {
  local target
  target="$(aws kms list-aliases --output json | py '
for a in json.loads(sys.stdin.read() or "{}").get("Aliases", []):
    if a["AliasName"] == sys.argv[1]:
        print(a.get("TargetKeyId", ""))' "$1")"
  if [ -n "$target" ]; then
    aws kms delete-alias --alias-name "$1"
    aws kms schedule-key-deletion --key-id "$target" --pending-window-in-days 7 >/dev/null 2>&1 || true
  fi
}

# delete_iam_user <이름> — 액세스 키·인라인/관리형 정책을 정리하고 사용자를 지운다.
delete_iam_user() {
  aws iam get-user --user-name "$1" >/dev/null 2>&1 || return 0
  local k p
  for k in $(aws iam list-access-keys --user-name "$1" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$1" --access-key-id "$k"
  done
  for p in $(aws iam list-user-policies --user-name "$1" --query 'PolicyNames[]' --output text); do
    aws iam delete-user-policy --user-name "$1" --policy-name "$p"
  done
  for p in $(aws iam list-attached-user-policies --user-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-user-policy --user-name "$1" --policy-arn "$p"
  done
  aws iam delete-user --user-name "$1"
}

# delete_role <이름> — 인라인·관리형 정책을 떼고 역할을 지운다.
delete_role() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || return 0
  local p
  for p in $(aws iam list-role-policies --role-name "$1" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$1" --policy-name "$p"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$1" --policy-arn "$p"
  done
  aws iam delete-role --role-name "$1"
}

TMP_LIB="$(mktemp -d)"
trap 'rm -rf "$TMP_LIB"' EXIT
