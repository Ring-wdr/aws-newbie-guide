#!/usr/bin/env bash
# M01 lab02 — 역할 + 신뢰 정책, assume-role 로 임시 자격 증명 받기 (🟢)
# 1) 운영 조회 역할을 만들고 김 개발자만 맡을 수 있게 신뢰 정책을 쓴다
# 2) 김 개발자가 assume-role → 임시 자격 증명(키 ID 접두사 EMULATOR, 세션 토큰, 만료 시각)
# 3) 임시 자격 증명으로 호출: 역할 권한 안은 허용, 밖은 거부
# 4) 신뢰 정책에 없는 이 개발자의 assume-role → AccessDenied
# 5) 세션 정책으로 권한을 더 좁히기 · 외부 ID(ExternalId) · 최대 세션 시간
# 6) EC2용 역할 → 인스턴스 프로파일 → 인스턴스에 연결
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ACCOUNT=000000000000
KIM=todayorder-dev-kim2
LEE=todayorder-dev-lee2
ROLE=todayorder-ops-readonly
PARTNER_ROLE=todayorder-partner-audit
EC2_ROLE=todayorder-api-server
PROFILE=todayorder-api-server-profile
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/$ROLE"

cleanup() {
  for i in $(aws ec2 describe-instances --filters Name=tag:Name,Values=todayorder-m01-api \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text); do
    aws ec2 terminate-instances --instance-ids "$i" >/dev/null
  done
  if aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
    for r in $(aws iam get-instance-profile --instance-profile-name "$PROFILE" --query 'InstanceProfile.Roles[].RoleName' --output text); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$r"
    done
    aws iam delete-instance-profile --instance-profile-name "$PROFILE"
  fi
  delete_role_fully "$ROLE"
  delete_role_fully "$PARTNER_ROLE"
  delete_role_fully "$EC2_ROLE"
  delete_user_fully "$KIM"
  delete_user_fully "$LEE"
}
cleanup

echo "== 1. 사용자 2명 (정책 없음) 과 액세스 키"
for u in "$KIM" "$LEE"; do aws iam create-user --user-name "$u" --query User.Arn --output text; done
read -r KIM_AK KIM_SK < <(aws iam create-access-key --user-name "$KIM" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
read -r LEE_AK LEE_SK < <(aws iam create-access-key --user-name "$LEE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
as_kim() { AWS_ACCESS_KEY_ID="$KIM_AK" AWS_SECRET_ACCESS_KEY="$KIM_SK" aws "$@"; }
as_lee() { AWS_ACCESS_KEY_ID="$LEE_AK" AWS_SECRET_ACCESS_KEY="$LEE_SK" aws "$@"; }

echo "== 2. 역할 만들기: 신뢰 정책(누가 맡나) + 권한 정책(맡으면 무엇을 하나)"
TRUST="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::$ACCOUNT:user/$KIM"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
  --query 'Role.{Arn: Arn, RoleId: RoleId, MaxSessionDuration: MaxSessionDuration}'
aws iam put-role-policy --role-name "$ROLE" --policy-name describe-only --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": ["ec2:Describe*", "iam:ListRoles"], "Resource": "*"}]
}'

echo "== 3. 김 개발자가 역할을 맡는다 (assume-role)"
creds="$(as_kim sts assume-role --role-arn "$ROLE_ARN" --role-session-name kim-oncall \
  --duration-seconds 900 --output json)"
printf '%s\n' "$creds" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["Credentials"]
print("AccessKeyId     :", c["AccessKeyId"])
print("SecretAccessKey :", c["SecretAccessKey"][:4] + "... (" + str(len(c["SecretAccessKey"])) + "자)")
print("SessionToken    :", c["SessionToken"][:12] + "... (" + str(len(c["SessionToken"])) + "자)")
print("Expiration      :", c["Expiration"])
print("AssumedRoleUser :", d["AssumedRoleUser"]["Arn"])'
read -r T_AK T_SK T_ST < <(printf '%s\n' "$creds" | python3 -c '
import json, sys
c = json.load(sys.stdin)["Credentials"]
print(c["AccessKeyId"], c["SecretAccessKey"], c["SessionToken"])')
as_role() { AWS_ACCESS_KEY_ID="$T_AK" AWS_SECRET_ACCESS_KEY="$T_SK" AWS_SESSION_TOKEN="$T_ST" aws "$@"; }

echo "== 4. 임시 자격 증명으로 호출"
who="$(as_role sts get-caller-identity --query Arn --output text)"
echo "나는 누구: $who"
vpcs="$(as_role ec2 describe-vpcs --query 'length(Vpcs)' --output text)"
echo "ec2 describe-vpcs (역할 권한 안): VPC $vpcs 개"
expect_fail as_role iam create-user --user-name todayorder-should-not-exist
err_outside="$ERR"

echo "== 5. 신뢰 정책에 없는 이 개발자가 같은 역할을 맡으려 하면"
expect_fail as_lee sts assume-role --role-arn "$ROLE_ARN" --role-session-name lee-try
err_trust="$ERR"

echo "== 6. 세션 정책: 맡을 때 권한을 더 좁힌다 (역할 권한 ∩ 세션 정책)"
read -r S_AK S_SK S_ST < <(as_kim sts assume-role --role-arn "$ROLE_ARN" --role-session-name kim-narrow \
  --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ec2:DescribeVpcs","Resource":"*"}]}' \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
as_narrow() { AWS_ACCESS_KEY_ID="$S_AK" AWS_SECRET_ACCESS_KEY="$S_SK" AWS_SESSION_TOKEN="$S_ST" aws "$@"; }
roles_full="$(as_role iam list-roles --query 'length(Roles)' --output text)"
echo "세션 정책 없이 iam list-roles: 역할 $roles_full 개"
expect_fail as_narrow iam list-roles
err_session="$ERR"

echo "== 7. 외부 ID: 파트너(제3자) 감사 역할은 약속한 ExternalId 가 있어야 맡을 수 있다"
aws iam create-role --role-name "$PARTNER_ROLE" --query Role.Arn --output text --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"AWS\": \"arn:aws:iam::$ACCOUNT:root\"},
    \"Action\": \"sts:AssumeRole\",
    \"Condition\": {\"StringEquals\": {\"sts:ExternalId\": \"todayorder-audit-7f3a\"}}
  }]
}"
expect_fail aws sts assume-role --role-arn "arn:aws:iam::$ACCOUNT:role/$PARTNER_ROLE" --role-session-name audit
err_extid="$ERR"
ext_ok="$(aws sts assume-role --role-arn "arn:aws:iam::$ACCOUNT:role/$PARTNER_ROLE" --role-session-name audit \
  --external-id todayorder-audit-7f3a --query AssumedRoleUser.Arn --output text)"
echo "외부 ID를 맞게 주면: $ext_ok"

echo "== 8. 최대 세션 시간(기본 3600초)보다 길게 요청하면"
expect_fail as_kim sts assume-role --role-arn "$ROLE_ARN" --role-session-name kim-long --duration-seconds 7200
err_duration="$ERR"

echo "== 9. EC2가 맡는 역할 → 인스턴스 프로파일 → 인스턴스"
aws iam create-role --role-name "$EC2_ROLE" --query Role.Arn --output text --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}'
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name read-receipts --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::todayorder-receipts/*"}]
}'
aws iam create-instance-profile --instance-profile-name "$PROFILE" --query InstanceProfile.Arn --output text
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$EC2_ROLE"
expect_fail aws sts assume-role --role-arn "arn:aws:iam::$ACCOUNT:role/$EC2_ROLE" --role-session-name me
err_service="$ERR"
AMI="$(aws ec2 describe-images --owners amazon --query 'Images[0].ImageId' --output text)"
IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=todayorder-m01-api}]' \
  --query 'Instances[0].InstanceId' --output text)"
assoc="$(aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$IID" \
  --query 'IamInstanceProfileAssociations[0].{Instance: InstanceId, Profile: IamInstanceProfile.Arn, State: State}' --output json)"
echo "$assoc"

# ---- 단언
key_id="$T_AK"
must_contain "$key_id" "EMULATOR" "임시 키 접두사 (실제 AWS는 ASIA)"
[ -n "$T_ST" ] || { echo "FAIL: 세션 토큰 없음"; exit 1; }
must_contain "$who" "assumed-role/$ROLE/kim-oncall" "assumed-role ARN"
[ "$vpcs" -ge 0 ] 2>/dev/null || { echo "FAIL: describe-vpcs 결과 이상 ($vpcs)"; exit 1; }
must_contain "$err_outside" "AccessDenied" "역할 권한 밖 호출 거부"
must_contain "$err_trust" "AccessDenied" "신뢰 정책에 없는 주체 거부"
must_contain "$err_session" "no session policy allows" "세션 정책이 권한을 좁힘"
must_contain "$err_extid" "AccessDenied" "외부 ID 없이 거부"
must_contain "$ext_ok" "assumed-role/$PARTNER_ROLE/audit" "외부 ID 맞으면 허용"
must_contain "$err_duration" "MaxSessionDuration" "최대 세션 시간 초과"
must_contain "$err_service" "AccessDenied" "EC2 전용 역할을 사람이 못 맡음"
must_contain "$assoc" "$PROFILE" "인스턴스 프로파일 연결"

cleanup
echo "LAB02 OK"
