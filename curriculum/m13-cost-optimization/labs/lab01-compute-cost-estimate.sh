#!/usr/bin/env bash
# M13 lab01 — 인벤토리로 월 비용 추정하기: 온디맨드 vs Savings Plans·Graviton vs 스팟, gp2→gp3, 노는 IP
# (🟢 인벤토리 읽기 / 🔴 실제 청구 금액 — Cost Explorer 501, 에뮬레이터는 과금하지 않음)
#
# TodayOrder 의 "지금" 구성을 에뮬레이터에 만들고(태그 cost-lab=m13), sdk/cost_estimator.py 가 읽어
# 예시 단가로 현재 월 비용과 개선안을 계산한다. 숫자는 레슨 02 워크시트의 정답과 같아야 한다.
# ⚠️ 단가는 예시 숫자다. 실제 가격은 AWS Pricing Calculator 로 확인한다.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/env.sh"
source "$ROOT/scripts/lab-wait.sh"   # CLI waiter(15초 간격) 대신 같은 조건을 1초 간격으로 확인 (wait_ec2_*)
EST="$ROOT/curriculum/m13-cost-optimization/sdk/cost_estimator.py"
LAB="m13"
cd "$ROOT"

teardown() {
  local ids id vpc
  ids="$(aws ec2 describe-instances --filters "Name=tag:cost-lab,Values=$LAB" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    # shellcheck disable=SC2086
    wait_ec2_instance_terminated $ids
  fi
  for id in $(aws ec2 describe-volumes --filters "Name=tag:cost-lab,Values=$LAB" --query 'Volumes[].VolumeId' --output text); do
    aws ec2 delete-volume --volume-id "$id"
  done
  for id in $(aws ec2 describe-nat-gateways --filter "Name=tag:cost-lab,Values=$LAB" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text); do
    aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null
  done
  for i in $(seq 120); do
    [ -z "$(aws ec2 describe-nat-gateways --filter "Name=tag:cost-lab,Values=$LAB" "Name=state,Values=pending,available,deleting" --query 'NatGateways[].NatGatewayId' --output text)" ] && break
    sleep 1
  done
  for id in $(aws ec2 describe-addresses --filters "Name=tag:cost-lab,Values=$LAB" --query 'Addresses[].AllocationId' --output text) \
    $(aws ec2 describe-addresses --filters "Name=tag:cost-lab-nat,Values=$LAB" --query 'Addresses[].AllocationId' --output text); do
    aws ec2 release-address --allocation-id "$id"
  done
  for vpc in $(aws ec2 describe-vpcs --filters "Name=tag:cost-lab,Values=$LAB" --query 'Vpcs[].VpcId' --output text); do
    for id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$id"
    done
    aws ec2 delete-vpc --vpc-id "$vpc"
  done
}
teardown

T="Key=cost-lab,Value=$LAB"
echo "== 1. TodayOrder 의 현재 구성 만들기 (태그 cost-lab=$LAB)"
VPC="$(aws ec2 create-vpc --cidr-block 10.31.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{$T}]" --query Vpc.VpcId --output text)"
SUBNET="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.31.0.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text)"
AMI="$(aws ec2 describe-images --owners amazon --query 'Images[0].ImageId' --output text)"
aws ec2 run-instances --image-id "$AMI" --instance-type m7i.large --count 4 --subnet-id "$SUBNET" \
  --tag-specifications "ResourceType=instance,Tags=[{$T},{Key=Name,Value=api},{Key=workload,Value=steady}]" >/dev/null
aws ec2 run-instances --image-id "$AMI" --instance-type c7i.xlarge --count 6 --subnet-id "$SUBNET" \
  --tag-specifications "ResourceType=instance,Tags=[{$T},{Key=Name,Value=settlement-batch},{Key=workload,Value=batch},{Key=hours-per-month,Value=240}]" >/dev/null
for _ in 1 2 3 4; do
  aws ec2 create-volume --availability-zone us-east-1a --volume-type gp2 --size 200 \
    --tag-specifications "ResourceType=volume,Tags=[{$T}]" >/dev/null
done
# NAT 용 퍼블릭 IP: 실제 AWS 에서는 NAT 요금과 별도로 퍼블릭 IPv4 요금이 붙는다. 추정기는 이 IP 의 요금을
# NAT 줄에 더해 계산하므로(중복 계산 방지) cost-lab 대신 정리용 태그만 붙인다
EIP_NAT="$(aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=cost-lab-nat,Value=$LAB}]" --query AllocationId --output text)"
aws ec2 create-nat-gateway --subnet-id "$SUBNET" --allocation-id "$EIP_NAT" \
  --tag-specifications "ResourceType=natgateway,Tags=[{$T},{Key=monthly-gb,Value=1000}]" --query NatGateway.NatGatewayId --output text
aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{$T}]" --query PublicIp --output text
ids="$(aws ec2 describe-instances --filters "Name=tag:cost-lab,Values=$LAB" "Name=instance-state-name,Values=pending,running" --query 'Reservations[].Instances[].InstanceId' --output text)"
# shellcheck disable=SC2086
wait_ec2_instance_running $ids
nat_ok() { [ -n "$(aws ec2 describe-nat-gateways --filter "Name=tag:cost-lab,Values=$LAB" "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text)" ]; }
for _ in $(seq 120); do nat_ok && break; sleep 1; done
nat_ok || { echo "FAIL: NAT 게이트웨이가 available 이 되지 않음"; exit 1; }
aws ec2 describe-instances --filters "Name=tag:cost-lab,Values=$LAB" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceType,Tags[?Key==`workload`]|[0].Value]' --output text | sort | uniq -c

echo "== 2. 인벤토리를 읽어 월 비용 추정 (예시 단가)"
out="$(uv run --quiet python "$EST" "$LAB")"
echo "$out"

# ---- 단언: 레슨 02 워크시트의 정답과 같아야 한다
grep -q '^TOTAL now=725.00 optimized=395.43$' <<<"$out" || { echo "FAIL: 합계가 워크시트 정답(725.00 → 395.43)과 다름"; exit 1; }
echo "LAB01 OK"
