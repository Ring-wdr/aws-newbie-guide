#!/usr/bin/env bash
# M08 lab06 — WAF Web ACL 을 ALB 에 연결하고 차단을 관찰 (🟢 구성 · 차단은 docker exec 선택 과제로 관찰)
# IP 세트 · 속도 기반 규칙 · AWS 관리형 규칙 그룹(공통·SQLi) → ALB 연결 → 공격 요청이 403 으로 막히는지
# → 샘플링된 요청(get-sampled-requests)으로 "어느 규칙이 막았나" 확인 → Shield·Firewall Manager 상태 읽기
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ACL_NAME="todayorder-m08-api-acl"
IPSET_NAME="todayorder-m08-blocklist"
ALB_NAME="todayorder-m08-alb"
VPC_TAG="todayorder-m08-waf-vpc"
CONTAINER="aws-emulator-$EMULATOR_PORT"
WORK="$TMP_LIB"
REG=(--scope REGIONAL)

# ---- 이전 실행 정리 (멱등): 연결 해제 → Web ACL → IP 세트 → ALB → VPC
for lb in $(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true); do
  aws wafv2 disassociate-web-acl --resource-arn "$lb" >/dev/null 2>&1 || true
  aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
done
waf_ids() { # waf_ids <list 명령 결과 키> <이름>  →  "Id LockToken"
  py '
for x in json.loads(sys.stdin.read() or "{}").get(sys.argv[1], []):
    if x["Name"] == sys.argv[2]:
        print(x["Id"], x["LockToken"])' "$1" "$2"
}
aws wafv2 list-web-acls "${REG[@]}" --output json | waf_ids WebACLs "$ACL_NAME" | while read -r id lt; do
  aws wafv2 delete-web-acl "${REG[@]}" --name "$ACL_NAME" --id "$id" --lock-token "$lt"
done
aws wafv2 list-ip-sets "${REG[@]}" --output json | waf_ids IPSets "$IPSET_NAME" | while read -r id lt; do
  aws wafv2 delete-ip-set "${REG[@]}" --name "$IPSET_NAME" --id "$id" --lock-token "$lt"
done
for v in $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_TAG" --query 'Vpcs[].VpcId' --output text); do
  for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$v" --query 'Subnets[].SubnetId' --output text); do aws ec2 delete-subnet --subnet-id "$s"; done
  for g in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$v" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$v"; aws ec2 delete-internet-gateway --internet-gateway-id "$g"
  done
  aws ec2 delete-vpc --vpc-id "$v"
done

echo "== 0. 보호할 대상: 주문 API 앞의 ALB (고정 응답 200 'orders-api-ok')"
VPC="$(aws ec2 create-vpc --cidr-block 10.81.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_TAG}]" --query Vpc.VpcId --output text)"
S1="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.81.1.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text)"
S2="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.81.2.0/24 --availability-zone us-east-1b --query Subnet.SubnetId --output text)"
IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --vpc-id "$VPC" --internet-gateway-id "$IGW"
read -r ALB DNS < <(aws elbv2 create-load-balancer --name "$ALB_NAME" --subnets "$S1" "$S2" \
  --query 'LoadBalancers[0].[LoadBalancerArn, DNSName]' --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
  --default-actions 'Type=fixed-response,FixedResponseConfig={StatusCode=200,ContentType=text/plain,MessageBody=orders-api-ok}' >/dev/null
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB"
echo "ALB DNSName: $DNS  (컨테이너 안 주소)"

can_exec=false
if docker exec "$CONTAINER" true >/dev/null 2>&1; then can_exec=true; fi
hit() { docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -m 5 "$@"; }
before_sqli=""
SQLI="/orders?id=1%27%20OR%20%271%27=%271"

if $can_exec; then
  echo "-- WAF 연결 전: 정상 요청 $(hit "http://$DNS/") · SQL 인젝션 시도 $(hit "http://$DNS$SQLI")  (둘 다 통과)"
  before_sqli="$(hit "http://$DNS$SQLI")"
fi

echo "== 1. IP 세트 — 차단할 공격자 대역"
IPSET_ARN="$(aws wafv2 create-ip-set "${REG[@]}" --name "$IPSET_NAME" --ip-address-version IPV4 \
  --addresses 203.0.113.0/24 --description "known bad actors" --query Summary.ARN --output text)"
echo "$IPSET_ARN"

echo "== 2. Web ACL — 기본 동작 Allow + 규칙 4개 (우선순위가 낮은 숫자부터 평가)"
cat >"$WORK/rules.json" <<EOF
[
 {"Name": "block-bad-ips", "Priority": 0, "Action": {"Block": {}},
  "Statement": {"IPSetReferenceStatement": {"ARN": "$IPSET_ARN",
    "IPSetForwardedIPConfig": {"HeaderName": "X-Forwarded-For", "FallbackBehavior": "NO_MATCH", "Position": "FIRST"}}},
  "VisibilityConfig": {"SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true, "MetricName": "blockBadIps"}},
 {"Name": "rate-limit-login", "Priority": 1, "Action": {"Block": {}},
  "Statement": {"RateBasedStatement": {"Limit": 20, "EvaluationWindowSec": 60, "AggregateKeyType": "IP",
    "ScopeDownStatement": {"ByteMatchStatement": {"SearchString": "/login", "FieldToMatch": {"UriPath": {}},
      "TextTransformations": [{"Priority": 0, "Type": "NONE"}], "PositionalConstraint": "STARTS_WITH"}}}},
  "VisibilityConfig": {"SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true, "MetricName": "rateLimitLogin"}},
 {"Name": "aws-common", "Priority": 2, "OverrideAction": {"None": {}},
  "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS", "Name": "AWSManagedRulesCommonRuleSet"}},
  "VisibilityConfig": {"SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true, "MetricName": "awsCommon"}},
 {"Name": "aws-sqli", "Priority": 3, "OverrideAction": {"None": {}},
  "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS", "Name": "AWSManagedRulesSQLiRuleSet"}},
  "VisibilityConfig": {"SampledRequestsEnabled": true, "CloudWatchMetricsEnabled": true, "MetricName": "awsSqli"}}
]
EOF
# ByteMatch 의 SearchString 은 blob 타입이라, CLI v2 에서는 raw-in-base64-out 을 줘야 평문으로 쓸 수 있다.
echo "필요 용량(WCU): $(aws wafv2 check-capacity "${REG[@]}" --cli-binary-format raw-in-base64-out --rules "file://$WORK/rules.json" --query Capacity --output text)"
ACL_ARN="$(aws wafv2 create-web-acl "${REG[@]}" --cli-binary-format raw-in-base64-out --name "$ACL_NAME" \
  --default-action Allow={} --rules "file://$WORK/rules.json" \
  --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=todayorderApiAcl \
  --query Summary.ARN --output text)"
ACL_ID="$(cut -d/ -f4 <<<"$ACL_ARN")"
aws wafv2 get-web-acl "${REG[@]}" --name "$ACL_NAME" --id "$ACL_ID" \
  --query 'WebACL.{Capacity: Capacity, Default: keys(DefaultAction)[0], Rules: Rules[].join(`: `, [to_string(Priority), Name])}'
rule_count="$(aws wafv2 get-web-acl "${REG[@]}" --name "$ACL_NAME" --id "$ACL_ID" --query 'length(WebACL.Rules)' --output text)"

echo "== 3. ALB 에 연결"
aws wafv2 associate-web-acl --web-acl-arn "$ACL_ARN" --resource-arn "$ALB"
assoc="$(aws wafv2 get-web-acl-for-resource --resource-arn "$ALB" --query WebACL.Name --output text)"
echo "ALB 에 연결된 Web ACL: $assoc"

g_normal=""; g_badip=""; g_sqli=""; g_xss=""; g_noua=""
if $can_exec; then
  echo "== 4. 공격 흉내 (선택 과제: docker exec 로 컨테이너 안에서 ALB 호출)"
  g_normal="$(hit "http://$DNS/")"
  g_badip="$(hit -H 'X-Forwarded-For: 203.0.113.5' "http://$DNS/")"
  g_sqli="$(hit "http://$DNS$SQLI")"
  g_xss="$(hit "http://$DNS/search?q=%3Cscript%3Ealert(1)%3C/script%3E")"
  g_noua="$(hit -A '' "http://$DNS/")"
  printf '%-34s %s\n' "정상 요청" "${g_normal}" "차단 목록 IP (X-Forwarded-For)" "${g_badip}" \
    "SQL 인젝션 쿼리" "${g_sqli}" "XSS 쿼리" "${g_xss}" "User-Agent 없음" "${g_noua}"
  echo "-- 로그인 30번 연타 (속도 제한 20/60초)"
  docker exec "$CONTAINER" sh -c "for i in \$(seq 30); do curl -s -o /dev/null -w '%{http_code}\n' -m 5 http://$DNS/login; done" | sort | uniq -c | tee "$WORK/login.txt"

  echo "== 5. 어느 규칙이 막았나 — 샘플링된 요청"
  now="$(date -u +%s)"
  for m in blockBadIps rateLimitLogin awsCommon awsSqli; do
    aws wafv2 get-sampled-requests --web-acl-arn "$ACL_ARN" --rule-metric-name "$m" "${REG[@]}" \
      --time-window StartTime=$((now - 900)),EndTime=$((now + 60)) --max-items 100 --output json | py '
from collections import Counter
rows = Counter((r["Action"], r["Request"]["URI"], r.get("RuleNameWithinRuleGroup") or "-") for r in json.load(sys.stdin)["SampledRequests"])
for (a, uri, sub), n in sorted(rows.items()):
    print(f"{sys.argv[1]:<15} {a:<6} x{n:<3} {uri[:45]:<45} {sub}")' "$m"
  done | tee "$WORK/sampled.txt"
else
  echo "== 4·5. SKIP(docker exec 불가 — 차단 관찰은 선택 과제)"
fi

echo "== 6. CloudFront 용 Web ACL 은 범위가 CLOUDFRONT 이고 us-east-1 에서 만든다"
CF_ACL="todayorder-m08-cf-acl"
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --output json | waf_ids WebACLs "$CF_ACL" | while read -r id lt; do
  aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 --name "$CF_ACL" --id "$id" --lock-token "$lt"
done
cf_arn="$(aws wafv2 create-web-acl --scope CLOUDFRONT --region us-east-1 --name "$CF_ACL" --default-action Allow={} \
  --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=todayorderCf \
  --query Summary.ARN --output text)"
echo "$cf_arn"

echo "== 7. Shield 와 Firewall Manager — 읽기만"
shield="$(aws shield get-subscription-state --query SubscriptionState --output text)"
echo "Shield Advanced 구독 상태: $shield  (Shield Standard 는 구독 없이 모든 고객에게 자동 적용)"
set +e
fms_err="$(aws fms list-policies 2>&1 >/dev/null)"
set -e
echo "Firewall Manager: $(grep -m1 -o 'AccessDeniedException.*' <<<"$fms_err")"

# ---- 단언
assert_eq "$rule_count" "4" "Web ACL 규칙 수"
assert_eq "$assoc" "$ACL_NAME" "ALB 에 연결된 Web ACL"
case "$cf_arn" in *":global/webacl/"*) ;; *) fail "CLOUDFRONT 범위 Web ACL ARN 형식: $cf_arn" ;; esac
assert_eq "$shield" "INACTIVE" "Shield Advanced 구독 상태"
if $can_exec; then
  assert_eq "$before_sqli" "200" "WAF 연결 전 SQLi 요청"
  assert_eq "${g_normal}" "200" "정상 요청"
  assert_eq "${g_badip}" "403" "차단 목록 IP"
  assert_eq "${g_sqli}" "403" "SQL 인젝션"
  assert_eq "${g_xss}" "403" "XSS"
  grep -q ' 403$' "$WORK/login.txt" || fail "속도 기반 규칙이 아무것도 막지 않음"
  grep -q ' 200$' "$WORK/login.txt" || fail "속도 제한 전 요청도 막힘"
  grep -q 'awsSqli.*SQLi_QUERYARGUMENTS' "$WORK/sampled.txt" || fail "SQLi 규칙의 샘플 요청이 없음"
fi
echo "LAB06 OK"
