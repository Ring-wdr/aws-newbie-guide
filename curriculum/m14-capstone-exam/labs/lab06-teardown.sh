#!/usr/bin/env bash
# M14 lab06 — 캡스톤 정리(teardown). 만든 순서의 역순으로 지우고, 남은 것이 없는지 단언한다.
# 실제 AWS 에서 캡스톤을 해 봤다면 반드시 실행할 것 — NAT 게이트웨이 2개·EIP·RDS Multi-AZ·ALB 는 시간당 과금된다.
# 지우지 "못하는" 것: KMS 키(7~30일 삭제 대기로 예약만 됨), 관리형 정책 등 AWS 소유 리소스.
# 등급: 🟢
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

echo "== 1. 거버넌스·관측: 예산, Config, CloudTrail, 알람"
aws budgets delete-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" >/dev/null 2>&1 || true
for r in $(aws configservice describe-config-rules --query "ConfigRules[?starts_with(ConfigRuleName, '$P-')].ConfigRuleName" --output text); do
  aws configservice delete-config-rule --config-rule-name "$r"
done
aws configservice stop-configuration-recorder --configuration-recorder-name default >/dev/null 2>&1 || true
aws configservice delete-delivery-channel --delivery-channel-name default >/dev/null 2>&1 || true
aws configservice delete-configuration-recorder --configuration-recorder-name default >/dev/null 2>&1 || true
aws cloudtrail delete-trail --name "$TRAIL" >/dev/null 2>&1 || true
for a in $(aws cloudwatch describe-alarms --alarm-name-prefix "$P-" --query 'MetricAlarms[].AlarmName' --output text); do
  aws cloudwatch delete-alarms --alarm-names "$a"
done
nuke_bucket "$CONFIG_BUCKET"
nuke_bucket "$TRAIL_BUCKET"
delete_role "$CONFIG_ROLE"
echo "삭제: 예산·Config 규칙/기록기·추적·알람·감사/Config 버킷"

echo "== 2. 주문 파이프라인: API, 매핑, 함수, 로그 그룹, 역할, 사용자 풀, 메시징 스택, 버스"
for id in $(aws apigatewayv2 get-apis --output json | py '
for a in json.load(sys.stdin).get("Items", []):
    if a["Name"] == sys.argv[1]:
        print(a["ApiId"])' "$API_NAME"); do
  aws apigatewayv2 delete-api --api-id "$id"
done
for u in $(aws lambda list-event-source-mappings --function-name "$WORKER_FN" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  aws lambda delete-event-source-mapping --uuid "$u" >/dev/null
done
for f in "$API_FN" "$WORKER_FN"; do
  aws lambda delete-function --function-name "$f" >/dev/null 2>&1 || true
  aws logs delete-log-group --log-group-name "/aws/lambda/$f" >/dev/null 2>&1 || true
done
delete_role "$API_ROLE"
delete_role "$WORKER_ROLE"
for pool in $(aws cognito-idp list-user-pools --max-results 60 --output json | py '
for p in json.load(sys.stdin)["UserPools"]:
    if p["Name"] == sys.argv[1]:
        print(p["Id"])' "$P-customers"); do
  aws cognito-idp delete-user-pool --user-pool-id "$pool"
done
delete_stack "$MSG_STACK"
aws events delete-event-bus --name "$BUS" >/dev/null 2>&1 || true
echo "삭제: HTTP API·Lambda 2·역할 2·사용자 풀·메시징 스택(토픽 2·큐 4)·이벤트 버스"

echo "== 3. 데이터: 영수증 버킷(모든 버전), 데이터 스택(테이블·비밀·파라미터·KMS 키 삭제 예약)"
nuke_bucket "$RECEIPTS"
KEY_ARN="$(stack_output "$DATA_STACK" KeyArn 2>/dev/null || true)"
delete_stack "$DATA_STACK"
# 스택이 지운 비밀은 30일 복구 대기(삭제 예약)로 남아 같은 이름으로 다시 만들 수 없다 → 실습이므로 즉시 삭제.
# (운영 비밀이라면 복구 기간을 두는 것이 맞다)
secret_left() { aws secretsmanager list-secrets --include-planned-deletion --query "SecretList[?Name=='$SECRET'].Name" --output text | grep -q .; }
if secret_left; then
  aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null
  poll 60 "비밀 즉시 삭제" sh -c "! aws secretsmanager list-secrets --include-planned-deletion --query \"SecretList[?Name=='$SECRET'].Name\" --output text | grep -q ."
fi
if [ -n "$KEY_ARN" ] && [ "$KEY_ARN" != None ]; then
  aws kms describe-key --key-id "$KEY_ARN" --query 'KeyMetadata.[KeyState, DeletionDate]' --output text
fi

echo "== 4. 관리 웹·정산 DB: RDS(삭제 방지 해제 → 최종 스냅샷 없이 삭제), ASG, ALB, 대상 그룹, 시작 템플릿, 인증서"
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  aws rds modify-db-instance --db-instance-identifier "$DB_ID" --no-deletion-protection --apply-immediately >/dev/null
  # 실제 운영 DB 라면 --final-db-snapshot-identifier 로 최종 스냅샷을 남긴다
  aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null
  poll 180 "DB 삭제" sh -c "! aws rds describe-db-instances --db-instance-identifier '$DB_ID' >/dev/null 2>&1"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || true
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text | grep -qx 1; then
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete
  poll 120 "ASG 삭제" sh -c "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names '$ASG' --query 'length(AutoScalingGroups)' --output text | grep -qx 0"
fi
alb="$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [ -n "$alb" ] && [ "$alb" != None ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$alb"
  poll 60 "ALB 삭제" sh -c "! aws elbv2 describe-load-balancers --names '$ALB' >/dev/null 2>&1"
fi
tg="$(aws elbv2 describe-target-groups --names "$TG" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
[ -n "$tg" ] && [ "$tg" != None ] && aws elbv2 delete-target-group --target-group-arn "$tg"
aws ec2 delete-launch-template --launch-template-name "$LT" >/dev/null 2>&1 || true
for c in $(aws acm list-certificates --output json | py '
for c in json.load(sys.stdin)["CertificateSummaryList"]:
    if c["DomainName"] == "partner.todayorder.example.com":
        print(c["CertificateArn"])'); do
  aws acm delete-certificate --certificate-arn "$c"
done
echo "삭제: RDS·ASG·ALB·대상 그룹·시작 템플릿·인증서"

echo "== 5. 네트워크 스택 (NAT 2·EIP 2·엔드포인트·서브넷·VPC)"
delete_stack "$NET_STACK"

echo "== 6. 남은 것 확인"
left="$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, '$P-')].StackName" --output text)"
buckets="$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '$P-')].Name" --output text)"
fns="$(aws lambda list-functions --query "Functions[?starts_with(FunctionName, '$P-')].FunctionName" --output text)"
tables="$(aws dynamodb list-tables --query "TableNames[?starts_with(@, '$P-')]" --output text)"
vpcs="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc" --query 'Vpcs[].VpcId' --output text)"
queues="$(aws sqs list-queues --queue-name-prefix "$P-" --query 'QueueUrls' --output text 2>/dev/null || true)"
printf '스택:[%s] 버킷:[%s] 함수:[%s] 테이블:[%s] VPC:[%s] 큐:[%s]\n' "$left" "$buckets" "$fns" "$tables" "$vpcs" "${queues/None/}"
[ -z "$left" ] || fail "스택이 남음: $left"
[ -z "$buckets" ] || fail "버킷이 남음: $buckets"
[ -z "$fns" ] || fail "함수가 남음: $fns"
[ -z "$tables" ] || fail "테이블이 남음: $tables"
[ -z "$vpcs" ] || fail "VPC 가 남음: $vpcs"
[ -z "$queues" ] || [ "$queues" = None ] || fail "큐가 남음: $queues"
aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1 && fail "DB 가 남음"
echo "LAB06 OK"
