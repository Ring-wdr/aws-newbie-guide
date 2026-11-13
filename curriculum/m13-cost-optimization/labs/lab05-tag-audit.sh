#!/usr/bin/env bash
# M13 lab05 — 비용 할당 태그 정책과 태그 누락 감사 (🟢 서비스별 태그 API / 🔴 Organizations 태그 정책 강제)
#
# 1) 태그 정책(labs/tag-policy.json): project=todayorder, cost-center∈{orders,payments,platform}, env∈{prod,staging,dev}
# 2) 리소스 10개를 일부러 섞어서 만든다 (5개는 정책 위반)
# 3) sdk/tag_audit.py 로 감사 → 5/10 위반, Tagging API GetResources 는 SQS 만 찾는 것도 비교
# 4) 위반을 각 서비스 API 로 고친다 → 다시 감사 → 0/10
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$ROOT/scripts/lab-wait.sh"   # CLI waiter(EC2 15초, DynamoDB table-not-exists 20초 간격) 대신 1초 간격 대기, table-exists 는 준비 직후 재확인
AUDIT="$ROOT/curriculum/m13-cost-optimization/sdk/tag_audit.py"
P="todayorder-m13-audit"
cd "$ROOT"

# --- 정리 (멱등)
ids="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$P-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
  # shellcheck disable=SC2086
  wait_ec2_instance_terminated $ids
fi
for v in $(aws ec2 describe-volumes --filters "Name=tag:Name,Values=$P-*" --query 'Volumes[].VolumeId' --output text); do aws ec2 delete-volume --volume-id "$v"; done
for b in images logs; do aws s3 rb "s3://$P-$b" --force >/dev/null 2>&1 || true; done
for t in orders sessions; do aws dynamodb delete-table --table-name "$P-$t" >/dev/null 2>&1 || true; done
for t in orders sessions; do wait_dynamodb_table_gone "$P-$t"; done
for q in events dlq; do
  url="$(aws sqs get-queue-url --queue-name "$P-$q" --query QueueUrl --output text 2>/dev/null || true)"
  [ -n "$url" ] && aws sqs delete-queue --queue-url "$url"
done
aws sns delete-topic --topic-arn "arn:aws:sns:us-east-1:000000000000:$P-alerts" 2>/dev/null || true

echo "== 0. (참고) AWS Organizations 태그 정책으로 강제할 수 있을까?"
set +e
org_out="$(aws organizations create-policy --name todayorder-tags --type TAG_POLICY --description "cost tags" \
  --content "file://$ROOT/curriculum/m13-cost-optimization/labs/tag-policy.json" 2>&1)"
set -e
echo "$org_out"

echo "== 1. 리소스 만들기 (일부러 섞어서)"
FULL='{Key=project,Value=todayorder},{Key=cost-center,Value=orders},{Key=env,Value=prod}'
AMI="$(aws ec2 describe-images --owners amazon --query 'Images[0].ImageId' --output text)"
aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$P-api},$FULL]" >/dev/null
aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$P-worker},{Key=project,Value=todayorder},{Key=env,Value=prod}]" >/dev/null
VOL="$(aws ec2 create-volume --availability-zone us-east-1a --size 50 --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$P-data},{Key=project,Value=todayorder},{Key=cost-center,Value=orders},{Key=env,Value=production}]" \
  --query VolumeId --output text)"
aws s3api create-bucket --bucket "$P-images" >/dev/null
aws s3api put-bucket-tagging --bucket "$P-images" --tagging 'TagSet=[{Key=project,Value=todayorder},{Key=cost-center,Value=orders},{Key=env,Value=prod}]'
aws s3api create-bucket --bucket "$P-logs" >/dev/null
aws dynamodb create-table --table-name "$P-orders" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=pk,AttributeType=S --key-schema AttributeName=pk,KeyType=HASH \
  --tags Key=project,Value=todayorder Key=cost-center,Value=orders Key=env,Value=prod >/dev/null
aws dynamodb create-table --table-name "$P-sessions" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=pk,AttributeType=S --key-schema AttributeName=pk,KeyType=HASH \
  --tags Key=project,Value=todayorder Key=cost-center,Value=platform >/dev/null
aws sqs create-queue --queue-name "$P-events" --tags project=todayorder,cost-center=orders,env=prod >/dev/null
DLQ="$(aws sqs create-queue --queue-name "$P-dlq" --tags Project=todayorder,cost-center=orders,env=prod --query QueueUrl --output text)"
aws sns create-topic --name "$P-alerts" --tags Key=project,Value=todayorder Key=cost-center,Value=platform Key=env,Value=prod >/dev/null
wait_dynamodb_table_active "$P-orders"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
wait_dynamodb_table_active "$P-sessions"   # = aws dynamodb wait table-exists + 준비 직후 재확인 (scripts/lab-wait.sh)
# DynamoDB 태그는 테이블이 ACTIVE 가 된 뒤에 조회된다(최종 일관성) — 보일 때까지 기다린다
ddb_tags_visible() {
  local n
  n="$(aws dynamodb list-tags-of-resource --resource-arn "arn:aws:dynamodb:us-east-1:000000000000:table/$1" --query 'length(Tags)' --output text)"
  [ "$n" = "$2" ]
}
for _ in $(seq 60); do ddb_tags_visible "$P-orders" 3 && ddb_tags_visible "$P-sessions" 2 && break; sleep 1; done

echo "== 2. 감사"
before="$(uv run --quiet python "$AUDIT" "$P-")"
echo "$before"

echo "== 3. 고치기 — 서비스마다 태그 API 가 다르다"
WORKER="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$P-worker" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)"
aws ec2 create-tags --resources "$WORKER" --tags Key=cost-center,Value=orders
aws ec2 create-tags --resources "$VOL" --tags Key=env,Value=prod
aws s3api put-bucket-tagging --bucket "$P-logs" --tagging 'TagSet=[{Key=project,Value=todayorder},{Key=cost-center,Value=platform},{Key=env,Value=prod}]'
aws dynamodb tag-resource --resource-arn "arn:aws:dynamodb:us-east-1:000000000000:table/$P-sessions" --tags Key=env,Value=prod
aws sqs untag-queue --queue-url "$DLQ" --tag-keys Project
aws sqs tag-queue --queue-url "$DLQ" --tags project=todayorder
for _ in $(seq 60); do ddb_tags_visible "$P-sessions" 3 && break; sleep 1; done

echo "== 4. 다시 감사"
after="$(uv run --quiet python "$AUDIT" "$P-")"
echo "$after"

# ---- 단언
grep -q '^NON-COMPLIANT 5 / 10$' <<<"$before" || { echo "FAIL: 처음 감사에서 5/10 위반이어야 함"; exit 1; }
for want in "ec2       $P-worker" "ebs       $P-data" "s3        $P-logs" "dynamodb  $P-sessions" "sqs       $P-dlq"; do
  grep -q "^✗ $want" <<<"$before" || { echo "FAIL: 위반 목록에 없음: $want"; exit 1; }
done
grep -q 'WRONG-CASE Project→project' <<<"$before" || { echo "FAIL: 대소문자 위반 판정"; exit 1; }
grep -q 'BAD-VALUE env=production' <<<"$before" || { echo "FAIL: 허용 값 위반 판정"; exit 1; }
grep -q '^NON-COMPLIANT 0 / 10$' <<<"$after" || { echo "FAIL: 고친 뒤에도 위반이 남음"; exit 1; }
grep -q 'NotImplemented' <<<"$org_out" || echo "참고: Organizations 태그 정책 생성이 501 이 아니다 — 문서 갱신 필요"
echo "LAB05 OK"
