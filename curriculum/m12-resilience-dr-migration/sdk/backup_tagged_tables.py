"""M12 — 태그 backup=daily 가 붙은 DynamoDB 테이블을 찾아 AWS Backup 온디맨드 백업을 돌린다.

백업 계획의 "태그 기반 선택"이 하는 일을 손으로 한 번 해 보는 예제다.
    1) 볼트·서비스 역할이 없으면 만든다 (역할 신뢰 정책: backup.amazonaws.com)
    2) 모든 테이블의 태그를 DynamoDB ListTagsOfResource 로 읽어 backup=daily 를 고른다
       (Resource Groups Tagging API 는 에뮬레이터에서 DynamoDB 를 못 찾는다 — 서비스 자체 API 를 쓴다)
    3) 고른 테이블마다 StartBackupJob → waiter 대신 폴링으로 COMPLETED 를 기다린다
    4) 볼트의 복구 지점을 출력한다

대상 테이블이 하나도 없으면 데모 테이블(todayorder-m12-sdk-demo, 태그 backup=daily)을 만들어 쓴다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m12-resilience-dr-migration/sdk/backup_tagged_tables.py
"""

from __future__ import annotations

import json
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

VAULT = "todayorder-sdk-vault"
ROLE = "todayorder-sdk-backup-role"
DEMO_TABLE = "todayorder-m12-sdk-demo"
TAG = ("backup", "daily")
TRUST = {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "backup.amazonaws.com"}, "Action": "sts:AssumeRole"}]}


def poll(what: str, fn: Any, done: Any, timeout: float = 120.0) -> Any:
    """fn() 결과가 done(결과)를 만족할 때까지 기다린다. 시간이 넘으면 마지막 값을 보여 주고 종료."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if done(last):
            return last
        time.sleep(1)
    raise SystemExit(f"{what}: {timeout:.0f}초 안에 끝나지 않음 (마지막 값 {last})")


def ensure_role(iam: Any) -> str:
    try:
        return iam.get_role(RoleName=ROLE)["Role"]["Arn"]
    except ClientError:
        arn = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(TRUST))["Role"]["Arn"]
        iam.attach_role_policy(RoleName=ROLE,
                               PolicyArn="arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup")
        return arn


def tagged_tables(ddb: Any) -> list[str]:
    arns: list[str] = []
    for page in ddb.get_paginator("list_tables").paginate():
        for name in page["TableNames"]:
            arn = ddb.describe_table(TableName=name)["Table"]["TableArn"]
            tags = {t["Key"]: t["Value"] for t in ddb.list_tags_of_resource(ResourceArn=arn).get("Tags", [])}
            if tags.get(TAG[0]) == TAG[1]:
                arns.append(arn)
    return arns


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    bk, ddb, iam = boto3.client("backup"), boto3.client("dynamodb"), boto3.client("iam")

    try:
        bk.create_backup_vault(BackupVaultName=VAULT)
        print(f"볼트 생성: {VAULT}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "AlreadyExistsException":
            raise
    role_arn = ensure_role(iam)

    targets = tagged_tables(ddb)
    if not targets:
        print(f"태그 {TAG[0]}={TAG[1]} 테이블이 없어 데모 테이블을 만듭니다: {DEMO_TABLE}")
        ddb.create_table(TableName=DEMO_TABLE, BillingMode="PAY_PER_REQUEST",
                         AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                         KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
                         Tags=[{"Key": TAG[0], "Value": TAG[1]}])
        ddb.get_waiter("table_exists").wait(TableName=DEMO_TABLE)
        # 태그는 테이블이 ACTIVE 가 된 뒤에야 조회된다(실제 DynamoDB 도 태그 반영은 최종 일관성)
        targets = poll("데모 테이블 태그 반영", lambda: tagged_tables(ddb), bool, 30)
    print(f"백업 대상 {len(targets)}개: {', '.join(a.split('/')[-1] for a in targets)}")

    for arn in targets:
        job = bk.start_backup_job(BackupVaultName=VAULT, ResourceArn=arn, IamRoleArn=role_arn,
                                  Lifecycle={"DeleteAfterDays": 35})
        state = poll("백업 작업", lambda j=job["BackupJobId"]: bk.describe_backup_job(BackupJobId=j)["State"],
                     lambda s: s in ("COMPLETED", "FAILED", "ABORTED", "EXPIRED"))
        print(f"  {arn.split('/')[-1]}: {state}")
        assert state == "COMPLETED"

    rps = bk.list_recovery_points_by_backup_vault(BackupVaultName=VAULT)["RecoveryPoints"]
    print(f"볼트 {VAULT} 의 복구 지점 {len(rps)}개")
    for rp in rps[-len(targets):]:
        print(f"  {rp['ResourceType']:<9} {rp['Status']:<10} {rp['ResourceArn'].split(':')[-1]}  "
              f"삭제 예정 {rp.get('Lifecycle', {}).get('DeleteAfterDays')}일 후")
    print("SDK backup_tagged_tables OK")


if __name__ == "__main__":
    main()
