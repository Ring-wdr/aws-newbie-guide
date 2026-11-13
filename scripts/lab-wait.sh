# shellcheck shell=bash
# lab 스크립트가 AWS CLI waiter(`aws <서비스> wait ...`) 대신 쓰는 1초 간격 대기 함수.
# 모듈의 labs/_lib.sh(또는 _common.sh)나 lab 스크립트가 scripts/env.sh 다음에 source 한다.
#
#   source "$(git rev-parse --show-toplevel)/scripts/lab-wait.sh"
#
# 왜 waiter 를 그대로 쓰지 않나
#   CLI waiter 는 정해진 간격으로 조회한다(RDS·DocumentDB·Route 53 30초, CloudFront 60초·20초,
#   DynamoDB 20초, EC2·ElastiCache 15초, Kinesis 10초 — awscli 에 들어 있는 waiters-2.json 기준).
#   에뮬레이터는 1초도 안 돼 상태를 바꾸지만, 생성 직후 첫 조회가 전이 상태(creating, pending, PENDING …)를
#   보면 waiter 는 다음 조회까지 한 간격을 통째로 잔다. 그래서 실행 시간이 길고 실행마다 들쭉날쭉하다.
#   실제 AWS 에서는 waiter 가 정상 도구다. 레슨은 waiter 를 가르치고, lab 스크립트만 이 함수를 쓴다.
#
# 규칙 (각 함수는 awscli 의 waiters-2.json acceptor 를 옮긴 것이다)
#   - 성공 조건은 waiter 의 success acceptor 와 같다(pathAll 은 "값이 하나 이상이고 모두 기대 값").
#   - waiter 가 failure 로 정한 상태(failed, deleting, incompatible-* …)를 보면 상한을 기다리지 않고 바로 실패한다.
#   - waiter 가 retry 로 정한 오류 코드만 다시 조회한다. 그 밖의 오류(연결 실패 포함)는 waiter 처럼 바로 실패한다.
#   - "사라짐"은 지정한 NotFound 오류 코드일 때만 성공이다. 다른 오류는 사라진 것으로 치지 않는다.
#   - 상한(기본 600초, LAB_WAIT_TIMEOUT — 1 이상의 정수 초. 아니면 기다리기 전에 거부)을 넘기면
#     마지막으로 관찰한 값을 보여 주고 실패한다.
#   - 조회가 실패했는데 에뮬레이터에 아예 닿지 않으면(꺼짐·재시작 중) 오류 코드 대신 그렇다고 알린다.
#   실패하면 1을 돌려준다(set -e 인 lab 은 그 자리에서 멈춘다). 인자·환경 변수가 잘못되면 2.
#   DynamoDB 테이블·Kinesis 스트림은 ACTIVE 를 본 뒤 잠깐 더 기다려 "아직 준비됨"인지 한 번 더 확인한다
#   (아래 "준비 직후 다시 확인" — VM 시계가 뒤로 옮겨질 때의 증상을 좁히고, 보이면 크게 실패한다).
#
# bash 전용이다(read -a, local -a, $SECONDS). zsh 셸에서 source 하지 말고 bash lab 스크립트에서 쓴다.

# ---- 내부 도구

# 빈 줄을 지운다 (aws 오류 메시지는 빈 줄로 시작한다)
_lw_clean() { sed '/^[[:space:]]*$/d'; }

# aws 오류 출력에서 오류 코드만 뽑는다: "An error occurred (Code) when calling ..." → Code
_lw_error_code() { sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' <<<"$1" | head -1; }

# 단어 $1 이 공백으로 구분한 목록 $2 에 있는가
_lw_in() {
  local w
  for w in $2; do [ "$w" = "$1" ] && return 0; done
  return 1
}

_lw_report() { # <설명> <사유> <마지막 관찰>
  echo "FAIL: 대기 실패 — $1: $2" >&2
  if [ -n "$3" ]; then
    echo "  마지막 관찰:" >&2
    printf '%s\n' "$3" | sed 's/^/    /' >&2
  else
    echo "  마지막 관찰: (출력 없음 — 조회 결과가 비어 있다)" >&2
  fi
  return 1
}

# 상한(LAB_WAIT_TIMEOUT)을 검사해 출력한다. 숫자가 아니면 매초 산술 오류를 내며 끝없이 도는 대신 바로 거부한다.
_lw_limit() {
  local v="${LAB_WAIT_TIMEOUT:-600}"
  case "$v" in
    '' | *[!0-9]* | 0 | 0*) echo "lab-wait: LAB_WAIT_TIMEOUT 은 1 이상의 정수(초)여야 한다: '$v'" >&2; return 2 ;;
  esac
  [ "${#v}" -le 9 ] || v=999999999   # bash 정수 범위를 넘는 자릿수는 줄인다
  echo "$v"
}

# 조회 실패 사유. 에뮬레이터에 아예 닿지 않으면(내려가면서 env.sh 가 가리키던 자격 증명·인증서 파일이 지워져
# NoCredentials 가 나거나, 연결이 거부됨) 오류 코드 대신 그렇다고 말한다. 닿으면 원래 오류 코드를 그대로 쓴다.
_lw_error_reason() { # <오류 코드> <출력>
  case "$1|$2" in
    NoCredentials\|* | *'Could not connect to the endpoint URL'* | *EndpointConnectionError* | *'Connection refused'*)
      if ! curl -s -o /dev/null --max-time 3 --cacert "${AWS_CA_BUNDLE:-/nonexistent}" \
        "${AWS_ENDPOINT_URL:-https://127.0.0.1:9}/__admin/health" 2>/dev/null; then
        echo "에뮬레이터(${AWS_ENDPOINT_URL:-?})에 연결하지 못했다 — 꺼졌거나 다시 시작되는 중이다${1:+ (aws 가 낸 오류: $1)}. scripts/emulator-status.sh 로 확인"
        return 0
      fi ;;
  esac
  echo "조회가 예상하지 못한 오류로 실패했다${1:+ ($1)}"
}

# 공통 인자 해석. 결과는 호출한 함수의 지역 변수(_want _fails _retry)에 넣는다.
_lw_opts() {
  _lw_argc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --want) _want="$2"; shift 2; _lw_argc=$((_lw_argc + 2)) ;;
      --fail) _fails="$2"; shift 2; _lw_argc=$((_lw_argc + 2)) ;;
      --retry-on) _retry="$2"; shift 2; _lw_argc=$((_lw_argc + 2)) ;;
      --) _lw_argc=$((_lw_argc + 1)); return 0 ;;
      *) echo "lab-wait: 알 수 없는 인자 '$1' (명령 앞에 -- 가 필요하다)" >&2; return 2 ;;
    esac
  done
  echo "lab-wait: 조회 명령이 없다 (-- 다음에 적는다)" >&2
  return 2
}

# ---- 범용 함수

# wait_state <설명> --want <값> [--fail "<실패 상태…>"] [--retry-on "<오류 코드…>"] -- <조회 명령…>
#   조회 명령은 상태 값을 공백·줄바꿈으로 구분해 출력한다(--output text). 값이 하나 이상이고 모두 <값>이면 성공.
#   하나라도 실패 상태면 바로 실패. 조회가 --retry-on 에 적은 오류 코드로 실패하면 다시 조회하고, 다른 오류면 바로 실패.
wait_state() {
  local desc="$1" _want="" _fails="" _retry="" _lw_argc
  shift
  _lw_opts "$@" || return 2
  shift "$_lw_argc"
  [ -n "$_want" ] || { echo "lab-wait: wait_state 에 --want 가 없다" >&2; return 2; }
  local limit start=$SECONDS out code tok bad n all
  limit="$(_lw_limit)" || return 2
  local -a toks
  while :; do
    if out="$("$@" 2>&1)"; then
      out="$(printf '%s\n' "$out" | _lw_clean)"
      read -r -a toks <<<"$(printf '%s' "$out" | tr '\n\t' '  ')"
      n=0 all=1 bad=""
      for tok in ${toks[@]+"${toks[@]}"}; do
        n=$((n + 1))
        [ "$tok" = "$_want" ] || all=0
        if [ -z "$bad" ] && _lw_in "$tok" "$_fails"; then bad="$tok"; fi
      done
      [ -n "$bad" ] && { _lw_report "$desc" "'$bad' 상태가 됐다 (CLI waiter 도 여기서 실패한다)" "$out"; return 1; }
      [ "$n" -gt 0 ] && [ "$all" = 1 ] && return 0
    else
      out="$(printf '%s\n' "$out" | _lw_clean)"
      code="$(_lw_error_code "$out")"
      if [ -z "$code" ] || ! _lw_in "$code" "$_retry"; then
        _lw_report "$desc" "$(_lw_error_reason "$code" "$out")" "$out"
        return 1
      fi
    fi
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      _lw_report "$desc" "${limit}초 안에 '$_want' 가 되지 않았다" "$out"
      return 1
    fi
    sleep 1
  done
}

# wait_gone <설명> <NotFound 오류 코드> [--fail "<실패 상태…>"] -- <조회 명령…>
#   조회 명령이 정확히 <NotFound 오류 코드>로 실패하면 성공. 다른 오류는 바로 실패.
#   아직 조회되면 출력 값을 보고, 실패 상태(예: 삭제를 기다리는데 creating)면 바로 실패한다.
#   일부러 NotFound 만 성공으로 친다: CLI 의 *-deleted waiter 는 "목록이 비었음"(RDS·DocumentDB 의
#   length(...) == 0)과 "모두 deleted"(ElastiCache cache-cluster-deleted)도 성공으로 치지만, 여기서는 뺐다.
#   식별자 하나로 조회하므로 빈 목록 대신 NotFound 가 오고, 'deleted' 가 보여도 NotFound 가 될 때까지 기다리는 쪽이
#   "정말 사라졌다"에 더 가깝다(같은 이름으로 곧바로 다시 만드는 lab 이 있다). CLI 보다 엄격한 쪽이다(AUTHORING 규칙 10).
wait_gone() {
  local desc="$1" notfound="$2" _want="" _fails="" _retry="" _lw_argc
  shift 2
  _lw_opts "$@" || return 2
  shift "$_lw_argc"
  local limit start=$SECONDS out code tok
  limit="$(_lw_limit)" || return 2
  local -a toks
  while :; do
    if out="$("$@" 2>&1)"; then
      out="$(printf '%s\n' "$out" | _lw_clean)"
      read -r -a toks <<<"$(printf '%s' "$out" | tr '\n\t' '  ')"
      for tok in ${toks[@]+"${toks[@]}"}; do
        if _lw_in "$tok" "$_fails"; then
          _lw_report "$desc" "삭제를 기다리는데 '$tok' 상태다 (CLI waiter 도 여기서 실패한다)" "$out"
          return 1
        fi
      done
    else
      out="$(printf '%s\n' "$out" | _lw_clean)"
      code="$(_lw_error_code "$out")"
      [ "$code" = "$notfound" ] && return 0
      local why
      why="$(_lw_error_reason "$code" "$out")"
      case "$why" in 에뮬레이터*) ;; *) why="기대한 $notfound 가 아닌 오류${code:+ ($code)}" ;; esac
      _lw_report "$desc" "$why" "$out"
      return 1
    fi
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      _lw_report "$desc" "${limit}초 안에 사라지지 않았다" "$out"
      return 1
    fi
    sleep 1
  done
}

# ---- 서비스별 함수: 이름 끝의 주석은 대신하는 CLI waiter 와, 옮겨 온 acceptor 다.

# aws ec2 wait vpc-available — 성공: Vpcs[].State 모두 available
wait_ec2_vpc_available() {
  wait_state "VPC $* available" --want available \
    -- aws ec2 describe-vpcs --vpc-ids "$@" --query 'Vpcs[].State' --output text
}
# aws ec2 wait nat-gateway-available — 성공: 모두 available / 실패: failed·deleting·deleted / 재시도: NatGatewayNotFound
wait_ec2_nat_available() {
  wait_state "NAT 게이트웨이 $* available" --want available --fail "failed deleting deleted" --retry-on NatGatewayNotFound \
    -- aws ec2 describe-nat-gateways --nat-gateway-ids "$@" --query 'NatGateways[].State' --output text
}
# aws ec2 wait instance-running — 성공: 모두 running / 실패: shutting-down·terminated·stopping / 재시도: InvalidInstanceID.NotFound
wait_ec2_instance_running() {
  wait_state "인스턴스 $* running" --want running --fail "shutting-down terminated stopping" --retry-on InvalidInstanceID.NotFound \
    -- aws ec2 describe-instances --instance-ids "$@" --query 'Reservations[].Instances[].State.Name' --output text
}
# aws ec2 wait instance-terminated — 성공: 모두 terminated / 실패: pending·stopping
wait_ec2_instance_terminated() {
  wait_state "인스턴스 $* terminated" --want terminated --fail "pending stopping" \
    -- aws ec2 describe-instances --instance-ids "$@" --query 'Reservations[].Instances[].State.Name' --output text
}
# aws ec2 wait instance-stopped — 성공: 모두 stopped / 실패: pending·terminated
wait_ec2_instance_stopped() {
  wait_state "인스턴스 $* stopped" --want stopped --fail "pending terminated" \
    -- aws ec2 describe-instances --instance-ids "$@" --query 'Reservations[].Instances[].State.Name' --output text
}
# aws ec2 wait volume-available / volume-in-use — 실패: deleted
wait_ec2_volume_available() {
  wait_state "볼륨 $* available" --want available --fail "deleted" \
    -- aws ec2 describe-volumes --volume-ids "$@" --query 'Volumes[].State' --output text
}
wait_ec2_volume_in_use() {
  wait_state "볼륨 $* in-use" --want in-use --fail "deleted" \
    -- aws ec2 describe-volumes --volume-ids "$@" --query 'Volumes[].State' --output text
}
# aws ec2 wait snapshot-completed — 성공: 모두 completed / 실패: error
wait_ec2_snapshot_completed() {
  wait_state "스냅샷 $* completed" --want completed --fail "error" \
    -- aws ec2 describe-snapshots --snapshot-ids "$@" --query 'Snapshots[].State' --output text
}

# RDS·DocumentDB 의 *-available waiter 실패 상태, *-deleted waiter 실패 상태
_LW_RDS_AVAILABLE_FAIL="deleted deleting failed incompatible-restore incompatible-parameters"
_LW_RDS_DELETED_FAIL="creating modifying rebooting resetting-master-credentials"
# aws rds wait db-instance-available / db-instance-deleted
wait_rds_instance_available() {
  wait_state "RDS 인스턴스 $1 available" --want available --fail "$_LW_RDS_AVAILABLE_FAIL" \
    -- aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[].DBInstanceStatus' --output text
}
wait_rds_instance_deleted() {
  wait_gone "RDS 인스턴스 $1 삭제" DBInstanceNotFound --fail "$_LW_RDS_DELETED_FAIL" \
    -- aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[].DBInstanceStatus' --output text
}
# aws rds wait db-snapshot-available / db-snapshot-deleted
wait_rds_snapshot_available() {
  wait_state "RDS 스냅샷 $1 available" --want available --fail "$_LW_RDS_AVAILABLE_FAIL" \
    -- aws rds describe-db-snapshots --db-snapshot-identifier "$1" --query 'DBSnapshots[].Status' --output text
}
wait_rds_snapshot_deleted() {
  wait_gone "RDS 스냅샷 $1 삭제" DBSnapshotNotFound --fail "$_LW_RDS_DELETED_FAIL" \
    -- aws rds describe-db-snapshots --db-snapshot-identifier "$1" --query 'DBSnapshots[].Status' --output text
}
# aws rds wait db-cluster-available / db-cluster-deleted
wait_rds_cluster_available() {
  wait_state "Aurora 클러스터 $1 available" --want available --fail "$_LW_RDS_AVAILABLE_FAIL" \
    -- aws rds describe-db-clusters --db-cluster-identifier "$1" --query 'DBClusters[].Status' --output text
}
wait_rds_cluster_deleted() {
  wait_gone "Aurora 클러스터 $1 삭제" DBClusterNotFoundFault --fail "$_LW_RDS_DELETED_FAIL" \
    -- aws rds describe-db-clusters --db-cluster-identifier "$1" --query 'DBClusters[].Status' --output text
}
# aws docdb wait db-instance-available / db-instance-deleted (acceptor 는 RDS 와 같다)
wait_docdb_instance_available() {
  wait_state "DocumentDB 인스턴스 $1 available" --want available --fail "$_LW_RDS_AVAILABLE_FAIL" \
    -- aws docdb describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[].DBInstanceStatus' --output text
}
wait_docdb_instance_deleted() {
  wait_gone "DocumentDB 인스턴스 $1 삭제" DBInstanceNotFound --fail "$_LW_RDS_DELETED_FAIL" \
    -- aws docdb describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[].DBInstanceStatus' --output text
}
# aws elasticache wait replication-group-available — 성공: 모두 available / 실패: deleted
wait_elasticache_replication_group_available() {
  wait_state "복제 그룹 $1 available" --want available --fail "deleted" \
    -- aws elasticache describe-replication-groups --replication-group-id "$1" --query 'ReplicationGroups[].Status' --output text
}
# aws elasticache wait cache-cluster-available — 실패: deleted·deleting·incompatible-network·restore-failed
wait_elasticache_cluster_available() {
  wait_state "캐시 클러스터 $1 available" --want available --fail "deleted deleting incompatible-network restore-failed" \
    -- aws elasticache describe-cache-clusters --cache-cluster-id "$1" --query 'CacheClusters[].CacheClusterStatus' --output text
}
# aws elasticache wait cache-cluster-deleted — 성공: CacheClusterNotFound
#   / 실패: available·creating·incompatible-network·modifying·restore-failed·snapshotting
wait_elasticache_cluster_deleted() {
  wait_gone "캐시 클러스터 $1 삭제" CacheClusterNotFound \
    --fail "available creating incompatible-network modifying restore-failed snapshotting" \
    -- aws elasticache describe-cache-clusters --cache-cluster-id "$1" --query 'CacheClusters[].CacheClusterStatus' --output text
}
# aws route53 wait resource-record-sets-changed — 성공: ChangeInfo.Status 가 INSYNC
wait_route53_change_insync() {
  wait_state "Route 53 변경 $1 INSYNC" --want INSYNC \
    -- aws route53 get-change --id "$1" --query 'ChangeInfo.Status' --output text
}
# aws cloudfront wait distribution-deployed — 성공: Distribution.Status 가 Deployed
wait_cloudfront_distribution_deployed() {
  wait_state "배포 $1 Deployed" --want Deployed \
    -- aws cloudfront get-distribution --id "$1" --query 'Distribution.Status' --output text
}
# aws cloudfront wait invalidation-completed — 성공: Invalidation.Status 가 Completed
wait_cloudfront_invalidation_completed() {
  wait_state "무효화 $2 Completed" --want Completed \
    -- aws cloudfront get-invalidation --distribution-id "$1" --id "$2" --query 'Invalidation.Status' --output text
}
# ---- 준비 직후 다시 확인 (DynamoDB 테이블·Kinesis 스트림)
#
# 에뮬레이터는 DynamoDB 테이블·Kinesis 스트림이 준비됐는지를 VM 벽시계로 판단한다(만든 시각 + 몇 초). 맥 시계가
# 인터넷 시각과 0.5초 넘게 다르면 Colima 게스트 에이전트와 VM 의 timesyncd 가 10초마다 VM 시계를 번갈아 옮겨,
# VM 시계가 약 2초(관찰 1.98~2.26초) 뒤로 갔다가 0.2~0.3초 만에 돌아온다. ACTIVE 가 된 바로 그 무렵에 이 일이
# 생기면 리소스가 잠깐 "준비 안 됨"으로 돌아간다: DynamoDB 는 DescribeTable 이 ACTIVE 인데 PutItem·Scan 이
# ResourceNotFoundException, Kinesis 는 ACTIVE → CREATING. (M00 레슨 3 문제 해결 표, clock-check.sh --stability)
#
# 그래서 ACTIVE 를 처음 본 뒤 LAB_WAIT_SETTLE 초(기본 3, 0 이면 끔) 기다렸다가 한 번 더 확인하고, 그때 준비가
# 안 돼 있으면 다시 기다리지 않고(ResourceNotFoundException 도 재시도하지 않는다) 증상과 확인 명령을 알리며 실패한다.
#
# 무엇을 보장하고 무엇을 보장하지 않나
#   - VM 시계가 두 시각(맥 시각·NTP 시각) 사이를 오가고 그 간격이 d 라 하자. ACTIVE 를 본 순간 VM 시계가 위쪽
#     시각이었더라도, 그 뒤 실제로 d 초가 지나면 아래쪽 시각으로도 준비 경계를 넘어 있다. 그러니 기다림이 d 보다
#     길면 10초마다 되풀이되는 옮김이 몇 번이든(방향이 앞이든 뒤든) 그 뒤로는 되돌아가지 않는다 — 한 번의 옮김만이
#     아니라 되풀이에도 통한다. 단, 간격 d 가 그대로이고(옮김이 쌓이지 않고 돌아오고) 기다림보다 작을 때만이다.
#     기본 3초는 관찰된 d(최대 2.26초)보다 약 0.7초 길다(시험: ACTIVE 직후 2초 되돌림 → PutItem 3/3 실패,
#     3초 기다린 뒤 0/3 실패, 4초 기다린 뒤 2초 되돌림도 성공).
#   - d 는 맥 시계가 틀린 정도라 정해진 값이 아니다. d 가 기다림보다 크면(예: 맥 시계가 5초 틀림) 이 기다림은
#     실패 구간을 줄일 뿐 없애지 못한다. 마지막 확인은 한 번 조회일 뿐이라, 그 순간이 0.2~0.3초짜리 되돌림과
#     겹칠 때만 잡는다(10초에 한 번이면 대략 3%). 이 확인을 통과한 뒤 lab 의 다음 호출이 같은 이유로 실패할 수 있고,
#     그때는 모듈 verify.sh 의 실패 요약이 clock-check.sh --stability --summary 로 VM 시계 불안정을 알린다.
#   - 기다리는 동안 상태가 잠깐 되돌아가는 것은 이 기다림이 견디려는 바로 그 일이므로 보지 않는다(보고 실패하면
#     기다림이 막아 줄 수 있는 경우까지 실패로 만든다).
#   - 테이블을 다시 만드는 다른 경로(CloudFormation 스택, boto3 예제, update-table 의 GSI·용량 변경)는 덮지 않는다.
#   실제 AWS 에서는 이런 되돌아감이 없으니 레슨은 CLI waiter 를 그대로 가르친다.

# LAB_WAIT_SETTLE 을 검사해 출력한다 (0 이상의 정수 초).
_lw_settle_secs() {
  local v="${LAB_WAIT_SETTLE:-3}"
  case "$v" in
    '' | *[!0-9]*) echo "lab-wait: LAB_WAIT_SETTLE 은 0 이상의 정수(초)여야 한다: '$v'" >&2; return 2 ;;
  esac
  [ "${#v}" -le 4 ] || { echo "lab-wait: LAB_WAIT_SETTLE 이 너무 크다: '$v'" >&2; return 2; }
  echo "$((10#$v))"
}

# ACTIVE 를 본 뒤 settle 초 뒤의 재확인이 실패했을 때 (재시도하지 않는다)
_lw_flip_report() { # <설명> <기다린 초> <무엇을 봤나> <마지막 관찰>
  _lw_report "$1" "ACTIVE 를 확인하고 ${2}초 뒤 다시 보니 준비되지 않았다 — $3" "$4"
  cat >&2 <<EOF
  준비됨(ACTIVE) 직후 다시 "준비 안 됨"이 되는 것은 Colima VM 시계가 뒤로 옮겨질 때의 증상이다
  (DynamoDB: ACTIVE 인데 ResourceNotFoundException / Kinesis: ACTIVE → CREATING). 다시 기다려 감추지 않고 여기서 멈춘다.
  확인:  bash scripts/clock-check.sh --stability     (해결 방법은 M00 레슨 3 문제 해결 표)
EOF
  return 1
}

# aws kinesis wait stream-exists — 성공: StreamStatus 가 ACTIVE. 그 뒤 LAB_WAIT_SETTLE 초 뒤에도 ACTIVE 인지 확인한다.
wait_kinesis_stream_active() {
  local settle out code
  settle="$(_lw_settle_secs)" || return 2
  wait_state "스트림 $1 ACTIVE" --want ACTIVE \
    -- aws kinesis describe-stream --stream-name "$1" --query 'StreamDescription.StreamStatus' --output text || return $?
  [ "$settle" -gt 0 ] || return 0
  sleep "$settle"
  if out="$(aws kinesis describe-stream --stream-name "$1" --query 'StreamDescription.StreamStatus' --output text 2>&1)"; then
    out="$(printf '%s\n' "$out" | _lw_clean)"
    [ "$out" = ACTIVE ] && return 0
    _lw_flip_report "스트림 $1 ACTIVE" "$settle" "상태가 '$out' 다" "$out"
    return 1
  fi
  out="$(printf '%s\n' "$out" | _lw_clean)"
  code="$(_lw_error_code "$out")"
  if [ "$code" = ResourceNotFoundException ]; then
    _lw_flip_report "스트림 $1 ACTIVE" "$settle" "DescribeStream 이 ResourceNotFoundException" "$out"
  else
    _lw_report "스트림 $1 ACTIVE (재확인)" "$(_lw_error_reason "$code" "$out")" "$out"
  fi
  return 1
}
# aws kinesis wait stream-not-exists — 성공: ResourceNotFoundException
wait_kinesis_stream_gone() {
  wait_gone "스트림 $1 삭제" ResourceNotFoundException \
    -- aws kinesis describe-stream --stream-name "$1" --query 'StreamDescription.StreamStatus' --output text
}
# aws dynamodb wait table-exists — 성공: Table.TableStatus 가 ACTIVE / 재시도: ResourceNotFoundException
#   (acceptor 는 CLI waiter 와 같다. 처음 ACTIVE 를 기다리는 동안의 ResourceNotFoundException 재시도는 waiter 의 것이다.)
#   이 래퍼는 빨라지려고 있는 것이 아니다 — 에뮬레이터의 DescribeTable 은 테이블이 ACTIVE 가 될 때까지 약 3초 응답을
#   늦추므로 waiter 의 첫 조회가 곧바로 ACTIVE 를 본다. 바로 그래서 waiter 가 끝난 순간이 준비 경계와 거의 같고,
#   위 "준비 직후 다시 확인"이 필요하다. 재확인은 DescribeTable 이 아니라 Scan(Select=COUNT, Limit=1, 데이터 변경 없음)
#   으로 한다 — 되돌아간 동안에도 DescribeTable 은 ACTIVE 를 돌려주고 데이터 호출만 ResourceNotFoundException 이다.
wait_dynamodb_table_active() {
  local settle out code
  settle="$(_lw_settle_secs)" || return 2
  wait_state "테이블 $1 ACTIVE" --want ACTIVE --retry-on ResourceNotFoundException \
    -- aws dynamodb describe-table --table-name "$1" --query 'Table.TableStatus' --output text || return $?
  [ "$settle" -gt 0 ] || return 0
  sleep "$settle"
  out="$(aws dynamodb scan --table-name "$1" --select COUNT --limit 1 --output text 2>&1)" && return 0
  out="$(printf '%s\n' "$out" | _lw_clean)"
  code="$(_lw_error_code "$out")"
  if [ "$code" = ResourceNotFoundException ]; then
    _lw_flip_report "테이블 $1 ACTIVE" "$settle" "DescribeTable 은 ACTIVE 였는데 Scan 이 ResourceNotFoundException" "$out"
  else
    _lw_report "테이블 $1 ACTIVE (재확인 Scan)" "$(_lw_error_reason "$code" "$out")" "$out"
  fi
  return 1
}
# aws dynamodb wait table-not-exists — 성공: ResourceNotFoundException
wait_dynamodb_table_gone() {
  wait_gone "테이블 $1 삭제" ResourceNotFoundException \
    -- aws dynamodb describe-table --table-name "$1" --query 'Table.TableStatus' --output text
}
