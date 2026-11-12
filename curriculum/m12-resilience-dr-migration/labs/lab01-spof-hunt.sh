#!/usr/bin/env bash
# M12 lab01 — TodayOrder v1 아키텍처에서 단일 장애점(SPOF) 찾기와 고치기 (🟢 구성 수준)
#
# 1) "v1" 을 그대로 만든다: 2-AZ VPC, NAT 게이트웨이 1개(AZ-a), API 서버 EC2 1대(AZ-a),
#    ALB(2-AZ) + 대상 그룹, RDS PostgreSQL 단일 AZ.
# 2) sdk/spof_audit.py 로 SPOF 를 찾는다 → 3건이어야 한다.
# 3) 고친다: AZ-b 에 NAT 하나 더 + 라우팅 분리, API 서버를 2-AZ Auto Scaling 그룹으로, RDS Multi-AZ.
# 4) 다시 감사 → 0건이어야 한다.
# 트래픽은 흐르지 않는다(인스턴스는 부팅하지 않는다). 여기서 보는 것은 "구성이 장애를 견딜 모양인가"이다.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
AUDIT="$ROOT/curriculum/m12-resilience-dr-migration/sdk/spof_audit.py"
cd "$ROOT"

P="todayorder-m12"
VPC_NAME="$P-v1"
AZ_A="us-east-1a"
AZ_B="us-east-1b"

wait_until() { # wait_until <설명> <최대초> <명령...>
  local what="$1" max="$2" i; shift 2
  for i in $(seq "$max"); do "$@" && return 0; sleep 1; done
  echo "FAIL: ${max}초 안에 '$what' 이 되지 않음"; return 1
}
rds_gone() { ! aws rds describe-db-instances --db-instance-identifier "$P-db" >/dev/null 2>&1; }
asg_gone() { [ -z "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$P-api-asg" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -v None)" ]; }
nats_gone() {
  [ -z "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$1" "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text)" ]
}

teardown() {
  local vpc
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$P-api-asg" --force-delete >/dev/null 2>&1 || true
  wait_until "ASG 삭제" 60 asg_gone
  aws ec2 delete-launch-template --launch-template-name "$P-api-lt" >/dev/null 2>&1 || true
  local alb tg
  alb="$(aws elbv2 describe-load-balancers --names "$P-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  [ -n "$alb" ] && [ "$alb" != "None" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$alb"
  tg="$(aws elbv2 describe-target-groups --names "$P-api" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  [ -n "$tg" ] && [ "$tg" != "None" ] && aws elbv2 delete-target-group --target-group-arn "$tg"
  if ! rds_gone; then
    aws rds delete-db-instance --db-instance-identifier "$P-db" --skip-final-snapshot >/dev/null
    wait_until "RDS 삭제" 120 rds_gone
  fi
  aws rds delete-db-subnet-group --db-subnet-group-name "$P-db-subnets" >/dev/null 2>&1 || true
  for vpc in $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query 'Vpcs[].VpcId' --output text); do
    local ids id
    ids="$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      aws ec2 terminate-instances --instance-ids $ids >/dev/null
      # shellcheck disable=SC2086
      aws ec2 wait instance-terminated --instance-ids $ids
    fi
    for id in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text); do
      aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null
    done
    wait_until "NAT 게이트웨이 삭제" 120 nats_gone "$vpc"
    for id in $(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$P-nat-*" --query 'Addresses[].AllocationId' --output text); do
      aws ec2 release-address --allocation-id "$id"
    done
    for id in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
      aws ec2 delete-internet-gateway --internet-gateway-id "$id"
    done
    for id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$id"
    done
    for id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
      aws ec2 delete-route-table --route-table-id "$id"
    done
    for id in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
      aws ec2 delete-security-group --group-id "$id" >/dev/null
    done
    aws ec2 delete-vpc --vpc-id "$vpc"
  done
}
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }

teardown

echo "== 1. TodayOrder v1 만들기"
VPC="$(aws ec2 create-vpc --cidr-block 10.12.0.0/16 --tag-specifications "$(tag vpc "$VPC_NAME")" --query Vpc.VpcId --output text)"
mk_subnet() { aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$1" --availability-zone "$2" --tag-specifications "$(tag subnet "$3")" --query Subnet.SubnetId --output text; }
PUB_A="$(mk_subnet 10.12.0.0/24 "$AZ_A" "$P-public-a")"
PUB_B="$(mk_subnet 10.12.1.0/24 "$AZ_B" "$P-public-b")"
APP_A="$(mk_subnet 10.12.10.0/24 "$AZ_A" "$P-app-a")"
APP_B="$(mk_subnet 10.12.11.0/24 "$AZ_B" "$P-app-b")"
DB_A="$(mk_subnet 10.12.20.0/24 "$AZ_A" "$P-db-a")"
DB_B="$(mk_subnet 10.12.21.0/24 "$AZ_B" "$P-db-b")"
IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
RT_PUB="$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tag route-table "$P-public")" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
for s in "$PUB_A" "$PUB_B"; do aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$s" >/dev/null; done

# v1 의 NAT: AZ-a 에 하나만. 프라이빗 서브넷 4개가 라우팅 테이블 하나로 전부 이 NAT 을 쓴다.
EIP_A="$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tag elastic-ip "$P-nat-a")" --query AllocationId --output text)"
NAT_A="$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_A" --tag-specifications "$(tag natgateway "$P-nat-a")" --query NatGateway.NatGatewayId --output text)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A"
RT_PRIV="$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tag route-table "$P-private")" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_PRIV" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_A" >/dev/null
for s in "$APP_A" "$APP_B" "$DB_A" "$DB_B"; do aws ec2 associate-route-table --route-table-id "$RT_PRIV" --subnet-id "$s" >/dev/null; done

# v1 의 API 서버: AZ-a 에 한 대.
AMI="$(aws ec2 describe-images --owners amazon --query 'Images[0].ImageId' --output text)"
SG_APP="$(aws ec2 create-security-group --vpc-id "$VPC" --group-name "$P-app" --description "api" --query GroupId --output text)"
API_1="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.small --subnet-id "$APP_A" --security-group-ids "$SG_APP" \
  --tag-specifications "$(tag instance "$P-api-1")" --query 'Instances[0].InstanceId' --output text)"
aws ec2 wait instance-running --instance-ids "$API_1"

# ALB 는 2-AZ 에 걸쳐 있지만 대상은 한 대.
ALB="$(aws elbv2 create-load-balancer --name "$P-alb" --subnets "$PUB_A" "$PUB_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
TG="$(aws elbv2 create-target-group --name "$P-api" --protocol HTTP --port 8080 --vpc-id "$VPC" --target-type instance --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG" >/dev/null
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=$API_1"

# 주문 DB: 단일 AZ.
aws rds create-db-subnet-group --db-subnet-group-name "$P-db-subnets" --db-subnet-group-description "orders db" --subnet-ids "$DB_A" "$DB_B" >/dev/null
aws rds create-db-instance --db-instance-identifier "$P-db" --engine postgres --db-instance-class db.t3.micro \
  --allocated-storage 20 --master-username app --master-user-password 'Passw0rd!x' \
  --db-subnet-group-name "$P-db-subnets" --no-multi-az --availability-zone "$AZ_A" >/dev/null
aws rds wait db-instance-available --db-instance-identifier "$P-db"
echo "v1 완성: VPC $VPC · NAT 1개 · API 1대 · ALB · RDS(단일 AZ)"

echo "== 2. SPOF 감사 (v1)"
before="$(uv run --quiet python "$AUDIT" "$VPC_NAME")"
echo "$before"

echo "== 3. 고치기"
echo "-- 3a. AZ-b 에 NAT 게이트웨이를 하나 더, 프라이빗 라우팅을 AZ 별로 나눈다"
EIP_B="$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tag elastic-ip "$P-nat-b")" --query AllocationId --output text)"
NAT_B="$(aws ec2 create-nat-gateway --subnet-id "$PUB_B" --allocation-id "$EIP_B" --tag-specifications "$(tag natgateway "$P-nat-b")" --query NatGateway.NatGatewayId --output text)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_B"
RT_PRIV_B="$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tag route-table "$P-private-b")" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_PRIV_B" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_B" >/dev/null
for s in "$APP_B" "$DB_B"; do
  assoc="$(aws ec2 describe-route-tables --route-table-ids "$RT_PRIV" --query "RouteTables[0].Associations[?SubnetId=='$s'].RouteTableAssociationId" --output text)"
  # ReplaceRouteTableAssociation 은 에뮬레이터에서 501 → 연결을 끊고 새로 잇는다 (실제 AWS 에서는 replace 한 번이면 된다)
  aws ec2 disassociate-route-table --association-id "$assoc"
  aws ec2 associate-route-table --route-table-id "$RT_PRIV_B" --subnet-id "$s" >/dev/null
done

echo "-- 3b. API 서버를 2-AZ Auto Scaling 그룹(최소 2대)으로 바꾸고, 수작업 서버는 내린다"
aws ec2 create-launch-template --launch-template-name "$P-api-lt" \
  --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.small\",\"SecurityGroupIds\":[\"$SG_APP\"]}" >/dev/null
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$P-api-asg" \
  --launch-template "LaunchTemplateName=$P-api-lt,Version=\$Latest" \
  --min-size 2 --max-size 4 --desired-capacity 2 --vpc-zone-identifier "$APP_A,$APP_B" \
  --target-group-arns "$TG" --health-check-type ELB --health-check-grace-period 60
asg_ready() {
  [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$P-api-asg" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text)" = "2" ]
}
wait_until "ASG 인스턴스 2대 InService" 120 asg_ready
# 실제 AWS 는 --target-group-arns 로 붙인 대상 그룹에 ASG 가 인스턴스를 자동 등록한다.
# 에뮬레이터는 자동 등록을 하지 않으므로 같은 결과를 손으로 만든다.
ASG_IDS="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$P-api-asg" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)"
# shellcheck disable=SC2046
aws elbv2 register-targets --target-group-arn "$TG" --targets $(printf 'Id=%s ' $ASG_IDS)
aws elbv2 deregister-targets --target-group-arn "$TG" --targets "Id=$API_1"
aws ec2 terminate-instances --instance-ids "$API_1" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$API_1"

echo "-- 3c. RDS 를 Multi-AZ 로"
aws rds modify-db-instance --db-instance-identifier "$P-db" --multi-az --apply-immediately \
  --query 'DBInstance.[DBInstanceStatus,MultiAZ]' --output text
multi_az_done() {
  [ "$(aws rds describe-db-instances --db-instance-identifier "$P-db" --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)" = "available	True" ]
}
wait_until "RDS Multi-AZ available" 120 multi_az_done

echo "== 4. SPOF 감사 (v2)"
after="$(uv run --quiet python "$AUDIT" "$VPC_NAME")"
echo "$after"

# ---- 단언
grep -q '^SPOF 3건$' <<<"$before" || { echo "FAIL: v1 에서 SPOF 3건을 찾지 못함"; exit 1; }
for kind in NAT COMPUTE DATABASE; do
  grep -q "^\[SPOF\] $kind" <<<"$before" || { echo "FAIL: v1 에서 $kind SPOF 누락"; exit 1; }
done
grep -q '^SPOF 0건$' <<<"$after" || { echo "FAIL: v2 에 SPOF 가 남음"; exit 1; }
echo "LAB01 OK"
