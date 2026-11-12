#!/usr/bin/env bash
# M03 lab02 — 구매 옵션을 API로 만져 보기 (🟡)
# 스팟 가격 기록 → 스팟 요청(fulfilled) → 예약 인스턴스·Savings Plans 상품 "읽기"
# → 온디맨드 용량 예약(ODCR) → 전용 인스턴스(Dedicated tenancy)·전용 호스트(Dedicated Host)
# 요금 청구·스팟 중단·할인 적용은 에뮬레이터에 없다. 가격 숫자는 에뮬레이터가 내놓는 값이며 실제 가격이 아니다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

LAB="m03-lab02"
m03_terminate_tagged "$LAB"
# 이전 실행이 남긴 스팟 요청·용량 예약·전용 호스트 정리
for sir in $(aws ec2 describe-spot-instance-requests --filters Name=state,Values=open,active \
  --query 'SpotInstanceRequests[].SpotInstanceRequestId' --output text); do
  aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$sir" >/dev/null
done
for cr in $(aws ec2 describe-capacity-reservations --filters Name=state,Values=active \
  --query 'CapacityReservations[].CapacityReservationId' --output text); do
  aws ec2 cancel-capacity-reservation --capacity-reservation-id "$cr" >/dev/null
done
for h in $(aws ec2 describe-hosts --filter Name=state,Values=available \
  --query 'Hosts[].HostId' --output text); do
  aws ec2 release-hosts --host-ids "$h" >/dev/null
done
m03_network
AMI="$(m03_ami)"
TAGS="ResourceType=instance,Tags=[{Key=Project,Value=todayorder},{Key=Lab,Value=$LAB}]"

echo "== 1. 스팟 가격 기록: 같은 유형이라도 AZ마다 가격이 다르다"
aws ec2 describe-spot-price-history --instance-types c7i.large --product-descriptions "Linux/UNIX" \
  --no-paginate --query 'SpotPriceHistory[].[AvailabilityZone,InstanceType,SpotPrice]' --output text | sort | uniq

echo "== 2. 스팟 인스턴스 요청 (one-time) → fulfilled"
SIR="$(aws ec2 request-spot-instances --instance-count 1 --type one-time \
  --launch-specification "{\"ImageId\":\"$AMI\",\"InstanceType\":\"c7i.large\",\"SubnetId\":\"$M03_SUBNET_A\"}" \
  --query 'SpotInstanceRequests[0].SpotInstanceRequestId' --output text)"
aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$SIR" \
  --query 'SpotInstanceRequests[0].[State,Status.Code,InstanceInterruptionBehavior]' --output text
fulfilled() {
  [ "$(aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$SIR" \
    --query 'SpotInstanceRequests[0].Status.Code' --output text)" = fulfilled ]
}
poll 60 "스팟 요청 fulfilled" fulfilled
aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$SIR" \
  --query 'SpotInstanceRequests[0].[State,Status.Code,InstanceId]' --output text
SPOT_IID="$(aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$SIR" \
  --query 'SpotInstanceRequests[0].InstanceId' --output text)"
aws ec2 create-tags --resources "$SPOT_IID" --tags Key=Lab,Value="$LAB" Key=Project,Value=todayorder
aws ec2 describe-instances --instance-ids "$SPOT_IID" \
  --query 'Reservations[0].Instances[0].{Lifecycle:InstanceLifecycle,Request:SpotInstanceRequestId,Type:InstanceType}'
lifecycle="$(aws ec2 describe-instances --instance-ids "$SPOT_IID" --query 'Reservations[0].Instances[0].InstanceLifecycle' --output text)"

echo "== 3. 스팟 요청을 취소해도 이미 뜬 인스턴스는 계속 돈다 (직접 종료해야 한다)"
aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "$SIR" \
  --query 'CancelledSpotInstanceRequests[0].State' --output text
after_cancel="$(aws ec2 describe-instances --instance-ids "$SPOT_IID" --query 'Reservations[0].Instances[0].State.Name' --output text)"
echo "스팟 인스턴스 상태: $after_cancel"

echo "== 4. 예약 인스턴스(RI) 상품 읽기 (m7i.large, Linux, standard)"
echo "-- 4a. 같은 상품이 범위(Scope)별로 있다: 리전 RI 와 영역(AZ) RI"
aws ec2 describe-reserved-instances-offerings --instance-type m7i.large --product-description Linux/UNIX \
  --offering-class standard --no-paginate \
  --query 'ReservedInstancesOfferings[?Duration==`31536000` && OfferingType==`No Upfront`].[Scope,AvailabilityZone]' --output text
echo "-- 4b. 리전 RI: 기간(초) · 결제 방식 · 선결제(FixedPrice) · 시간당(UsagePrice)"
aws ec2 describe-reserved-instances-offerings --instance-type m7i.large --product-description Linux/UNIX \
  --offering-class standard --no-paginate \
  --query 'ReservedInstancesOfferings[?Scope==`Region`].[Duration,OfferingType,FixedPrice,UsagePrice]' --output text | sort
ri_scopes="$(aws ec2 describe-reserved-instances-offerings --instance-type m7i.large --product-description Linux/UNIX \
  --no-paginate --query 'ReservedInstancesOfferings[].Scope' --output text | tr '\t' '\n' | sort -u | tr '\n' '/')"
ri_count="$(aws ec2 describe-reserved-instances-offerings --instance-type m7i.large --product-description Linux/UNIX \
  --no-paginate --query 'length(ReservedInstancesOfferings)' --output text)"
echo "(standard + convertible 상품 수: $ri_count, 범위: $ri_scopes)"

echo "== 5. Savings Plans 상품 읽기: 유형별 개수와 적용 대상"
aws savingsplans describe-savings-plans-offerings \
  --query 'searchResults[].[planType,join(`,`,productTypes)]' --output text | sort | uniq -c
sp_types="$(aws savingsplans describe-savings-plans-offerings \
  --query 'searchResults[].planType' --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')"

echo "== 6. 온디맨드 용량 예약(ODCR): 약정 없이 특정 AZ에 용량 확보"
CR="$(aws ec2 create-capacity-reservation --instance-type m7i.large --instance-platform Linux/UNIX \
  --availability-zone us-east-1a --instance-count 2 --end-date-type unlimited \
  --tag-specifications 'ResourceType=capacity-reservation,Tags=[{Key=Project,Value=todayorder}]' \
  --query CapacityReservation.CapacityReservationId --output text)"
aws ec2 describe-capacity-reservations --capacity-reservation-ids "$CR" \
  --query 'CapacityReservations[0].[InstanceType,AvailabilityZone,TotalInstanceCount,AvailableInstanceCount,InstanceMatchCriteria,State]' --output text
cr_state="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "$CR" --query 'CapacityReservations[0].State' --output text)"

echo "== 7. 전용 인스턴스(Dedicated Instance): tenancy=dedicated"
DED="$(aws ec2 run-instances --image-id "$AMI" --instance-type m7i.large --subnet-id "$M03_SUBNET_A" \
  --placement Tenancy=dedicated --tag-specifications "$TAGS" --query 'Instances[0].InstanceId' --output text)"
tenancy="$(aws ec2 describe-instances --instance-ids "$DED" --query 'Reservations[0].Instances[0].Placement.Tenancy' --output text)"
echo "$DED tenancy=$tenancy"

echo "== 8. 전용 호스트(Dedicated Host): 물리 서버 한 대를 통째로 할당"
HOST="$(aws ec2 allocate-hosts --instance-type m7i.large --availability-zone us-east-1a --quantity 1 \
  --query 'HostIds[0]' --output text)"
aws ec2 describe-hosts --host-ids "$HOST" \
  --query 'Hosts[0].[HostId,State,HostProperties.InstanceType,AvailabilityZone]' --output text

echo "== 9. 정리: 스팟 인스턴스·전용 인스턴스 종료, 용량 예약 취소, 호스트 반납"
aws ec2 cancel-capacity-reservation --capacity-reservation-id "$CR" --output text
aws ec2 release-hosts --host-ids "$HOST" --query 'Successful' --output text
m03_terminate_tagged "$LAB"
echo "정리 완료"

# ---- 단언
[ "$lifecycle" = "spot" ] || fail "스팟 인스턴스의 InstanceLifecycle 이 spot 이 아님 ($lifecycle)"
[ "$after_cancel" = "running" ] || fail "스팟 요청 취소 후 인스턴스 상태가 running 이 아님 ($after_cancel)"
[ "$ri_count" -ge 2 ] || fail "RI 상품이 없음"
case "$ri_scopes" in *"Availability Zone"*Region* | *Region*"Availability Zone"*) ;; *) fail "리전/영역 RI 가 모두 보이지 않음 ($ri_scopes)" ;; esac
case "$sp_types" in *Compute*EC2Instance* | *EC2Instance*Compute*) ;; *) fail "Savings Plans 유형이 둘 다 보이지 않음 ($sp_types)" ;; esac
[ "$cr_state" = "active" ] || fail "용량 예약이 active 가 아님 ($cr_state)"
[ "$tenancy" = "dedicated" ] || fail "tenancy 가 dedicated 가 아님 ($tenancy)"
[ "$(aws ec2 describe-hosts --host-ids "$HOST" --query 'Hosts[0].State' --output text)" = "released" ] || fail "호스트가 반납되지 않음"
echo "LAB02 OK"
