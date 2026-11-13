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
#   - 상한(기본 600초, LAB_WAIT_TIMEOUT)을 넘기면 마지막으로 관찰한 값을 보여 주고 실패한다.
#   실패하면 1을 돌려준다(set -e 인 lab 은 그 자리에서 멈춘다).

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
  local limit="${LAB_WAIT_TIMEOUT:-600}" start=$SECONDS out code tok bad n all
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
        _lw_report "$desc" "조회가 예상하지 못한 오류로 실패했다${code:+ ($code)}" "$out"
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
wait_gone() {
  local desc="$1" notfound="$2" _want="" _fails="" _retry="" _lw_argc
  shift 2
  _lw_opts "$@" || return 2
  shift "$_lw_argc"
  local limit="${LAB_WAIT_TIMEOUT:-600}" start=$SECONDS out code tok
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
      _lw_report "$desc" "기대한 $notfound 가 아닌 오류${code:+ ($code)}" "$out"
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
# aws kinesis wait stream-exists — 성공: StreamStatus 가 ACTIVE
wait_kinesis_stream_active() {
  wait_state "스트림 $1 ACTIVE" --want ACTIVE \
    -- aws kinesis describe-stream --stream-name "$1" --query 'StreamDescription.StreamStatus' --output text
}
# aws kinesis wait stream-not-exists — 성공: ResourceNotFoundException
wait_kinesis_stream_gone() {
  wait_gone "스트림 $1 삭제" ResourceNotFoundException \
    -- aws kinesis describe-stream --stream-name "$1" --query 'StreamDescription.StreamStatus' --output text
}
# (aws dynamodb wait table-exists 는 대신하지 않는다: 에뮬레이터의 DescribeTable 은 테이블이 ACTIVE 가 될 때까지
#  약 3초 동안 응답을 늦추므로, waiter 의 첫 조회가 곧바로 ACTIVE 를 본다 — 1초 간격 폴링으로 줄어드는 시간이 없다.)
# aws dynamodb wait table-not-exists — 성공: ResourceNotFoundException
wait_dynamodb_table_gone() {
  wait_gone "테이블 $1 삭제" ResourceNotFoundException \
    -- aws dynamodb describe-table --table-name "$1" --query 'Table.TableStatus' --output text
}
