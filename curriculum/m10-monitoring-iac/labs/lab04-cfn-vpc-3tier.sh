#!/usr/bin/env bash
# M10 lab04 — CloudFormation으로 2-AZ 3-티어 VPC 재현 (🟢 생성·Outputs·롤백·삭제 / 🟡 드리프트 / 🔴 VPC 스택 변경 세트)
#   templates/vpc-3tier.yaml : VPC 1, 서브넷 6, IGW, NAT GW(+EIP), 라우팅 테이블 3, 보안 그룹 체인 3
# 순서: 검증 → 생성 → EC2 API로 실재 확인 → Outputs·Export → 드리프트(관찰) → VPC 스택 변경 세트(에뮬레이터 501 관찰)
#       → 잘못된 파라미터로 만든 두 번째 스택의 자동 롤백 → 삭제
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

TPL="$(cd "$(dirname "$0")" && pwd)/templates/vpc-3tier.yaml"
STACK="todayorder-network"
BROKEN="todayorder-network-stg"

delete_stack_if_exists "$BROKEN"
delete_stack_if_exists "$STACK"

echo "== 1. validate-template: 문법과 파라미터 확인 (리소스는 아직 안 만든다)"
aws cloudformation validate-template --template-body "file://$TPL" \
  --query '{Description: Description, Parameters: Parameters[].[ParameterKey, DefaultValue]}'

echo "== 2. create-stack → 상태 폴링"
aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$TPL" \
  --tags Key=project,Value=todayorder --query StackId --output text
status="$(wait_stack "$STACK")"
echo "스택 상태: $status"
[ "$status" = CREATE_COMPLETE ] || fail "스택 생성 실패: $status"
aws cloudformation describe-stack-resources --stack-name "$STACK" --output json | py -c '
import json, sys, collections
res = json.load(sys.stdin)["StackResources"]
c = collections.Counter(r["ResourceType"] for r in res)
for t, n in sorted(c.items()):
    print(f"  {t:<45} {n}")
states = sorted({r["ResourceStatus"] for r in res})
print("  %-45s %d  (상태: %s)" % ("합계", len(res), states))'

echo "== 3. Outputs 와 Export"
aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey, OutputValue, ExportName]' --output table
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
VPC_ID="$(out VpcId)"
aws cloudformation list-exports --query 'Exports[].[Name, Value]' --output text

echo "== 4. 템플릿이 아니라 EC2 API로 실재 확인"
echo "-- 서브넷 6개 (AZ·CIDR)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets, &CidrBlock)[].[CidrBlock, AvailabilityZone, MapPublicIpOnLaunch]' --output table
subnets="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["Subnets"]))')"
echo "-- 라우팅 테이블별 기본 경로(0.0.0.0/0)의 대상"
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json | py -c '
import json, sys
for rt in json.load(sys.stdin)["RouteTables"]:
    if any(a.get("Main") for a in rt.get("Associations", [])):
        print("  %s  VPC 기본(main) 라우팅 테이블 — 명시적으로 연결하지 않은 서브넷이 쓴다" % rt["RouteTableId"])
        continue
    subs = len([a for a in rt.get("Associations", []) if a.get("SubnetId")])
    default = [r.get("GatewayId") or r.get("NatGatewayId") for r in rt["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]
    target = default[0] if default else "(없음: 프라이빗)"
    print("  %s  연결 서브넷 %d개  0.0.0.0/0 → %s" % (rt["RouteTableId"], subs, target))'
routes="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json | py -c '
import json, sys
t = [r.get("GatewayId", r.get("NatGatewayId", ""))[:4] for rt in json.load(sys.stdin)["RouteTables"] for r in rt["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]
print(",".join(sorted(t)))')"
echo "-- NAT 게이트웨이"
aws ec2 describe-nat-gateways --nat-gateway-ids "$(out NatGatewayId)" \
  --query 'NatGateways[0].{State: State, Subnet: SubnetId, PublicIp: NatGatewayAddresses[0].PublicIp}'
echo "-- 보안 그룹 체인 (누가 누구에게 열려 있나)"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --output json | py -c '
import json, sys
sgs = json.load(sys.stdin)["SecurityGroups"]
name = {g["GroupId"]: g["Description"].split(" - ")[0] for g in sgs}
for g in sorted(sgs, key=lambda g: g["Description"]):
    if g["GroupName"] == "default":
        continue
    for p in g["IpPermissions"]:
        src = [r["CidrIp"] for r in p.get("IpRanges", [])] + [name.get(u["GroupId"], u["GroupId"]) + " SG" for u in p.get("UserIdGroupPairs", [])]
        print("  %-9s tcp/%s  ← %s" % (name[g["GroupId"]], p.get("FromPort"), ", ".join(src)))'

echo "== 5. 드리프트 감지: 콘솔에서 누가 web SG에 SSH(22)를 열었다고 하자"
WEB_SG="$(aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id WebSg \
  --query StackResourceDetail.PhysicalResourceId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --query 'Return'
DID="$(aws cloudformation detect-stack-drift --stack-name "$STACK" --query StackDriftDetectionId --output text)"
wait_until 60 1 "드리프트 감지 완료" bash -c \
  "[ \"\$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id $DID --query DetectionStatus --output text)\" != DETECTION_IN_PROGRESS ]"
aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DID" \
  --query '{Detection: DetectionStatus, Stack: StackDriftStatus, DriftedResources: DriftedStackResourceCount}'
aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" --output json | py -c '
import json, sys, collections
d = json.load(sys.stdin)["StackResourceDrifts"]
c = collections.defaultdict(list)
for x in d:
    c[x["StackResourceDriftStatus"]].append(x["LogicalResourceId"])
for k in sorted(c):
    print("  %-9s %2d개: %s" % (k, len(c[k]), " ".join(sorted(c[k]))))'
echo "   ↑ 에뮬레이터 1.0.322: IGW·라우팅·NAT·EIP 등은 실제로 있는데도 DELETED로, 바꾼 WebSg는 IN_SYNC로 나온다."
echo "     VPC 스택의 드리프트 결과는 믿을 수 없다 → 정확한 드리프트 실습은 lab05(S3·SQS)에서."
aws ec2 revoke-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 22 --cidr 0.0.0.0/0 --query Return

echo "== 6. 변경 세트로 앱 서브넷 C(10.0.13.0/24) 추가 — 에뮬레이터에서는 실패하고 롤백된다"
TPL2="$(mktemp)"
trap 'rm -f "$TPL2"' EXIT
py - "$TPL" "$TPL2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
add = "  AppC:\n    Type: AWS::EC2::Subnet\n    Properties: {VpcId: !Ref Vpc, CidrBlock: 10.0.13.0/24, AvailabilityZone: us-east-1c}\nOutputs:"
open(dst, "w").write(t.replace("Outputs:", add, 1))
PY
aws cloudformation create-change-set --stack-name "$STACK" --change-set-name add-app-c \
  --template-body "file://$TPL2" --change-set-type UPDATE --query Id --output text >/dev/null
wait_until 60 1 "변경 세트 계산" bash -c \
  "aws cloudformation describe-change-set --stack-name $STACK --change-set-name add-app-c --query Status --output text | grep -qE 'CREATE_COMPLETE|FAILED'"
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name add-app-c \
  --query 'Changes[].ResourceChange.{Action: Action, Logical: LogicalResourceId, Type: ResourceType}'
aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name add-app-c
update_status="$(wait_stack "$STACK")"
echo "스택 상태: $update_status"
aws cloudformation describe-stack-events --stack-name "$STACK" --output json | py -c '
import json, sys
for e in json.load(sys.stdin)["StackEvents"]:
    if e["ResourceStatus"] == "UPDATE_FAILED":
        print("  %s: %s" % (e["LogicalResourceId"], e["ResourceStatusReason"]))
        break'
subnets_after="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["Subnets"]))')"
echo "롤백 후 서브넷 수: $subnets_after (변경 전 그대로)"

echo "== 7. 롤백: VpcCidr 만 10.1.0.0/16 으로 바꾼 스테이징 스택 (서브넷 CIDR은 10.0.x 로 하드코딩되어 있다)"
aws cloudformation create-stack --stack-name "$BROKEN" --template-body "file://$TPL" \
  --parameters ParameterKey=VpcCidr,ParameterValue=10.1.0.0/16 ParameterKey=EnvName,ParameterValue=todayorder-stg \
  --query StackId --output text >/dev/null
broken_status="$(wait_stack "$BROKEN")"
echo "스택 상태: $broken_status"
aws cloudformation describe-stack-events --stack-name "$BROKEN" --output json | py -c '
import json, sys
ev = json.load(sys.stdin)["StackEvents"]
first = [e for e in ev if e["ResourceStatus"] == "CREATE_FAILED" and e["LogicalResourceId"] != e["StackName"]][-1]
print("  첫 실패: %s — %s" % (first["LogicalResourceId"], first["ResourceStatusReason"]))'
leftover="$(aws ec2 describe-vpcs --filters Name=cidr,Values=10.1.0.0/16 --output json | py -c 'import json,sys; print(len(json.load(sys.stdin)["Vpcs"]))')"
echo "롤백 후 남은 10.1.0.0/16 VPC: $leftover 개"
aws cloudformation delete-stack --stack-name "$BROKEN"   # ROLLBACK_COMPLETE 스택은 지우는 것 말고 할 수 있는 게 없다

echo "== 8. 삭제: 스택을 지우면 만든 리소스가 모두 사라진다"
aws cloudformation delete-stack --stack-name "$STACK"
wait_until 180 2 "VPC 삭제" bash -c \
  "[ \"\$(aws ec2 describe-vpcs --filters Name=vpc-id,Values=$VPC_ID --output json | py -c \"import json,sys; print(len(json.load(sys.stdin)['Vpcs']))\")\" = 0 ]"
echo "VPC $VPC_ID 삭제 확인"
wait_until 180 2 "스택 삭제" bash -c "! aws cloudformation describe-stacks --stack-name $STACK >/dev/null 2>&1"
wait_until 180 2 "스테이징 스택 삭제" bash -c "! aws cloudformation describe-stacks --stack-name $BROKEN >/dev/null 2>&1"

# ---- 단언
[ "$subnets" = 6 ] || fail "서브넷이 6개가 아님: $subnets"
[ "$routes" = "igw-,nat-" ] || fail "기본 경로 대상이 IGW 1·NAT 1 이 아님: $routes"
[ "$update_status" = UPDATE_ROLLBACK_COMPLETE ] || echo "참고: VPC 스택 변경 세트가 $update_status — 에뮬레이터가 바뀐 듯하다. 레슨 3 설명을 갱신할 것"
[ "$subnets_after" -ge 6 ] || fail "변경 세트 이후 서브넷 수 이상: $subnets_after"
[ "$broken_status" = ROLLBACK_COMPLETE ] || fail "잘못된 스택이 ROLLBACK_COMPLETE가 아님: $broken_status"
[ "$leftover" = 0 ] || fail "롤백 후 VPC가 남음"
echo "LAB04 OK"
