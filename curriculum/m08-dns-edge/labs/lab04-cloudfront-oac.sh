#!/usr/bin/env bash
# M08 lab04 — CloudFront 배포 + S3 오리진 + OAC (🟡)
# 비공개 S3 버킷 → OAC → 배포(캐시 정책·HTTPS 리디렉션) → 버킷 정책(배포 ARN 조건) → 무효화 → CloudFront Functions
# 배포의 DomainName 은 *.cloudfront.net 이 아니라 컨테이너 안 주소(127.0.0.1:<임의 포트>)다.
# 배포에 실제로 GET 을 보내 보는 부분(5·6단계)은 docker exec 로 컨테이너 안에서만 가능한 선택 과제다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

BUCKET="todayorder-m08-static"
COMMENT="todayorder-m08-lab04"
OAC_NAME="todayorder-m08-oac"
FN_NAME="todayorder-m08-security-headers"
CONTAINER="aws-emulator-$EMULATOR_PORT"
WORK="$TMP_LIB"
CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6" # 관리형 캐시 정책 Managed-CachingOptimized (AWS 공통 ID)

# ---- 이전 실행 정리 (멱등): 배포는 "비활성화 → 배포 완료 대기 → 삭제" 순서여야 지워진다
for id in $(aws cloudfront list-distributions --output json | py '
for d in (json.loads(sys.stdin.read() or "{}").get("DistributionList", {}).get("Items") or []):
    if d["Comment"] == sys.argv[1]:
        print(d["Id"])' "$COMMENT"); do
  aws cloudfront get-distribution-config --id "$id" --output json >"$WORK/old.json"
  etag="$(py 'print(json.load(sys.stdin)["ETag"])' <"$WORK/old.json")"
  if [ "$(py 'print(json.load(sys.stdin)["DistributionConfig"]["Enabled"])' <"$WORK/old.json")" = "True" ]; then
    py 'c = json.load(sys.stdin)["DistributionConfig"]; c["Enabled"] = False; print(json.dumps(c))' <"$WORK/old.json" >"$WORK/disabled.json"
    etag="$(aws cloudfront update-distribution --id "$id" --if-match "$etag" --distribution-config "file://$WORK/disabled.json" --query ETag --output text)"
  fi
  aws cloudfront wait distribution-deployed --id "$id"
  aws cloudfront delete-distribution --id "$id" --if-match "$etag"
done
for id in $(aws cloudfront list-origin-access-controls --output json | py '
for o in (json.loads(sys.stdin.read() or "{}").get("OriginAccessControlList", {}).get("Items") or []):
    if o["Name"] == sys.argv[1]:
        print(o["Id"])' "$OAC_NAME"); do
  aws cloudfront delete-origin-access-control --id "$id" --if-match "$(aws cloudfront get-origin-access-control --id "$id" --query ETag --output text)"
done
if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
  aws cloudfront delete-function --name "$FN_NAME" --if-match "$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
fi
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true

echo "== 1. 비공개 S3 버킷과 정적 파일"
aws s3 mb "s3://$BUCKET"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
printf '<h1>TodayOrder</h1>\n' >"$WORK/index.html"
aws s3 cp "$WORK/index.html" "s3://$BUCKET/index.html" --content-type text/html --no-progress >/dev/null
echo "업로드: s3://$BUCKET/index.html"

echo "== 2. OAC(Origin Access Control) 만들기 — CloudFront 가 S3 요청에 SigV4 로 서명하게 한다"
OAC="$(aws cloudfront create-origin-access-control --origin-access-control-config \
  Name="$OAC_NAME",SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
  --query OriginAccessControl.Id --output text)"
aws cloudfront get-origin-access-control --id "$OAC" --query 'OriginAccessControl.OriginAccessControlConfig'

echo "== 3. 배포 만들기"
# external-host-ok: 아래 원본 DomainName(<버킷>.s3.us-east-1.amazonaws.com)은 에뮬레이터가 이름 해석 없이 내부에서 S3 버킷으로 매핑한다(docs/FIDELITY.md 환경 메모)
cat >"$WORK/dist.json" <<EOF
{
  "CallerReference": "m08-lab04-$(date +%s)-$RANDOM",
  "Comment": "$COMMENT",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_200",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "s3-static",
    "DomainName": "$BUCKET.s3.us-east-1.amazonaws.com",
    "OriginAccessControlId": "$OAC",
    "S3OriginConfig": {"OriginAccessIdentity": ""}
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-static",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "$CACHING_OPTIMIZED",
    "Compress": true
  }
}
EOF
aws cloudfront create-distribution --distribution-config "file://$WORK/dist.json" \
  --query 'Distribution.{Id: Id, Status: Status, DomainName: DomainName, ARN: ARN}' --output json | tee "$WORK/created.json"
DIST="$(py 'print(json.load(sys.stdin)["Id"])' <"$WORK/created.json")"
DOMAIN="$(py 'print(json.load(sys.stdin)["DomainName"])' <"$WORK/created.json")"
DIST_ARN="arn:aws:cloudfront::000000000000:distribution/$DIST"
aws cloudfront wait distribution-deployed --id "$DIST"
status="$(aws cloudfront get-distribution --id "$DIST" --query Distribution.Status --output text)"
echo "대기 후 상태: $status  ·  DomainName: $DOMAIN  (실제 AWS라면 dxxxxxxxxxxxxx.cloudfront.net)"
aws cloudfront get-distribution-config --id "$DIST" \
  --query 'DistributionConfig.{Root: DefaultRootObject, Viewer: DefaultCacheBehavior.ViewerProtocolPolicy, CachePolicy: DefaultCacheBehavior.CachePolicyId, OAC: Origins.Items[0].OriginAccessControlId, PriceClass: PriceClass}'

# 컨테이너 안에서 배포 주소로 GET (선택 과제). docker 를 쓸 수 없으면 건너뛴다.
cf_get() { docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' "http://$DOMAIN$1"; }
can_exec=false
if docker exec "$CONTAINER" true >/dev/null 2>&1; then can_exec=true; fi
# 에뮬레이터가 돌려준 주소가 루프백일 때만 접속한다(바깥 호스트일 수 있으면 관찰을 건너뛴다)
# (정확히 127.0.0.1 또는 127.0.0.1:<포트> 만. 127.0.0.1.<도메인> 같은 이름은 DNS 를 거치므로 거부)
[[ "$DOMAIN" =~ ^127\.0\.0\.1(:[0-9]+)?$ ]] || { echo "참고: DomainName 이 루프백이 아니다($DOMAIN) — 접속하지 않는다"; can_exec=false; }

echo "== 4. 버킷 정책 없이 배포로 GET (선택 과제: docker exec)"
code_before="SKIP"
if $can_exec; then code_before="$(cf_get /index.html)"; echo "HTTP $code_before"; else echo "SKIP(docker exec 불가)"; fi

echo "== 5. OAC 용 버킷 정책: cloudfront.amazonaws.com 에게, 이 배포(AWS:SourceArn)에서 온 GetObject 만 허용"
cat >"$WORK/policy.json" <<EOF
{"Version": "2012-10-17", "Statement": [{
  "Sid": "AllowCloudFrontServicePrincipalReadOnly",
  "Effect": "Allow",
  "Principal": {"Service": "cloudfront.amazonaws.com"},
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::$BUCKET/*",
  "Condition": {"StringEquals": {"AWS:SourceArn": "$DIST_ARN"}}
}]}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$WORK/policy.json"
aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text | py 'print(json.loads(sys.stdin.read())["Statement"][0]["Condition"])'

code_after="SKIP"; cache1=""; cache2=""
if $can_exec; then
  hdr() { docker exec "$CONTAINER" curl -s -D - -o /dev/null "http://$DOMAIN/index.html" | tr -d '\r'; }
  first="$(hdr)"; second="$(hdr)"
  code_after="$(head -1 <<<"$first" | awk '{print $2}')"
  cache1="$(grep -i '^x-cache' <<<"$first")"; cache2="$(grep -i '^x-cache' <<<"$second")"
  echo "배포로 GET /index.html → HTTP $code_after"
  echo "첫 요청 [$cache1] → 두 번째 요청 [$cache2]"
fi
echo "-- 버킷에 직접 익명 요청 (호스트에서): S3 는 여전히 비공개"
direct="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$AWS_CA_BUNDLE" "$AWS_ENDPOINT_URL/$BUCKET/index.html")"
echo "HTTP $direct"

echo "== 6. 무효화(invalidation) — 엣지 캐시에서 /index.html 을 지운다"
INV="$(aws cloudfront create-invalidation --distribution-id "$DIST" --paths /index.html --query Invalidation.Id --output text)"
aws cloudfront wait invalidation-completed --distribution-id "$DIST" --id "$INV"
inv_status="$(aws cloudfront get-invalidation --distribution-id "$DIST" --id "$INV" --query Invalidation.Status --output text)"
echo "무효화 $INV: $inv_status"

echo "== 7. CloudFront Functions — 만들기는 되지만 TestFunction 은 501"
printf 'function handler(event) {\n  var r = event.response;\n  r.headers["strict-transport-security"] = {value: "max-age=63072000"};\n  return r;\n}\n' >"$WORK/fn.js"
aws cloudfront create-function --name "$FN_NAME" --function-config Comment="HSTS header",Runtime=cloudfront-js-2.0 \
  --function-code "fileb://$WORK/fn.js" --query 'FunctionSummary.[Name, Status, FunctionConfig.Runtime]' --output text
set +e
test_err="$(aws cloudfront test-function --name "$FN_NAME" --if-match "$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)" \
  --event-object fileb://<(printf '{"version":"1.0","context":{"eventType":"viewer-response"},"viewer":{"ip":"192.0.2.1"},"request":{"method":"GET","uri":"/","headers":{}},"response":{"statusCode":200,"headers":{}}}') 2>&1 >/dev/null)"
set -e
echo "$test_err" | grep -m1 'error occurred'

# ---- 단언
assert_eq "$status" "Deployed" "배포 상태"
case "$DOMAIN" in *.cloudfront.net) echo "참고: DomainName 이 cloudfront.net 으로 바뀌었다 — README 갱신" ;; esac
assert_eq "$direct" "403" "버킷 직접 익명 접근"
assert_eq "$inv_status" "Completed" "무효화 상태"
grep -q NotImplemented <<<"$test_err" || echo "참고: TestFunction 이 이제 구현됨 — README 갱신"
if $can_exec; then
  assert_eq "$code_before" "403" "버킷 정책 없는 OAC 요청"
  assert_eq "$code_after" "200" "버킷 정책 추가 후 OAC 요청"
  assert_eq "$cache1" "x-cache: Miss from cloudfront" "첫 요청은 캐시 미스"
  assert_eq "$cache2" "x-cache: Hit from cloudfront" "두 번째 요청은 캐시 적중"
fi
echo "LAB04 OK"
