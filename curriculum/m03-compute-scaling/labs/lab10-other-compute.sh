#!/usr/bin/env bash
# M03 lab10 — 그 밖의 컴퓨트 한눈에: Elastic Beanstalk, Lightsail, Batch (🟡)
# 설정값·카탈로그를 읽고 리소스를 만들어 본다. 실제 애플리케이션·작업은 실행되지 않는다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

APP="todayorder-admin"
ENV_NAME="todayorder-admin-dev"
LS="todayorder-landing"
CE="todayorder-batch-ce"

cleanup() {
  aws elasticbeanstalk delete-application --application-name "$APP" --terminate-env-by-force >/dev/null 2>&1 || true
  aws lightsail delete-instance --instance-name "$LS" >/dev/null 2>&1 || true
  if aws batch describe-compute-environments --compute-environments "$CE" --query 'computeEnvironments[0].computeEnvironmentName' --output text 2>/dev/null | grep -q "$CE"; then
    aws batch update-compute-environment --compute-environment "$CE" --state DISABLED >/dev/null 2>&1 || true
    aws batch delete-compute-environment --compute-environment "$CE" >/dev/null 2>&1 || true
  fi
  return 0
}
cleanup
m03_network

echo "== 1. Elastic Beanstalk: 플랫폼(솔루션 스택) 카탈로그"
aws elasticbeanstalk list-available-solution-stacks \
  --query 'SolutionStacks[?contains(@, `Python`) || contains(@, `Corretto 21`)] | [:4]' --output text | tr '\t' '\n'
STACK="$(aws elasticbeanstalk list-available-solution-stacks \
  --query 'SolutionStacks[?contains(@, `running Python 3.13`)] | [0]' --output text)"

echo "== 2. Beanstalk 이 대신 만들어 주는 Auto Scaling 기본값 읽기"
aws elasticbeanstalk describe-configuration-options --solution-stack-name "$STACK" \
  --options Namespace=aws:autoscaling:asg --query 'Options[].[Name,DefaultValue]' --output text

echo "== 3. 애플리케이션 + 환경 만들기 (코드를 올리면 EC2·ASG·ELB·경보를 Beanstalk 이 관리)"
aws elasticbeanstalk create-application --application-name "$APP" --description "TodayOrder 관리자 화면" \
  --query 'Application.ApplicationName' --output text
aws elasticbeanstalk create-environment --application-name "$APP" --environment-name "$ENV_NAME" \
  --solution-stack-name "$STACK" --query '[EnvironmentName,Status]' --output text
env_ready() {
  [ "$(aws elasticbeanstalk describe-environments --environment-names "$ENV_NAME" \
    --query 'Environments[0].Status' --output text)" = Ready ]
}
poll 60 "Beanstalk 환경 Ready" env_ready
aws elasticbeanstalk describe-environments --environment-names "$ENV_NAME" \
  --query 'Environments[0].[Status,Health,CNAME]' --output text
echo "-- 환경이 거느린 리소스 (이름만 기록된다: 에뮬레이터는 실제 ASG·ELB 를 만들지 않는다)"
aws elasticbeanstalk describe-environment-resources --environment-name "$ENV_NAME" \
  --query 'EnvironmentResources.{ASG:length(AutoScalingGroups),Instances:length(Instances),LaunchTemplates:length(LaunchTemplates),LoadBalancers:length(LoadBalancers),Alarms:length(Triggers)}'
eb_asg="$(aws elasticbeanstalk describe-environment-resources --environment-name "$ENV_NAME" \
  --query 'length(EnvironmentResources.AutoScalingGroups)' --output text)"

echo "== 4. Lightsail: 월 정액 번들 카탈로그 (가격은 에뮬레이터 값)"
aws lightsail get-bundles --query 'bundles[:4].[bundleId,price,cpuCount,ramSizeInGb,diskSizeInGb,transferPerMonthInGb]' --output text
aws lightsail create-instances --instance-names "$LS" --availability-zone us-east-1a \
  --blueprint-id amazon_linux_2023 --bundle-id nano_3_0 --query 'operations[0].[operationType,status]' --output text
ls_state() { [ "$(aws lightsail get-instance --instance-name "$LS" --query 'instance.state.name' --output text)" = running ]; }
poll 60 "Lightsail running" ls_state
aws lightsail get-instance --instance-name "$LS" --query 'instance.[name,state.name,blueprintId,bundleId]' --output text

echo "== 5. AWS Batch: Fargate Spot 컴퓨트 환경"
SG="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$M03_VPC" Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text)"
aws batch create-compute-environment --compute-environment-name "$CE" --type MANAGED \
  --compute-resources "type=FARGATE_SPOT,maxvCpus=16,subnets=$M03_SUBNET_A,$M03_SUBNET_B,securityGroupIds=$SG" \
  --query computeEnvironmentName --output text
aws batch describe-compute-environments --compute-environments "$CE" \
  --query 'computeEnvironments[0].[computeEnvironmentName,type,state,computeResources.type,computeResources.maxvCpus]' --output text
ce_type="$(aws batch describe-compute-environments --compute-environments "$CE" --query 'computeEnvironments[0].computeResources.type' --output text)"

echo "== 6. Outposts·Serverless Application Repository 목록 (빈 목록)"
aws outposts list-outposts --query 'length(Outposts)' --output text
aws serverlessrepo list-applications --query 'length(Applications)' --output text

echo "== 7. 정리"
cleanup
echo "정리 완료"

# ---- 단언
[ "$eb_asg" -ge 1 ] || fail "Beanstalk 환경 리소스에 ASG 가 없음"
[ "$ce_type" = "FARGATE_SPOT" ] || fail "Batch 컴퓨트 환경 유형이 FARGATE_SPOT 이 아님 ($ce_type)"
[ "$(aws elasticbeanstalk describe-applications --application-names "$APP" --query 'length(Applications)' --output text)" = "0" ] || fail "Beanstalk 애플리케이션이 남음"
echo "LAB10 OK"
