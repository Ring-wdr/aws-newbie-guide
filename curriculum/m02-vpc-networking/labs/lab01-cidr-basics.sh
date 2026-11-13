#!/usr/bin/env bash
# M02 lab01 — CIDR 손계산을 에뮬레이터로 채점하기 (🟢)
# 1) 서브넷 크기별 "사용 가능 IP = 2^(32-n) - 5" 를 손으로 계산하고 AvailableIpAddressCount 와 비교
# 2) VPC·서브넷 크기 제한(/16 ~ /28), VPC 범위 밖, 겹치는 CIDR 오류를 관찰
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

NAME="todayorder-cidr-lab"
teardown_vpc "$NAME"

echo "== 1. 연습용 VPC 10.99.0.0/16 (2^16 = 65,536개 주소)"
VPC="$(aws ec2 create-vpc --cidr-block 10.99.0.0/16 --tag-specifications "$(tags vpc "$NAME")" --query Vpc.VpcId --output text)"
wait_ec2_vpc_available "$VPC"
echo "   $VPC"

echo "== 2. 크기가 다른 서브넷 4개: 손계산 vs AvailableIpAddressCount"
printf '   %-16s %8s %12s %25s\n' CIDR total "2^(32-n)-5" AvailableIpAddressCount
for cidr in 10.99.0.0/20 10.99.16.0/24 10.99.17.0/26 10.99.17.64/28; do
  bits="${cidr#*/}"
  total=$((1 << (32 - bits)))
  mine=$((total - 5))   # 네트워크 주소, VPC 라우터(.1), DNS(.2), 예약(.3), 브로드캐스트(마지막) = 5개
  got="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$cidr" --availability-zone us-east-1a \
    --query Subnet.AvailableIpAddressCount --output text)"
  printf '   %-16s %8s %12s %25s\n' "$cidr" "$total" "$mine" "$got"
  [ "$mine" = "$got" ] || die "$cidr 의 사용 가능 IP: 손계산 $mine, 에뮬레이터 $got"
done

echo "== 3. 서브넷은 /28 보다 작을 수 없다 (/29 시도)"
e_small="$(expect_error aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.99.18.0/29)"
echo "$e_small"

echo "== 4. VPC 범위(10.99.0.0/16) 밖의 서브넷 (10.100.0.0/24 시도)"
e_range="$(expect_error aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.100.0.0/24)"
echo "$e_range"

echo "== 5. 이미 있는 서브넷(10.99.16.0/24)과 겹치는 CIDR (10.99.16.128/25 시도)"
e_conflict="$(expect_error aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.99.16.128/25)"
echo "$e_conflict"

echo "== 6. VPC 자체도 /16 ~ /28 (/15, /29 시도)"
e_vpc15="$(expect_error aws ec2 create-vpc --cidr-block 10.0.0.0/15)"
e_vpc29="$(expect_error aws ec2 create-vpc --cidr-block 10.0.0.0/29)"
echo "$e_vpc15"
echo "$e_vpc29"

echo "== 7. 정리"
teardown_vpc "$NAME"

# ---- 단언
case "$e_small" in *InvalidSubnet.Range*) ;; *) die "/29 서브넷이 거부되지 않음: $e_small" ;; esac
case "$e_range" in *InvalidSubnet.Range*) ;; *) die "범위 밖 서브넷이 거부되지 않음: $e_range" ;; esac
case "$e_conflict" in *InvalidSubnet.Conflict*) ;; *) die "겹치는 서브넷이 거부되지 않음: $e_conflict" ;; esac
case "$e_vpc15$e_vpc29" in *InvalidVpc.Range*InvalidVpc.Range*) ;; *) die "VPC 크기 제한이 재현되지 않음" ;; esac
[ -z "$(vpc_id "$NAME")" ] || die "연습용 VPC가 남아 있음"
echo "LAB01 OK"
