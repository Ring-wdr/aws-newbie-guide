#!/usr/bin/env bash
# M08 lab05 — Global Accelerator 가속기·리스너·엔드포인트 그룹 (🟡)
# 고정 애니캐스트 IP 2개를 받는 것까지는 보이지만, 그 IP로 트래픽이 흐르지는 않는다.
# 실제 AWS에서 Global Accelerator API 는 us-west-2(오레곤) 엔드포인트로만 호출한다 → 모든 호출에 --region us-west-2.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

NAME="todayorder-m08-ga"
GA=(--region us-west-2)
WORK="$TMP_LIB"

# ---- 이전 실행 정리 (멱등). 끝에서 순서대로 지우므로 보통은 남은 것이 없다.
# ListEndpointGroups 가 501 이라 남은 엔드포인트 그룹을 찾을 수 없으면, 그 가속기는 그대로 두고 새로 만든다.
for arn in $(aws globalaccelerator list-accelerators "${GA[@]}" --output json | py '
for a in json.loads(sys.stdin.read() or "{}").get("Accelerators", []):
    if a["Name"] == sys.argv[1]:
        print(a["AcceleratorArn"])' "$NAME"); do
  for l in $(aws globalaccelerator list-listeners "${GA[@]}" --accelerator-arn "$arn" --query 'Listeners[].ListenerArn' --output text); do
    aws globalaccelerator delete-listener "${GA[@]}" --listener-arn "$l" >/dev/null 2>&1 || true
  done
  aws globalaccelerator update-accelerator "${GA[@]}" --accelerator-arn "$arn" --no-enabled >/dev/null
  aws globalaccelerator delete-accelerator "${GA[@]}" --accelerator-arn "$arn" >/dev/null 2>&1 || echo "(남은 가속기 정리 건너뜀: $arn)"
done

echo "== 1. 가속기 만들기 — 고정 애니캐스트 IPv4 2개"
aws globalaccelerator create-accelerator "${GA[@]}" --name "$NAME" --ip-address-type IPV4 \
  --idempotency-token "m08-lab05-$(date +%s)-$RANDOM" --output json \
  --query 'Accelerator.{Arn: AcceleratorArn, Ips: IpSets[0].IpAddresses, DnsName: DnsName, Status: Status}' | tee "$WORK/acc.json"
ACC="$(py 'print(json.load(sys.stdin)["Arn"])' <"$WORK/acc.json")"
ips="$(py 'print(" ".join(json.load(sys.stdin)["Ips"]))' <"$WORK/acc.json")"
poll 120 "가속기 DEPLOYED" sh -c "aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn '$ACC' --query Accelerator.Status --output text | grep -qx DEPLOYED"
echo "대기 후 상태: DEPLOYED"

echo "== 2. 리스너: TCP 443, 같은 클라이언트는 같은 엔드포인트로(SOURCE_IP 선호도)"
LIS="$(aws globalaccelerator create-listener "${GA[@]}" --accelerator-arn "$ACC" --protocol TCP \
  --port-ranges FromPort=443,ToPort=443 --client-affinity SOURCE_IP --idempotency-token "l-$RANDOM" \
  --query Listener.ListenerArn --output text)"
aws globalaccelerator describe-listener "${GA[@]}" --listener-arn "$LIS" --query 'Listener.{Protocol: Protocol, Ports: PortRanges, Affinity: ClientAffinity}'

echo "== 3. 엔드포인트 그룹: 서울(트래픽 100%) + 버지니아(트래픽 다이얼 0% — 대기)"
EG_SEOUL="$(aws globalaccelerator create-endpoint-group "${GA[@]}" --listener-arn "$LIS" \
  --endpoint-group-region ap-northeast-2 --traffic-dial-percentage 100 \
  --health-check-protocol TCP --health-check-port 443 --threshold-count 3 \
  --endpoint-configurations EndpointId=eipalloc-0a1b2c3d4e5f60001,Weight=128 \
  --idempotency-token "eg1-$RANDOM" --query EndpointGroup.EndpointGroupArn --output text)"
EG_US="$(aws globalaccelerator create-endpoint-group "${GA[@]}" --listener-arn "$LIS" \
  --endpoint-group-region us-east-1 --traffic-dial-percentage 0 \
  --endpoint-configurations EndpointId=eipalloc-0a1b2c3d4e5f60002,Weight=128 \
  --idempotency-token "eg2-$RANDOM" --query EndpointGroup.EndpointGroupArn --output text)"
for eg in "$EG_SEOUL" "$EG_US"; do
  aws globalaccelerator describe-endpoint-group "${GA[@]}" --endpoint-group-arn "$eg" \
    --query 'EndpointGroup.[EndpointGroupRegion, TrafficDialPercentage, EndpointDescriptions[0].EndpointId, EndpointDescriptions[0].HealthState]' --output text
done
seoul_dial="$(aws globalaccelerator describe-endpoint-group "${GA[@]}" --endpoint-group-arn "$EG_SEOUL" --query EndpointGroup.TrafficDialPercentage --output text)"

echo "== 4. 목록 조회: ListEndpointGroups 는 501"
set +e
leg_err="$(aws globalaccelerator list-endpoint-groups "${GA[@]}" --listener-arn "$LIS" 2>&1 >/dev/null)"
set -e
echo "$leg_err" | grep -m1 'error occurred'

echo "== 5. 지우는 순서: 엔드포인트 그룹 → 리스너 → (비활성화) → 가속기"
set +e
order_err="$(aws globalaccelerator delete-listener "${GA[@]}" --listener-arn "$LIS" 2>&1 >/dev/null)"
set -e
echo "엔드포인트 그룹이 남은 채 리스너 삭제 → $(grep -o 'AssociatedEndpointGroupFoundException' <<<"$order_err")"
aws globalaccelerator delete-endpoint-group "${GA[@]}" --endpoint-group-arn "$EG_SEOUL"
aws globalaccelerator delete-endpoint-group "${GA[@]}" --endpoint-group-arn "$EG_US"
aws globalaccelerator delete-listener "${GA[@]}" --listener-arn "$LIS"
set +e
enabled_err="$(aws globalaccelerator delete-accelerator "${GA[@]}" --accelerator-arn "$ACC" 2>&1 >/dev/null)"
set -e
echo "활성 상태에서 가속기 삭제 → $(grep -o 'AcceleratorNotDisabledException' <<<"$enabled_err")"
aws globalaccelerator update-accelerator "${GA[@]}" --accelerator-arn "$ACC" --no-enabled --query 'Accelerator.[Enabled, Status]' --output text
poll 120 "비활성화 반영(DEPLOYED)" sh -c "aws globalaccelerator describe-accelerator --region us-west-2 --accelerator-arn '$ACC' --query Accelerator.Status --output text | grep -qx DEPLOYED"
aws globalaccelerator delete-accelerator "${GA[@]}" --accelerator-arn "$ACC"
left="$(aws globalaccelerator list-accelerators "${GA[@]}" --output json | py '
print(sum(1 for a in json.loads(sys.stdin.read() or "{}").get("Accelerators", []) if a["AcceleratorArn"] == sys.argv[1]))' "$ACC")"
echo "삭제 후 남은 가속기(이 lab 것): $left"

# ---- 단언
[ "$(wc -w <<<"$ips")" -eq 2 ] || fail "정적 IP 가 2개가 아님: $ips"
assert_eq "$seoul_dial" "100.0" "서울 엔드포인트 그룹 트래픽 다이얼"
grep -q AssociatedEndpointGroupFoundException <<<"$order_err" || fail "엔드포인트 그룹이 남은 리스너가 지워짐"
grep -q AcceleratorNotDisabledException <<<"$enabled_err" || fail "활성 가속기가 지워짐"
assert_eq "$left" "0" "가속기 삭제"
grep -q NotImplemented <<<"$leg_err" || echo "참고: ListEndpointGroups 가 이제 구현됨 — README 갱신"
echo "LAB05 OK"
