#!/usr/bin/env bash
# M03 lab08 — 시작 템플릿(버전) + Auto Scaling 그룹 (🟢 생성·희망 용량 변경·인스턴스 새로 고침)
# 시작 템플릿 v1(t3.micro) → v2(t3.small, v1 상속) → ASG(min 2 / max 6 / desired 2, 2개 AZ)
# → 희망 용량 4 (확장) → 범위 밖 값 거부 → 2 (축소: 어떤 인스턴스가 남는가?) → 인스턴스 새로 고침으로 전부 v2
# 조정 정책·예약 작업·수명 주기 후크·자가 치유는 lab09.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

ASG="todayorder-api-asg"
LT_NAME="todayorder-api-lt"
TG_NAME="todayorder-asg-tg"

cleanup() {
  local a ids
  if [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text)" != "0" ]; then
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete
  fi
  ids="$(aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values="$ASG" \
    Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
  # shellcheck disable=SC2086
  [ -n "$ids" ] && wait_for instance terminated $ids >/dev/null
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null 2>&1 || true
  a="$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  [ -n "$a" ] && aws elbv2 delete-target-group --target-group-arn "$a"
  return 0
}
cleanup
m03_network
AMI="$(m03_ami)"

asg_instances() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus,InstanceType,LaunchTemplate.Version]' --output text | sort -k2,2 -k1,1
}
count_inservice() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' --output text
}
has_n() { [ "$(count_inservice)" = "$1" ] && [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups[0].Instances)' --output text)" = "$1" ]; }

echo "== 1. 시작 템플릿 v1: AMI, t3.micro, IMDSv2 필수, 태그"
LT="$(aws ec2 create-launch-template --launch-template-name "$LT_NAME" --version-description "v1 t3.micro" \
  --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\",\"MetadataOptions\":{\"HttpTokens\":\"required\"},\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"Project\",\"Value\":\"todayorder\"}]}]}" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)"
echo "$LT"

echo "== 2. 버전 2: v1 을 원본으로 인스턴스 유형만 t3.small 로 (나머지는 상속)"
aws ec2 create-launch-template-version --launch-template-id "$LT" --source-version 1 \
  --version-description "v2 t3.small" --launch-template-data '{"InstanceType":"t3.small"}' \
  --query 'LaunchTemplateVersion.VersionNumber' --output text
aws ec2 describe-launch-template-versions --launch-template-id "$LT" \
  --query 'LaunchTemplateVersions[].[VersionNumber,VersionDescription,DefaultVersion,LaunchTemplateData.InstanceType,LaunchTemplateData.ImageId,LaunchTemplateData.MetadataOptions.HttpTokens]' --output text | sort
aws ec2 describe-launch-templates --launch-template-ids "$LT" \
  --query 'LaunchTemplates[0].[DefaultVersionNumber,LatestVersionNumber]' --output text

echo "== 3. ASG: 2개 AZ, min 2 / max 6 / desired 2, 대상 그룹 + ELB 헬스 체크, 기본(\$Default) 버전 = v1"
TG="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8080 --vpc-id "$M03_VPC" \
  --health-check-path /health --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG" \
  --launch-template "LaunchTemplateId=$LT,Version=\$Default" \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "$M03_SUBNET_A,$M03_SUBNET_B" \
  --target-group-arns "$TG" --health-check-type ELB --health-check-grace-period 120 \
  --tags Key=Project,Value=todayorder,PropagateAtLaunch=true
poll 60 "InService 2대" has_n 2
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,HealthCheck:HealthCheckType,Grace:HealthCheckGracePeriod,AZs:AvailabilityZones,TerminationPolicies:TerminationPolicies}'
asg_instances
azs_used="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"
echo "-- ASG 인스턴스는 EC2 에서도 보인다 (태그 aws:autoscaling:groupName)"
aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values="$ASG" Name=instance-state-name,Values=running \
  --query 'length(Reservations[].Instances[])' --output text

echo "== 4. 기본 버전을 v2 로 바꾸고 희망 용량 4 (확장: 새 인스턴스는 v2 로)"
aws ec2 modify-launch-template --launch-template-id "$LT" --default-version 2 \
  --query 'LaunchTemplate.DefaultVersionNumber' --output text
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 4
poll 60 "InService 4대" has_n 4
asg_instances

echo "== 5. 범위 밖 희망 용량은 거부된다"
expect_error ValidationError aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 10
expect_error ValidationError aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 1

echo "== 6. 희망 용량 2 (축소): 어떤 인스턴스가 남을까?"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 2
poll 60 "InService 2대" has_n 2
asg_instances
echo "(실제 AWS의 기본 종료 정책은 AZ 균형 → 오래된 시작 템플릿 버전(v1) 순으로 고른다. 레슨 6 참고)"

echo "== 7. 인스턴스 새로 고침(Instance Refresh): 모든 인스턴스를 현재 기본 버전(v2)으로 교체"
RID="$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG" \
  --preferences MinHealthyPercentage=50 --query InstanceRefreshId --output text)"
refresh_done() {
  [ "$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG" --instance-refresh-ids "$RID" \
    --query 'InstanceRefreshes[0].Status' --output text)" = Successful ]
}
poll 120 "인스턴스 새로 고침 Successful" refresh_done
aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG" --instance-refresh-ids "$RID" \
  --query 'InstanceRefreshes[0].[Status,PercentageComplete,Preferences.MinHealthyPercentage]' --output text
poll 60 "InService 2대" has_n 2
asg_instances
types_after="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].InstanceType' --output text | tr '\t' '\n' | sort -u | tr -d '\n')"

echo "== 8. (에뮬레이터 차이) ASG 에 연결한 대상 그룹에 인스턴스가 자동 등록되지 않는다"
tg_count="$(aws elbv2 describe-target-health --target-group-arn "$TG" --query 'length(TargetHealthDescriptions)' --output text)"
echo "대상 그룹의 대상 수: $tg_count  (실제 AWS: ASG 인스턴스가 자동 등록된다)"

echo "== 9. 정리 (ASG 강제 삭제 → 인스턴스도 종료)"
cleanup
echo "정리 완료"

# ---- 단언
[ "$azs_used" = "2" ] || fail "인스턴스가 2개 AZ 에 퍼지지 않음 ($azs_used)"
[ "$types_after" = "t3.small" ] || fail "인스턴스 새로 고침 후 유형이 모두 t3.small 이 아님 ($types_after)"
[ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'length(AutoScalingGroups)' --output text)" = "0" ] || fail "ASG 가 남아 있음"
echo "LAB08 OK"
