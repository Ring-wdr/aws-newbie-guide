#!/usr/bin/env bash
# M02 lab05 — 네트워크 ACL: 번호 순서 평가, 명시적 Deny, 상태 비저장(응답 포트도 열어야 한다) (🟢)
#   todayorder-public-nacl : 퍼블릭 서브넷. 악성 대역 203.0.113.0/24 를 규칙 90 으로 차단
#   todayorder-db-nacl     : DB 서브넷. 앱 서브넷에서 오는 5432 만 허용 + 응답용 임시 포트(1024-65535) 아웃바운드
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ensure_three_tier
VPC="$(vpc_id "$M02_VPC_NAME")"
DEFAULT_ACL="$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=true" --query 'NetworkAcls[0].NetworkAclId' --output text)"

# 서브넷을 지정한 NACL로 옮긴다 (서브넷은 항상 NACL 하나와 연결되어 있으므로 '교체'만 있다).
move_subnet_to_acl() {
  local subnet="$1" acl="$2" assoc
  assoc="$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$subnet" \
    --query "NetworkAcls[0].Associations[?SubnetId=='$subnet'].NetworkAclAssociationId | [0]" --output text)"
  aws ec2 replace-network-acl-association --association-id "$assoc" --network-acl-id "$acl" >/dev/null
}

# 이전 실행의 NACL 정리: 서브넷을 기본 NACL로 되돌린 뒤 삭제 (연결된 NACL은 지울 수 없다)
for n in todayorder-public-nacl todayorder-db-nacl; do
  acl="$(aws ec2 describe-network-acls --filters "Name=tag:Name,Values=$n" --query 'NetworkAcls[0].NetworkAclId' --output text)"
  [ "$acl" = "None" ] && continue
  for s in $(aws ec2 describe-network-acls --network-acl-ids "$acl" --query 'NetworkAcls[0].Associations[].SubnetId' --output text); do
    move_subnet_to_acl "$s" "$DEFAULT_ACL"
  done
  aws ec2 delete-network-acl --network-acl-id "$acl"
done

echo "== 1. 기본 NACL(VPC와 함께 생김)은 '전부 허용', 새로 만든 NACL은 '전부 거부'로 시작한다"
aws ec2 describe-network-acls --network-acl-ids "$DEFAULT_ACL" \
  --query 'NetworkAcls[0].Entries[?!Egress].[RuleNumber, RuleAction, Protocol, CidrBlock]' --output text | sed 's/^/   기본  /'
PUB_ACL="$(aws ec2 create-network-acl --vpc-id "$VPC" --tag-specifications "$(tags network-acl todayorder-public-nacl)" --query NetworkAcl.NetworkAclId --output text)"
DB_ACL="$(aws ec2 create-network-acl --vpc-id "$VPC" --tag-specifications "$(tags network-acl todayorder-db-nacl)" --query NetworkAcl.NetworkAclId --output text)"
aws ec2 describe-network-acls --network-acl-ids "$PUB_ACL" \
  --query 'NetworkAcls[0].Entries[?!Egress].[RuleNumber, RuleAction, Protocol, CidrBlock]' --output text | sed 's/^/   새것  /'

entry() { # entry <acl> <ingress|egress> <번호> <allow|deny> <프로토콜> <cidr> [포트범위]
  local args=(--network-acl-id "$1" "--$2" --rule-number "$3" --rule-action "$4" --protocol "$5" --cidr-block "$6")
  [ -n "${7:-}" ] && args+=(--port-range "From=${7%-*},To=${7#*-}")
  aws ec2 create-network-acl-entry "${args[@]}"
}

echo "== 2. 퍼블릭 NACL 규칙"
entry "$PUB_ACL" ingress 90  deny  -1  203.0.113.0/24         # 악성 대역: 허용 규칙(100)보다 번호가 작아야 먼저 평가된다
entry "$PUB_ACL" ingress 100 allow tcp 0.0.0.0/0      443-443  # HTTPS (ALB)
entry "$PUB_ACL" ingress 110 allow tcp 0.0.0.0/0      1024-65535 # 인터넷에서 돌아오는 응답(NAT·ALB가 연 연결)
entry "$PUB_ACL" ingress 120 allow -1  10.0.0.0/16             # VPC 내부(앱 → NAT, 앱 → ALB 응답)
entry "$PUB_ACL" egress  100 allow -1  0.0.0.0/0
for s in todayorder-public-a todayorder-public-b; do move_subnet_to_acl "$(subnet_id "$s")" "$PUB_ACL"; done

echo "== 3. DB NACL 규칙 (상태 비저장 → 응답이 나갈 아웃바운드 임시 포트도 직접 열어야 한다)"
entry "$DB_ACL" ingress 100 allow tcp 10.0.10.0/24 5432-5432
entry "$DB_ACL" ingress 110 allow tcp 10.0.11.0/24 5432-5432
entry "$DB_ACL" egress  100 allow tcp 10.0.10.0/24 1024-65535
entry "$DB_ACL" egress  110 allow tcp 10.0.11.0/24 1024-65535
for s in todayorder-db-a todayorder-db-b; do move_subnet_to_acl "$(subnet_id "$s")" "$DB_ACL"; done

echo "== 4. 규칙 번호 오류: 같은 번호 중복, 범위(1~32766) 밖"
e_dup="$(expect_error entry "$PUB_ACL" ingress 100 allow tcp 0.0.0.0/0 80-80)"
e_num="$(expect_error entry "$PUB_ACL" ingress 32767 allow -1 0.0.0.0/0)"
echo "$e_dup"; echo "$e_num"

echo "== 5. DB NACL 의 규칙 (describe-network-acls 출력 그대로 — 이걸 보고 아래 문제를 푼다)"
aws ec2 describe-network-acls --network-acl-ids "$DB_ACL" \
  --query 'sort_by(NetworkAcls[0].Entries, &RuleNumber)[].[Egress, RuleNumber, RuleAction, Protocol, CidrBlock, PortRange.From, PortRange.To]' \
  --output table

# NACL 평가기: 번호가 작은 규칙부터 보다가 '처음 일치하는' 규칙의 동작으로 끝낸다.
#   nacl_eval <acl> <ingress|egress> <tcp포트> <상대 IP>  → "규칙번호 allow|deny"
nacl_eval() {
  local acl="$1" dir="$2" port="$3" peer="$4" want_egress=False num action proto cidr from to
  [ "$dir" = egress ] && want_egress=True
  while read -r egress num action proto cidr from to; do
    [ "$egress" = "$want_egress" ] || continue
    in_cidr "$peer" "$cidr" || continue
    if [ "$proto" = "-1" ] || { [ "$proto" = 6 ] && [ "$port" -ge "$from" ] && [ "$port" -le "$to" ]; }; then
      echo "$num $action"; return
    fi
  done < <(aws ec2 describe-network-acls --network-acl-ids "$acl" \
    --query 'sort_by(NetworkAcls[0].Entries, &RuleNumber)[].[Egress, RuleNumber, RuleAction, Protocol, CidrBlock, PortRange.From, PortRange.To]' \
    --output text)
}

echo "== 6. 워크시트: 어느 규칙이 판정하는가?"
q1="$(nacl_eval "$PUB_ACL" ingress 443 203.0.113.9)";   echo "   Q1 203.0.113.9 → 퍼블릭:443 (인바운드)          $q1"
q2="$(nacl_eval "$PUB_ACL" ingress 443 198.51.100.20)"; echo "   Q2 198.51.100.20 → 퍼블릭:443 (인바운드)        $q2"
q3="$(nacl_eval "$PUB_ACL" ingress 22 198.51.100.20)";  echo "   Q3 198.51.100.20 → 퍼블릭:22 (인바운드)         $q3"
q4="$(nacl_eval "$DB_ACL" ingress 5432 10.0.10.25)";    echo "   Q4 app-a 10.0.10.25 → DB:5432 (인바운드)        $q4"
q5="$(nacl_eval "$DB_ACL" egress 49152 10.0.10.25)";    echo "   Q5 DB → app-a 10.0.10.25:49152 응답 (아웃바운드) $q5"
q6="$(nacl_eval "$DB_ACL" ingress 5432 10.0.0.50)";     echo "   Q6 public-a 10.0.0.50 → DB:5432 (인바운드)      $q6"

# ---- 단언
assert_eq "DB 서브넷 2개가 DB NACL에 연결" 2 \
  "$(aws ec2 describe-network-acls --network-acl-ids "$DB_ACL" --query 'length(NetworkAcls[0].Associations)' --output text)"
case "$e_dup" in *NetworkAclEntryAlreadyExists*) ;; *) die "중복 규칙 번호: $e_dup" ;; esac
case "$e_num" in *InvalidParameterValue*) ;; *) die "범위 밖 규칙 번호: $e_num" ;; esac
assert_eq "Q1~Q6" "90 deny|100 allow|32767 deny|100 allow|100 allow|32767 deny" "$q1|$q2|$q3|$q4|$q5|$q6"
echo "LAB05 OK"
