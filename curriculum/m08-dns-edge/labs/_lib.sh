# shellcheck shell=bash
# M08 lab 공용 도우미. 각 lab 이 env.sh 다음에 source 한다. (verify.sh 는 lab*.sh 만 실행하므로 이 파일은 단독 실행되지 않는다)

ROOT="$(git rev-parse --show-toplevel)"

# CLI waiter(Route 53 30초, CloudFront 60초·20초 간격) 대신 같은 조건을 1초 간격으로 확인하는 함수
# (wait_route53_change_insync 등). 이유는 scripts/lab-wait.sh 머리말. 레슨에서 손으로 칠 때는 waiter 가 맞다.
source "$(git rev-parse --show-toplevel)/scripts/lab-wait.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# assert_eq <실제> <기대> <설명>
assert_eq() { [ "$1" = "$2" ] || fail "$3 (기대: '$2', 실제: '$1')"; }

# poll <상한 초> <설명> <명령...> — 명령이 성공할 때까지 1초 간격으로 다시 시도한다.
# 고정 시간 sleep 대신 쓴다. 상한을 넘기면 마지막 출력과 함께 실패한다.
poll() {
  local limit="$1" desc="$2" start=$SECONDS out
  shift 2
  until out="$("$@" 2>&1)"; do
    if ((SECONDS - start >= limit)); then
      fail "$desc: ${limit}초 안에 조건을 만족하지 못했다. 마지막 관찰: ${out:-없음}"
    fi
    sleep 1
  done
}

# JSON 가공용 파이썬 (저장소의 uv 환경 — 학습자 PC에 jq 가 없어도 된다)
# 사용법: <JSON 을 내는 명령> | py '<파이썬 코드>' [인자...]   (json·sys 는 미리 import 됨)
py() {
  uv run --quiet --project "$ROOT" python -c "import json, sys
$1" "${@:2}"
}

# delete_zones <영역 이름> — 같은 이름의 호스팅 영역(퍼블릭·프라이빗 모두)을 레코드까지 지운다.
# Route 53 은 NS·SOA 이외의 레코드가 남아 있으면 영역을 지우지 못한다(HostedZoneNotEmpty).
delete_zones() {
  local name="${1%.}." zid
  for zid in $(aws route53 list-hosted-zones --output json | py '
for z in json.loads(sys.stdin.read() or "{}").get("HostedZones", []):
    if z["Name"] == sys.argv[1]:
        print(z["Id"])' "$name"); do
    aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json | py '
rrs = [r for r in json.load(sys.stdin)["ResourceRecordSets"]
       if not (r["Name"] == sys.argv[1] and r["Type"] in ("NS", "SOA"))]
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in rrs]}))' "$name" >"$TMP_LIB/del.json"
    if ! grep -q '"Changes": \[\]' "$TMP_LIB/del.json"; then
      aws route53 change-resource-record-sets --hosted-zone-id "$zid" \
        --change-batch "file://$TMP_LIB/del.json" >/dev/null
    fi
    aws route53 delete-hosted-zone --id "$zid" >/dev/null
  done
}

# delete_health_checks <caller-reference 접두사> — 이 lab 이 만든 상태 확인을 지운다.
# 계산된(CALCULATED) 상태 확인을 먼저 지운다. 실제 AWS는 다른 상태 확인이 참조 중인 자식을
# 먼저 지우려 하면 HealthCheckInUse 로 거부한다.
delete_health_checks() {
  local id
  for id in $(aws route53 list-health-checks --output json | py '
hcs = [h for h in json.loads(sys.stdin.read() or "{}").get("HealthChecks", [])
       if h["CallerReference"].startswith(sys.argv[1])]
for h in sorted(hcs, key=lambda h: h["HealthCheckConfig"]["Type"] != "CALCULATED"):
    print(h["Id"])' "$1"); do
    aws route53 delete-health-check --health-check-id "$id" >/dev/null
  done
}

TMP_LIB="$(mktemp -d)"
trap 'rm -rf "$TMP_LIB"' EXIT
