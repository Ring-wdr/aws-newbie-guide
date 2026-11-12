#!/usr/bin/env bash
# M09 lab09 — GuardDuty 탐지기와 샘플 결과(finding) + 탐지·보안 서비스 활성화 상태 읽기 (🟡)
# 에뮬레이터의 GuardDuty 는 실제 위협(로그 분석)을 탐지하지 않는다. CreateSampleFindings 로 만든
# "[SAMPLE]" 결과만 보인다. 결과를 EventBridge 로 내보내는 연동도 관찰되지 않았다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"
source "$(dirname "$0")/_lib.sh"

WORK="$TMP_LIB"
cd "$WORK"

echo "== 1. 탐지기(detector) — 계정·리전당 하나. 이미 있으면 그대로 쓴다"
DET="$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)"
if [ "$DET" = "None" ] || [ -z "$DET" ]; then
  DET="$(aws guardduty create-detector --enable --finding-publishing-frequency FIFTEEN_MINUTES --query DetectorId --output text)"
  echo "새 탐지기: $DET"
else
  echo "기존 탐지기 재사용: $DET"
fi
aws guardduty get-detector --detector-id "$DET" --query '{Status: Status, Frequency: FindingPublishingFrequency}'
status="$(aws guardduty get-detector --detector-id "$DET" --query Status --output text)"
expect_error second_err aws guardduty create-detector --enable
echo "두 번째 탐지기 만들기 → $(grep -m1 -oE '[A-Za-z]+Exception' <<<"$second_err")"

echo "== 2. 샘플 결과 만들기 — TodayOrder 에 일어날 법한 세 가지"
TYPES=("UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS"
  "CryptoCurrency:EC2/BitcoinTool.B!DNS"
  "Recon:EC2/PortProbeUnprotectedPort")
aws guardduty create-sample-findings --detector-id "$DET" --finding-types "${TYPES[@]}"
poll 60 "샘플 결과" sh -c "aws guardduty list-findings --detector-id '$DET' --query 'length(FindingIds)' --output text | grep -qv '^0$'"

echo "== 3. 결과 읽기 — 유형 이름이 곧 '무슨 일인가'다 (위협목적:리소스/위협이름)"
aws guardduty list-findings --detector-id "$DET" --output json --query FindingIds >ids.json
py 'ids = json.load(sys.stdin); print(" ".join(ids[-50:]))' <ids.json >ids.txt
# shellcheck disable=SC2046
aws guardduty get-findings --detector-id "$DET" --finding-ids $(cat ids.txt) --output json | py '
seen = set()
for f in sorted(json.load(sys.stdin)["Findings"], key=lambda f: -f["Severity"]):
    if f["Type"] in seen or f["Type"] not in sys.argv[1:]:
        continue
    seen.add(f["Type"])
    level = "높음" if f["Severity"] >= 7 else "중간" if f["Severity"] >= 4 else "낮음"
    sample = json.loads(f["Service"].get("AdditionalInfo", {}).get("Value", "{}")).get("sample")
    sev, typ, res = f["Severity"], f["Type"], f["Resource"]["ResourceType"]
    print(f"{sev:>4} {level}  {typ:<70} 리소스={res:<12} sample={sample}")' "${TYPES[@]}" | tee findings.txt
aws guardduty get-findings-statistics --detector-id "$DET" --finding-statistic-types COUNT_BY_SEVERITY \
  --query 'FindingStatistics.CountBySeverity'

echo "== 4. 그 밖의 탐지·보안 서비스 — '켜져 있나'만 읽는다"
macie="$(aws macie2 get-macie-session --query status --output text 2>/dev/null || echo NOT_ENABLED)"
if [ "$macie" = "NOT_ENABLED" ]; then aws macie2 enable-macie >/dev/null; macie="$(aws macie2 get-macie-session --query status --output text)"; fi
echo "Macie(S3 민감 데이터)            : $macie"
aws securityhub enable-security-hub --enable-default-standards >/dev/null 2>&1 || true
echo "Security Hub(통합 대시보드) 표준 :"
aws securityhub get-enabled-standards --query 'StandardsSubscriptions[].StandardsArn' --output text | tr '\t' '\n' | sed 's/^/   /'
echo "Inspector(취약점 스캔) 계정 상태 :"
aws inspector2 batch-get-account-status --query 'accounts[0].resourceState.{ec2: ec2.status, ecr: ecr.status, lambda: lambda.status}' --output text | sed 's/^/   /'
graph="$(aws detective list-graphs --query 'GraphList[0].Arn' --output text 2>/dev/null || echo None)"
if [ "$graph" = "None" ]; then graph="$(aws detective create-graph --query GraphArn --output text)"; fi
echo "Detective(조사용 행동 그래프)    : $graph"

# ---- 단언
assert_eq "$status" "ENABLED" "탐지기 상태"
grep -q BadRequestException <<<"$second_err" || grep -q InvalidInputException <<<"$second_err" || fail "두 번째 탐지기가 만들어짐"
[ "$(wc -l <findings.txt | tr -d ' ')" -eq 3 ] || fail "샘플 결과 3종이 모두 보이지 않음"
grep -q 'sample=True' findings.txt || fail "샘플 표시가 없음"
assert_eq "$macie" "ENABLED" "Macie 상태"
echo "LAB09 OK"
