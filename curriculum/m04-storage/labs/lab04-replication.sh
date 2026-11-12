#!/usr/bin/env bash
# M04 lab04 — 복제(Replication): 원본 버킷의 새 객체가 대상 버킷에 실제로 복사된다 (🟢)
# 1) 두 버킷 모두 버전 관리 → 2) S3가 맡을 복제 역할(신뢰 정책 + 권한) → 3) 복제 규칙(접두사 필터, 대상 클래스)
# 4) 기존 객체는 복제 안 됨 / 새 객체는 복제됨 / 필터 밖은 안 됨 → 5) 삭제 마커 복제는 기본 꺼짐
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

SRC="todayorder-m04-images-seoul"
DST="todayorder-m04-images-dr"
ROLE="todayorder-m04-s3-replication"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

purge_bucket "$SRC"
purge_bucket "$DST"
aws iam delete-role-policy --role-name "$ROLE" --policy-name replicate >/dev/null 2>&1 || true
aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true

# wait_for_key <버킷> <키> : 최대 60초 폴링
wait_for_key() {
  for _ in $(seq 1 30); do
    aws s3api head-object --bucket "$1" --key "$2" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "FAIL: 60초 안에 s3://$1/$2 가 나타나지 않음"
  aws s3api list-objects-v2 --bucket "$1" --output json
  return 1
}

echo "== 1. 원본·대상 버킷 (둘 다 버전 관리 필수)"
for b in "$SRC" "$DST"; do
  aws s3api create-bucket --bucket "$b" >/dev/null
  aws s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled
done
echo "-- 복제 규칙을 걸기 전에 올린 기존 객체"
printf 'old-image' >old.jpg
aws s3api put-object --bucket "$SRC" --key images/old.jpg --body old.jpg >/dev/null

echo "== 2. S3가 맡을 복제 역할 (신뢰 정책: s3.amazonaws.com)"
cat >trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
cat >perm.json <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:GetReplicationConfiguration","s3:ListBucket"],"Resource":"arn:aws:s3:::$SRC"},
  {"Effect":"Allow","Action":["s3:GetObjectVersionForReplication","s3:GetObjectVersionAcl","s3:GetObjectVersionTagging"],"Resource":"arn:aws:s3:::$SRC/*"},
  {"Effect":"Allow","Action":["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags"],"Resource":"arn:aws:s3:::$DST/*"}
]}
JSON
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://trust.json --query Role.Arn --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name replicate --policy-document file://perm.json
echo "$ROLE_ARN"

echo "== 3. 복제 규칙: images/ 만, 대상에서는 STANDARD_IA 로 (DR 사본은 덜 읽으니까)"
cat >repl.json <<JSON
{
  "Role": "$ROLE_ARN",
  "Rules": [{
    "ID": "images-to-dr",
    "Status": "Enabled",
    "Priority": 1,
    "Filter": { "Prefix": "images/" },
    "DeleteMarkerReplication": { "Status": "Disabled" },
    "Destination": { "Bucket": "arn:aws:s3:::$DST", "StorageClass": "STANDARD_IA" }
  }]
}
JSON
aws s3api put-bucket-replication --bucket "$SRC" --replication-configuration file://repl.json
aws s3api get-bucket-replication --bucket "$SRC" \
  --query 'ReplicationConfiguration.Rules[].{ID: ID, Prefix: Filter.Prefix, Dest: Destination.Bucket, Class: Destination.StorageClass}' --output json

echo "== 4. 새 객체 두 개: images/ (규칙 안) 와 docs/ (규칙 밖)"
printf 'new-image' >new.jpg
aws s3api put-object --bucket "$SRC" --key images/P-001.jpg --body new.jpg >/dev/null
aws s3api put-object --bucket "$SRC" --key docs/readme.txt --body new.jpg >/dev/null
wait_for_key "$DST" images/P-001.jpg

echo "== 5. 복제 상태: 원본 COMPLETED(처음엔 PENDING일 수 있음) / 대상 REPLICA, 버전 ID 동일"
src_status=""
for _ in $(seq 1 30); do
  src_status="$(aws s3api head-object --bucket "$SRC" --key images/P-001.jpg --query ReplicationStatus --output text)"
  [ "$src_status" = "COMPLETED" ] && break
  sleep 2
done
aws s3api head-object --bucket "$SRC" --key images/P-001.jpg --query '{Status: ReplicationStatus, VersionId: VersionId}' --output json
aws s3api head-object --bucket "$DST" --key images/P-001.jpg \
  --query '{Status: ReplicationStatus, VersionId: VersionId, Class: StorageClass}' --output json
dst_status="$(aws s3api head-object --bucket "$DST" --key images/P-001.jpg --query ReplicationStatus --output text)"
dst_class="$(aws s3api head-object --bucket "$DST" --key images/P-001.jpg --query StorageClass --output text)"

echo "== 6. 대상 버킷 목록: 기존 객체(old.jpg)와 규칙 밖(docs/)은 없다"
dst_keys="$(aws s3api list-objects-v2 --bucket "$DST" --output json | jq -c '[.Contents[]?.Key]')"
echo "$dst_keys"

echo "== 7. 원본에서 삭제 → 삭제 마커는 기본적으로 복제되지 않는다 (대상에서는 여전히 읽힌다)"
aws s3api delete-object --bucket "$SRC" --key images/P-001.jpg >/dev/null
# 복제가 비동기이므로 "안 생긴다"는 잠시 지켜본 뒤 판단한다 (10초 관찰)
for _ in $(seq 1 5); do sleep 2; done
dm_disabled="$(aws s3api list-object-versions --bucket "$DST" --prefix images/P-001.jpg --output json | jq '(.DeleteMarkers // []) | length')"
echo "대상의 삭제 마커 수: $dm_disabled"
aws s3api head-object --bucket "$DST" --key images/P-001.jpg --query ContentLength --output text

echo "== 8. DeleteMarkerReplication=Enabled 로 바꾸면 삭제 마커도 복제된다"
jq '.Rules[0].DeleteMarkerReplication.Status = "Enabled"' repl.json >repl2.json
aws s3api put-bucket-replication --bucket "$SRC" --replication-configuration file://repl2.json
aws s3api put-object --bucket "$SRC" --key images/P-002.jpg --body new.jpg >/dev/null
wait_for_key "$DST" images/P-002.jpg
aws s3api delete-object --bucket "$SRC" --key images/P-002.jpg >/dev/null
dm_enabled=0
for _ in $(seq 1 30); do
  dm_enabled="$(aws s3api list-object-versions --bucket "$DST" --prefix images/P-002.jpg --output json | jq '(.DeleteMarkers // []) | length')"
  [ "$dm_enabled" -ge 1 ] && break
  sleep 2
done
echo "대상의 삭제 마커 수: $dm_enabled"

echo "== 9. 정리"
purge_bucket "$SRC"
purge_bucket "$DST"
aws iam delete-role-policy --role-name "$ROLE" --policy-name replicate
aws iam delete-role --role-name "$ROLE"

# ---- 단언
[ "$src_status" = "COMPLETED" ] || { echo "FAIL: 원본 복제 상태 ($src_status)"; exit 1; }
[ "$dst_status" = "REPLICA" ] || { echo "FAIL: 대상 복제 상태 ($dst_status)"; exit 1; }
[ "$dst_class" = "STANDARD_IA" ] || { echo "FAIL: 대상 클래스 ($dst_class)"; exit 1; }
[ "$dst_keys" = '["images/P-001.jpg"]' ] || { echo "FAIL: 대상 키 목록 ($dst_keys)"; exit 1; }
[ "$dm_disabled" = "0" ] || { echo "FAIL: 기본 설정인데 삭제 마커가 복제됨"; exit 1; }
[ "$dm_enabled" -ge 1 ] || { echo "FAIL: DeleteMarkerReplication=Enabled 인데 삭제 마커가 복제되지 않음"; exit 1; }
echo "LAB04 OK"
