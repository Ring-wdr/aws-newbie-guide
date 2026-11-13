#!/usr/bin/env bash
# M08 lab01 — 호스팅 영역과 레코드 CRUD, Alias vs CNAME (🟢)
# 퍼블릭 호스팅 영역 → A/CNAME/TXT 레코드 → 변경 상태 PENDING→INSYNC → apex CNAME 거부 →
# apex Alias(CloudFront) · 영역 안 Alias → 같은 이름의 프라이빗 호스팅 영역(split-horizon) → 레코드 삭제
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ZONE="todayorder.example"
WORK="$TMP_LIB"

# 이전 실행이 남긴 영역과 VPC 를 지우고 시작한다 (멱등).
delete_zones "$ZONE"
for v in $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=todayorder-m08-vpc --query 'Vpcs[].VpcId' --output text); do
  aws ec2 delete-vpc --vpc-id "$v"
done

echo "== 1. 퍼블릭 호스팅 영역 만들기"
ZID="$(aws route53 create-hosted-zone --name "$ZONE" --caller-reference "m08-lab01-$(date +%s)-$RANDOM" \
  --hosted-zone-config Comment="TodayOrder public zone" --query HostedZone.Id --output text)"
echo "HostedZoneId: $ZID"
aws route53 get-hosted-zone --id "$ZID" --query 'DelegationSet.NameServers'
aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate \
  --query 'ResourceRecordSets[].{Name: Name, Type: Type, TTL: TTL}' --output table

echo "== 2. 레코드 만들기: A(api), CNAME(shop), TXT(apex)"
# external-host-ok: example.net 은 RFC 2606 예약 도메인(문서용). CNAME 값으로 저장만 하고 해석·접속하지 않는다
SHOP_TARGET=todayorder-shop.example.net
cat >"$WORK/create.json" <<EOF
{"Comment": "M08 lab01 첫 레코드",
 "Changes": [
  {"Action": "CREATE", "ResourceRecordSet": {"Name": "api.$ZONE", "Type": "A", "TTL": 60,
    "ResourceRecords": [{"Value": "192.0.2.10"}, {"Value": "192.0.2.11"}]}},
  {"Action": "CREATE", "ResourceRecordSet": {"Name": "shop.$ZONE", "Type": "CNAME", "TTL": 300,
    "ResourceRecords": [{"Value": "$SHOP_TARGET"}]}},
  {"Action": "CREATE", "ResourceRecordSet": {"Name": "$ZONE", "Type": "TXT", "TTL": 300,
    "ResourceRecords": [{"Value": "\"v=spf1 -all\""}]}}
 ]}
EOF
CHANGE="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" \
  --change-batch "file://$WORK/create.json" --query ChangeInfo.Id --output text)"
echo "변경 ID: $CHANGE  처음 상태: $(aws route53 get-change --id "$CHANGE" --query ChangeInfo.Status --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE"
change_status="$(aws route53 get-change --id "$CHANGE" --query ChangeInfo.Status --output text)"
echo "대기 후 상태: $change_status"

echo "== 3. 같은 레코드를 CREATE 로 또 만들기 (실패해야 정상) — UPSERT 와의 차이"
set +e
err="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "file://$WORK/create.json" 2>&1 >/dev/null)"
set -e
echo "$err" | grep -m1 'error occurred'

echo "== 4. 영역 꼭대기(apex)에 CNAME 만들기 (실패해야 정상)"
set +e
apex_err="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"$ZONE\", \"Type\": \"CNAME\", \"TTL\": 300,
  \"ResourceRecords\": [{\"Value\": \"d111111abcdef8.cloudfront.net\"}]}}]}" 2>&1 >/dev/null)"
set -e
echo "$apex_err" | grep -m1 'error occurred'

echo "== 5. apex 에는 Alias: CloudFront 배포를 가리키는 A 레코드 (Z2FDTNDATAQYW2 = CloudFront 고정 영역 ID)"
aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"$ZONE\", \"Type\": \"A\",
  \"AliasTarget\": {\"HostedZoneId\": \"Z2FDTNDATAQYW2\", \"DNSName\": \"d111111abcdef8.cloudfront.net\", \"EvaluateTargetHealth\": false}}}]}" \
  --query ChangeInfo.Status --output text
echo "-- www 는 같은 영역의 api 레코드를 가리키는 Alias"
aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"www.$ZONE\", \"Type\": \"A\",
  \"AliasTarget\": {\"HostedZoneId\": \"${ZID#/hostedzone/}\", \"DNSName\": \"api.$ZONE\", \"EvaluateTargetHealth\": false}}}]}" \
  --query ChangeInfo.Status --output text

echo "== 6. Route 53 이 실제로 무엇을 대답하는지: test-dns-answer"
for q in "api A" "shop CNAME" "www A" "@ A" "@ TXT" "nothing A"; do
  set -- $q
  name="$1.$ZONE"; [ "$1" = "@" ] && name="$ZONE"
  aws route53 test-dns-answer --hosted-zone-id "$ZID" --record-name "$name" --record-type "$2" \
    --query '[RecordName, RecordType, ResponseCode, join(`,`, RecordData)]' --output text
done
www_answer="$(aws route53 test-dns-answer --hosted-zone-id "$ZID" --record-name "www.$ZONE" --record-type A --query 'join(`,`, RecordData)' --output text)"
nx_code="$(aws route53 test-dns-answer --hosted-zone-id "$ZID" --record-name "nothing.$ZONE" --record-type A --query ResponseCode --output text)"

echo "== 7. 같은 이름의 프라이빗 호스팅 영역 (VPC 안에서만 보이는 '사내용' 답)"
VPC="$(aws ec2 create-vpc --cidr-block 10.80.0.0/16 --query Vpc.VpcId --output text \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=todayorder-m08-vpc}]')"
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'
PZID="$(aws route53 create-hosted-zone --name "$ZONE" --caller-reference "m08-lab01-private-$(date +%s)-$RANDOM" \
  --vpc VPCRegion=us-east-1,VPCId="$VPC" --hosted-zone-config Comment="TodayOrder internal",PrivateZone=true \
  --query HostedZone.Id --output text)"
aws route53 change-resource-record-sets --hosted-zone-id "$PZID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"api.$ZONE\", \"Type\": \"A\", \"TTL\": 60,
  \"ResourceRecords\": [{\"Value\": \"10.80.1.25\"}]}}]}" >/dev/null
aws route53 list-hosted-zones-by-name --dns-name "$ZONE" \
  --query "HostedZones[?Name=='$ZONE.'].{Id: Id, Private: Config.PrivateZone, Records: ResourceRecordSetCount}" --output table
echo "-- test-dns-answer 는 퍼블릭 영역 전용이다 (실패해야 정상)"
set +e
priv_err="$(aws route53 test-dns-answer --hosted-zone-id "$PZID" --record-name "api.$ZONE" --record-type A 2>&1 >/dev/null)"
set -e
echo "$priv_err" | grep -m1 'error occurred'
private_answer="$(aws route53 list-resource-record-sets --hosted-zone-id "$PZID" --no-paginate \
  --query "ResourceRecordSets[?Name=='api.$ZONE.'].ResourceRecords[].Value" --output text)"
public_answer="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate \
  --query "ResourceRecordSets[?Name=='api.$ZONE.'].ResourceRecords[].Value" --output text | tr '\t' ',')"
echo "api.$ZONE — 퍼블릭 영역: $public_answer / 프라이빗 영역(VPC 안): $private_answer"

echo "== 8. 레코드 삭제 — DELETE 는 현재 값과 정확히 같아야 한다"
aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{
  \"Changes\": [{\"Action\": \"DELETE\", \"ResourceRecordSet\": {\"Name\": \"shop.$ZONE\", \"Type\": \"CNAME\", \"TTL\": 300,
  \"ResourceRecords\": [{\"Value\": \"todayorder-shop.example.net\"}]}}]}" --query ChangeInfo.Status --output text
aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate \
  --query 'ResourceRecordSets[].[Name, Type, TTL || `alias`]' --output text
types="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate --query 'ResourceRecordSets[].Type' --output text | tr '\t' ' ')"

# ---- 단언
assert_eq "$change_status" "INSYNC" "변경 상태"
grep -q 'already exists' <<<"$err" || fail "중복 CREATE 가 거부되지 않음"
grep -q 'InvalidChangeBatch' <<<"$apex_err" || fail "apex CNAME 이 거부되지 않음"
assert_eq "$www_answer" "192.0.2.10,192.0.2.11" "영역 안 Alias 응답"
assert_eq "$nx_code" "NXDOMAIN" "없는 이름의 응답 코드"
assert_eq "$private_answer" "10.80.1.25" "프라이빗 영역 레코드"
grep -q 'private hosted zone' <<<"$priv_err" || fail "프라이빗 영역 test-dns-answer 가 거부되지 않음"
grep -q CNAME <<<"$types" && fail "CNAME 이 삭제되지 않음"
echo "LAB01 OK"
