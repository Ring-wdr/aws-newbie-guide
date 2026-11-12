"""M05: RDS / DynamoDB / ElastiCache 탐침."""

from __future__ import annotations

import os
import socket
import subprocess
import time
from typing import Any

from botocore.exceptions import ClientError

from lib import Probe, wait_until


def _vpc_subnets(p: Probe, cidr2: str) -> list[str]:
    ec2 = p.client("ec2")
    try:
        vpc = ec2.create_vpc(CidrBlock=f"10.{cidr2}.0.0/16")["Vpc"]["VpcId"]
        p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
        subs = []
        for i, az in ((1, "us-east-1a"), (2, "us-east-1b")):
            sid = ec2.create_subnet(VpcId=vpc, CidrBlock=f"10.{cidr2}.{i}.0/24", AvailabilityZone=az)["Subnet"]["SubnetId"]
            subs.append(sid)
            p.cleanup("sn", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
        return subs
    except Exception:  # noqa: BLE001
        return []


def _tcp_from_container(host: str, port: int) -> str:
    """에뮬레이터 컨테이너 안에서 TCP 연결을 시도한다 (bash /dev/tcp 사용)."""
    ep = os.environ.get("EMULATOR_PORT", "9297")
    try:
        r = subprocess.run(["docker", "exec", f"aws-emulator-{ep}", "bash", "-c",
                            f"timeout 3 bash -c 'exec 3<>/dev/tcp/{host}/{port}' && echo OPEN || echo CLOSED"],
                           capture_output=True, text=True, timeout=15)
        return (r.stdout.strip() or r.stderr.strip())[:60]
    except Exception as e:  # noqa: BLE001
        return f"{type(e).__name__}"


def _tcp_from_host(host: str, port: int) -> bool:
    try:
        socket.create_connection((host, port), timeout=2).close()
        return True
    except Exception:  # noqa: BLE001
        return False


def run_rds(p: Probe) -> None:
    rds = p.client("rds")
    p.call("DescribeDBEngineVersions(postgres)", rds.describe_db_engine_versions, Engine="postgres", MaxRecords=20)
    p.call("DescribeOrderableDBInstanceOptions(mysql)", rds.describe_orderable_db_instance_options, Engine="mysql", MaxRecords=20)
    subs = _vpc_subnets(p, 40)
    sng = p.name("sng")
    if subs and p.call("CreateDBSubnetGroup", rds.create_db_subnet_group, DBSubnetGroupName=sng,
                       DBSubnetGroupDescription="probe", SubnetIds=subs) is not None:
        p.cleanup("sng", lambda: rds.delete_db_subnet_group(DBSubnetGroupName=sng))
    pg = p.name("pg")
    if p.call("CreateDBParameterGroup(postgres16)", rds.create_db_parameter_group, DBParameterGroupName=pg,
              DBParameterGroupFamily="postgres16", Description="probe") is not None:
        p.cleanup("pg", lambda: rds.delete_db_parameter_group(DBParameterGroupName=pg))
        p.call("ModifyDBParameterGroup(log_min_duration_statement)", rds.modify_db_parameter_group, DBParameterGroupName=pg,
               Parameters=[{"ParameterName": "log_min_duration_statement", "ParameterValue": "500", "ApplyMethod": "immediate"}])
    dbid = p.name("db")
    kw: dict[str, Any] = {"DBSubnetGroupName": sng} if subs else {}
    db = p.call("CreateDBInstance(postgres, MultiAZ)", rds.create_db_instance, DBInstanceIdentifier=dbid, Engine="postgres",
                DBInstanceClass="db.t3.micro", AllocatedStorage=20, MasterUsername="todayorder",
                MasterUserPassword="Todayorder-Pass-123", MultiAZ=True, BackupRetentionPeriod=7,
                DBParameterGroupName=pg, StorageEncrypted=True, **kw)
    if not db:
        return
    p.cleanup("db", lambda: rds.delete_db_instance(DBInstanceIdentifier=dbid, SkipFinalSnapshot=True,
                                                   DeleteAutomatedBackups=True))
    seen = [db["DBInstance"]["DBInstanceStatus"]]

    def _desc() -> dict[str, Any]:
        return rds.describe_db_instances(DBInstanceIdentifier=dbid)["DBInstances"][0]

    def _avail() -> bool:
        s = _desc()["DBInstanceStatus"]
        if s != seen[-1]:
            seen.append(s)
        return s == "available"
    ok = wait_until(_avail, 30, 1)
    p.behavior("DB 인스턴스 creating→available", ok, " → ".join(seen))
    d = _desc()
    ep = d.get("Endpoint") or {}
    p.behavior("Endpoint 주소·포트 반환", bool(ep.get("Address")) and bool(ep.get("Port")), f"{ep.get('Address')}:{ep.get('Port')}")
    p.behavior("MultiAZ·SecondaryAvailabilityZone 표시", d.get("MultiAZ") is True,
               f"MultiAZ={d.get('MultiAZ')} AZ={d.get('AvailabilityZone')} Secondary={d.get('SecondaryAvailabilityZone')}")
    if ep.get("Address") and ep.get("Port"):
        host_ok = _tcp_from_host(ep["Address"], int(ep["Port"]))
        inside = _tcp_from_container(ep["Address"], int(ep["Port"]))
        p.behavior("Endpoint 포트에 실제 DB가 떠 있음(컨테이너 안 TCP)", inside == "OPEN", f"컨테이너 안: {inside}")
        if inside == "OPEN":
            ep_ = os.environ.get("EMULATOR_PORT", "9297")
            cmd = (f"exec 3<>/dev/tcp/{ep['Address']}/{ep['Port']}; printf '\\x00\\x00\\x00\\x08\\x04\\xd2\\x16\\x2f' >&3; "
                   "timeout 2 head -c 1 <&3")
            try:
                out = subprocess.run(["docker", "exec", f"aws-emulator-{ep_}", "bash", "-c", cmd],
                                     capture_output=True, text=True, timeout=15).stdout
            except Exception as e:  # noqa: BLE001
                out = type(e).__name__
            p.behavior("Endpoint가 PostgreSQL 프로토콜로 응답(SSLRequest → 'S'/'N')", out in ("S", "N"), f"응답 {out!r}")
        p.behavior("호스트(macOS)에서 Endpoint 포트로 TCP 연결", host_ok, "연결됨" if host_ok else "연결 불가(포트가 컨테이너 밖에 게시되지 않음)")
    rr = p.call("CreateDBInstanceReadReplica", rds.create_db_instance_read_replica, DBInstanceIdentifier=p.name("db-rr"),
                SourceDBInstanceIdentifier=dbid, DBInstanceClass="db.t3.micro")
    if rr:
        p.cleanup("rr", lambda: rds.delete_db_instance(DBInstanceIdentifier=p.name("db-rr"), SkipFinalSnapshot=True))
        rd = rds.describe_db_instances(DBInstanceIdentifier=p.name("db-rr"))["DBInstances"][0]
        p.behavior("읽기 복제본이 원본을 가리킴", rd.get("ReadReplicaSourceDBInstanceIdentifier") == dbid,
                   f"Source={rd.get('ReadReplicaSourceDBInstanceIdentifier')}; 원본 Replicas={_desc().get('ReadReplicaDBInstanceIdentifiers')}")
    snap = p.call("CreateDBSnapshot", rds.create_db_snapshot, DBSnapshotIdentifier=p.name("snap"), DBInstanceIdentifier=dbid)
    if snap:
        p.cleanup("snap", lambda: rds.delete_db_snapshot(DBSnapshotIdentifier=p.name("snap")))
        ok = wait_until(lambda: rds.describe_db_snapshots(DBSnapshotIdentifier=p.name("snap"))["DBSnapshots"][0]["Status"] == "available", 20)
        p.behavior("스냅샷 creating→available", ok, f"생성 직후 {snap['DBSnapshot']['Status']}")
        if ok:
            rs = p.call("RestoreDBInstanceFromDBSnapshot", rds.restore_db_instance_from_db_snapshot,
                        DBInstanceIdentifier=p.name("db-restored"), DBSnapshotIdentifier=p.name("snap"),
                        DBInstanceClass="db.t3.micro")
            if rs:
                p.cleanup("rs", lambda: rds.delete_db_instance(DBInstanceIdentifier=p.name("db-restored"), SkipFinalSnapshot=True))
    p.call("DescribeDBSnapshots(automated)", rds.describe_db_snapshots, DBInstanceIdentifier=dbid, SnapshotType="automated")
    wait_until(lambda: _desc()["DBInstanceStatus"] == "available", 20)
    p.call("ModifyDBInstance(DBInstanceClass, ApplyImmediately)", rds.modify_db_instance, DBInstanceIdentifier=dbid,
           DBInstanceClass="db.t3.small", ApplyImmediately=True)
    time.sleep(1)
    p.behavior("Modify 후 클래스 변경 반영", wait_until(lambda: _desc()["DBInstanceClass"] == "db.t3.small", 20),
               f"{_desc()['DBInstanceClass']} / {_desc()['DBInstanceStatus']}")
    wait_until(lambda: _desc()["DBInstanceStatus"] == "available", 20)
    az0 = _desc().get("AvailabilityZone")
    if p.call("RebootDBInstance(ForceFailover)", rds.reboot_db_instance, DBInstanceIdentifier=dbid, ForceFailover=True) is not None:
        wait_until(lambda: _desc()["DBInstanceStatus"] == "available", 20)
        az1 = _desc().get("AvailabilityZone")
        p.behavior("강제 장애 조치 후 AZ가 바뀜", az0 != az1, f"{az0} → {az1}")
    p.expect_error("CreateDBInstance(같은 식별자)", rds.create_db_instance, "DBInstanceAlreadyExists",
                   DBInstanceIdentifier=dbid, Engine="postgres", DBInstanceClass="db.t3.micro", AllocatedStorage=20,
                   MasterUsername="x1", MasterUserPassword="Todayorder-Pass-123",
                   what="같은 식별자 → DBInstanceAlreadyExists")
    p.call("CreateDBInstance(mysql)", rds.create_db_instance, DBInstanceIdentifier=p.name("mysql"), Engine="mysql",
           DBInstanceClass="db.t3.micro", AllocatedStorage=20, MasterUsername="todayorder", MasterUserPassword="Todayorder-Pass-123")
    p.cleanup("mysql", lambda: rds.delete_db_instance(DBInstanceIdentifier=p.name("mysql"), SkipFinalSnapshot=True))

    # Aurora
    cid = p.name("aurora")
    cl = p.call("CreateDBCluster(aurora-postgresql)", rds.create_db_cluster, DBClusterIdentifier=cid, Engine="aurora-postgresql",
                MasterUsername="todayorder", MasterUserPassword="Todayorder-Pass-123", **kw)
    if cl:
        p.cleanup("cluster", lambda: rds.delete_db_cluster(DBClusterIdentifier=cid, SkipFinalSnapshot=True))
        c = cl["DBCluster"]
        p.behavior("Aurora 클러스터 엔드포인트(쓰기)·리더 엔드포인트", bool(c.get("Endpoint")) and bool(c.get("ReaderEndpoint")),
                   f"{c.get('Endpoint')} / {c.get('ReaderEndpoint')}")
        ci = p.call("CreateDBInstance(Aurora 클러스터 인스턴스)", rds.create_db_instance, DBInstanceIdentifier=p.name("aurora-1"),
                    DBClusterIdentifier=cid, Engine="aurora-postgresql", DBInstanceClass="db.r6g.large")
        if ci:
            p.cleanup("ci", lambda: rds.delete_db_instance(DBInstanceIdentifier=p.name("aurora-1"), SkipFinalSnapshot=True))
            m = rds.describe_db_clusters(DBClusterIdentifier=cid)["DBClusters"][0].get("DBClusterMembers", [])
            p.behavior("클러스터 멤버(쓰기 인스턴스)로 조회됨", any(x.get("IsClusterWriter") for x in m), str(m)[:120])
    p.call("CreateDBProxy", rds.create_db_proxy, DBProxyName=p.name("proxy")[:60], EngineFamily="POSTGRESQL",
           Auth=[{"AuthScheme": "SECRETS", "SecretArn": "arn:aws:secretsmanager:us-east-1:000000000000:secret:x", "IAMAuth": "DISABLED"}],
           RoleArn="arn:aws:iam::000000000000:role/proxy", VpcSubnetIds=subs or ["subnet-1", "subnet-2"])
    p.cleanup("proxy", lambda: rds.delete_db_proxy(DBProxyName=p.name("proxy")[:60]))


def run_dynamodb(p: Probe) -> None:
    ddb = p.client("dynamodb")
    # M00 실습: 테이블 이름 2글자
    try:
        ddb.create_table(TableName="ab", AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                         KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}], BillingMode="PAY_PER_REQUEST")
        ddb.delete_table(TableName="ab")
        p.behavior("테이블 이름 2글자 → ValidationException", False, "성공했다")
    except ClientError as e:
        err = e.response["Error"]
        p.behavior("테이블 이름 2글자 → ValidationException", err["Code"] == "ValidationException",
                   f"HTTP {e.response['ResponseMetadata']['HTTPStatusCode']} {err['Code']}: {err['Message']}")
    t = p.name("orders")
    ct = p.call("CreateTable(PK/SK, 온디맨드, Streams)", ddb.create_table, TableName=t,
                AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
                KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
                BillingMode="PAY_PER_REQUEST",
                StreamSpecification={"StreamEnabled": True, "StreamViewType": "NEW_AND_OLD_IMAGES"})
    if not ct:
        return
    p.cleanup("t", lambda: ddb.delete_table(TableName=t))
    ok = wait_until(lambda: ddb.describe_table(TableName=t)["Table"]["TableStatus"] == "ACTIVE", 15)
    p.behavior("테이블 CREATING→ACTIVE", ok, f"생성 직후 {ct['TableDescription']['TableStatus']}")
    p.call("DescribeTable", ddb.describe_table, TableName=t)
    for i in range(5):
        ddb.put_item(TableName=t, Item={"pk": {"S": "USER#1"}, "sk": {"S": f"ORDER#{i:03d}"},
                                         "status": {"S": "PAID" if i % 2 else "NEW"}, "amount": {"N": str(1000 * i)}})
    ddb.put_item(TableName=t, Item={"pk": {"S": "USER#2"}, "sk": {"S": "ORDER#000"}, "status": {"S": "NEW"}})
    p.call("PutItem", ddb.put_item, TableName=t, Item={"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}, "stock": {"N": "3"}})
    g = p.call("GetItem(ConsistentRead)", ddb.get_item, TableName=t, Key={"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}},
               ConsistentRead=True)
    if g:
        p.behavior("GetItem 왕복", g.get("Item", {}).get("stock", {}).get("N") == "3", "")
    q = p.call("Query(pk=USER#1, begins_with sk)", ddb.query, TableName=t,
               KeyConditionExpression="pk = :p AND begins_with(sk, :s)",
               ExpressionAttributeValues={":p": {"S": "USER#1"}, ":s": {"S": "ORDER#"}}, ReturnConsumedCapacity="TOTAL")
    s = p.call("Scan(전체)", ddb.scan, TableName=t, ReturnConsumedCapacity="TOTAL")
    if q and s:
        p.behavior("Query는 파티션만, Scan은 전체를 읽음(Count/ScannedCount)", q["Count"] == 5 and s["ScannedCount"] == 7,
                   f"Query Count={q['Count']} ScannedCount={q['ScannedCount']} CU={q.get('ConsumedCapacity', {}).get('CapacityUnits')}; "
                   f"Scan ScannedCount={s['ScannedCount']} CU={s.get('ConsumedCapacity', {}).get('CapacityUnits')}")
    f = p.call("Scan(FilterExpression)", ddb.scan, TableName=t, FilterExpression="#s = :v",
               ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":v": {"S": "PAID"}})
    if f:
        p.behavior("FilterExpression은 읽은 뒤 거른다(ScannedCount > Count)", f["ScannedCount"] > f["Count"],
                   f"Count={f['Count']} ScannedCount={f['ScannedCount']}")
    pg = ddb.get_paginator("query").paginate(TableName=t, KeyConditionExpression="pk = :p",
                                              ExpressionAttributeValues={":p": {"S": "USER#1"}}, Limit=2)
    pages = [len(x["Items"]) for x in pg]
    p.behavior("Limit=2 페이지네이션(LastEvaluatedKey)", pages == [2, 2, 1] or pages == [2, 2, 1, 0], str(pages))

    # 조건부 쓰기: 재고 차감
    def _dec(q_: int) -> dict[str, Any]:
        return ddb.update_item(TableName=t, Key={"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}},
                               UpdateExpression="SET stock = stock - :q", ConditionExpression="stock >= :q",
                               ExpressionAttributeValues={":q": {"N": str(q_)}}, ReturnValues="UPDATED_NEW")
    r = p.call("UpdateItem(조건부 재고 차감 2)", _dec, 2)
    if r:
        p.behavior("재고 3 → 1", r["Attributes"]["stock"]["N"] == "1", r["Attributes"]["stock"]["N"])
    p.expect_error("UpdateItem(재고 부족)", lambda: _dec(2), "ConditionalCheckFailedException",
                   what="재고 1에서 2 차감 → ConditionalCheckFailedException")
    p.expect_error("PutItem(attribute_not_exists)", ddb.put_item, "ConditionalCheckFailedException", TableName=t,
                   Item={"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}}, ConditionExpression="attribute_not_exists(pk)",
                   what="이미 있는 키에 attribute_not_exists → ConditionalCheckFailedException")

    # GSI
    u = p.call("UpdateTable(GSI 추가: status-index)", ddb.update_table, TableName=t,
               AttributeDefinitions=[{"AttributeName": "status", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
               GlobalSecondaryIndexUpdates=[{"Create": {"IndexName": "status-index", "KeySchema": [
                   {"AttributeName": "status", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
                   "Projection": {"ProjectionType": "ALL"}}}])
    if u:
        ok = wait_until(lambda: all(gi["IndexStatus"] == "ACTIVE" for gi in
                                    ddb.describe_table(TableName=t)["Table"].get("GlobalSecondaryIndexes", [])), 20)
        p.behavior("GSI CREATING→ACTIVE(백필)", ok, str([gi["IndexStatus"] for gi in
                                                       ddb.describe_table(TableName=t)["Table"].get("GlobalSecondaryIndexes", [])]))
        gq = p.call("Query(GSI status=PAID)", ddb.query, TableName=t, IndexName="status-index",
                    KeyConditionExpression="#s = :v", ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":v": {"S": "PAID"}})
        if gq:
            p.behavior("GSI 쿼리가 기존 항목까지 반환(백필)", gq["Count"] == 2, f"Count={gq['Count']}")
        p.expect_error("Query(GSI, ConsistentRead=True)", ddb.query, "ValidationException", TableName=t, IndexName="status-index",
                       KeyConditionExpression="#s = :v", ExpressionAttributeNames={"#s": "status"},
                       ExpressionAttributeValues={":v": {"S": "PAID"}}, ConsistentRead=True,
                       what="GSI 강력 일관 읽기 → ValidationException")

    # TTL
    if p.call("UpdateTimeToLive", ddb.update_time_to_live, TableName=t,
              TimeToLiveSpecification={"Enabled": True, "AttributeName": "expires_at"}) is not None:
        d = p.call("DescribeTimeToLive", ddb.describe_time_to_live, TableName=t)
        if d:
            p.behavior("TTL 상태 ENABLED(또는 ENABLING)", d["TimeToLiveDescription"].get("TimeToLiveStatus") in ("ENABLED", "ENABLING"),
                       str(d["TimeToLiveDescription"]))
        ddb.put_item(TableName=t, Item={"pk": {"S": "SESSION#1"}, "sk": {"S": "S"}, "expires_at": {"N": str(int(time.time()) - 3600)}})
        gone = wait_until(lambda: "Item" not in ddb.get_item(TableName=t, Key={"pk": {"S": "SESSION#1"}, "sk": {"S": "S"}}), 5)
        p.behavior("만료 시각이 지난 항목이 5초 안에 삭제됨(AWS는 보통 수일 내, 즉시 아님)", gone,
                   "삭제됨" if gone else "남아 있음 — AWS도 즉시 지우지 않으므로 정상 범위")

    # Streams
    desc = ddb.describe_table(TableName=t)["Table"]
    arn = desc.get("LatestStreamArn")
    p.behavior("Streams 켜면 LatestStreamArn 발급", bool(arn), str(arn)[-40:])
    if arn:
        st = p.client("dynamodbstreams")
        ds = p.call("DescribeStream", st.describe_stream, StreamArn=arn)
        if ds and ds["StreamDescription"].get("Shards"):
            recs: list[Any] = []
            for sh in ds["StreamDescription"]["Shards"]:
                it = p.call("GetShardIterator(TRIM_HORIZON)", st.get_shard_iterator, StreamArn=arn, ShardId=sh["ShardId"],
                            ShardIteratorType="TRIM_HORIZON")
                if it:
                    gr = p.call("GetRecords", st.get_records, ShardIterator=it["ShardIterator"])
                    if gr:
                        recs += gr["Records"]
            names = sorted({r["eventName"] for r in recs})
            p.behavior("스트림에 INSERT/MODIFY 레코드가 실제로 기록됨", "INSERT" in names and "MODIFY" in names,
                       f"{len(recs)}건 {names}")
            if recs:
                r0 = [r for r in recs if r["eventName"] == "MODIFY"]
                p.behavior("NEW_AND_OLD_IMAGES: MODIFY 레코드에 OldImage/NewImage", bool(r0) and "OldImage" in r0[0]["dynamodb"]
                           and "NewImage" in r0[0]["dynamodb"], "")
        elif ds:
            p.behavior("스트림 샤드 존재", False, "Shards 없음")

    # 트랜잭션
    tw = p.call("TransactWriteItems(주문 생성 + 재고 차감)", ddb.transact_write_items, TransactItems=[
        {"Put": {"TableName": t, "Item": {"pk": {"S": "USER#9"}, "sk": {"S": "ORDER#900"}, "status": {"S": "NEW"}},
                 "ConditionExpression": "attribute_not_exists(pk)"}},
        {"Update": {"TableName": t, "Key": {"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}},
                    "UpdateExpression": "SET stock = stock - :q", "ConditionExpression": "stock >= :q",
                    "ExpressionAttributeValues": {":q": {"N": "1"}}}}])
    if tw is not None:
        code = p.expect_error("TransactWriteItems(재고 부족)", ddb.transact_write_items, "TransactionCanceledException",
                              TransactItems=[
                                  {"Put": {"TableName": t, "Item": {"pk": {"S": "USER#9"}, "sk": {"S": "ORDER#901"}}}},
                                  {"Update": {"TableName": t, "Key": {"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}},
                                              "UpdateExpression": "SET stock = stock - :q", "ConditionExpression": "stock >= :q",
                                              "ExpressionAttributeValues": {":q": {"N": "5"}}}}],
                              what="조건 하나가 실패하면 트랜잭션 전체 취소 → TransactionCanceledException")
        if code:
            g = ddb.get_item(TableName=t, Key={"pk": {"S": "USER#9"}, "sk": {"S": "ORDER#901"}})
            p.behavior("취소된 트랜잭션의 다른 쓰기(주문 901)도 반영되지 않음(원자성)", "Item" not in g, "")
    p.call("TransactGetItems", ddb.transact_get_items, TransactItems=[
        {"Get": {"TableName": t, "Key": {"pk": {"S": "ITEM#apple"}, "sk": {"S": "STOCK"}}}}])
    p.call("BatchWriteItem(25개)", ddb.batch_write_item, RequestItems={t: [
        {"PutRequest": {"Item": {"pk": {"S": f"BATCH#{i}"}, "sk": {"S": "X"}}}} for i in range(25)]})
    p.expect_error("BatchWriteItem(26개)", ddb.batch_write_item, "ValidationException", RequestItems={t: [
        {"PutRequest": {"Item": {"pk": {"S": f"B2#{i}"}, "sk": {"S": "X"}}}} for i in range(26)]},
        what="BatchWriteItem 26개(한도 25) → ValidationException")
    p.call("BatchGetItem", ddb.batch_get_item, RequestItems={t: {"Keys": [{"pk": {"S": "BATCH#1"}, "sk": {"S": "X"}}]}})
    p.call("ExecuteStatement(PartiQL SELECT)", ddb.execute_statement,
           Statement=f'SELECT * FROM "{t}" WHERE pk = ?', Parameters=[{"S": "USER#1"}])

    # 용량 모드·백업
    t2 = p.name("prov")
    if p.call("CreateTable(PROVISIONED 5/5)", ddb.create_table, TableName=t2,
              AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
              KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}], BillingMode="PROVISIONED",
              ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}) is not None:
        p.cleanup("t2", lambda: ddb.delete_table(TableName=t2))
        wait_until(lambda: ddb.describe_table(TableName=t2)["Table"]["TableStatus"] == "ACTIVE", 15)
        p.call("UpdateTable(PROVISIONED → PAY_PER_REQUEST)", ddb.update_table, TableName=t2, BillingMode="PAY_PER_REQUEST")
        bm = ddb.describe_table(TableName=t2)["Table"].get("BillingModeSummary", {}).get("BillingMode")
        p.behavior("용량 모드 전환 반영", bm == "PAY_PER_REQUEST", str(bm))
    p.call("UpdateContinuousBackups(PITR)", ddb.update_continuous_backups, TableName=t,
           PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True})
    cb = p.call("DescribeContinuousBackups", ddb.describe_continuous_backups, TableName=t)
    if cb:
        p.behavior("PITR ENABLED", cb["ContinuousBackupsDescription"].get("PointInTimeRecoveryDescription", {})
                   .get("PointInTimeRecoveryStatus") == "ENABLED", "")
    bk = p.call("CreateBackup", ddb.create_backup, TableName=t, BackupName=p.name("bk"))
    if bk:
        barn = bk["BackupDetails"]["BackupArn"]
        p.cleanup("bk", lambda: ddb.delete_backup(BackupArn=barn))
        ok = wait_until(lambda: ddb.describe_backup(BackupArn=barn)["BackupDescription"]["BackupDetails"]["BackupStatus"] == "AVAILABLE", 20)
        p.behavior("백업 CREATING→AVAILABLE", ok, f"생성 직후 {bk['BackupDetails']['BackupStatus']}")
        rt = p.call("RestoreTableFromBackup", ddb.restore_table_from_backup, TargetTableName=p.name("restored"), BackupArn=barn)
        if rt:
            p.cleanup("rt", lambda: ddb.delete_table(TableName=p.name("restored")))
            wait_until(lambda: ddb.describe_table(TableName=p.name("restored"))["Table"]["TableStatus"] == "ACTIVE", 15)
            n = ddb.scan(TableName=p.name("restored"), Select="COUNT")["Count"]
            p.behavior("백업에서 복원한 테이블에 데이터가 있음", n > 0, f"Count={n}")
    p.call("ExportTableToPointInTime", ddb.export_table_to_point_in_time,
           TableArn=desc["TableArn"], S3Bucket=p.name("export"), ExportFormat="DYNAMODB_JSON")
    p.call("UpdateTable(글로벌 테이블 복제본 us-west-2)", ddb.update_table, TableName=t,
           ReplicaUpdates=[{"Create": {"RegionName": "us-west-2"}}])


def run_elasticache(p: Probe) -> None:
    ec = p.client("elasticache")
    subs = _vpc_subnets(p, 50)
    sng = p.name("csg")
    if subs and p.call("CreateCacheSubnetGroup", ec.create_cache_subnet_group, CacheSubnetGroupName=sng,
                       CacheSubnetGroupDescription="probe", SubnetIds=subs) is not None:
        p.cleanup("sng", lambda: ec.delete_cache_subnet_group(CacheSubnetGroupName=sng))
    kw: dict[str, Any] = {"CacheSubnetGroupName": sng} if subs else {}
    rgid = f"to-rg-{p.suffix}"
    rg = p.call("CreateReplicationGroup(valkey, 복제본 1, Multi-AZ)", ec.create_replication_group, ReplicationGroupId=rgid,
                ReplicationGroupDescription="probe", Engine="valkey", CacheNodeType="cache.t3.micro",
                NumCacheClusters=2, AutomaticFailoverEnabled=True, MultiAZEnabled=True, **kw)
    if rg is None:
        rg = p.call("CreateReplicationGroup(redis)", ec.create_replication_group, ReplicationGroupId=rgid,
                    ReplicationGroupDescription="probe", Engine="redis", CacheNodeType="cache.t3.micro",
                    NumCacheClusters=2, AutomaticFailoverEnabled=True, **kw)
    if rg:
        p.cleanup("rg", lambda: ec.delete_replication_group(ReplicationGroupId=rgid))
        seen = [rg["ReplicationGroup"]["Status"]]

        def _avail() -> bool:
            s = ec.describe_replication_groups(ReplicationGroupId=rgid)["ReplicationGroups"][0]["Status"]
            if s != seen[-1]:
                seen.append(s)
            return s == "available"
        ok = wait_until(_avail, 30, 1)
        p.behavior("복제 그룹 creating→available", ok, " → ".join(seen))
        d = ec.describe_replication_groups(ReplicationGroupId=rgid)["ReplicationGroups"][0]
        ng = (d.get("NodeGroups") or [{}])[0]
        pe = ng.get("PrimaryEndpoint") or {}
        p.behavior("기본(쓰기)·리더 엔드포인트 반환", bool(pe.get("Address")),
                   f"Primary={pe.get('Address')}:{pe.get('Port')} Reader={(ng.get('ReaderEndpoint') or {}).get('Address')} "
                   f"members={len(ng.get('NodeGroupMembers', []))}")
        if pe.get("Address") and pe.get("Port"):
            inside = _tcp_from_container(pe["Address"], int(pe["Port"]))
            p.behavior("엔드포인트 포트에 실제 캐시 서버가 떠 있음(컨테이너 안 TCP)", inside == "OPEN", f"컨테이너 안: {inside}")
        p.call("TestFailover", ec.test_failover, ReplicationGroupId=rgid, NodeGroupId=ng.get("NodeGroupId", "0001"))
    cc = p.call("CreateCacheCluster(memcached 2노드)", ec.create_cache_cluster, CacheClusterId=f"to-mc-{p.suffix}",
                Engine="memcached", CacheNodeType="cache.t3.micro", NumCacheNodes=2, **kw)
    if cc:
        p.cleanup("cc", lambda: ec.delete_cache_cluster(CacheClusterId=f"to-mc-{p.suffix}"))
        ok = wait_until(lambda: ec.describe_cache_clusters(CacheClusterId=f"to-mc-{p.suffix}")["CacheClusters"][0]
                        ["CacheClusterStatus"] == "available", 30, 1)
        d = ec.describe_cache_clusters(CacheClusterId=f"to-mc-{p.suffix}", ShowCacheNodeInfo=True)["CacheClusters"][0]
        p.behavior("Memcached 클러스터 available + 구성 엔드포인트", ok and bool(d.get("ConfigurationEndpoint")),
                   f"{d['CacheClusterStatus']} {d.get('ConfigurationEndpoint')}")
    p.call("CreateServerlessCache(valkey)", ec.create_serverless_cache, ServerlessCacheName=f"to-sl-{p.suffix}", Engine="valkey")
    p.cleanup("sl", lambda: ec.delete_serverless_cache(ServerlessCacheName=f"to-sl-{p.suffix}"))


def run_db_gaps(p: Probe) -> None:
    """M05 모듈 저자가 찾은 501·동작 차이를 재현한다. 501 오퍼레이션은 존재하지 않는 ID로도 501을 돌려준다."""
    rds, ec, dax, ddb = p.client("rds"), p.client("elasticache"), p.client("dax"), p.client("dynamodb")
    p.call("RestoreDBInstanceToPointInTime", rds.restore_db_instance_to_point_in_time,
           SourceDBInstanceIdentifier=p.name("nodb"), TargetDBInstanceIdentifier=p.name("nodb-r"), UseLatestRestorableTime=True)
    p.call("PromoteReadReplica", rds.promote_read_replica, DBInstanceIdentifier=p.name("nodb"))
    p.call("CreateDBClusterEndpoint", rds.create_db_cluster_endpoint, DBClusterIdentifier=p.name("nocl"),
           DBClusterEndpointIdentifier=p.name("ep"), EndpointType="READER")
    p.call("DescribeDBInstanceAutomatedBackups", rds.describe_db_instance_automated_backups)
    p.call("DeleteReplicationGroup", ec.delete_replication_group, ReplicationGroupId=p.name("norg"))

    subs = _vpc_subnets(p, 45)
    if subs:
        try:
            dax.create_subnet_group(SubnetGroupName=p.name("daxsng"), SubnetIds=subs)
            p.behavior("DAX CreateSubnetGroup(유효한 서브넷) 이 성공", True, "성공")
            p.cleanup("daxsng", lambda: dax.delete_subnet_group(SubnetGroupName=p.name("daxsng")))
        except ClientError as e:
            err = e.response["Error"]
            p.behavior("DAX CreateSubnetGroup(유효한 서브넷) 이 성공", False,
                       f"{err.get('Code')}: {err.get('Message', '')[:120]}")

    # DynamoDB PITR
    t = p.name("pitr")
    ddb.create_table(TableName=t, BillingMode="PAY_PER_REQUEST",
                     AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                     KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])
    p.cleanup("pitr", lambda: ddb.delete_table(TableName=t))
    ddb.get_waiter("table_exists").wait(TableName=t, WaiterConfig={"Delay": 1, "MaxAttempts": 30})
    p.call("UpdateContinuousBackups(PITR on)", ddb.update_continuous_backups, TableName=t,
           PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True})

    def _latest() -> Any:
        return ddb.describe_continuous_backups(TableName=t)["ContinuousBackupsDescription"][
            "PointInTimeRecoveryDescription"].get("LatestRestorableDateTime")

    l0 = _latest()
    ddb.put_item(TableName=t, Item={"pk": {"S": "o1"}, "v": {"S": "v1"}})
    time.sleep(2)
    import datetime as _dt
    between = _dt.datetime.now(_dt.timezone.utc)
    time.sleep(2)
    ddb.put_item(TableName=t, Item={"pk": {"S": "o1"}, "v": {"S": "v2"}})
    time.sleep(2)
    l1 = _latest()
    p.behavior("PITR LatestRestorableDateTime 이 시간이 지나면 앞으로 감", l0 is not None and l1 is not None and l1 > l0,
               f"PITR 켠 직후 {l0} → 6초 뒤 {l1}")

    def _restore_value(label: str, **kw: Any) -> str:
        tgt = p.name(f"pitr-{label}")
        try:
            ddb.restore_table_to_point_in_time(SourceTableName=t, TargetTableName=tgt, **kw)
        except ClientError as e:
            return f"오류 {e.response['Error']['Code']}: {e.response['Error'].get('Message', '')[:80]}"
        p.cleanup(f"r-{label}", lambda: ddb.delete_table(TableName=tgt))
        try:
            ddb.get_waiter("table_exists").wait(TableName=tgt, WaiterConfig={"Delay": 1, "MaxAttempts": 30})
            it = ddb.get_item(TableName=tgt, Key={"pk": {"S": "o1"}}, ConsistentRead=True).get("Item")
            return it["v"]["S"] if it else "(항목 없음)"
        except Exception as e:  # noqa: BLE001
            return f"{type(e).__name__}"

    v_latest = _restore_value("latest", UseLatestRestorableTime=True)
    p.behavior("PITR UseLatestRestorableTime 복원 → 최신 데이터(v2)", v_latest == "v2", f"복원된 값 {v_latest}")
    v_between = _restore_value("between", RestoreDateTime=between)
    p.behavior("PITR RestoreDateTime(v1과 v2 사이) 복원 → 그 시점 데이터(v1)", v_between == "v1", f"복원 결과 {v_between}")


CHECKS = {
    "rds": run_rds,
    "dynamodb": run_dynamodb,
    "elasticache": run_elasticache,
    "db-gaps": run_db_gaps,
}
