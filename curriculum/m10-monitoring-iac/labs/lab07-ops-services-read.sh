#!/usr/bin/env bash
# M10 lab07 — 운영 지원 서비스의 "설정값 읽기" (🟡)
# Service Quotas·Compute Optimizer·Well-Architected Tool·Managed Grafana/Prometheus·Service Catalog·Proton·License Manager 는
# 조회 API가 응답한다. Trusted Advisor(Support API)·Health API 는 실제 AWS처럼 "Business 이상 지원 플랜 필요"로 거부된다.
# 에뮬레이터에는 실제 사용량·추천·장애 이벤트가 없으므로 값을 "읽는" 데까지만 한다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

echo "== 1. Service Quotas: 리전당 EC2-VPC 탄력적 IP 한도 (NAT 게이트웨이마다 EIP 하나가 필요하다)"
aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 \
  --query 'Quota.{Name: QuotaName, Value: Value, Adjustable: Adjustable}'
eip="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query Quota.Value --output text)"

echo "== 2. Service Quotas: Lambda 한도 중 시험에 나오는 것"
aws service-quotas list-service-quotas --service-code lambda --output json | py -c '
import json, sys
want = {"L-B99A9384", "FunctionTimeout", "L-2ACBD22F"}
for q in json.load(sys.stdin)["Quotas"]:
    if q["QuotaCode"] in want:
        print("  %-30s %s" % (q["QuotaName"], q["Value"]))'

echo "== 3. Trusted Advisor (Support API) — Basic 지원 플랜이면 거부"
set +e
ta="$(aws support describe-trusted-advisor-checks --language en 2>&1)"
echo "$ta"
echo "== 4. AWS Health API — Business 이상 지원 플랜 필요"
health="$(aws health describe-events 2>&1)"
echo "$health"
set -e

echo "== 5. Compute Optimizer 가입 상태"
aws compute-optimizer get-enrollment-status --query '{Status: status}'

echo "== 6. Well-Architected Tool 공식 렌즈"
aws wellarchitected list-lenses --output json | py -c '
import json, sys
for l in json.load(sys.stdin)["LensSummaries"][:3]:
    print("  %s (%s)" % (l["LensName"], l["LensType"]))'

echo "== 7. 관리형 관측·거버넌스 서비스 목록 조회 (모두 비어 있음)"
for svc in "grafana list-workspaces" "amp list-workspaces" "servicecatalog list-portfolios" \
  "proton list-environments" "license-manager list-license-configurations"; do
  # shellcheck disable=SC2086 # 서비스·오퍼레이션 이름을 단어로 나누려는 의도
  n="$(aws $svc --output json | py -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(v) for v in d.values() if isinstance(v, list)))')"
  printf '  %-45s %s개\n' "aws $svc" "$n"
done

# ---- 단언
[ "$eip" = "5.0" ] || echo "참고: EIP 한도 값이 $eip (실제 AWS 기본값은 5)"
[[ "$ta" == *SubscriptionRequiredException* ]] || fail "Trusted Advisor 가 지원 플랜 오류를 내지 않음"
[[ "$health" == *SubscriptionRequiredException* ]] || fail "Health API 가 지원 플랜 오류를 내지 않음"
echo "LAB07 OK"
