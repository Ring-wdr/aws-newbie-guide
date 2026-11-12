#!/usr/bin/env bash
# M07 lab06 — ECR 저장소, ECS 클러스터·작업 정의·서비스 (🟡: 구성은 되지만 태스크는 이미지를 받지 못해 STOPPED)
#
# 주의: 이 에뮬레이터는 태스크를 시작할 때 컨테이너 이미지를 **실제로 내려받으려** 한다. 이미지 주소를 ECR 형식
# (000000000000.dkr.ecr.us-east-1.amazonaws.com/...)으로 주면 에뮬레이터 컨테이너가 그 실제 AWS 호스트로
# 연결을 시도한다(저자가 관찰: i/o timeout). 이 저장소는 실제 AWS 에 어떤 요청도 보내지 않는 것이 원칙이므로,
# 태스크의 이미지는 절대 해석되지 않는 예약 도메인(.invalid, RFC 2606)에 둔다. 실제 AWS 라면 ECR 저장소 URI 를 쓴다.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO=todayorder/order-api
CLUSTER=todayorder-cluster
FAMILY=todayorder-order-api
SERVICE=todayorder-order-api-svc
EXEC_ROLE=todayorder-ecs-task-execution-role
TASK_ROLE=todayorder-order-api-task-role
IMAGE="registry.todayorder.invalid/todayorder/order-api:1.0"

echo "== 0. 이전 실행 정리"
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null | grep -q .; then
  aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force >/dev/null
fi
aws ecr delete-repository --repository-name "$REPO" --force >/dev/null 2>&1 || true

echo "== 1. ECR 저장소: 푸시할 때 취약점 스캔, 태그 불변(같은 태그 덮어쓰기 금지)"
aws ecr create-repository --repository-name "$REPO" --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE --query 'repository.{Uri: repositoryUri, ScanOnPush: imageScanningConfiguration.scanOnPush, Mutability: imageTagMutability}'
echo "-- 수명 주기 정책: 태그 없는 이미지는 14일 뒤 삭제"
aws ecr put-lifecycle-policy --repository-name "$REPO" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"expire untagged","selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":14},"action":{"type":"expire"}}]}' \
  --query repositoryName --output text
echo "-- docker login 에 쓰는 인증 토큰 (값은 출력하지 않는다)"
aws ecr get-authorization-token --query 'authorizationData[0].{Endpoint: proxyEndpoint, HasToken: length(authorizationToken) > `0`}'
aws ecr describe-images --repository-name "$REPO" --query 'length(imageDetails)'

echo "== 2. 태스크용 네트워크 (awsvpc 모드: 태스크마다 ENI 를 받는다) — VPC·서브넷·보안 그룹"
VPC="$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=todayorder-m07-ecs --query 'Vpcs[0].VpcId' --output text)"
if [ "$VPC" = None ]; then
  VPC="$(aws ec2 create-vpc --cidr-block 10.77.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=todayorder-m07-ecs}]' --query Vpc.VpcId --output text)"
  aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.77.1.0/24 --availability-zone us-east-1a >/dev/null
  aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.77.2.0/24 --availability-zone us-east-1b >/dev/null
  aws ec2 create-security-group --vpc-id "$VPC" --group-name todayorder-m07-ecs-tasks --description "order api tasks" >/dev/null
fi
SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text | tr '\t' ',')"
SG="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=todayorder-m07-ecs-tasks --query 'SecurityGroups[0].GroupId' --output text)"

echo "== 3. 역할 2개: 작업 실행 역할(ECS 에이전트가 이미지 풀·로그 전송) vs 작업 역할(앱 코드가 AWS 호출)"
ensure_role "$EXEC_ROLE" ecs-tasks.amazonaws.com
aws iam attach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
ensure_role "$TASK_ROLE" ecs-tasks.amazonaws.com
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name orders-rw --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\"],\"Resource\":\"arn:aws:dynamodb:$REGION:$ACCOUNT:table/todayorder-orders\"}]}"

echo "== 4. 클러스터 (Fargate 용량 공급자)"
aws ecs create-cluster --cluster-name "$CLUSTER" --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
  --query 'cluster.{Name: clusterName, Status: status, Providers: capacityProviders}'

echo "== 5. 작업 정의 (Fargate: 0.25 vCPU, 512 MiB, awsvpc)"
cat >"$WORK/containers.json" <<JSON
[{"name": "order-api", "image": "$IMAGE", "essential": true,
  "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
  "environment": [{"name": "TABLE_NAME", "value": "todayorder-orders"}]}]
JSON
aws ecs register-task-definition --family "$FAMILY" --requires-compatibilities FARGATE --network-mode awsvpc \
  --cpu 256 --memory 512 --execution-role-arn "arn:aws:iam::$ACCOUNT:role/$EXEC_ROLE" \
  --task-role-arn "arn:aws:iam::$ACCOUNT:role/$TASK_ROLE" --container-definitions "file://$WORK/containers.json" \
  --query 'taskDefinition.{Family: family, Revision: revision, Cpu: cpu, Memory: memory, Network: networkMode, Compat: requiresCompatibilities}'

NET="awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}"
echo "== 6. 서비스: 태스크 2개를 항상 유지"
aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition "$FAMILY" \
  --desired-count 2 --launch-type FARGATE --network-configuration "$NET" \
  --query 'service.{Name: serviceName, Status: status, Desired: desiredCount, LaunchType: launchType}'

echo "== 7. 단발성 태스크(run-task) 하나를 띄우고 상태를 끝까지 따라간다"
TASK="$(aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE --task-definition "$FAMILY" \
  --network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
seen=""
stopped() {
  local s
  s="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --query 'tasks[0].lastStatus' --output text)"
  case " $seen " in *" $s "*) ;; *) seen="$seen $s"; echo "  lastStatus: $s" ;; esac
  [ "$s" = STOPPED ]
}
poll 120 "태스크 종료" stopped
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].{lastStatus: lastStatus, desiredStatus: desiredStatus, stopCode: stopCode}'
reason="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --query 'tasks[0].stoppedReason' --output text)"
echo "stoppedReason: $reason" | cut -c1-200

echo "== 8. 서비스가 띄운 태스크도 같은 이유로 멈춘다 — 서비스의 STOPPED 태스크 하나 확인"
svc_stopped() {
  aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status STOPPED \
    --output json --query taskArns >"$WORK/svc.json"
  grep -q 'arn:' "$WORK/svc.json"
}
poll 120 "서비스 태스크 STOPPED" svc_stopped
SVC_TASK="$(grep -o 'arn:[^"]*' "$WORK/svc.json" | head -1)"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$SVC_TASK" \
  --query 'tasks[0].{group: group, lastStatus: lastStatus, stopCode: stopCode}'
svc_reason="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$SVC_TASK" --query 'tasks[0].stoppedReason' --output text)"
echo "stoppedReason: $svc_reason" | cut -c1-80
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{Desired: desiredCount, Running: runningCount}'

echo "== 9. 정리: 서비스 desired 0 → 삭제"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 --query service.desiredCount
aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --query service.status --output text

# ---- 단언
grep -q CannotPullContainerError <<<"$reason" || fail "예상한 이미지 풀 실패가 아님: $reason"
grep -q CannotPullContainerError <<<"$svc_reason" || fail "서비스 태스크의 정지 이유: $svc_reason"
echo "LAB06 OK"
