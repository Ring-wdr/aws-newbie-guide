#!/usr/bin/env bash
# M01 lab05 — Organizations OU 구성 (🟢) / SCP·계정 API (🔴 501 관찰) / IAM Identity Center 읽기
# 에뮬레이터에는 조직이 처음부터 하나 있다(관리 계정 = 000000000000). 그 루트 아래 OU 트리를 만든다.
#
#   Root
#   ├── todayorder-security          (로그·감사 계정 자리)
#   ├── todayorder-workloads
#   │   ├── todayorder-prod
#   │   └── todayorder-dev
#   └── todayorder-sandbox
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ROOT_ID="$(aws organizations list-roots --query 'Roots[0].Id' --output text)"

# OU 이름으로 ID 찾기 (없으면 빈 문자열)
ou_id() { # <부모 ID> <이름>
  aws organizations list-organizational-units-for-parent --parent-id "$1" --output json \
    | python3 -c 'import json,sys; n=sys.argv[1]; print(next((o["Id"] for o in json.load(sys.stdin)["OrganizationalUnits"] if o["Name"]==n), ""))' "$2"
}
# OU 를 하위 OU 까지 지운다 (OU 는 비어 있어야 지워진다 — 자식부터)
delete_ou_tree() {
  local id="$1" c
  for c in $(aws organizations list-organizational-units-for-parent --parent-id "$id" --query 'OrganizationalUnits[].Id' --output text); do
    delete_ou_tree "$c"
  done
  aws organizations delete-organizational-unit --organizational-unit-id "$id"
}
cleanup() {
  local n id
  for n in todayorder-security todayorder-workloads todayorder-sandbox; do
    id="$(ou_id "$ROOT_ID" "$n")"
    [ -n "$id" ] && delete_ou_tree "$id"
  done
  return 0
}
cleanup

echo "== 1. 조직과 루트"
aws organizations describe-organization \
  --query 'Organization.{Id: Id, FeatureSet: FeatureSet, MasterAccountId: MasterAccountId, PolicyTypes: AvailablePolicyTypes}'
aws organizations list-roots --query 'Roots[0].{Id: Id, Name: Name}'

echo "== 2. OU 트리 만들기"
mk() { aws organizations create-organizational-unit --parent-id "$1" --name "$2" --query 'OrganizationalUnit.Id' --output text; }
SEC="$(mk "$ROOT_ID" todayorder-security)"
WL="$(mk "$ROOT_ID" todayorder-workloads)"
SBX="$(mk "$ROOT_ID" todayorder-sandbox)"
PROD="$(mk "$WL" todayorder-prod)"
DEV="$(mk "$WL" todayorder-dev)"
echo "security=$SEC workloads=$WL sandbox=$SBX prod=$PROD dev=$DEV"

echo "== 3. 트리 확인"
aws organizations list-organizational-units-for-parent --parent-id "$ROOT_ID" --query 'OrganizationalUnits[].Name'
aws organizations list-organizational-units-for-parent --parent-id "$WL" --query 'OrganizationalUnits[].{Name: Name, Path: Path}'

echo "== 4. 같은 부모 아래 같은 이름의 OU는 만들 수 없다"
expect_fail aws organizations create-organizational-unit --parent-id "$WL" --name todayorder-prod
e_dup="$ERR"

echo "== 5. 하위 OU 가 있는 OU 는 지울 수 없다"
expect_fail aws organizations delete-organizational-unit --organizational-unit-id "$WL"
e_notempty="$ERR"

echo "== 6. SCP 만들기·붙이기·목록 — 에뮬레이터 미구현(501)"
expect_fail aws organizations create-policy --name todayorder-deny-leave-org --type SERVICE_CONTROL_POLICY \
  --description "member accounts cannot leave" \
  --content "file://$(cd "$(dirname "$0")" && pwd)/policies/scp-deny-leave-org.json"
e_create="$ERR"
expect_fail aws organizations attach-policy --policy-id p-FullAWSAccess --target-id "$PROD"
e_attach="$ERR"
expect_fail aws organizations list-policies --filter SERVICE_CONTROL_POLICY
e_list="$ERR"

echo "== 7. 계정 API 도 미구현(501)"
expect_fail aws organizations list-accounts
e_accounts="$ERR"

echo "== 8. IAM Identity Center 인스턴스 읽기"
aws sso-admin list-instances --no-paginate --query 'Instances[0].{Name: Name, Status: Status, IdentityStoreId: IdentityStoreId, Owner: OwnerAccountId}'
INST="$(aws sso-admin list-instances --no-paginate --query 'Instances[0].InstanceArn' --output text)"
echo "--- 권한 세트 만들기"
expect_fail aws sso-admin create-permission-set --instance-arn "$INST" --name TodayOrderDeveloper --session-duration PT8H
e_ps="$ERR"

# ---- 단언
[ "$(ou_id "$WL" todayorder-prod)" = "$PROD" ] || { echo "FAIL: prod OU 가 workloads 아래에 없음"; exit 1; }
[ "$(ou_id "$WL" todayorder-dev)" = "$DEV" ] || { echo "FAIL: dev OU 가 workloads 아래에 없음"; exit 1; }
must_contain "$e_dup" "DuplicateOrganizationalUnitException" "OU 이름 중복"
must_contain "$e_notempty" "OrganizationalUnitNotEmptyException" "비어 있지 않은 OU 삭제"
for e in "$e_create" "$e_attach" "$e_list" "$e_accounts"; do
  must_contain "$e" "NotImplemented" "SCP·계정 API 501 (구현되면 레슨·FIDELITY 갱신)"
done
must_contain "$e_ps" "account instances" "계정 인스턴스는 권한 세트 미지원"

cleanup
echo "LAB05 OK"
