#!/usr/bin/env bash
# M12 lab03 — AWS Backup: 볼트·계획·선택, 온디맨드 백업 → 복구 지점, 복사·복원, 볼트 잠금 (🟢, 복원 데이터는 🟡)
#
# 1) 서비스 역할: 신뢰 정책에 backup.amazonaws.com 이 있는 역할 / 없는 역할(ec2)
# 2) 볼트 2개: todayorder-vault (주), todayorder-dr-vault (실제 AWS라면 다른 리전의 볼트)
# 3) 백업 계획: 매일 05:00 UTC, 35일 보관, DR 볼트로 복사(90일 보관)
# 4) 백업 선택(태그 backup=daily): 잘못된 역할은 거부 → 올바른 역할은 성공
# 5) 주문 테이블 온디맨드 백업 → COMPLETED + 복구 지점
# 6) 복구 지점을 DR 볼트로 복사(StartCopyJob) — ListCopyJobs 는 501
# 7) 복원(StartRestoreJob) → 새 테이블이 생긴다. 단 에뮬레이터는 항목(데이터)을 복원하지 않는다
# 8) 볼트 잠금(거버넌스 모드): 보존 기간 중 복구 지점 삭제가 거부된다
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

VAULT="todayorder-vault"
DR_VAULT="todayorder-dr-vault"
PLAN="todayorder-daily"
ROLE="todayorder-backup-role"
BAD_ROLE="todayorder-not-backup-role"
TABLE="todayorder-orders-bk"
RESTORED="todayorder-orders-restored"
ACCOUNT="000000000000"
VAULT_ARN="arn:aws:backup:us-east-1:$ACCOUNT:backup-vault:$VAULT"

wait_until() { # wait_until <설명> <최대초> <명령...>
  local what="$1" max="$2" i; shift 2
  for i in $(seq "$max"); do "$@" && return 0; sleep 1; done
  echo "FAIL: ${max}초 안에 '$what' 이 되지 않음"; return 1
}
table_gone() { ! aws dynamodb describe-table --table-name "$1" >/dev/null 2>&1; }

cleanup() {
  # ListBackupPlans 가 501 이라 계획을 이름으로 찾을 수 없다 → 만들 때 볼트 태그에 계획 ID 를 적어 두고 그걸로 찾는다.
  local pid sid rp v r t
  pid="$(aws backup list-tags --resource-arn "$VAULT_ARN" --query 'Tags."todayorder:backup-plan-id"' --output text 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != "None" ]; then
    for sid in $(aws backup list-backup-selections --backup-plan-id "$pid" --query 'BackupSelectionsList[].SelectionId' --output text 2>/dev/null); do
      aws backup delete-backup-selection --backup-plan-id "$pid" --selection-id "$sid"
    done
    aws backup delete-backup-plan --backup-plan-id "$pid" >/dev/null 2>&1 || true
  fi
  for v in "$VAULT" "$DR_VAULT"; do
    aws backup describe-backup-vault --backup-vault-name "$v" >/dev/null 2>&1 || continue
    aws backup delete-backup-vault-lock-configuration --backup-vault-name "$v" 2>/dev/null || true
    for rp in $(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$v" --query 'RecoveryPoints[].RecoveryPointArn' --output text); do
      aws backup delete-recovery-point --backup-vault-name "$v" --recovery-point-arn "$rp"
    done
    aws backup delete-backup-vault --backup-vault-name "$v"
  done
  for r in "$ROLE" "$BAD_ROLE"; do
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
    done
    aws iam delete-role --role-name "$r" 2>/dev/null || true
  done
  for t in "$TABLE" "$RESTORED"; do
    aws dynamodb delete-table --table-name "$t" >/dev/null 2>&1 || true
    wait_until "$t 삭제" 60 table_gone "$t"
  done
}
cleanup

echo "== 1. 서비스 역할 두 개"
trust() { printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"%s"},"Action":"sts:AssumeRole"}]}' "$1"; }
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$(trust backup.amazonaws.com)" --query Role.Arn --output text)"
for p in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForRestores; do
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn "arn:aws:iam::aws:policy/service-role/$p"
done
BAD_ROLE_ARN="$(aws iam create-role --role-name "$BAD_ROLE" --assume-role-policy-document "$(trust ec2.amazonaws.com)" --query Role.Arn --output text)"
echo "$ROLE_ARN (신뢰: backup.amazonaws.com)"
echo "$BAD_ROLE_ARN (신뢰: ec2.amazonaws.com)"

echo "== 2. 백업 볼트"
aws backup create-backup-vault --backup-vault-name "$VAULT" --query BackupVaultArn --output text
DR_VAULT_ARN="$(aws backup create-backup-vault --backup-vault-name "$DR_VAULT" --query BackupVaultArn --output text)"
echo "$DR_VAULT_ARN"

echo "== 3. 백업 계획: 매일 05:00 UTC, 35일 보관, DR 볼트로 복사(90일)"
PLAN_JSON="$(cat <<EOF
{"BackupPlanName":"$PLAN","Rules":[{"RuleName":"daily-0500utc","TargetBackupVaultName":"$VAULT",
 "ScheduleExpression":"cron(0 5 ? * * *)","StartWindowMinutes":60,"CompletionWindowMinutes":180,
 "Lifecycle":{"DeleteAfterDays":35},
 "CopyActions":[{"DestinationBackupVaultArn":"$DR_VAULT_ARN","Lifecycle":{"DeleteAfterDays":90}}]}]}
EOF
)"
PLAN_ID="$(aws backup create-backup-plan --backup-plan "$PLAN_JSON" --query BackupPlanId --output text)"
aws backup tag-resource --resource-arn "$VAULT_ARN" --tags "todayorder:backup-plan-id=$PLAN_ID"
aws backup get-backup-plan --backup-plan-id "$PLAN_ID" \
  --query 'BackupPlan.Rules[0].{Rule:RuleName,Schedule:ScheduleExpression,Retain:Lifecycle.DeleteAfterDays,CopyTo:CopyActions[0].DestinationBackupVaultArn}'

echo "== 4. 백업 선택(태그 backup=daily) — 먼저 잘못된 역할로"
SEL_TAGS='"ListOfTags":[{"ConditionType":"STRINGEQUALS","ConditionKey":"backup","ConditionValue":"daily"}]'
set +e
bad_sel="$(aws backup create-backup-selection --backup-plan-id "$PLAN_ID" \
  --backup-selection "{\"SelectionName\":\"tagged-daily\",\"IamRoleArn\":\"$BAD_ROLE_ARN\",$SEL_TAGS}" 2>&1)"
set -e
echo "$bad_sel"
echo "-- 올바른 역할로"
aws backup create-backup-selection --backup-plan-id "$PLAN_ID" \
  --backup-selection "{\"SelectionName\":\"tagged-daily\",\"IamRoleArn\":\"$ROLE_ARN\",$SEL_TAGS}" \
  --query '{SelectionId:SelectionId,BackupPlanId:BackupPlanId}'

echo "== 5. 주문 테이블(태그 backup=daily)과 온디맨드 백업"
TABLE_ARN="$(aws dynamodb create-table --table-name "$TABLE" --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=orderId,AttributeType=S --key-schema AttributeName=orderId,KeyType=HASH \
  --tags Key=backup,Value=daily Key=project,Value=todayorder --query TableDescription.TableArn --output text)"
aws dynamodb wait table-exists --table-name "$TABLE"
for n in 2001 2002 2003; do
  aws dynamodb put-item --table-name "$TABLE" --item "{\"orderId\":{\"S\":\"B-$n\"},\"amount\":{\"N\":\"$n\"}}"
done
JOB_ID="$(aws backup start-backup-job --backup-vault-name "$VAULT" --resource-arn "$TABLE_ARN" --iam-role-arn "$ROLE_ARN" \
  --lifecycle DeleteAfterDays=35 --query BackupJobId --output text)"
job_done() { case "$(aws backup describe-backup-job --backup-job-id "$JOB_ID" --query State --output text)" in COMPLETED | FAILED | ABORTED | EXPIRED) return 0 ;; *) return 1 ;; esac; }
wait_until "백업 작업 종료" 120 job_done || aws backup describe-backup-job --backup-job-id "$JOB_ID" --query State
aws backup describe-backup-job --backup-job-id "$JOB_ID" --query '{State:State,ResourceType:ResourceType,PercentDone:PercentDone,Retain:RecoveryPointLifecycle.DeleteAfterDays}'
RP_ARN="$(aws backup describe-backup-job --backup-job-id "$JOB_ID" --query RecoveryPointArn --output text)"
aws backup list-recovery-points-by-backup-vault --backup-vault-name "$VAULT" \
  --query 'RecoveryPoints[].{ResourceType:ResourceType,Status:Status,Resource:ResourceArn}'

echo "== 6. 복구 지점을 DR 볼트로 복사"
COPY_ID="$(aws backup start-copy-job --recovery-point-arn "$RP_ARN" --source-backup-vault-name "$VAULT" \
  --destination-backup-vault-arn "$DR_VAULT_ARN" --iam-role-arn "$ROLE_ARN" --query CopyJobId --output text)"
copy_done() { case "$(aws backup describe-copy-job --copy-job-id "$COPY_ID" --query CopyJob.State --output text)" in COMPLETED | FAILED) return 0 ;; *) return 1 ;; esac; }
wait_until "복사 작업 종료" 120 copy_done
aws backup describe-copy-job --copy-job-id "$COPY_ID" --query 'CopyJob.{State:State,To:DestinationBackupVaultArn}'
set +e
list_copy="$(aws backup list-copy-jobs 2>&1)"
set -e
echo "list-copy-jobs → $list_copy"

echo "== 7. 복원: 복구 지점에서 새 테이블 만들기"
RESTORE_ID="$(aws backup start-restore-job --recovery-point-arn "$RP_ARN" --iam-role-arn "$ROLE_ARN" \
  --resource-type DynamoDB --metadata "targetTableName=$RESTORED" --query RestoreJobId --output text)"
restore_done() { case "$(aws backup describe-restore-job --restore-job-id "$RESTORE_ID" --query Status --output text)" in COMPLETED | FAILED | ABORTED) return 0 ;; *) return 1 ;; esac; }
wait_until "복원 작업 종료" 120 restore_done
aws backup describe-restore-job --restore-job-id "$RESTORE_ID" --query '{Status:Status,Created:CreatedResourceArn}'
aws dynamodb wait table-exists --table-name "$RESTORED"
orig_count="$(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text)"
restored_count="$(aws dynamodb scan --table-name "$RESTORED" --select COUNT --query Count --output text)"
echo "원본 항목 ${orig_count}개 · 복원된 테이블 항목 ${restored_count}개 (실제 AWS라면 백업 시점의 ${orig_count}개)"

echo "== 8. 볼트 잠금(거버넌스 모드, 최소 보존 7일) → 복구 지점 삭제 시도"
aws backup put-backup-vault-lock-configuration --backup-vault-name "$VAULT" --min-retention-days 7 --max-retention-days 365
aws backup describe-backup-vault --backup-vault-name "$VAULT" --query '{Locked:Locked,MinRetentionDays:MinRetentionDays,MaxRetentionDays:MaxRetentionDays}'
set +e
del_locked="$(aws backup delete-recovery-point --backup-vault-name "$VAULT" --recovery-point-arn "$RP_ARN" 2>&1)"
set -e
echo "$del_locked"
echo "-- 거버넌스 모드는 권한 있는 사용자가 잠금 설정을 지울 수 있다 (정리를 위해 해제)"
aws backup delete-backup-vault-lock-configuration --backup-vault-name "$VAULT"

# ---- 단언
grep -q 'InvalidParameterValueException' <<<"$bad_sel" || { echo "FAIL: 잘못된 신뢰 정책의 역할이 거부되지 않음"; exit 1; }
[ "$(aws backup describe-backup-job --backup-job-id "$JOB_ID" --query State --output text)" = "COMPLETED" ] || { echo "FAIL: 백업 작업"; exit 1; }
[ "$(aws backup describe-backup-vault --backup-vault-name "$VAULT" --query NumberOfRecoveryPoints --output text)" -ge 1 ] || { echo "FAIL: 복구 지점 없음"; exit 1; }
[ "$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$DR_VAULT" --query 'length(RecoveryPoints)' --output text)" = "1" ] || { echo "FAIL: DR 볼트 복사본"; exit 1; }
grep -q 'NotImplemented' <<<"$list_copy" || { echo "FAIL: ListCopyJobs 가 이제 구현됨 → 문서 갱신 필요"; exit 1; }
[ "$restored_count" = "0" ] || echo "참고: 복원 테이블에 데이터가 있다($restored_count) — 에뮬레이터가 데이터 복원을 지원하기 시작함. 문서 갱신 필요"
grep -q 'Lock' <<<"$del_locked" || { echo "FAIL: 볼트 잠금이 삭제를 막지 않음"; exit 1; }
echo "LAB03 OK"
