#!/usr/bin/env bash
# M14 lab01 — 캡스톤 계층 1: 네트워크(CloudFormation) + 점주용 관리 웹(ALB·시작 템플릿·ASG) + 정산 DB(RDS Multi-AZ)
#   CloudFormation: VPC·서브넷 6·IGW·NAT 2·라우팅 테이블 4·게이트웨이 엔드포인트 2·보안 그룹 3
#   CLI:            ACM 인증서(가져오기)·ALB·대상 그룹·HTTPS/HTTP 리스너·시작 템플릿·ASG·RDS
# 등급: 🟢 구성 (트래픽·부팅·장애 조치는 없음 — README "에뮬레이터 제약")
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. 네트워크 스택 (CloudFormation, 2초 간격 폴링)"
deploy_stack "$NET_STACK" "$LABS/templates/network.yaml"
VPC="$(stack_output "$NET_STACK" VpcId)"
PUB="$(stack_output "$NET_STACK" PublicSubnets)"
APP="$(stack_output "$NET_STACK" AppSubnets)"
DBS="$(stack_output "$NET_STACK" DbSubnets)"
ALB_SG="$(stack_output "$NET_STACK" AlbSgId)"
APP_SG="$(stack_output "$NET_STACK" AppSgId)"
DB_SG="$(stack_output "$NET_STACK" DbSgId)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'sort_by(Subnets,&CidrBlock)[].[Tags[?Key==`Name`]|[0].Value, CidrBlock, AvailabilityZone]' --output text

echo "== 2. 앱 서브넷의 경로: AZ마다 자기 NAT, S3·DynamoDB 는 게이트웨이 엔드포인트"
for rt in $(stack_output "$NET_STACK" AppRouteTables | tr , ' '); do
  aws ec2 describe-route-tables --route-table-ids "$rt" --output json | py '
rt = json.load(sys.stdin)["RouteTables"][0]
name = next(t["Value"] for t in rt.get("Tags", []) if t["Key"] == "Name")
for r in rt["Routes"]:
    dest = r.get("DestinationCidrBlock") or r.get("DestinationPrefixListId")
    tgt = r.get("NatGatewayId") or r.get("GatewayId")
    print(f"{name:<26}{dest:<16}{tgt}")'
done

echo "== 3. ALB 인증서 — 자체 서명 인증서를 ACM 으로 가져온다 (실제 AWS: ACM 공인 인증서 + DNS 검증)"
DOMAIN=partner.todayorder.example.com
CERT="$(aws acm list-certificates --output json | py '
for c in json.load(sys.stdin)["CertificateSummaryList"]:
    if c["DomainName"] == sys.argv[1]:
        print(c["CertificateArn"])' "$DOMAIN" | head -1)"
if [ -z "$CERT" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 90 \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1
  CERT="$(aws acm import-certificate --certificate "fileb://$WORK/cert.pem" --private-key "fileb://$WORK/key.pem" \
    --tags Key=Project,Value=todayorder --query CertificateArn --output text)"
fi
aws acm describe-certificate --certificate-arn "$CERT" --query 'Certificate.[DomainName, Status, Type]' --output text

echo "== 4. 관리 웹 계층을 새로 만든다 (이전 실행분 정리: ASG → ALB → 대상 그룹 → 시작 템플릿)"
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text | grep -qx 1; then
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete
  poll 120 "ASG 삭제" sh -c "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names '$ASG' --query 'length(AutoScalingGroups)' --output text | grep -qx 0"
fi
old_alb="$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [ -n "$old_alb" ] && [ "$old_alb" != None ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$old_alb"
  poll 60 "ALB 삭제" sh -c "! aws elbv2 describe-load-balancers --names '$ALB' >/dev/null 2>&1"
fi
old_tg="$(aws elbv2 describe-target-groups --names "$TG" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
[ -n "$old_tg" ] && [ "$old_tg" != None ] && aws elbv2 delete-target-group --target-group-arn "$old_tg"
aws ec2 delete-launch-template --launch-template-name "$LT" >/dev/null 2>&1 || true

echo "== 5. ALB (인터넷용, 퍼블릭 서브넷 2개) + 대상 그룹(8080, /health) + 리스너 2개"
ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB" --type application --scheme internet-facing \
  --subnets ${PUB//,/ } --security-groups "$ALB_SG" --tags Key=Project,Value=todayorder \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
TG_ARN="$(aws elbv2 create-target-group --name "$TG" --protocol HTTP --port 8080 --vpc-id "$VPC" \
  --target-type instance --health-check-path /health --health-check-interval-seconds 15 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
# 등록 취소 지연(연결 드레이닝)을 기본 300초 → 60초로: 관리 웹 요청은 짧다
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=60 >/dev/null
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 --certificates "CertificateArn=$CERT" \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --query 'Listeners[0].[Protocol, Port, SslPolicy]' --output text
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
  --query 'Listeners[0].[Protocol, Port, DefaultActions[0].Type]' --output text

echo "== 6. 시작 템플릿 (IMDSv2 필수, 앱 SG, 퍼블릭 IP 없음) + ASG (앱 서브넷 2개, 최소 2, ELB 헬스 체크)"
AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"
USERDATA="$(printf '#!/bin/bash\n# 실제 AWS: 관리 웹(jar)을 내려받아 8080 으로 실행\necho start partner-web\n' | base64 | tr -d '\n')"
aws ec2 create-launch-template --launch-template-name "$LT" --version-description v1 --launch-template-data "{
  \"ImageId\": \"$AMI\", \"InstanceType\": \"t4g.small\",
  \"SecurityGroupIds\": [\"$APP_SG\"],
  \"MetadataOptions\": {\"HttpTokens\": \"required\", \"HttpEndpoint\": \"enabled\"},
  \"UserData\": \"$USERDATA\",
  \"TagSpecifications\": [{\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Project\", \"Value\": \"todayorder\"}]}]}" \
  --query 'LaunchTemplate.[LaunchTemplateName, LatestVersionNumber]' --output text
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --launch-template "LaunchTemplateName=$LT,Version=\$Latest" --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "$APP" --target-group-arns "$TG_ARN" --health-check-type ELB --health-check-grace-period 120 \
  --tags Key=Project,Value=todayorder,PropagateAtLaunch=true
in_service() {
  [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text)" = 2 ]
}
poll 120 "ASG 인스턴스 2대 InService" in_service
IDS="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].[AvailabilityZone, LifecycleState, HealthStatus]' --output text | sort
# 에뮬레이터는 --target-group-arns 로 ASG 인스턴스를 대상 그룹에 등록하지 않는다(M03·M12) → 직접 등록
targets=""
for i in $IDS; do targets="$targets Id=$i"; done
# shellcheck disable=SC2086
aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets $targets
healthy() {
  [ "$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)" = 2 ]
}
poll 60 "대상 2개 healthy" healthy
echo "대상 그룹 healthy: 2"
echo "-- 실제 AWS 에서는 대상 추적 조정 정책을 붙인다(에뮬레이터 PutScalingPolicy 501 → 레슨 02 설계 문서에 JSON)"

echo "== 7. 정산 DB: RDS PostgreSQL Multi-AZ, 암호화, DB 서브넷(인터넷 경로 없음), 마스터 암호는 Secrets Manager 가 관리"
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" --db-subnet-group-description "capstone DB subnets" \
    --subnet-ids ${DBS//,/ } >/dev/null
fi
db_vpc="$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --query 'DBSubnetGroups[0].VpcId' --output text)"
if [ "$db_vpc" != "$VPC" ]; then
  # 네트워크 스택이 새로 만들어졌다면 옛 서브넷 그룹·DB 를 버리고 다시 만든다
  aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
  poll 120 "옛 DB 삭제" sh -c "! aws rds describe-db-instances --db-instance-identifier '$DB_ID' >/dev/null 2>&1"
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" --db-subnet-group-description "capstone DB subnets" \
    --subnet-ids ${DBS//,/ } >/dev/null
fi
if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  aws rds create-db-instance --db-instance-identifier "$DB_ID" --engine postgres --db-instance-class db.t4g.micro \
    --allocated-storage 20 --storage-type gp3 --master-username todayadmin --manage-master-user-password \
    --multi-az --storage-encrypted --db-subnet-group-name "$DB_SUBNET_GROUP" --vpc-security-group-ids "$DB_SG" \
    --backup-retention-period 7 --deletion-protection --no-publicly-accessible \
    --tags Key=Project,Value=todayorder >/dev/null
fi
poll 180 "DB available" sh -c "aws rds describe-db-instances --db-instance-identifier '$DB_ID' --query 'DBInstances[0].DBInstanceStatus' --output text | grep -qx available"
aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].{Status: DBInstanceStatus, MultiAZ: MultiAZ,
  Encrypted: StorageEncrypted, Public: PubliclyAccessible, BackupDays: BackupRetentionPeriod, DeletionProtection: DeletionProtection,
  SecretStatus: MasterUserSecret.SecretStatus}'

# ---- 단언
assert_eq "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'length(Subnets)' --output text)" 6 "서브넷 수"
assert_eq "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available" --query 'length(NatGateways[])' --output text)" 2 "NAT 수"
nat_azs="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available" --query 'NatGateways[].SubnetId' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"
assert_eq "$nat_azs" 2 "NAT 가 서로 다른 퍼블릭 서브넷에"
for rt in $(stack_output "$NET_STACK" AppRouteTables | tr , ' '); do
  assert_eq "$(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'length(RouteTables[0].Routes[?DestinationPrefixListId])' --output text)" 2 "$rt 의 게이트웨이 엔드포인트 경로"
done
assert_eq "$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$P-db-rt" --query 'length(RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`])' --output text)" 0 "DB 라우팅 테이블에 기본 경로 없음"
assert_eq "$(aws ec2 describe-security-groups --group-ids "$DB_SG" --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)" "$APP_SG" "db-sg 는 app-sg 만 허용"
assert_eq "$(aws ec2 describe-security-groups --group-ids "$APP_SG" --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)" "$ALB_SG" "app-sg 는 alb-sg 만 허용"
assert_eq "$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].State.Code' --output text)" active "ALB 상태"
assert_eq "$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'length(Listeners)' --output text)" 2 "리스너 수"
lt_v="$(aws ec2 describe-launch-template-versions --launch-template-name "$LT" --query 'LaunchTemplateVersions[0].LaunchTemplateData.MetadataOptions.HttpTokens' --output text)"
assert_eq "$lt_v" required "IMDSv2 필수"
azs="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"
assert_eq "$azs" 2 "ASG 인스턴스가 2개 AZ 에"
assert_eq "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].MultiAZ' --output text)" True "RDS Multi-AZ"
assert_eq "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].PubliclyAccessible' --output text)" False "RDS 비공개"
echo "LAB01 OK"
