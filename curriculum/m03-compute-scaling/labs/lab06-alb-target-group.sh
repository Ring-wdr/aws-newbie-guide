#!/usr/bin/env bash
# M03 lab06 — ALB + 대상 그룹 + 리스너 규칙, 그리고 NLB (🟡)
# 보안 그룹 → ALB(2개 AZ) → 대상 그룹(헬스 체크 /health) → 대상 등록 → 리스너(HTTP:80) → 경로 규칙
# → 스티키 세션·등록 취소 지연 → 인스턴스 중지 시 대상 상태 → NLB(교차 영역 기본 꺼짐)
# 헬스 체크는 실제로 HTTP 를 보내지 않는다(인스턴스가 running 이면 healthy). 규칙이 실제로 응답하는지는 lab07(선택 과제).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab06"
ALB_NAME="todayorder-alb"
NLB_NAME="todayorder-nlb"
TG_NAME="todayorder-api-tg"
TCP_TG_NAME="todayorder-api-tcp-tg"

lb_arn() { aws elbv2 describe-load-balancers --names "$1" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true; }
tg_arn() { aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true; }
cleanup() {
  local n a
  for n in "$ALB_NAME" "$NLB_NAME"; do
    a="$(lb_arn "$n")"
    [ -n "$a" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$a"
  done
  for n in "$TG_NAME" "$TCP_TG_NAME"; do
    a="$(tg_arn "$n")"
    [ -n "$a" ] && aws elbv2 delete-target-group --target-group-arn "$a"
  done
  m03_terminate_tagged "$LAB"
  a="$(aws ec2 describe-security-groups --filters Name=group-name,Values=todayorder-alb-sg --query 'SecurityGroups[].GroupId' --output text)"
  [ -n "$a" ] && aws ec2 delete-security-group --group-id "$a" >/dev/null 2>&1 || true
  return 0
}
cleanup
m03_network
AMI="$(m03_ami)"

echo "== 1. ALB 용 보안 그룹: 인터넷에서 80 허용"
SG="$(aws ec2 create-security-group --group-name todayorder-alb-sg --description "TodayOrder ALB" --vpc-id "$M03_VPC" \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --query 'SecurityGroupRules[0].[IpProtocol,FromPort,CidrIpv4]' --output text

echo "== 2. ALB 는 최소 2개 AZ 의 서브넷이 필요하다"
expect_error ValidationError aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --subnets "$M03_SUBNET_A"
ALB="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
  --subnets "$M03_SUBNET_A" "$M03_SUBNET_B" --security-groups "$SG" \
  --tags Key=Project,Value=todayorder \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" \
  --query 'LoadBalancers[0].{Type:Type,Scheme:Scheme,State:State.Code,DNSName:DNSName,AZs:AvailabilityZones[].ZoneName}'
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB" && echo "waiter: active"

echo "== 3. 대상 그룹: HTTP 8080, 헬스 체크 GET /health (15초 간격, 2번 성공=healthy, 3번 실패=unhealthy)"
TG="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8080 --vpc-id "$M03_VPC" \
  --target-type instance --health-check-path /health --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 describe-target-groups --target-group-arns "$TG" \
  --query 'TargetGroups[0].[Protocol,Port,TargetType,HealthCheckPath,HealthCheckIntervalSeconds,HealthyThresholdCount,UnhealthyThresholdCount]' --output text

echo "== 4. API 서버 2대(각 AZ에 1대)를 대상으로 등록"
IA="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --subnet-id "$M03_SUBNET_A" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=todayorder-api-a},{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[0].InstanceId' --output text)"
IB="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --subnet-id "$M03_SUBNET_B" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=todayorder-api-b},{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[0].InstanceId' --output text)"
wait_for instance running "$IA" "$IB" >/dev/null
aws elbv2 register-targets --target-group-arn "$TG" --targets Id="$IA" Id="$IB"
echo "-- 리스너가 없으면 대상 그룹은 아직 쓰이지 않는다"
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text

echo "== 5. 리스너 HTTP:80 → 기본 동작: 대상 그룹으로 전달"
LIS="$(aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG" --query 'Listeners[0].ListenerArn' --output text)"
all_healthy() {
  [ "$(aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)" = 2 ]
}
poll 60 "대상 2개 healthy" all_healthy
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text

echo "== 6. 리스너 규칙 (번호가 작을수록 먼저 평가, 맞는 규칙이 없으면 default)"
aws elbv2 create-rule --listener-arn "$LIS" --priority 10 \
  --conditions Field=path-pattern,Values='/api/*' \
  --actions Type=forward,TargetGroupArn="$TG" --query 'Rules[0].Priority' --output text >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 20 \
  --conditions Field=path-pattern,Values=/ping \
  --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=200,ContentType=text/plain,MessageBody=todayorder-ok}' \
  --query 'Rules[0].Priority' --output text >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 30 \
  --conditions '[{"Field":"http-header","HttpHeaderConfig":{"HttpHeaderName":"X-Canary","Values":["on"]}}]' \
  --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=200,ContentType=text/plain,MessageBody=canary}' \
  --query 'Rules[0].Priority' --output text >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 40 \
  --conditions Field=path-pattern,Values=/old-menu \
  --actions 'Type=redirect,RedirectConfig={Path=/api/menu,StatusCode=HTTP_301}' \
  --query 'Rules[0].Priority' --output text >/dev/null
aws elbv2 describe-rules --listener-arn "$LIS" \
  --query 'Rules[].[Priority,Conditions[0].Field,Actions[0].Type]' --output text
echo "-- 같은 우선순위는 둘 수 없다"
expect_error PriorityInUse aws elbv2 create-rule --listener-arn "$LIS" --priority 10 \
  --conditions Field=path-pattern,Values=/dup --actions Type=forward,TargetGroupArn="$TG"
rule_count="$(aws elbv2 describe-rules --listener-arn "$LIS" --query 'length(Rules)' --output text)"

echo "== 7. 대상 그룹 속성: 스티키 세션(1시간), 등록 취소 지연 30초"
echo "-- 기본값"
aws elbv2 describe-target-group-attributes --target-group-arn "$TG" \
  --query 'Attributes[?Key==`stickiness.enabled`||Key==`deregistration_delay.timeout_seconds`||Key==`load_balancing.algorithm.type`||Key==`load_balancing.cross_zone.enabled`].[Key,Value]' --output text
aws elbv2 modify-target-group-attributes --target-group-arn "$TG" --attributes \
  Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie \
  Key=stickiness.lb_cookie.duration_seconds,Value=3600 Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
echo "-- 변경 후"
aws elbv2 describe-target-group-attributes --target-group-arn "$TG" \
  --query 'Attributes[?starts_with(Key,`stickiness.lb`)||Key==`stickiness.enabled`||Key==`deregistration_delay.timeout_seconds`].[Key,Value]' --output text
sticky="$(aws elbv2 describe-target-group-attributes --target-group-arn "$TG" --query 'Attributes[?Key==`stickiness.enabled`].Value' --output text)"
echo "-- ALB 의 교차 영역 로드 밸런싱 (ALB 는 기본 켜짐, 대상 그룹 단위로 끌 수 있다)"
aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB" \
  --query 'Attributes[?Key==`load_balancing.cross_zone.enabled`||Key==`idle_timeout.timeout_seconds`].[Key,Value]' --output text

echo "== 8. api-a 를 중지하면? 대상 상태가 바뀐다 (실제 HTTP 검사가 아니라 인스턴스 상태를 따른다)"
aws ec2 stop-instances --instance-ids "$IA" >/dev/null
wait_for instance stopped "$IA" >/dev/null
a_unhealthy() {
  [ "$(aws elbv2 describe-target-health --target-group-arn "$TG" --targets Id="$IA" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)" = unhealthy ]
}
poll 60 "api-a unhealthy" a_unhealthy
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text

echo "== 9. NLB: TCP, 교차 영역 기본 꺼짐"
NLB="$(aws elbv2 create-load-balancer --name "$NLB_NAME" --type network --scheme internal \
  --subnets "$M03_SUBNET_A" "$M03_SUBNET_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 create-target-group --name "$TCP_TG_NAME" --protocol TCP --port 8080 --vpc-id "$M03_VPC" --target-type ip \
  --query 'TargetGroups[0].[Protocol,Port,TargetType,HealthCheckProtocol]' --output text
aws elbv2 describe-load-balancers --load-balancer-arns "$NLB" --query 'LoadBalancers[0].[Type,Scheme,DNSName]' --output text
nlb_cross="$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$NLB" \
  --query 'Attributes[?Key==`load_balancing.cross_zone.enabled`].Value' --output text)"
echo "load_balancing.cross_zone.enabled = $nlb_cross"

echo "== 10. 정리"
cleanup
echo "정리 완료"

# ---- 단언
[ "$rule_count" = "5" ] || fail "규칙 수가 5(4개 + default)가 아님 ($rule_count)"
[ "$sticky" = "true" ] || fail "스티키 세션이 켜지지 않음 ($sticky)"
[ "$nlb_cross" = "false" ] || fail "NLB 교차 영역 기본값이 false 가 아님 ($nlb_cross)"
echo "LAB06 OK"
