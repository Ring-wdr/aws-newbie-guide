#!/usr/bin/env bash
# M04 lab02 — 스토리지 클래스와 수명 주기 규칙 (🟢 구성 · 전환 자체는 일어나지 않음)
# 1) 클래스를 지정해 올리기 → 2) Glacier 객체는 복원 전엔 못 읽는다 → 3) 복원 요청·완료 폴링
# 4) 영수증 버킷 수명 주기 규칙 구성 → 5) AWS라면 거부될 규칙을 에뮬레이터는 받아 준다 / 일부는 거부한다
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

BUCKET="todayorder-m04-receipts-lc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
aws s3api create-bucket --bucket "$BUCKET" >/dev/null

echo "== 1. 스토리지 클래스를 지정해 올리기"
printf '{"orderId":"A-0001","total":12000}' >r.json
for cls in STANDARD STANDARD_IA ONEZONE_IA INTELLIGENT_TIERING GLACIER_IR GLACIER DEEP_ARCHIVE; do
  aws s3api put-object --bucket "$BUCKET" --key "receipts/$cls.json" --body r.json --storage-class "$cls" >/dev/null
done
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].[Key, StorageClass]' --output text

echo "== 2. 범용 버킷에 EXPRESS_ONEZONE? (디렉터리 버킷 전용 클래스)"
set +e
express="$(aws s3api put-object --bucket "$BUCKET" --key receipts/x.json --body r.json --storage-class EXPRESS_ONEZONE 2>&1 >/dev/null)"
set -e
echo "$express"

echo "== 3. Glacier Instant Retrieval 은 바로 읽힌다"
aws s3api get-object --bucket "$BUCKET" --key receipts/GLACIER_IR.json out-ir.json --query StorageClass --output text

echo "== 4. Glacier Flexible Retrieval 은 복원 전에는 못 읽는다"
set +e
glacier_get="$(aws s3api get-object --bucket "$BUCKET" --key receipts/GLACIER.json out-g.json 2>&1 >/dev/null)"
set -e
echo "$glacier_get"

echo "== 5. Deep Archive 에 Expedited(신속) 복원 요청 → 지원하지 않는 검색 옵션"
set +e
deep_exp="$(aws s3api restore-object --bucket "$BUCKET" --key receipts/DEEP_ARCHIVE.json \
  --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"Expedited"}}' 2>&1 >/dev/null)"
set -e
echo "$deep_exp"

echo "== 6. Glacier 객체 복원 요청 (Standard 등급, 임시 사본 1일)"
aws s3api restore-object --bucket "$BUCKET" --key receipts/GLACIER.json \
  --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"Standard"}}'
aws s3api head-object --bucket "$BUCKET" --key receipts/GLACIER.json --query '{Class: StorageClass, Restore: Restore}' --output json

echo "== 7. 복원 완료(ongoing-request=\"false\")까지 폴링 (최대 120초)"
restore=""
for _ in $(seq 1 60); do
  restore="$(aws s3api head-object --bucket "$BUCKET" --key receipts/GLACIER.json --query Restore --output text)"
  case "$restore" in *'ongoing-request="false"'*) break ;; esac
  sleep 2
done
echo "Restore: $restore"
aws s3api get-object --bucket "$BUCKET" --key receipts/GLACIER.json out-g.json --query StorageClass --output text
cmp r.json out-g.json && echo "복원된 사본을 읽었습니다 (클래스는 여전히 GLACIER)"

echo "== 8. 영수증 버킷 수명 주기 규칙 (30일 IA → 90일 Glacier IR → 365일 Deep Archive → 7년 후 삭제)"
cat >lifecycle.json <<'JSON'
{
  "Rules": [
    {
      "ID": "receipts-tiering",
      "Status": "Enabled",
      "Filter": { "Prefix": "receipts/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER_IR" },
        { "Days": 365, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 2555 }
    },
    {
      "ID": "tmp-cleanup",
      "Status": "Enabled",
      "Filter": { "Prefix": "tmp/" },
      "Expiration": { "Days": 1 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
JSON
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration file://lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID: ID, Prefix: Filter.Prefix, Transitions: Transitions[].[Days, StorageClass], ExpireDays: Expiration.Days}' --output json
rules_ok="$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'length(Rules)' --output text)"

echo "== 9. 규칙이 있어도 객체의 클래스는 그대로 (전환은 시간이 지나야 일어나는데, 에뮬레이터는 전환을 하지 않는다)"
std_class="$(aws s3api head-object --bucket "$BUCKET" --key receipts/STANDARD.json --query StorageClass --output text)"
echo "receipts/STANDARD.json StorageClass=$std_class"

echo "== 10. AWS라면 거부될 규칙: STANDARD_IA 로 10일 만에 전환 (AWS 최소 30일)"
set +e
bad_ia="$(aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"bad-ia-10d","Status":"Enabled","Filter":{"Prefix":"receipts/"},"Transitions":[{"Days":10,"StorageClass":"STANDARD_IA"}]}]}' 2>&1)"
bad_ia_rc=$?
set -e
echo "rc=$bad_ia_rc $bad_ia"

echo "== 11. 에뮬레이터도 거부하는 규칙: 전환 순서가 거꾸로 (GLACIER 30일 → STANDARD_IA 60일)"
set +e
reverse="$(aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"reverse","Status":"Enabled","Filter":{"Prefix":"receipts/"},"Transitions":[{"Days":30,"StorageClass":"GLACIER"},{"Days":60,"StorageClass":"STANDARD_IA"}]}]}' 2>&1 >/dev/null)"
set -e
echo "$reverse"

echo "== 12. 정리"
aws s3api delete-bucket-lifecycle --bucket "$BUCKET"
aws s3 rb "s3://$BUCKET" --force >/dev/null

# ---- 단언
case "$express" in *InvalidStorageClass*) ;; *) echo "FAIL: EXPRESS_ONEZONE 이 범용 버킷에 들어감"; exit 1 ;; esac
case "$glacier_get" in *InvalidObjectState*) ;; *) echo "FAIL: 복원 전 GLACIER 읽기가 거부되지 않음"; exit 1 ;; esac
case "$deep_exp" in *InvalidTier*) ;; *) echo "FAIL: Deep Archive Expedited 가 거부되지 않음"; exit 1 ;; esac
case "$restore" in *'ongoing-request="false"'*) ;; *) echo "FAIL: 120초 안에 복원이 끝나지 않음 (마지막 관찰: $restore)"; exit 1 ;; esac
[ "$rules_ok" = "2" ] || { echo "FAIL: 수명 주기 규칙 수 ($rules_ok)"; exit 1; }
[ "$std_class" = "None" ] || [ "$std_class" = "STANDARD" ] || { echo "FAIL: 클래스가 바뀜 ($std_class)"; exit 1; }
# 10일 IA 규칙: 에뮬레이터 1.0.322 는 받아 준다(AWS는 InvalidArgument). 거부하기 시작하면 문서를 갱신해야 한다.
[ "$bad_ia_rc" -eq 0 ] || { echo "FAIL: 에뮬레이터가 10일 IA 규칙을 거부하기 시작함 → 레슨 2 갱신 필요"; exit 1; }
case "$reverse" in *InvalidArgument*) ;; *) echo "FAIL: 거꾸로 된 전환이 거부되지 않음"; exit 1 ;; esac
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then echo "FAIL: 버킷이 남아 있음"; exit 1; fi
echo "LAB02 OK"
