#!/usr/bin/env bash
# M04 lab11 — 하이브리드·이전 서비스 구성 (🟡 구성까지. 데이터는 실제로 움직이지 않는다 · 일부 🔴 501)
# 1) Storage Gateway: S3 File Gateway 활성화 + NFS 파일 공유(S3 버킷) / SMB 공유·Volume·Tape 작업은 501
# 2) DataSync: S3 → S3 작업 실행 → SUCCESS 지만 파일 0개 (복사 없음) / NFS 위치는 501
# 3) Transfer Family: S3 를 저장소로 쓰는 SFTP 서버
set -euo pipefail
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$LAB_DIR/_lib.sh"

SHARE_BUCKET="todayorder-m04-store-share"
SRC="todayorder-m04-legacy-export"
DST="todayorder-m04-migrated"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cleanup() {
  for g in $(aws storagegateway list-gateways --output json | jq -r '.Gateways[] | select(.GatewayName | startswith("todayorder-m04-")) | .GatewayARN'); do
    aws storagegateway delete-gateway --gateway-arn "$g" >/dev/null
  done
  for t in $(aws datasync list-tasks --output json | jq -r '.Tasks[] | select(.Name == "todayorder-m04-migrate") | .TaskArn'); do
    aws datasync delete-task --task-arn "$t"
  done
  for l in $(aws datasync list-locations --output json | jq -r ".Locations[] | select(.LocationUri | test(\"$SRC|$DST\")) | .LocationArn"); do
    aws datasync delete-location --location-arn "$l"
  done
  for s in $(aws transfer list-servers --output json | jq -r '.Servers[].ServerId'); do
    tags="$(aws transfer list-tags-for-resource --arn "arn:aws:transfer:us-east-1:000000000000:server/$s" --output json 2>/dev/null || echo '{}')"
    if jq -e '.Tags[]? | select(.Key == "Name" and .Value == "todayorder-m04-sftp")' <<<"$tags" >/dev/null; then
      aws transfer delete-server --server-id "$s"
    fi
  done
  purge_bucket "$SHARE_BUCKET"
  purge_bucket "$SRC"
  purge_bucket "$DST"
}
cleanup
for b in "$SHARE_BUCKET" "$SRC" "$DST"; do aws s3api create-bucket --bucket "$b" >/dev/null; done

# 서비스가 맡을 역할(실제 AWS에서 필요). 에뮬레이터는 역할 존재를 검사하지 않지만 실제처럼 만든다.
make_role() { # <이름> <서비스 주체> <버킷>
  aws iam delete-role-policy --role-name "$1" --policy-name s3 >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$1" >/dev/null 2>&1 || true
  aws iam create-role --role-name "$1" --assume-role-policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$2\"},\"Action\":\"sts:AssumeRole\"}]}" \
    --query Role.Arn --output text
  aws iam put-role-policy --role-name "$1" --policy-name s3 --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetBucketLocation\",\"s3:ListBucket\",\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucketMultipartUploads\",\"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],\"Resource\":[\"arn:aws:s3:::$3\",\"arn:aws:s3:::$3/*\"]}]}"
}

echo "== 1. Storage Gateway — S3 File Gateway 활성화"
echo "   (실제로는 사내에 게이트웨이 VM/하드웨어를 설치하고 그 장비에서 활성화 키를 받는다. 여기서는 임의의 키)"
SGW_ROLE="$(make_role todayorder-m04-sgw-role storagegateway.amazonaws.com "$SHARE_BUCKET")"
FILE_GW="$(aws storagegateway activate-gateway --activation-key AAAAA-BBBBB-CCCCC-DDDDD-EEEEE \
  --gateway-name todayorder-m04-file-gw --gateway-timezone GMT+9:00 --gateway-region us-east-1 \
  --gateway-type FILE_S3 --query GatewayARN --output text)"
aws storagegateway describe-gateway-information --gateway-arn "$FILE_GW" \
  --query '{Name: GatewayName, Type: GatewayType, State: GatewayState}' --output json

echo "-- NFS 파일 공유: 사내 서버(10.0.0.0/16)가 NFS 로 마운트하면, 파일이 S3 객체로 저장된다"
aws storagegateway create-nfs-file-share --client-token todayorder-m04-nfs-share --gateway-arn "$FILE_GW" \
  --role "$SGW_ROLE" --location-arn "arn:aws:s3:::$SHARE_BUCKET" --client-list 10.0.0.0/16 \
  --default-storage-class S3_STANDARD --output json >/dev/null
share_status=""
for _ in $(seq 1 60); do   # CREATING → AVAILABLE 을 기다린다 (최대 120초)
  share_status="$(aws storagegateway list-file-shares --gateway-arn "$FILE_GW" --query 'FileShareInfoList[0].FileShareStatus' --output text)"
  [ "$share_status" = "AVAILABLE" ] && break
  sleep 2
done
aws storagegateway list-file-shares --gateway-arn "$FILE_GW" \
  --query 'FileShareInfoList[].{Type: FileShareType, Status: FileShareStatus}' --output json

echo "-- SMB 파일 공유(윈도 클라이언트용) → 에뮬레이터 501"
expect_error NotImplemented aws storagegateway create-smb-file-share --client-token todayorder-m04-smb-share \
  --gateway-arn "$FILE_GW" --role "$SGW_ROLE" --location-arn "arn:aws:s3:::$SHARE_BUCKET" --authentication GuestAccess

echo "== 2. Volume Gateway(캐시 모드) / Tape Gateway — 게이트웨이는 활성화되지만 볼륨·테이프 생성은 501"
VOL_GW="$(aws storagegateway activate-gateway --activation-key AAAAA-BBBBB-CCCCC-DDDDD-EEEEF \
  --gateway-name todayorder-m04-volume-gw --gateway-timezone GMT+9:00 --gateway-region us-east-1 \
  --gateway-type CACHED --query GatewayARN --output text)"
expect_error NotImplemented aws storagegateway create-cached-iscsi-volume --gateway-arn "$VOL_GW" \
  --volume-size-in-bytes 10737418240 --target-name todayorder-orders-db --network-interface-id 192.0.2.2 \
  --client-token todayorder-m04-volume-1
TAPE_GW="$(aws storagegateway activate-gateway --activation-key AAAAA-BBBBB-CCCCC-DDDDD-EEEEG \
  --gateway-name todayorder-m04-tape-gw --gateway-timezone GMT+9:00 --gateway-region us-east-1 \
  --gateway-type VTL --tape-drive-type IBM-ULT3580-TD5 --medium-changer-type AWS-Gateway-VTL --query GatewayARN --output text)"
expect_error NotImplemented aws storagegateway create-tapes --gateway-arn "$TAPE_GW" \
  --tape-size-in-bytes 107374182400 --client-token todayorder-m04-tapes-1 --num-tapes-to-create 2 --tape-barcode-prefix TODY
aws storagegateway list-gateways --output json |
  jq -c '.Gateways[] | select(.GatewayName | startswith("todayorder-m04-")) | {GatewayName, GatewayType}'

echo "== 3. DataSync — S3 → S3 이전 작업"
printf 'order,total\nA-1,12000\n' >orders-2025.csv
aws s3 cp orders-2025.csv "s3://$SRC/export/orders-2025.csv" --no-progress >/dev/null
DS_ROLE="$(make_role todayorder-m04-datasync-role datasync.amazonaws.com "$SRC")"
L_SRC="$(aws datasync create-location-s3 --s3-bucket-arn "arn:aws:s3:::$SRC" --subdirectory /export \
  --s3-config "BucketAccessRoleArn=$DS_ROLE" --query LocationArn --output text)"
L_DST="$(aws datasync create-location-s3 --s3-bucket-arn "arn:aws:s3:::$DST" \
  --s3-config "BucketAccessRoleArn=$DS_ROLE" --query LocationArn --output text)"
TASK="$(aws datasync create-task --name todayorder-m04-migrate --source-location-arn "$L_SRC" \
  --destination-location-arn "$L_DST" --options VerifyMode=ONLY_FILES_TRANSFERRED,OverwriteMode=ALWAYS \
  --query TaskArn --output text)"
# CreateTask 는 작업을 CREATING 상태로 돌려준다. AVAILABLE 이 되기 전에 실행하면
# InvalidRequestException("is in status CREATING") — 그래서 상태를 폴링한다 (최대 120초).
task_status=""
for _ in $(seq 1 60); do
  task_status="$(aws datasync describe-task --task-arn "$TASK" --query Status --output text)"
  [ "$task_status" = "AVAILABLE" ] && break
  sleep 2
done
[ "$task_status" = "AVAILABLE" ] || { echo "FAIL: 120초 안에 DataSync 작업이 AVAILABLE 이 되지 않음 (마지막 상태: $task_status)"; exit 1; }
echo "작업 상태: $task_status"
EXEC="$(aws datasync start-task-execution --task-arn "$TASK" --query TaskExecutionArn --output text)"
ds_status=""
for _ in $(seq 1 60); do
  ds_status="$(aws datasync describe-task-execution --task-execution-arn "$EXEC" --query Status --output text)"
  case "$ds_status" in SUCCESS | ERROR) break ;; esac
  sleep 2
done
case "$ds_status" in SUCCESS | ERROR) ;; *) echo "FAIL: 120초 안에 실행이 끝나지 않음 (마지막 상태: $ds_status)"; exit 1 ;; esac
aws datasync describe-task-execution --task-execution-arn "$EXEC" \
  --query '{Status: Status, FilesTransferred: FilesTransferred, BytesTransferred: BytesTransferred}' --output json
dst_count="$(aws s3api list-objects-v2 --bucket "$DST" --output json | jq '(.Contents // []) | length')"
echo "대상 버킷 객체 수: $dst_count   ← 에뮬레이터는 작업 상태만 SUCCESS 로 바꾸고 실제로 복사하지 않는다"
echo "-- 온프레미스 NFS 위치(에이전트 필요) → 501"
# 서버 이름은 예약 이름(.invalid): 사설 IP(예: 10.0.0.5)는 학습자 LAN에 실제로 있을 수 있어, 에뮬레이터가 이 API를 구현하면 접속을 시도할 수 있다
expect_error NotImplemented aws datasync create-location-nfs --server-hostname nfs.todayorder.invalid --subdirectory /export \
  --on-prem-config AgentArns=arn:aws:datasync:us-east-1:000000000000:agent/agent-0123456789abcdef0

echo "== 4. Transfer Family — S3 에 저장하는 관리형 SFTP 서버 (협력사가 정산 파일을 SFTP 로 올린다)"
SFTP="$(aws transfer create-server --protocols SFTP --domain S3 --identity-provider-type SERVICE_MANAGED \
  --endpoint-type PUBLIC --tags Key=Name,Value=todayorder-m04-sftp --query ServerId --output text)"
sftp_state=""
for _ in $(seq 1 60); do   # 최대 120초
  sftp_state="$(aws transfer describe-server --server-id "$SFTP" --query Server.State --output text)"
  [ "$sftp_state" = "ONLINE" ] && break
  sleep 2
done
aws transfer describe-server --server-id "$SFTP" \
  --query 'Server.{Protocols: Protocols, Domain: Domain, State: State, Endpoint: EndpointType}' --output json

echo "== 5. 정리"
cleanup
for r in todayorder-m04-sgw-role todayorder-m04-datasync-role; do
  aws iam delete-role-policy --role-name "$r" --policy-name s3
  aws iam delete-role --role-name "$r"
done

# ---- 단언 (데이터가 움직이지 않는 것까지 확인: 에뮬레이터가 복사를 시작하면 문서 갱신 필요)
[ "$share_status" = "AVAILABLE" ] || { echo "FAIL: 120초 안에 파일 공유가 AVAILABLE 이 되지 않음 (마지막 상태: $share_status)"; exit 1; }
[ "$ds_status" = "SUCCESS" ] || { echo "FAIL: DataSync 실행 상태 ($ds_status)"; exit 1; }
[ "$dst_count" = "0" ] || { echo "NOTE: DataSync 가 실제로 복사하기 시작함 → 레슨 7·README 갱신 필요"; exit 1; }
[ "$sftp_state" = "ONLINE" ] || { echo "FAIL: 120초 안에 SFTP 서버가 ONLINE 이 되지 않음 (마지막 상태: $sftp_state)"; exit 1; }
echo "LAB11 OK"
