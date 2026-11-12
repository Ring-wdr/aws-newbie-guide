#!/usr/bin/env bash
# M09 lab06 — ACM 인증서 (🟢 가져오기 · 🟡 DNS 검증 요청과 검증 레코드 · 🔴 발급)
# ① openssl 로 만든 자체 서명 인증서를 ACM 으로 가져오면 바로 ISSUED(IMPORTED)
# ② ACM 에 공인 인증서를 요청(DNS 검증)하면 검증용 CNAME 을 알려 준다 → Route 53 에 넣어도
#    에뮬레이터는 실제 DNS 검증을 하지 않으므로 PENDING_VALIDATION 에서 멈춘다(실제 AWS는 보통 수 분 안에 ISSUED)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

# 예약 이름만 쓴다(RFC 2606). 에뮬레이터는 .example/.test/.local/.invalid 최상위 도메인을 곧바로 FAILED 처리하지만
# example.com 아래 이름은 PENDING_VALIDATION 에 머문다.
DOMAIN="todayorder.example.com"
INTERNAL="api.todayorder.internal"
WORK="$TMP_LIB"
cd "$WORK"
command -v openssl >/dev/null || fail "openssl 이 필요합니다"

# ---- 이전 실행 정리 (멱등): 이 lab 의 인증서와 호스팅 영역
for arn in $(aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION FAILED --output json | py '
for c in json.loads(sys.stdin.read() or "{}").get("CertificateSummaryList", []):
    if c["DomainName"] in sys.argv[1:]:
        print(c["CertificateArn"])' "$INTERNAL" "api.$DOMAIN" "api.todayorder.example"); do
  aws acm delete-certificate --certificate-arn "$arn"
done
for zid in $(aws route53 list-hosted-zones --output json | py '
for z in json.loads(sys.stdin.read() or "{}").get("HostedZones", []):
    if z["Name"] == sys.argv[1]:
        print(z["Id"])' "$DOMAIN."); do
  aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json | py '
rrs = [r for r in json.load(sys.stdin)["ResourceRecordSets"] if r["Type"] not in ("NS", "SOA")]
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in rrs]}))' >del.json
  grep -q '"Changes": \[\]' del.json || aws route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch file://del.json >/dev/null
  aws route53 delete-hosted-zone --id "$zid" >/dev/null
done

echo "== 1. openssl 로 자체 서명 인증서 만들기 (사내 관리 API 용, 30일)"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 \
  -subj "/CN=$INTERNAL" -addext "subjectAltName=DNS:$INTERNAL" 2>/dev/null
openssl x509 -in cert.pem -noout -subject -issuer -enddate

echo "== 2. ACM 으로 가져오기(import)"
IMPORTED="$(aws acm import-certificate --certificate fileb://cert.pem --private-key fileb://key.pem \
  --tags Key=app,Value=todayorder --query CertificateArn --output text)"
aws acm describe-certificate --certificate-arn "$IMPORTED" \
  --query 'Certificate.{Domain: DomainName, Type: Type, Status: Status, KeyAlgorithm: KeyAlgorithm, RenewalEligibility: RenewalEligibility, InUseBy: InUseBy}'
imported_status="$(aws acm describe-certificate --certificate-arn "$IMPORTED" --query Certificate.Status --output text)"
imported_renew="$(aws acm describe-certificate --certificate-arn "$IMPORTED" --query Certificate.RenewalEligibility --output text)"
echo "-- 가져온 인증서는 개인 키를 내보낼 수 없다(내보내기는 내보내기 가능 옵션으로 발급한 인증서만)"
expect_error export_err aws acm export-certificate --certificate-arn "$IMPORTED" --passphrase fileb://<(printf 'pass1234')
echo "$export_err" | grep -m1 -o 'ValidationException.*'

echo "== 3. 공인 인증서 요청 — DNS 검증 (api.$DOMAIN)"
ZID="$(aws route53 create-hosted-zone --name "$DOMAIN" --caller-reference "m09-lab06-$(date +%s)-$RANDOM" --query HostedZone.Id --output text)"
REQ="$(aws acm request-certificate --domain-name "api.$DOMAIN" --validation-method DNS --key-algorithm RSA_2048 \
  --query CertificateArn --output text)"
poll 60 "검증 레코드 제공" sh -c "aws acm describe-certificate --certificate-arn '$REQ' --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text | grep -q '^_'"
aws acm describe-certificate --certificate-arn "$REQ" \
  --query 'Certificate.{Status: Status, Type: Type, Validation: DomainValidationOptions[0].{Method: ValidationMethod, Status: ValidationStatus, Record: ResourceRecord}}'

echo "== 4. 검증 CNAME 을 Route 53 에 넣는다 (실제 AWS라면 이걸로 발급·자동 갱신이 된다)"
aws acm describe-certificate --certificate-arn "$REQ" --output json \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' | py '
r = json.load(sys.stdin)
print(json.dumps({"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {"Name": r["Name"], "Type": r["Type"], "TTL": 300,
  "ResourceRecords": [{"Value": r["Value"]}]}}]}))' >cname.json
aws route53 wait resource-record-sets-changed --id "$(aws route53 change-resource-record-sets --hosted-zone-id "$ZID" \
  --change-batch file://cname.json --query ChangeInfo.Id --output text)"
echo "CNAME 반영됨(INSYNC). 20초 동안 상태를 지켜본다:"
seen=""
for _ in $(seq 4); do
  s="$(aws acm describe-certificate --certificate-arn "$REQ" --query Certificate.Status --output text)"
  seen="$seen $s"
  [ "$s" = ISSUED ] && break
  sleep 5
done
echo "관찰한 상태:$seen"
requested_status="$(aws acm describe-certificate --certificate-arn "$REQ" --query Certificate.Status --output text)"

echo "== 5. .example 최상위 도메인으로 요청하면 에뮬레이터는 곧 FAILED 로 바꾼다"
BAD="$(aws acm request-certificate --domain-name api.todayorder.example --validation-method DNS --query CertificateArn --output text)"
poll 60 ".example 최상위 도메인 FAILED" sh -c "aws acm describe-certificate --certificate-arn '$BAD' --query Certificate.Status --output text | grep -qx FAILED"
aws acm describe-certificate --certificate-arn "$BAD" --query 'Certificate.[Status, FailureReason]' --output text

echo "== 6. 목록"
aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION FAILED \
  --query 'CertificateSummaryList[].[DomainName, Status, Type]' --output text

# ---- 단언
assert_eq "$imported_status" "ISSUED" "가져온 인증서 상태"
assert_eq "$imported_renew" "INELIGIBLE" "가져온 인증서는 ACM 자동 갱신 대상이 아님"
grep -q 'not an export enabled certificate' <<<"$export_err" || fail "가져온 인증서 내보내기가 거부되지 않음"
if [ "$requested_status" = "ISSUED" ]; then
  echo "참고: DNS 검증 인증서가 ISSUED 가 됐다 — 에뮬레이터가 바뀌었다. README 의 등급을 갱신할 것"
else
  assert_eq "$requested_status" "PENDING_VALIDATION" "DNS 검증 요청 인증서 상태"
fi
echo "LAB06 OK"
