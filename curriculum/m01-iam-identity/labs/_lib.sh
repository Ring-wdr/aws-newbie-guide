# shellcheck shell=bash
# M01 실습 공용 함수. 각 labNN-*.sh 가 scripts/env.sh 를 source 한 뒤에 이 파일을 source 한다.
# (이 파일은 실습이 아니므로 verify.sh 가 직접 실행하지 않는다)

# IAM 사용자를 "흔적 없이" 지운다. 사용자는 붙어 있는 것(그룹 소속, 정책, 키, 로그인 프로필,
# 권한 경계)을 먼저 떼어 내야 지워진다 — 그렇지 않으면 DeleteConflict.
delete_user_fully() {
  local u="$1" x
  aws iam get-user --user-name "$u" >/dev/null 2>&1 || return 0
  for x in $(aws iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' --output text); do
    aws iam remove-user-from-group --user-name "$u" --group-name "$x"
  done
  for x in $(aws iam list-attached-user-policies --user-name "$u" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-user-policy --user-name "$u" --policy-arn "$x"
  done
  for x in $(aws iam list-user-policies --user-name "$u" --query 'PolicyNames[]' --output text); do
    aws iam delete-user-policy --user-name "$u" --policy-name "$x"
  done
  for x in $(aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$u" --access-key-id "$x"
  done
  aws iam delete-login-profile --user-name "$u" >/dev/null 2>&1 || true
  aws iam delete-user-permissions-boundary --user-name "$u" >/dev/null 2>&1 || true
  aws iam delete-user --user-name "$u"
}

delete_group_fully() {
  local g="$1" x
  aws iam get-group --group-name "$g" >/dev/null 2>&1 || return 0
  for x in $(aws iam get-group --group-name "$g" --query 'Users[].UserName' --output text); do
    aws iam remove-user-from-group --group-name "$g" --user-name "$x"
  done
  for x in $(aws iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-group-policy --group-name "$g" --policy-arn "$x"
  done
  for x in $(aws iam list-group-policies --group-name "$g" --query 'PolicyNames[]' --output text); do
    aws iam delete-group-policy --group-name "$g" --policy-name "$x"
  done
  aws iam delete-group --group-name "$g"
}

delete_role_fully() {
  local r="$1" x
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || return 0
  for x in $(aws iam list-instance-profiles-for-role --role-name "$r" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$x" --role-name "$r"
  done
  for x in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$x"
  done
  for x in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$x"
  done
  aws iam delete-role --role-name "$r"
}

# 고객 관리형 정책: 기본이 아닌 버전을 먼저 지워야 정책을 지울 수 있다.
delete_policy_fully() {
  local arn="$1" v
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || return 0
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$arn"
}

# 명령이 실패해야 정상인 단계: stderr 를 보여 주고 변수 ERR 에 담는다. 성공하면 ERR 은 빈 문자열.
# 사용: expect_fail aws iam list-users ; echo "$ERR"
expect_fail() {
  ERR=""
  local out
  if out="$("$@" 2>&1)"; then
    echo "(성공함 — 실패를 기대했다)"
    echo "$out"
    return 0
  fi
  ERR="$(printf '%s\n' "$out" | sed '/^$/d')"
  printf '%s\n' "$ERR"
}

# 단언 도우미
must_contain() { # <값> <기대 부분 문자열> <설명>
  case "$1" in
    *"$2"*) ;;
    *) echo "FAIL: $3 — '$2' 가 없음"; echo "  실제: $1"; exit 1 ;;
  esac
}
