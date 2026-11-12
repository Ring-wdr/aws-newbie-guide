#!/usr/bin/env bash
# M08 lab02 — 라우팅 정책 8종 레코드와 test-dns-answer (🟢 레코드·단순·가중치·다중값 / 🟡 지연 시간·지리·지리 근접·IP 기반의 응답 선택)
# 장애 조치(failover)는 상태 확인과 함께 lab03 에서 다룬다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ZONE="routing.todayorder.example"
WORK="$TMP_LIB"
delete_zones "$ZONE"

ZID="$(aws route53 create-hosted-zone --name "$ZONE" --caller-reference "m08-lab02-$(date +%s)-$RANDOM" \
  --query HostedZone.Id --output text)"
echo "호스팅 영역: $ZONE ($ZID)"

# 질의 도우미: ask <이름> [test-dns-answer 추가 옵션...] → "RCODE 값1,값2"
ask() {
  aws route53 test-dns-answer --hosted-zone-id "$ZID" --record-name "$1.$ZONE" --record-type A "${@:2}" \
    --query '[ResponseCode, join(`,`, RecordData)]' --output text | tr '\t' ' ' | sed 's/ *$//'
}
change() { aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "file://$1" --query ChangeInfo.Id --output text; }

echo "== 1. 레코드 7종을 한 번에 (장애 조치는 lab03)"
cat >"$WORK/records.json" <<EOF
{"Changes": [
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "simple.$ZONE", "Type": "A", "TTL": 60,
   "ResourceRecords": [{"Value": "192.0.2.10"}, {"Value": "192.0.2.11"}]}},

 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "weighted.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "blue", "Weight": 75, "ResourceRecords": [{"Value": "192.0.2.1"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "weighted.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "green", "Weight": 25, "ResourceRecords": [{"Value": "192.0.2.2"}]}},

 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "latency.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "seoul", "Region": "ap-northeast-2", "ResourceRecords": [{"Value": "198.51.100.1"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "latency.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "virginia", "Region": "us-east-1", "ResourceRecords": [{"Value": "198.51.100.2"}]}},

 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geo.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "korea", "GeoLocation": {"CountryCode": "KR"}, "ResourceRecords": [{"Value": "203.0.113.1"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geo.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "europe", "GeoLocation": {"ContinentCode": "EU"}, "ResourceRecords": [{"Value": "203.0.113.2"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geo.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "default", "GeoLocation": {"CountryCode": "*"}, "ResourceRecords": [{"Value": "203.0.113.9"}]}},

 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geoprox.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "seoul", "GeoProximityLocation": {"AWSRegion": "ap-northeast-2", "Bias": 0},
   "ResourceRecords": [{"Value": "203.0.113.21"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geoprox.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "virginia", "GeoProximityLocation": {"AWSRegion": "us-east-1", "Bias": 50},
   "ResourceRecords": [{"Value": "203.0.113.22"}]}},

 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "multi.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "web-1", "MultiValueAnswer": true, "ResourceRecords": [{"Value": "192.0.2.31"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "multi.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "web-2", "MultiValueAnswer": true, "ResourceRecords": [{"Value": "192.0.2.32"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "multi.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "web-3", "MultiValueAnswer": true, "ResourceRecords": [{"Value": "192.0.2.33"}]}}
]}
EOF
aws route53 wait resource-record-sets-changed --id "$(change "$WORK/records.json")"

echo "== 2. IP 기반 라우팅: CIDR 컬렉션 → 위치 → 레코드"
CID="$(aws route53 create-cidr-collection --name "todayorder-isp-$(date +%s)-$RANDOM" --caller-reference "m08-lab02-$RANDOM" \
  --query Collection.Id --output text)"
echo "CIDR 컬렉션 ID: $CID"
set +e
cidr_err="$(aws route53 change-cidr-collection --id "$CID" \
  --changes '[{"LocationName": "isp-a", "Action": "PUT", "CidrList": ["203.0.113.0/24"]}]' 2>&1 >/dev/null)"
set -e
echo "ChangeCidrCollection → $(grep -m1 -o 'NotImplemented.*' <<<"$cidr_err")"
cat >"$WORK/ip.json" <<EOF
{"Changes": [
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "ipbased.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "isp-a", "CidrRoutingConfig": {"CollectionId": "$CID", "LocationName": "isp-a"},
   "ResourceRecords": [{"Value": "192.0.2.41"}]}},
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "ipbased.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "default", "CidrRoutingConfig": {"CollectionId": "$CID", "LocationName": "*"},
   "ResourceRecords": [{"Value": "192.0.2.49"}]}}
]}
EOF
aws route53 wait resource-record-sets-changed --id "$(change "$WORK/ip.json")"

echo "== 3. 저장된 레코드: 이름별 라우팅 속성"
aws route53 list-resource-record-sets --hosted-zone-id "$ZID" --no-paginate \
  --query "ResourceRecordSets[?SetIdentifier].[Name, SetIdentifier, Weight || Region || GeoLocation.CountryCode || GeoLocation.ContinentCode || GeoProximityLocation.AWSRegion || CidrRoutingConfig.LocationName || \`multi\`, ResourceRecords[0].Value]" \
  --output text

echo "== 4. 단순(simple) — 값 여러 개를 한꺼번에"
simple="$(ask simple)"; echo "simple   → $simple"

echo "== 5. 가중치(weighted) — blue 75 : green 25, 40번 물어보기"
for _ in $(seq 40); do ask weighted; done | sort | uniq -c | tee "$WORK/weighted.txt"
echo "-- green 의 가중치를 0으로 (롤백): 이제 blue 만"
sed 's/"Weight": 25/"Weight": 0/' "$WORK/records.json" >"$WORK/rollback.json"
aws route53 wait resource-record-sets-changed --id "$(change "$WORK/rollback.json")"
for _ in $(seq 10); do ask weighted; done | sort | uniq -c | tee "$WORK/rollback.txt"

echo "== 6. 다중값 응답(multivalue) — 건강한 레코드 여러 개를 함께"
multi="$(ask multi)"; echo "multi    → $multi"

echo "== 7. 지연 시간·지리적 위치·지리 근접·IP 기반 — 질의자 IP 를 바꿔 가며 (에뮬레이터 한계 관찰)"
printf '%-38s %-20s %-20s %-20s %-20s\n' "질의자(resolver / ECS)" latency geo geoprox ipbased
for opt in "" "--resolver-ip 211.234.10.1" "--resolver-ip 3.80.0.1" "--resolver-ip 2.16.0.1" \
  "--edns0-client-subnet-ip 203.0.113.7 --edns0-client-subnet-mask 24"; do
  # shellcheck disable=SC2086
  printf '%-38s %-20s %-20s %-20s %-20s\n' "${opt:-(지정 안 함)}" "$(ask latency $opt)" "$(ask geo $opt)" "$(ask geoprox $opt)" "$(ask ipbased $opt)"
done
geo_kr="$(ask geo --resolver-ip 211.234.10.1)"
lat_us="$(ask latency --resolver-ip 3.80.0.1)"

echo "== 8. 기본(*) 레코드가 없는 지리적 위치 레코드 — 일치하는 위치가 없으면 '빈 응답'"
cat >"$WORK/geo-nodefault.json" <<EOF
{"Changes": [
 {"Action": "UPSERT", "ResourceRecordSet": {"Name": "geo-kr-only.$ZONE", "Type": "A", "TTL": 60,
   "SetIdentifier": "korea", "GeoLocation": {"CountryCode": "KR"}, "ResourceRecords": [{"Value": "203.0.113.1"}]}}
]}
EOF
aws route53 wait resource-record-sets-changed --id "$(change "$WORK/geo-nodefault.json")"
nodefault="$(ask geo-kr-only --resolver-ip 211.234.10.1)"
echo "geo-kr-only → '$nodefault'"

echo "== 9. 정책을 섞으면? 같은 이름·유형에 가중치 + 지연 시간 (실제 AWS는 거부한다)"
set +e
mix_out="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{\"Changes\": [
 {\"Action\": \"CREATE\", \"ResourceRecordSet\": {\"Name\": \"weighted.$ZONE\", \"Type\": \"A\", \"TTL\": 60,
   \"SetIdentifier\": \"tokyo\", \"Region\": \"ap-northeast-1\", \"ResourceRecords\": [{\"Value\": \"192.0.2.3\"}]}}]}" \
   --query ChangeInfo.Status --output text 2>&1)"
set -e
echo "에뮬레이터 응답: $mix_out"
if [ "$mix_out" = "PENDING" ]; then
  echo "→ 에뮬레이터는 받아 준다(AWS와 다름). 정리를 위해 방금 만든 레코드를 지운다."
  aws route53 change-resource-record-sets --hosted-zone-id "$ZID" --change-batch "{\"Changes\": [
   {\"Action\": \"DELETE\", \"ResourceRecordSet\": {\"Name\": \"weighted.$ZONE\", \"Type\": \"A\", \"TTL\": 60,
     \"SetIdentifier\": \"tokyo\", \"Region\": \"ap-northeast-1\", \"ResourceRecords\": [{\"Value\": \"192.0.2.3\"}]}}]}" >/dev/null
fi

# ---- 단언
assert_eq "$simple" "NOERROR 192.0.2.10,192.0.2.11" "단순 레코드"
grep -q '192.0.2.1$' "$WORK/weighted.txt" || fail "가중치: blue 가 한 번도 안 나옴"
grep -q '192.0.2.2$' "$WORK/weighted.txt" || fail "가중치: green 이 한 번도 안 나옴 (75:25, 40회)"
grep -q '192.0.2.2$' "$WORK/rollback.txt" && fail "가중치 0 인 green 이 응답됨"
assert_eq "$multi" "NOERROR 192.0.2.31,192.0.2.32,192.0.2.33" "다중값 응답"
assert_eq "$nodefault" "NOERROR" "기본 레코드 없는 지리적 위치(빈 응답)"
case "$geo_kr" in "NOERROR 203.0.113."*) ;; *) fail "지리적 위치 레코드 응답 없음: $geo_kr" ;; esac
case "$lat_us" in "NOERROR 198.51.100."*) ;; *) fail "지연 시간 레코드 응답 없음: $lat_us" ;; esac
grep -q 'NotImplemented' <<<"$cidr_err" || echo "참고: ChangeCidrCollection 이 이제 구현됨 — README 의 제약 표를 갱신할 것"
echo "LAB02 OK"
