#!/usr/bin/env bash
# M02 lab04 — 보안 그룹 체이닝: 인터넷 → ALB(443) → 앱(8080) → DB(5432) (🟢)
# IP 대신 "보안 그룹 ID"를 출처로 쓰면, 앱 서버가 몇 대가 되든 규칙을 고칠 필요가 없다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"

# 이 lab 이 만드는 SG가 남아 있으면 지운다 (서로 참조하므로 규칙부터 걷어 낸다).
old=""
for g in todayorder-db-sg todayorder-app-sg todayorder-alb-sg; do
  id="$(sg_id "$VPC" "$g")"; [ -n "$id" ] && old="$old $id"
done
for id in $old; do
  rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$id" --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text)"
  [ -n "$rules" ] && aws ec2 revoke-security-group-ingress --group-id "$id" --security-group-rule-ids $rules >/dev/null
done
for id in $old; do aws ec2 delete-security-group --group-id "$id" >/dev/null; done

mk_sg() {
  aws ec2 create-security-group --vpc-id "$VPC" --group-name "$1" --description "$2" \
    --tag-specifications "$(tags security-group "$1")" --query GroupId --output text
}

echo "== 1. 보안 그룹 3개"
ALB="$(mk_sg todayorder-alb-sg "TodayOrder ALB - HTTPS from internet")"
APP="$(mk_sg todayorder-app-sg "TodayOrder order API - 8080 from ALB only")"
DB="$(mk_sg todayorder-db-sg "TodayOrder PostgreSQL - 5432 from app only")"
echo "   alb=$ALB app=$APP db=$DB"

echo "== 2. 인바운드 규칙: 인터넷→ALB 443, ALB SG→앱 8080, 앱 SG→DB 5432"
aws ec2 authorize-security-group-ingress --group-id "$ALB" \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS from anywhere}]' \
  --query 'SecurityGroupRules[0].[GroupId,IpProtocol,FromPort,CidrIpv4]' --output text
aws ec2 authorize-security-group-ingress --group-id "$APP" \
  --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$ALB,Description=from ALB}]" \
  --query 'SecurityGroupRules[0].[GroupId,IpProtocol,FromPort,ReferencedGroupInfo.GroupId]' --output text
aws ec2 authorize-security-group-ingress --group-id "$DB" \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$APP,Description=from order API}]" \
  --query 'SecurityGroupRules[0].[GroupId,IpProtocol,FromPort,ReferencedGroupInfo.GroupId]' --output text

echo "== 3. DB SG의 전체 규칙 (새 SG에는 '아웃바운드 전체 허용'이 기본으로 들어 있다)"
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$DB" \
  --query 'SecurityGroupRules[].{Egress: IsEgress, Proto: IpProtocol, Port: FromPort, Cidr: CidrIpv4, FromSG: ReferencedGroupInfo.GroupId}' \
  --output table

echo "== 4. 같은 규칙을 한 번 더 추가하면?"
e_dup="$(expect_error aws ec2 authorize-security-group-ingress --group-id "$ALB" --protocol tcp --port 443 --cidr 0.0.0.0/0)"
echo "$e_dup"

echo "== 5. 앱 SG를 지우려 하면? (DB SG가 참조 중)"
e_dep="$(expect_error aws ec2 delete-security-group --group-id "$APP")"
echo "$e_dep"

echo "== 6. SG에는 Deny 규칙이 없다 — 'Allow 목록'만 있고, 목록에 없으면 거부"
echo "   (CLI에도 deny 옵션 자체가 없다: authorize-* / revoke-* 뿐)"

echo "== 7. 워크시트: 규칙을 읽고 판정 (허용 = 인바운드 규칙 중 하나라도 일치)"
# sg_allows <대상 SG> <포트> <출처: cidr:IP 또는 sg:ID>
sg_allows() {
  local target="$1" port="$2" src="$3" rule proto from to cidr ref
  while read -r proto from to cidr ref; do
    [ "$proto" = "-1" ] || { [ "$proto" = tcp ] && [ "$port" -ge "$from" ] && [ "$port" -le "$to" ]; } || continue
    case "$src" in
      sg:*) [ "$ref" = "${src#sg:}" ] && return 0 ;;
      cidr:*) [ "$cidr" != "None" ] && in_cidr "${src#cidr:}" "$cidr" && return 0 ;;
    esac
  done < <(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$target" \
    --query 'SecurityGroupRules[?!IsEgress].[IpProtocol, FromPort, ToPort, CidrIpv4, ReferencedGroupInfo.GroupId]' --output text)
  return 1
}
verdict() { if sg_allows "$@"; then echo ALLOW; else echo DENY; fi; }
q1="$(verdict "$ALB" 443 cidr:203.0.113.7)"; echo "   Q1 인터넷(203.0.113.7) → ALB:443          $q1"
q2="$(verdict "$APP" 8080 "sg:$ALB")";        echo "   Q2 ALB(SG $ALB) → 앱:8080   $q2"
q3="$(verdict "$DB" 5432 "sg:$ALB")";         echo "   Q3 ALB(SG $ALB) → DB:5432   $q3   (ALB가 DB에 직접 붙을 수는 없다)"
q4="$(verdict "$DB" 5432 "sg:$APP")";         echo "   Q4 앱(SG $APP) → DB:5432    $q4"
q5="$(verdict "$APP" 22 cidr:203.0.113.7)";  echo "   Q5 인터넷 → 앱:22(SSH)                    $q5"

# ---- 단언
assert_eq "DB SG 인바운드 출처" "$APP" \
  "$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$DB" --query 'SecurityGroupRules[?!IsEgress].ReferencedGroupInfo.GroupId | [0]' --output text)"
case "$e_dup" in *InvalidPermission.Duplicate*) ;; *) die "중복 규칙이 거부되지 않음: $e_dup" ;; esac
case "$e_dep" in *DependencyViolation*) ;; *) die "참조 중인 SG 삭제가 거부되지 않음: $e_dep" ;; esac
assert_eq "판정 Q1~Q5" "ALLOW ALLOW DENY ALLOW DENY" "$q1 $q2 $q3 $q4 $q5"
echo "LAB04 OK"
