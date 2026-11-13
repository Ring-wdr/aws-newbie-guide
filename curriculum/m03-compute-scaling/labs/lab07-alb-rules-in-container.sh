#!/usr/bin/env bash
# M03 lab07 — (선택 과제) ALB 리스너 규칙이 실제로 응답하는지 컨테이너 안에서 확인 (🟡)
#
# 에뮬레이터는 ALB 리스너를 "컨테이너 안의" 127.0.0.1:<임의 포트>에 실제로 띄운다. 이 포트는 내 Mac 으로
# 게시되지 않으므로 `docker exec aws-emulator-$EMULATOR_PORT curl ...` 로 컨테이너 안에서 요청한다.
# 실제 AWS에서는 ALB DNS 이름(…elb.amazonaws.com)으로 인터넷에서 바로 요청한다. docker 가 없으면 이 lab 은 건너뛴다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab07"
ALB_NAME="todayorder-alb-rules"
TG_NAME="todayorder-rules-tg"
CONTAINER="aws-emulator-$EMULATOR_PORT"

if ! docker exec "$CONTAINER" true >/dev/null 2>&1; then
  echo "SKIP: docker exec $CONTAINER 를 쓸 수 없다 (선택 과제)"
  exit 0
fi

cleanup() {
  local a
  a="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  [ -n "$a" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$a"
  a="$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
  [ -n "$a" ] && aws elbv2 delete-target-group --target-group-arn "$a"
  m03_terminate_tagged "$LAB"
  return 0
}
cleanup
m03_network
AMI="$(m03_ami)"

echo "== 1. ALB + 대상 그룹(인스턴스 1대) + 리스너 + 규칙 4개"
ALB="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application \
  --subnets "$M03_SUBNET_A" "$M03_SUBNET_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
TG="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 8080 --vpc-id "$M03_VPC" \
  --health-check-path /health --query 'TargetGroups[0].TargetGroupArn' --output text)"
IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --subnet-id "$M03_SUBNET_A" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]" \
  --query 'Instances[0].InstanceId' --output text)"
wait_for instance running "$IID" >/dev/null
aws elbv2 register-targets --target-group-arn "$TG" --targets Id="$IID"
LIS="$(aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG" --query 'Listeners[0].ListenerArn' --output text)"
aws elbv2 create-rule --listener-arn "$LIS" --priority 20 --conditions Field=path-pattern,Values=/ping \
  --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=200,ContentType=text/plain,MessageBody=todayorder-ok}' >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 30 \
  --conditions '[{"Field":"http-header","HttpHeaderConfig":{"HttpHeaderName":"X-Canary","Values":["on"]}}]' \
  --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=200,ContentType=text/plain,MessageBody=canary}' >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 40 --conditions Field=path-pattern,Values=/old-menu \
  --actions 'Type=redirect,RedirectConfig={Path=/api/menu,StatusCode=HTTP_301}' >/dev/null
aws elbv2 create-rule --listener-arn "$LIS" --priority 50 --conditions Field=host-header,Values=admin.todayorder.example \
  --actions 'Type=fixed-response,FixedResponseConfig={StatusCode=403,ContentType=text/plain,MessageBody=admin-blocked}' >/dev/null
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB"
DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" --query 'LoadBalancers[0].DNSName' --output text)"
echo "ALB DNSName = $DNS  (에뮬레이터: 컨테이너 안의 주소)"
# 에뮬레이터가 돌려준 주소에만 접속한다: 루프백이 아니면(바깥 호스트일 수 있으면) 접속하지 않고 멈춘다
# (정확히 127.0.0.1 또는 127.0.0.1:<포트> 만. 127.0.0.1.<도메인> 같은 이름은 DNS 를 거치므로 거부)
[[ "$DNS" =~ ^127\.0\.0\.1(:[0-9]+)?$ ]] || fail "ALB DNSName 이 루프백 주소가 아니다($DNS) — 접속하지 않는다 (에뮬레이터가 바뀌었을 수 있다 → 레슨 갱신)"

req() { docker exec "$CONTAINER" curl -s -m 5 -w ' [HTTP %{http_code}]' "$@"; echo; }
echo "== 2. 내 Mac 에서 직접 → 연결 안 됨"
if curl -s -m 3 "http://$DNS/ping" >/dev/null 2>&1; then host_ok=yes; else host_ok=no; fi
echo "호스트에서 연결 성공? $host_ok"

echo "== 3. 컨테이너 안에서 요청"
echo -n "GET /ping              → "; ping_out="$(req "http://$DNS/ping")"; echo "$ping_out"
echo -n "GET / (X-Canary: on)   → "; canary_out="$(req -H 'X-Canary: on' "http://$DNS/")"; echo "$canary_out"
echo -n "GET /old-menu          → "; redir_out="$(req -o /dev/null "http://$DNS/old-menu")"; echo "$redir_out"
echo -n "GET /api/orders        → "; fwd_out="$(req -o /dev/null "http://$DNS/api/orders")"; echo "$fwd_out"
echo -n "GET / (Host: admin…)   → "; host_out="$(req -o /dev/null -H 'Host: admin.todayorder.example' "http://$DNS/")"; echo "$host_out"

echo "== 4. 정리"
cleanup
echo "정리 완료"

# ---- 단언: 관찰한 동작이 레슨 5 의 설명과 같은지
[ "$host_ok" = "no" ] || fail "호스트에서 ALB 에 연결됨 (에뮬레이터가 바뀌었을 수 있다 → 레슨 갱신)"
case "$ping_out" in *todayorder-ok*"HTTP 200"*) ;; *) fail "/ping 고정 응답이 아님 ($ping_out)" ;; esac
case "$canary_out" in *canary*"HTTP 200"*) ;; *) fail "X-Canary 헤더 규칙이 동작하지 않음 ($canary_out)" ;; esac
case "$redir_out" in *"HTTP 301"*) ;; *) fail "리디렉션이 301 이 아님 ($redir_out)" ;; esac
case "$fwd_out" in *"HTTP 502"*) ;; *) fail "실체 없는 대상으로의 전달이 502 가 아님 ($fwd_out)" ;; esac
case "$host_out" in *"HTTP 502"*) ;; *) fail "host-header 규칙 동작이 바뀜 ($host_out) → 레슨·README 갱신" ;; esac
echo "LAB07 OK"
