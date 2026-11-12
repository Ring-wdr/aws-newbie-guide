#!/usr/bin/env bash
# M09 lab07 — CloudTrail 추적: 버킷 정책 → 추적 생성·로깅 → IAM 이벤트를 LookupEvents 와 S3 로그 파일에서 찾기 (🟡)
# 에뮬레이터 차이: LookupEvents(이벤트 기록)에 IAM 이벤트는 나오지만 S3·KMS 같은 다른 서비스 이벤트는 안 나온다.
# 그래서 이 lab 의 단언은 IAM 이벤트로 한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

TRAIL="todayorder-m09-trail"
BUCKET="todayorder-m09-trail-logs"
SUSPECT="todayorder-m09-suspicious-user"
PROBE_BUCKET="todayorder-m09-trail-probe"
TRAIL_ARN="arn:aws:cloudtrail:us-east-1:000000000000:trail/$TRAIL"
WORK="$TMP_LIB"
cd "$WORK"

# ---- 이전 실행 정리 (멱등)
aws cloudtrail delete-trail --name "$TRAIL" >/dev/null 2>&1 || true
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
aws s3 rb "s3://$PROBE_BUCKET" --force >/dev/null 2>&1 || true
delete_iam_user "$SUSPECT"

echo "== 1. 로그 버킷 — 정책 없이 추적을 만들면? (실패해야 정상)"
aws s3 mb "s3://$BUCKET" >/dev/null
expect_error nopolicy_err aws cloudtrail create-trail --name "$TRAIL" --s3-bucket-name "$BUCKET"
echo "$nopolicy_err" | grep -m1 'error occurred'

echo "== 2. CloudTrail 이 이 추적에서만 쓰도록 허용하는 버킷 정책"
cat >policy.json <<EOF
{"Version": "2012-10-17", "Statement": [
  {"Sid": "AWSCloudTrailAclCheck", "Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"},
   "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::$BUCKET",
   "Condition": {"StringEquals": {"aws:SourceArn": "$TRAIL_ARN"}}},
  {"Sid": "AWSCloudTrailWrite", "Effect": "Allow", "Principal": {"Service": "cloudtrail.amazonaws.com"},
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::$BUCKET/AWSLogs/000000000000/*",
   "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control", "aws:SourceArn": "$TRAIL_ARN"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://policy.json

echo "== 3. 멀티 리전 추적 + 로그 파일 무결성 검증 → 로깅 시작"
aws cloudtrail create-trail --name "$TRAIL" --s3-bucket-name "$BUCKET" --is-multi-region-trail \
  --enable-log-file-validation --include-global-service-events \
  --query '{Name: Name, MultiRegion: IsMultiRegionTrail, Validation: LogFileValidationEnabled, Global: IncludeGlobalServiceEvents}'
aws cloudtrail start-logging --name "$TRAIL"
logging="$(aws cloudtrail get-trail-status --name "$TRAIL" --query IsLogging --output text)"
echo "IsLogging: $logging"
echo "-- 관리 이벤트(기본) + 특정 버킷의 S3 데이터 이벤트(객체 단위, 별도 과금)를 기록"
aws cloudtrail put-event-selectors --trail-name "$TRAIL" --event-selectors "[{
  \"ReadWriteType\": \"All\", \"IncludeManagementEvents\": true,
  \"DataResources\": [{\"Type\": \"AWS::S3::Object\", \"Values\": [\"arn:aws:s3:::todayorder-receipts/\"]}]}]" \
  --query 'EventSelectors[0].{Mgmt: IncludeManagementEvents, Data: DataResources[0].Values}'

echo "== 4. 수상한 일 저지르기: 누군가 사용자를 만들고 관리자 권한을 붙인다 + 버킷도 하나 만든다"
aws iam create-user --user-name "$SUSPECT" --query User.Arn --output text
aws iam attach-user-policy --user-name "$SUSPECT" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws s3 mb "s3://$PROBE_BUCKET" >/dev/null

echo "== 5. LookupEvents(이벤트 기록, 최근 90일 관리 이벤트) 에서 찾기"
find_events() {
  aws cloudtrail lookup-events --lookup-attributes "AttributeKey=$1,AttributeValue=$2" --max-results 20 --output json | py '
for e in json.load(sys.stdin)["Events"]:
    ev = json.loads(e["CloudTrailEvent"])
    req = ev.get("requestParameters") or {}
    print(e["EventName"], e["EventSource"], e.get("Username", "-"), req.get("userName") or req.get("bucketName") or "-", sep="\t")'
}
poll 60 "CreateUser 이벤트" sh -c "aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateUser --max-results 50 --query 'Events[].CloudTrailEvent' --output text | grep -q '$SUSPECT'"
echo "-- EventName=CreateUser"
find_events EventName CreateUser | grep "$SUSPECT" | tee create.txt
echo "-- EventName=AttachUserPolicy"
find_events EventName AttachUserPolicy | grep "$SUSPECT" | tee attach.txt
echo "-- EventName=CreateBucket (에뮬레이터는 S3 이벤트를 이벤트 기록에 남기지 않는다)"
find_events EventName CreateBucket | tee bucket.txt
[ -s bucket.txt ] || echo "(없음)"
echo "-- 이벤트 원본 JSON 의 핵심 필드"
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AttachUserPolicy --max-results 20 --output json | py '
for e in json.load(sys.stdin)["Events"]:
    ev = json.loads(e["CloudTrailEvent"])
    if (ev.get("requestParameters") or {}).get("userName") == sys.argv[1]:
        keep = {k: ev.get(k) for k in ("eventTime", "eventSource", "eventName", "awsRegion", "sourceIPAddress", "userIdentity", "requestParameters")}
        keep["userIdentity"] = {k: keep["userIdentity"].get(k) for k in ("type", "arn")}
        print(json.dumps(keep, ensure_ascii=False, indent=2)); break' "$SUSPECT"

echo "== 6. 추적은 같은 이벤트를 S3 에 gzip JSON 파일로 남긴다 (장기 보관·Athena 분석용)"
poll 60 "로그 파일" sh -c "aws s3api list-objects-v2 --bucket '$BUCKET' --prefix AWSLogs/000000000000/CloudTrail/ --query 'length(Contents)' --output text | grep -qv '^0$\\|None'"
aws s3 cp "s3://$BUCKET/AWSLogs/" logs/ --recursive --no-progress >/dev/null
find logs -name '*.json.gz' | head -1 | sed 's#^logs/#AWSLogs/#'
in_files="$(for f in $(find logs -name '*.json.gz'); do gzip -dc "$f"; echo; done | py '
n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    for r in json.loads(line).get("Records", []):
        if (r.get("requestParameters") or {}).get("userName") == sys.argv[1]:
            n += 1
print(n)' "$SUSPECT")"
echo "로그 파일 안에서 $SUSPECT 관련 레코드: ${in_files}건"

echo "== 7. 정리: 로깅 중지 → 추적 삭제 (버킷의 로그 파일은 남는다)"
aws cloudtrail stop-logging --name "$TRAIL"
aws cloudtrail delete-trail --name "$TRAIL"
delete_iam_user "$SUSPECT"

# ---- 단언
grep -q InsufficientS3BucketPolicyException <<<"$nopolicy_err" || fail "정책 없는 버킷으로 추적이 만들어짐: $nopolicy_err"
assert_eq "$logging" "True" "로깅 상태"
grep -q "CreateUser.*iam.amazonaws.com" create.txt || fail "CreateUser 이벤트가 없음"
grep -q "AttachUserPolicy" attach.txt || fail "AttachUserPolicy 이벤트가 없음"
[ "$in_files" -ge 1 ] || fail "S3 로그 파일에 IAM 이벤트가 없음"
if [ -s bucket.txt ]; then echo "참고: CreateBucket 이 이벤트 기록에 나타났다 — 에뮬레이터가 바뀌었다. README 갱신"; fi
echo "LAB07 OK"
