"""M10~M13: CloudWatch / Logs / CloudFormation / Glue / Athena / Backup / DMS / Budgets / 태그 API
그리고 시험 범위의 기타 서비스 존재 확인(misc-optional)."""

from __future__ import annotations

import datetime as dt
import json
import time

import boto3

from lib import _CFG, Probe, wait_until


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _sns_to_sqs(p: Probe, tag: str) -> tuple[str, str]:
    """SNS 토픽 + 구독한 SQS 큐를 만들고 (topic_arn, queue_url) 반환."""
    sns, sqs = p.client("sns"), p.client("sqs")
    topic = sns.create_topic(Name=p.name(tag))["TopicArn"]
    q = sqs.create_queue(QueueName=p.name(tag + "q"))["QueueUrl"]
    qarn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    sqs.set_queue_attributes(QueueUrl=q, Attributes={"Policy": json.dumps({"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow", "Principal": {"Service": "sns.amazonaws.com"}, "Action": "sqs:SendMessage", "Resource": qarn,
        "Condition": {"ArnEquals": {"aws:SourceArn": topic}}}]})})
    sns.subscribe(TopicArn=topic, Protocol="sqs", Endpoint=qarn, Attributes={"RawMessageDelivery": "true"})
    p.cleanup("topic", lambda: sns.delete_topic(TopicArn=topic))
    p.cleanup("queue", lambda: sqs.delete_queue(QueueUrl=q))
    return topic, q


def _drain(p: Probe, q: str, timeout: float = 10) -> list[str]:
    sqs = p.client("sqs")
    got: list[str] = []
    end = time.monotonic() + timeout
    while time.monotonic() < end and not got:
        r = sqs.receive_message(QueueUrl=q, MaxNumberOfMessages=10, WaitTimeSeconds=1)
        for m in r.get("Messages", []):
            got.append(m["Body"])
            sqs.delete_message(QueueUrl=q, ReceiptHandle=m["ReceiptHandle"])
    return got


def run_cloudwatch(p: Probe) -> None:
    cw = p.client("cloudwatch")
    ns = f"TodayOrder/Probe{p.suffix}"
    dims = [{"Name": "Service", "Value": "order-api"}]
    p.call("PutMetricData(사용자 지정 네임스페이스·차원)", cw.put_metric_data, Namespace=ns, MetricData=[
        {"MetricName": "OrderLatency", "Dimensions": dims, "Value": v, "Unit": "Milliseconds"} for v in (100, 200, 300)])
    lm = p.call("ListMetrics(네임스페이스)", cw.list_metrics, Namespace=ns)
    if lm is not None:
        p.behavior("게시한 지표가 ListMetrics에 보임", len(lm["Metrics"]) == 1, f"{len(lm['Metrics'])}개")
    st = p.call("GetMetricStatistics", cw.get_metric_statistics, Namespace=ns, MetricName="OrderLatency", Dimensions=dims,
                StartTime=_now() - dt.timedelta(minutes=10), EndTime=_now() + dt.timedelta(minutes=1), Period=60,
                Statistics=["Average", "SampleCount", "Maximum"])
    if st:
        dp = st["Datapoints"]
        p.behavior("데이터 포인트 집계(평균 200, 표본 3, 최댓값 300)",
                   bool(dp) and dp[0].get("SampleCount") == 3 and dp[0].get("Average") == 200 and dp[0].get("Maximum") == 300,
                   str(dp)[:150])
    md = p.call("GetMetricData", cw.get_metric_data, StartTime=_now() - dt.timedelta(minutes=10),
                EndTime=_now() + dt.timedelta(minutes=1), MetricDataQueries=[{
                    "Id": "m1", "MetricStat": {"Metric": {"Namespace": ns, "MetricName": "OrderLatency", "Dimensions": dims},
                                               "Period": 60, "Stat": "Sum"}}])
    if md:
        vals = md["MetricDataResults"][0].get("Values", [])
        p.behavior("GetMetricData 합계 600", vals[:1] == [600.0], str(vals))
    ec2m = p.call("ListMetrics(AWS/EC2)", cw.list_metrics, Namespace="AWS/EC2")
    if ec2m is not None:
        p.behavior("기본 EC2 지표(AWS/EC2)가 저절로 생김", len(ec2m["Metrics"]) > 0,
                   f"{len(ec2m['Metrics'])}개 — 인스턴스가 실제로 돌지 않으므로 없을 수 있음")

    topic, q = _sns_to_sqs(p, "alarm")
    alarm = p.name("latency-high")
    a = p.call("PutMetricAlarm(SNS 액션)", cw.put_metric_alarm, AlarmName=alarm, Namespace=ns, MetricName="OrderLatency",
               Dimensions=dims, Statistic="Average", Period=10, EvaluationPeriods=1, Threshold=1000,
               ComparisonOperator="GreaterThanThreshold", AlarmActions=[topic], OKActions=[topic],
               TreatMissingData="notBreaching")
    if a is None:
        p.skip("알람 동작", "알람 생성 실패")
    else:
        p.cleanup("alarm", lambda: cw.delete_alarms(AlarmNames=[alarm]))
        st0 = cw.describe_alarms(AlarmNames=[alarm])["MetricAlarms"][0]["StateValue"]
        cw.put_metric_data(Namespace=ns, MetricData=[{"MetricName": "OrderLatency", "Dimensions": dims, "Value": 5000}])
        auto = wait_until(lambda: cw.describe_alarms(AlarmNames=[alarm])["MetricAlarms"][0]["StateValue"] == "ALARM", 25, 1)
        p.behavior("임계값 초과 데이터만으로 알람이 스스로 ALARM이 됨(25초 대기, Period=10)", auto,
                   f"처음 {st0} → {cw.describe_alarms(AlarmNames=[alarm])['MetricAlarms'][0]['StateValue']}")
        auto_msgs = _drain(p, q, 3)
        if not auto:
            p.call("SetAlarmState(ALARM)", cw.set_alarm_state, AlarmName=alarm, StateValue="ALARM", StateReason="probe")
            s = cw.describe_alarms(AlarmNames=[alarm])["MetricAlarms"][0]["StateValue"]
            p.behavior("SetAlarmState 후 DescribeAlarms가 ALARM", s == "ALARM", s)
        h = p.call("DescribeAlarmHistory", cw.describe_alarm_history, AlarmName=alarm, HistoryItemType="StateUpdate")
        if h:
            p.behavior("알람 상태 변경 이력이 기록됨", len(h["AlarmHistoryItems"]) > 0, f"{len(h['AlarmHistoryItems'])}건")
        msgs = auto_msgs + _drain(p, q, 10)
        p.behavior("알람 액션: SNS → 구독한 SQS 큐로 알림 도착", any(alarm in m for m in msgs),
                   f"{len(msgs)}건 {msgs[0][:100] if msgs else ''}")
        comp = p.name("composite")
        if p.call("PutCompositeAlarm", cw.put_composite_alarm, AlarmName=comp,
                  AlarmRule=f'ALARM("{alarm}")', AlarmActions=[topic]) is not None:
            p.cleanup("comp", lambda: cw.delete_alarms(AlarmNames=[comp]))
            ok = wait_until(lambda: cw.describe_alarms(AlarmNames=[comp], AlarmTypes=["CompositeAlarm"])
                            ["CompositeAlarms"][0]["StateValue"] == "ALARM", 15, 1)
            p.behavior("복합 알람이 하위 알람 상태를 따라 ALARM", ok,
                       cw.describe_alarms(AlarmNames=[comp], AlarmTypes=["CompositeAlarm"])["CompositeAlarms"][0]["StateValue"])
    dash = p.name("dash")
    if p.call("PutDashboard", cw.put_dashboard, DashboardName=dash, DashboardBody=json.dumps({"widgets": [{
            "type": "metric", "x": 0, "y": 0, "width": 6, "height": 6,
            "properties": {"metrics": [[ns, "OrderLatency", "Service", "order-api"]], "region": "us-east-1"}}]})) is not None:
        p.cleanup("dash", lambda: cw.delete_dashboards(DashboardNames=[dash]))


def run_logs(p: Probe) -> None:
    logs, cw = p.client("logs"), p.client("cloudwatch")
    g = f"/todayorder/probe/{p.suffix}"
    if p.call("CreateLogGroup", logs.create_log_group, logGroupName=g) is None:
        p.skip("Logs", "로그 그룹 생성 실패")
        return
    p.cleanup("lg", lambda: logs.delete_log_group(logGroupName=g))
    p.call("PutRetentionPolicy(7일)", logs.put_retention_policy, logGroupName=g, retentionInDays=7)
    p.expect_error("PutRetentionPolicy(8일)", logs.put_retention_policy, "InvalidParameterException",
                   logGroupName=g, retentionInDays=8, what="허용되지 않은 보존 기간(8일)은 거부")
    ns = f"TodayOrder/Logs{p.suffix}"
    p.call("PutMetricFilter(ERROR 개수)", logs.put_metric_filter, logGroupName=g, filterName="errors", filterPattern="ERROR",
           metricTransformations=[{"metricName": "ErrorCount", "metricNamespace": ns, "metricValue": "1"}])
    p.call("CreateLogStream", logs.create_log_stream, logGroupName=g, logStreamName="api-1")
    ts = int(time.time() * 1000)
    events = [{"timestamp": ts + i, "message": m} for i, m in enumerate(
        ["INFO order created id=1", "ERROR payment failed id=2", "INFO order created id=3", "ERROR timeout id=4"])]
    p.call("PutLogEvents", logs.put_log_events, logGroupName=g, logStreamName="api-1", logEvents=events)
    ge = p.call("GetLogEvents", logs.get_log_events, logGroupName=g, logStreamName="api-1", startFromHead=True)
    if ge:
        p.behavior("GetLogEvents로 4건 조회", len(ge["events"]) == 4, f"{len(ge['events'])}건")
    fe = p.call("FilterLogEvents(패턴 ERROR)", logs.filter_log_events, logGroupName=g, filterPattern="ERROR")
    if fe:
        p.behavior("FilterLogEvents가 패턴으로 2건만 반환", len(fe["events"]) == 2, f"{len(fe['events'])}건")
    fe2 = logs.filter_log_events(logGroupName=g, filterPattern='"payment failed"') if fe else None
    if fe2 is not None:
        p.behavior("FilterLogEvents 구문 패턴(\"payment failed\") 1건", len(fe2["events"]) == 1, f"{len(fe2['events'])}건")
    ok = wait_until(lambda: any(d.get("Sum") == 2.0 for d in cw.get_metric_statistics(
        Namespace=ns, MetricName="ErrorCount", StartTime=_now() - dt.timedelta(minutes=10),
        EndTime=_now() + dt.timedelta(minutes=1), Period=300, Statistics=["Sum"])["Datapoints"]), 15, 1)
    p.behavior("지표 필터: ERROR 로그 2건 → CloudWatch 지표 ErrorCount 합계 2", ok,
               str(cw.get_metric_statistics(Namespace=ns, MetricName="ErrorCount", StartTime=_now() - dt.timedelta(minutes=10),
                                            EndTime=_now() + dt.timedelta(minutes=1), Period=300,
                                            Statistics=["Sum"])["Datapoints"])[:120])
    # 구독 필터 → Kinesis
    kin = p.client("kinesis")
    stream = p.name("logsub")
    try:
        kin.create_stream(StreamName=stream, ShardCount=1)
        p.cleanup("ks", lambda: kin.delete_stream(StreamName=stream, EnforceConsumerDeletion=True))
        wait_until(lambda: kin.describe_stream_summary(StreamName=stream)["StreamDescriptionSummary"]["StreamStatus"] == "ACTIVE", 15)
        sarn = kin.describe_stream_summary(StreamName=stream)["StreamDescriptionSummary"]["StreamARN"]
        p.call("PutSubscriptionFilter(→ Kinesis)", logs.put_subscription_filter, logGroupName=g, filterName="to-kinesis",
               filterPattern="ERROR", destinationArn=sarn, roleArn="arn:aws:iam::000000000000:role/todayorder-cwl-to-kinesis")
    except Exception as e:  # noqa: BLE001
        p.skip("PutSubscriptionFilter", f"Kinesis 준비 실패: {e}")
    q = p.call("StartQuery(Logs Insights)", logs.start_query, logGroupName=g, startTime=int(time.time()) - 600,
               endTime=int(time.time()) + 60, queryString="fields @message | filter @message like /ERROR/ | stats count() as n")
    if q:
        qid = q["queryId"]
        done = wait_until(lambda: logs.get_query_results(queryId=qid)["status"] in ("Complete", "Failed", "Cancelled"), 15)
        r = logs.get_query_results(queryId=qid)
        p.behavior("Logs Insights 쿼리가 완료되고 결과 n=2", done and r["status"] == "Complete" and
                   any(f.get("value") == "2" for row in r.get("results", []) for f in row), f"status={r['status']} {r.get('results')}"[:150])


VPC_TEMPLATE = {
    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": "TodayOrder probe VPC",
    "Parameters": {"VpcCidr": {"Type": "String", "Default": "10.20.0.0/16"}},
    "Resources": {
        "Vpc": {"Type": "AWS::EC2::VPC", "Properties": {"CidrBlock": {"Ref": "VpcCidr"}, "EnableDnsHostnames": True,
                                                         "Tags": [{"Key": "Name", "Value": "todayorder-cfn"}]}},
        "PublicA": {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": {"Ref": "Vpc"}, "CidrBlock": "10.20.0.0/24",
                                                                "AvailabilityZone": "us-east-1a", "MapPublicIpOnLaunch": True}},
        "PublicB": {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": {"Ref": "Vpc"}, "CidrBlock": "10.20.1.0/24",
                                                                "AvailabilityZone": "us-east-1b"}},
        "Igw": {"Type": "AWS::EC2::InternetGateway"},
        "IgwAttach": {"Type": "AWS::EC2::VPCGatewayAttachment", "Properties": {"VpcId": {"Ref": "Vpc"},
                                                                                "InternetGatewayId": {"Ref": "Igw"}}},
        "PublicRt": {"Type": "AWS::EC2::RouteTable", "Properties": {"VpcId": {"Ref": "Vpc"}}},
        "DefaultRoute": {"Type": "AWS::EC2::Route", "DependsOn": "IgwAttach",
                         "Properties": {"RouteTableId": {"Ref": "PublicRt"}, "DestinationCidrBlock": "0.0.0.0/0",
                                        "GatewayId": {"Ref": "Igw"}}},
        "AssocA": {"Type": "AWS::EC2::SubnetRouteTableAssociation",
                   "Properties": {"SubnetId": {"Ref": "PublicA"}, "RouteTableId": {"Ref": "PublicRt"}}},
        "WebSg": {"Type": "AWS::EC2::SecurityGroup", "Properties": {
            "GroupDescription": "web", "VpcId": {"Ref": "Vpc"},
            "SecurityGroupIngress": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "CidrIp": "0.0.0.0/0"}]}},
    },
    "Outputs": {"VpcId": {"Value": {"Ref": "Vpc"}}, "PublicSubnetA": {"Value": {"Ref": "PublicA"}},
                "VpcCidrOut": {"Value": {"Fn::GetAtt": ["Vpc", "CidrBlock"]}}},
}


def _wait_stack(cfn, name: str, timeout: float = 30) -> str:  # noqa: ANN001
    terminal = ("_COMPLETE", "_FAILED")
    wait_until(lambda: cfn.describe_stacks(StackName=name)["Stacks"][0]["StackStatus"].endswith(terminal), timeout, 1)
    return cfn.describe_stacks(StackName=name)["Stacks"][0]["StackStatus"]


def run_cloudformation(p: Probe) -> None:
    cfn, ec2 = p.client("cloudformation"), p.client("ec2")
    body = json.dumps(VPC_TEMPLATE)
    v = p.call("ValidateTemplate", cfn.validate_template, TemplateBody=body)
    if v:
        p.behavior("ValidateTemplate가 파라미터를 읽음", [x["ParameterKey"] for x in v.get("Parameters", [])] == ["VpcCidr"])
    name = p.name("vpc")
    s = p.call("CreateStack(VPC 템플릿)", cfn.create_stack, StackName=name, TemplateBody=body)
    if not s:
        p.skip("CloudFormation 동작", "스택 생성 실패")
    else:
        p.cleanup("stack", lambda: cfn.delete_stack(StackName=name))
        status = _wait_stack(cfn, name)
        p.behavior("스택이 CREATE_COMPLETE에 도달", status == "CREATE_COMPLETE", status)
        res = {r["LogicalResourceId"]: r for r in cfn.describe_stack_resources(StackName=name)["StackResources"]}
        p.behavior("스택 리소스 9개 모두 CREATE_COMPLETE", len(res) == 9 and all(r["ResourceStatus"] == "CREATE_COMPLETE"
                                                                       for r in res.values()),
                   f"{len(res)}개 {sorted({r['ResourceStatus'] for r in res.values()})}")
        vpc_id = res.get("Vpc", {}).get("PhysicalResourceId", "")
        try:
            vp = ec2.describe_vpcs(VpcIds=[vpc_id])["Vpcs"]
            subs = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
            igws = ec2.describe_internet_gateways(Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}])["InternetGateways"]
            rts = ec2.describe_route_tables(RouteTableIds=[res["PublicRt"]["PhysicalResourceId"]])["RouteTables"]
            routes = [r.get("GatewayId") for r in rts[0]["Routes"]] if rts else []
            sgs = ec2.describe_security_groups(GroupIds=[res["WebSg"]["PhysicalResourceId"]])["SecurityGroups"]
            ok = (len(vp) == 1 and vp[0]["CidrBlock"] == "10.20.0.0/16" and len(subs) == 2 and len(igws) == 1
                  and res["Igw"]["PhysicalResourceId"] in routes and len(sgs) == 1)
            p.behavior("선언한 리소스가 EC2 API로 실제 조회됨(VPC·서브넷 2·IGW 연결·0.0.0.0/0 라우트·SG)", ok,
                       f"vpc={vpc_id} subnets={len(subs)} igw={len(igws)} routes={routes} sg={len(sgs)}")
        except Exception as e:  # noqa: BLE001
            p.behavior("선언한 리소스가 EC2 API로 실제 조회됨(VPC·서브넷 2·IGW 연결·0.0.0.0/0 라우트·SG)", False,
                       f"{type(e).__name__}: {str(e)[:150]}")
        outs = {o["OutputKey"]: o["OutputValue"] for o in cfn.describe_stacks(StackName=name)["Stacks"][0].get("Outputs", [])}
        p.behavior("Outputs(Ref, Fn::GetAtt) 값", outs.get("VpcId") == vpc_id and outs.get("VpcCidrOut") == "10.20.0.0/16",
                   str(outs))
        # 변경 세트
        t2 = json.loads(body)
        t2["Resources"]["PrivateA"] = {"Type": "AWS::EC2::Subnet", "Properties": {
            "VpcId": {"Ref": "Vpc"}, "CidrBlock": "10.20.10.0/24", "AvailabilityZone": "us-east-1a"}}
        cs = p.call("CreateChangeSet(서브넷 추가)", cfn.create_change_set, StackName=name, ChangeSetName="add-private",
                    TemplateBody=json.dumps(t2), ChangeSetType="UPDATE")
        if cs:
            wait_until(lambda: cfn.describe_change_set(StackName=name, ChangeSetName="add-private")["Status"]
                       in ("CREATE_COMPLETE", "FAILED"), 20, 1)
            d = p.call("DescribeChangeSet", cfn.describe_change_set, StackName=name, ChangeSetName="add-private")
            if d:
                ch = [(c["ResourceChange"]["Action"], c["ResourceChange"]["LogicalResourceId"]) for c in d.get("Changes", [])]
                p.behavior("변경 세트가 Add PrivateA 1건을 보여 줌", ch == [("Add", "PrivateA")], f"{d['Status']} {ch}")
            if p.call("ExecuteChangeSet", cfn.execute_change_set, StackName=name, ChangeSetName="add-private") is not None:
                st = _wait_stack(cfn, name)
                n = len(ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"])
                why = [f"{e['LogicalResourceId']}: {e.get('ResourceStatusReason', '')[:110]}"
                       for e in cfn.describe_stack_events(StackName=name)["StackEvents"]
                       if e["ResourceStatus"].endswith("FAILED")][:1]
                p.behavior("(VPC 스택) 변경 세트 실행 후 UPDATE_COMPLETE, 서브넷 3개", st == "UPDATE_COMPLETE" and n == 3,
                           f"{st}, 서브넷 {n} {why}")
        dr = p.call("DetectStackDrift", cfn.detect_stack_drift, StackName=name)
        if dr:
            did = dr["StackDriftDetectionId"]
            wait_until(lambda: cfn.describe_stack_drift_detection_status(StackDriftDetectionId=did)["DetectionStatus"]
                       != "DETECTION_IN_PROGRESS", 15)
            p.behavior("드리프트 감지 결과", True,
                       cfn.describe_stack_drift_detection_status(StackDriftDetectionId=did).get("StackDriftStatus", "?"))
        if p.call("DeleteStack", cfn.delete_stack, StackName=name) is not None:
            gone = wait_until(lambda: not ec2.describe_vpcs(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Vpcs"], 30, 1)
            p.behavior("DeleteStack 후 VPC가 실제로 삭제됨", gone)

    # 실패와 롤백
    bad = {"Resources": {"Ok": {"Type": "AWS::SQS::Queue"},
                         "Bad": {"Type": "AWS::EC2::Subnet", "Properties": {"VpcId": "vpc-doesnotexist", "CidrBlock": "10.0.0.0/24"}}}}
    bn = p.name("bad")
    if p.call("CreateStack(잘못된 참조)", cfn.create_stack, StackName=bn, TemplateBody=json.dumps(bad)) is not None:
        p.cleanup("bad", lambda: cfn.delete_stack(StackName=bn))
        st = _wait_stack(cfn, bn)
        p.behavior("실패한 스택은 ROLLBACK_COMPLETE (생성됐던 리소스는 롤백)", st == "ROLLBACK_COMPLETE", st)
    p.expect_error("CreateStack(존재하지 않는 리소스 유형)", cfn.create_stack, "ValidationError", StackName=p.name("badtype"),
                   TemplateBody=json.dumps({"Resources": {"X": {"Type": "AWS::Nope::Thing"}}}),
                   what="알 수 없는 리소스 유형은 ValidationError")

    # 앱 리소스
    app = {"Resources": {
        "Bucket": {"Type": "AWS::S3::Bucket", "Properties": {"VersioningConfiguration": {"Status": "Enabled"}}},
        "Queue": {"Type": "AWS::SQS::Queue", "Properties": {"VisibilityTimeout": 45}},
        "Table": {"Type": "AWS::DynamoDB::Table", "Properties": {
            "BillingMode": "PAY_PER_REQUEST", "AttributeDefinitions": [{"AttributeName": "pk", "AttributeType": "S"}],
            "KeySchema": [{"AttributeName": "pk", "KeyType": "HASH"}]}}},
        "Outputs": {"QueueUrl": {"Value": {"Ref": "Queue"}}, "BucketName": {"Value": {"Ref": "Bucket"}},
                    "TableName": {"Value": {"Ref": "Table"}}}}
    an = p.name("app")
    if p.call("CreateStack(S3+SQS+DynamoDB)", cfn.create_stack, StackName=an, TemplateBody=json.dumps(app)) is not None:
        p.cleanup("app", lambda: cfn.delete_stack(StackName=an))
        st = _wait_stack(cfn, an)
        outs = {o["OutputKey"]: o["OutputValue"] for o in cfn.describe_stacks(StackName=an)["Stacks"][0].get("Outputs", [])}
        try:
            ver = p.client("s3").get_bucket_versioning(Bucket=outs["BucketName"]).get("Status")
            vis = p.client("sqs").get_queue_attributes(QueueUrl=outs["QueueUrl"], AttributeNames=["VisibilityTimeout"])[
                "Attributes"]["VisibilityTimeout"]
            tbl = p.client("dynamodb").describe_table(TableName=outs["TableName"])["Table"]["TableStatus"]
            p.behavior("S3(버전 관리)·SQS(가시성 45)·DynamoDB가 속성까지 실제 생성", st == "CREATE_COMPLETE" and ver == "Enabled"
                       and vis == "45" and tbl == "ACTIVE", f"{st} versioning={ver} visibility={vis} table={tbl}")
        except Exception as e:  # noqa: BLE001
            p.behavior("S3(버전 관리)·SQS(가시성 45)·DynamoDB가 속성까지 실제 생성", False, f"{st} {type(e).__name__}: {str(e)[:120]}")
        # 단순 스택(앱 리소스)의 변경 세트: 큐 하나 추가
        app2 = json.loads(json.dumps(app))
        app2["Resources"]["Dlq"] = {"Type": "AWS::SQS::Queue", "Properties": {"MessageRetentionPeriod": 1209600}}
        if p.call("CreateChangeSet(앱 스택에 큐 추가)", cfn.create_change_set, StackName=an, ChangeSetName="add-dlq",
                  TemplateBody=json.dumps(app2), ChangeSetType="UPDATE") is not None:
            wait_until(lambda: cfn.describe_change_set(StackName=an, ChangeSetName="add-dlq")["Status"]
                       in ("CREATE_COMPLETE", "FAILED"), 20, 1)
            ch = [(c["ResourceChange"]["Action"], c["ResourceChange"]["LogicalResourceId"])
                  for c in cfn.describe_change_set(StackName=an, ChangeSetName="add-dlq").get("Changes", [])]
            cfn.execute_change_set(StackName=an, ChangeSetName="add-dlq")
            st2 = _wait_stack(cfn, an)
            p.behavior("(앱 스택) 변경 세트 Add Dlq → UPDATE_COMPLETE", st2 == "UPDATE_COMPLETE" and ch == [("Add", "Dlq")],
                       f"{ch} → {st2}")
    ssn = p.name("set")
    if p.call("CreateStackSet", cfn.create_stack_set, StackSetName=ssn, TemplateBody=json.dumps(
            {"Resources": {"Q": {"Type": "AWS::SQS::Queue"}}}), PermissionModel="SELF_MANAGED") is not None:
        p.cleanup("ss", lambda: cfn.delete_stack_set(StackSetName=ssn))
        p.call("CreateStackInstances(us-east-1, us-west-2)", cfn.create_stack_instances, StackSetName=ssn,
               Accounts=["000000000000"], Regions=["us-east-1", "us-west-2"])


def run_glue(p: Probe) -> None:
    glue, s3 = p.client("glue"), p.client("s3")
    bucket = p.name("lake")
    s3.create_bucket(Bucket=bucket)

    def _empty() -> None:
        for o in s3.list_objects_v2(Bucket=bucket).get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=o["Key"])
        s3.delete_bucket(Bucket=bucket)

    p.cleanup("bucket", _empty)
    for d in ("2026-11-01", "2026-11-02"):
        s3.put_object(Bucket=bucket, Key=f"orders/dt={d}/part-0.json",
                      Body=b'{"order_id":"1","amount":1000}\n{"order_id":"2","amount":2500}\n')
    db = p.name("db").replace("-", "_")
    if p.call("CreateDatabase", glue.create_database, DatabaseInput={"Name": db}) is None:
        p.skip("Glue", "DB 생성 실패")
        return
    p.cleanup("db", lambda: glue.delete_database(Name=db))
    p.call("CreateTable(파티션 dt, JSON, S3 위치)", glue.create_table, DatabaseName=db, TableInput={
        "Name": "orders", "TableType": "EXTERNAL_TABLE", "PartitionKeys": [{"Name": "dt", "Type": "string"}],
        "StorageDescriptor": {"Columns": [{"Name": "order_id", "Type": "string"}, {"Name": "amount", "Type": "bigint"}],
                              "Location": f"s3://{bucket}/orders/",
                              "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
                              "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
                              "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}}})
    t = p.call("GetTables", glue.get_tables, DatabaseName=db)
    if t:
        p.behavior("테이블 정의가 카탈로그에 보임", [x["Name"] for x in t["TableList"]] == ["orders"])
    p.call("BatchCreatePartition", glue.batch_create_partition, DatabaseName=db, TableName="orders", PartitionInputList=[
        {"Values": [d], "StorageDescriptor": {"Location": f"s3://{bucket}/orders/dt={d}/"}} for d in ("2026-11-01",)])
    gp = p.call("GetPartitions", glue.get_partitions, DatabaseName=db, TableName="orders")
    if gp is not None:
        p.behavior("파티션 1개 조회", len(gp["Partitions"]) == 1, f"{len(gp['Partitions'])}개")
    iam = p.client("iam")
    role = iam.create_role(RoleName=p.name("glue"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "glue.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("role", lambda: iam.delete_role(RoleName=role["RoleName"]))
    p.expect_error("CreateCrawler(존재하지 않는 역할)", glue.create_crawler, "InvalidInputException", Name=p.name("nocrawler"),
                   Role="arn:aws:iam::000000000000:role/does-not-exist", DatabaseName=db,
                   Targets={"S3Targets": [{"Path": f"s3://{bucket}/orders/"}]},
                   what="Glue가 역할의 신뢰 정책을 확인(없는 역할 거부)")
    crawler = p.name("crawler")
    if p.call("CreateCrawler", glue.create_crawler, Name=crawler, Role=role["Arn"],
              DatabaseName=db, Targets={"S3Targets": [{"Path": f"s3://{bucket}/orders/"}]}, TablePrefix="crawled_") is not None:
        p.cleanup("crawler", lambda: glue.delete_crawler(Name=crawler))
        if p.call("StartCrawler", glue.start_crawler, Name=crawler) is not None:
            done = wait_until(lambda: glue.get_crawler(Name=crawler)["Crawler"]["State"] == "READY"
                              and glue.get_crawler(Name=crawler)["Crawler"].get("LastCrawl") is not None, 30, 1)
            c = glue.get_crawler(Name=crawler)["Crawler"]
            tables = [x["Name"] for x in glue.get_tables(DatabaseName=db)["TableList"]]
            p.behavior("크롤러가 실제로 S3를 읽어 테이블(crawled_*)을 만듦", done and any(x.startswith("crawled_") for x in tables),
                       f"State={c['State']} LastCrawl={c.get('LastCrawl', {}).get('Status')} tables={tables}")
    job = p.name("etl")
    if p.call("CreateJob", glue.create_job, Name=job, Role=role["Arn"],
              Command={"Name": "glueetl", "ScriptLocation": f"s3://{bucket}/scripts/etl.py"}, GlueVersion="4.0") is not None:
        p.cleanup("job", lambda: glue.delete_job(JobName=job))
        p.call("StartJobRun", glue.start_job_run, JobName=job)
    p.call("ListJobs", glue.list_jobs)


def run_athena(p: Probe) -> None:
    ath, s3, glue = p.client("athena"), p.client("s3"), p.client("glue")
    bucket = p.name("athena")
    s3.create_bucket(Bucket=bucket)

    def _empty() -> None:
        for o in s3.list_objects_v2(Bucket=bucket).get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=o["Key"])
        s3.delete_bucket(Bucket=bucket)

    p.cleanup("bucket", _empty)
    wg = p.name("wg")
    if p.call("CreateWorkGroup(결과 위치)", ath.create_work_group, Name=wg, Configuration={
            "ResultConfiguration": {"OutputLocation": f"s3://{bucket}/results/"}, "EnforceWorkGroupConfiguration": True,
            "BytesScannedCutoffPerQuery": 10 * 1024 * 1024}) is None:
        p.skip("Athena", "작업 그룹 생성 실패")
        return
    p.cleanup("wg", lambda: ath.delete_work_group(WorkGroup=wg, RecursiveDeleteOption=True))

    def _run(sql: str, label: str, ctx: dict | None = None) -> tuple[str, dict | None]:
        kw = {"QueryString": sql, "WorkGroup": wg}
        if ctx:
            kw["QueryExecutionContext"] = ctx
        r = p.call(f"StartQueryExecution({label})", ath.start_query_execution, **kw)
        if not r:
            return "?", None
        qid = r["QueryExecutionId"]
        states: list[str] = []

        def _poll() -> bool:
            s = ath.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
            if not states or states[-1] != s:
                states.append(s)
            return s in ("SUCCEEDED", "FAILED", "CANCELLED")

        wait_until(_poll, 20, 0.3)
        st = ath.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        res = None
        if st["State"] == "SUCCEEDED":
            res = ath.get_query_results(QueryExecutionId=qid)
        return " → ".join(states) + (f" ({st.get('StateChangeReason', '')[:80]})" if st.get("StateChangeReason") else ""), res

    states, res = _run("SELECT 1 AS one", "SELECT 1")
    rows = [[c.get("VarCharValue") for c in r["Data"]] for r in res["ResultSet"]["Rows"]] if res else None
    p.behavior("SELECT 1이 실행되어 결과 반환", rows == [["one"], ["1"]], f"{states} rows={rows}")
    # Glue 테이블 위의 쿼리
    db = p.name("adb").replace("-", "_")
    s3.put_object(Bucket=bucket, Key="orders/dt=2026-11-01/p.json", Body=b'{"order_id":"1","amount":1000}\n{"order_id":"2","amount":2500}\n')
    try:
        glue.create_database(DatabaseInput={"Name": db})
        p.cleanup("db", lambda: glue.delete_database(Name=db))
        glue.create_table(DatabaseName=db, TableInput={
            "Name": "orders", "TableType": "EXTERNAL_TABLE",
            "StorageDescriptor": {"Columns": [{"Name": "order_id", "Type": "string"}, {"Name": "amount", "Type": "bigint"}],
                                  "Location": f"s3://{bucket}/orders/dt=2026-11-01/",
                                  "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
                                  "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
                                  "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}}})
        states, res = _run("SELECT sum(amount) AS total FROM orders", "Glue 테이블 집계", {"Database": db})
        rows = [[c.get("VarCharValue") for c in r["Data"]] for r in res["ResultSet"]["Rows"]] if res else None
        p.behavior("Glue 테이블(S3 JSON)에 SUM 쿼리 → 3500", rows == [["total"], ["3500"]], f"{states} rows={rows}")
        outs = s3.list_objects_v2(Bucket=bucket, Prefix="results/").get("KeyCount", 0)
        allk = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])]
        p.behavior("쿼리 결과 파일이 작업 그룹 결과 위치(S3)에 저장됨", outs > 0, f"results/ 아래 {outs}개, 버킷 전체 {allk[:4]}")
    except Exception as e:  # noqa: BLE001
        p.skip("Athena Glue 쿼리", f"{type(e).__name__}: {str(e)[:100]}")
    p.call("ListQueryExecutions", ath.list_query_executions, WorkGroup=wg)


def run_backup(p: Probe) -> None:
    bk, ddb = p.client("backup"), p.client("dynamodb")
    vault = p.name("vault")
    if p.call("CreateBackupVault", bk.create_backup_vault, BackupVaultName=vault) is None:
        p.skip("Backup", "볼트 생성 실패")
        return
    vault2 = p.name("vault-dr")
    bk.create_backup_vault(BackupVaultName=vault2)
    v2arn = bk.describe_backup_vault(BackupVaultName=vault2)["BackupVaultArn"]

    def _clean_vaults() -> None:
        for v in (vault, vault2):
            for rp in bk.list_recovery_points_by_backup_vault(BackupVaultName=v).get("RecoveryPoints", []):
                bk.delete_recovery_point(BackupVaultName=v, RecoveryPointArn=rp["RecoveryPointArn"])
            bk.delete_backup_vault(BackupVaultName=v)

    p.cleanup("vaults", _clean_vaults)
    plan = p.call("CreateBackupPlan(일일 + 복사 액션)", bk.create_backup_plan, BackupPlan={
        "BackupPlanName": p.name("plan"), "Rules": [{
            "RuleName": "daily", "TargetBackupVaultName": vault, "ScheduleExpression": "cron(0 5 ? * * *)",
            "Lifecycle": {"DeleteAfterDays": 35},
            "CopyActions": [{"DestinationBackupVaultArn": v2arn, "Lifecycle": {"DeleteAfterDays": 90}}]}]})
    iam = p.client("iam")
    brole = iam.create_role(RoleName=p.name("backup"), AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "backup.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]
    p.cleanup("brole", lambda: iam.delete_role(RoleName=brole["RoleName"]))
    if plan:
        pid = plan["BackupPlanId"]
        sel = p.call("CreateBackupSelection(태그 기준)", bk.create_backup_selection, BackupPlanId=pid, BackupSelection={
            "SelectionName": "tagged", "IamRoleArn": brole["Arn"],
            "ListOfTags": [{"ConditionType": "STRINGEQUALS", "ConditionKey": "backup", "ConditionValue": "daily"}]})

        def _del_plan() -> None:
            if sel:
                bk.delete_backup_selection(BackupPlanId=pid, SelectionId=sel["SelectionId"])
            bk.delete_backup_plan(BackupPlanId=pid)

        p.cleanup("plan", _del_plan)
    tname = p.name("bk")
    tarn = ddb.create_table(TableName=tname, BillingMode="PAY_PER_REQUEST",
                            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])["TableDescription"]["TableArn"]
    p.cleanup("table", lambda: ddb.delete_table(TableName=tname))
    wait_until(lambda: ddb.describe_table(TableName=tname)["Table"]["TableStatus"] == "ACTIVE", 10)
    job = p.call("StartBackupJob(DynamoDB 테이블)", bk.start_backup_job, BackupVaultName=vault, ResourceArn=tarn,
                 IamRoleArn=brole["Arn"])
    if job:
        jid = job["BackupJobId"]
        done = wait_until(lambda: bk.describe_backup_job(BackupJobId=jid)["State"] in ("COMPLETED", "FAILED", "ABORTED"), 20, 1)
        j = bk.describe_backup_job(BackupJobId=jid)
        p.behavior("백업 작업이 COMPLETED, 복구 지점 생성", done and j["State"] == "COMPLETED",
                   f"State={j['State']} RecoveryPoint={str(j.get('RecoveryPointArn'))[-40:]}")
        rps = bk.list_recovery_points_by_backup_vault(BackupVaultName=vault).get("RecoveryPoints", [])
        p.behavior("볼트에 복구 지점이 보임", len(rps) > 0, f"{len(rps)}개")
        p.call("ListCopyJobs", bk.list_copy_jobs)


def run_dms(p: Probe) -> None:
    dms, ec2 = p.client("dms"), p.client("ec2")
    vpc = ec2.create_vpc(CidrBlock="10.97.0.0/16")["Vpc"]["VpcId"]
    p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
    subs = []
    for i, az in enumerate(("us-east-1a", "us-east-1b")):
        sid = ec2.create_subnet(VpcId=vpc, CidrBlock=f"10.97.{i}.0/24", AvailabilityZone=az)["Subnet"]["SubnetId"]
        subs.append(sid)
        p.cleanup(f"s{i}", lambda sid=sid: ec2.delete_subnet(SubnetId=sid))
    sg = p.name("dmssub")
    if p.call("CreateReplicationSubnetGroup", dms.create_replication_subnet_group, ReplicationSubnetGroupIdentifier=sg,
              ReplicationSubnetGroupDescription="probe", SubnetIds=subs) is not None:
        p.cleanup("sg", lambda: dms.delete_replication_subnet_group(ReplicationSubnetGroupIdentifier=sg))
    ri = p.call("CreateReplicationInstance", dms.create_replication_instance, ReplicationInstanceIdentifier=p.name("ri"),
                ReplicationInstanceClass="dms.t3.micro", AllocatedStorage=20, ReplicationSubnetGroupIdentifier=sg,
                MultiAZ=False, PubliclyAccessible=False)
    ri_arn = ri["ReplicationInstance"]["ReplicationInstanceArn"] if ri else None
    if ri_arn:
        ok = wait_until(lambda: dms.describe_replication_instances(Filters=[{"Name": "replication-instance-arn",
                                                                            "Values": [ri_arn]}])
                        ["ReplicationInstances"][0]["ReplicationInstanceStatus"] == "available", 20, 1)
        st = dms.describe_replication_instances(Filters=[{"Name": "replication-instance-arn", "Values": [ri_arn]}])[
            "ReplicationInstances"][0]["ReplicationInstanceStatus"]
        p.behavior("복제 인스턴스 creating → available", ok, f"처음 {ri['ReplicationInstance']['ReplicationInstanceStatus']} → {st}")

        def _del_ri() -> None:
            dms.delete_replication_instance(ReplicationInstanceArn=ri_arn)
            wait_until(lambda: not dms.describe_replication_instances(Filters=[{"Name": "replication-instance-arn",
                                                                               "Values": [ri_arn]}])["ReplicationInstances"], 20, 1)

        p.cleanup("ri", _del_ri)
    src = p.call("CreateEndpoint(source mysql)", dms.create_endpoint, EndpointIdentifier=p.name("src"), EndpointType="source",
                 EngineName="mysql", ServerName="onprem.todayorder.example", Port=3306, Username="dms", Password="Passw0rd!x")
    tgt = p.call("CreateEndpoint(target aurora-postgresql)", dms.create_endpoint, EndpointIdentifier=p.name("tgt"),
                 EndpointType="target", EngineName="aurora-postgresql", ServerName="aurora.todayorder.example", Port=5432,
                 Username="dms", Password="Passw0rd!x", DatabaseName="orders")
    if src:
        sa = src["Endpoint"]["EndpointArn"]
        p.cleanup("src", lambda: dms.delete_endpoint(EndpointArn=sa))
    if tgt:
        ta = tgt["Endpoint"]["EndpointArn"]
        p.cleanup("tgt", lambda: dms.delete_endpoint(EndpointArn=ta))
    if ri_arn and src:
        if p.call("TestConnection", dms.test_connection, ReplicationInstanceArn=ri_arn, EndpointArn=sa) is not None:
            wait_until(lambda: dms.describe_connections(Filters=[{"Name": "endpoint-arn", "Values": [sa]}])["Connections"][0]
                       ["Status"] not in ("testing",), 15, 1)
            c = dms.describe_connections(Filters=[{"Name": "endpoint-arn", "Values": [sa]}])["Connections"][0]
            p.behavior("존재하지 않는 원본 DB로의 TestConnection은 failed여야 함", c["Status"] == "failed",
                       f"Status={c['Status']} {c.get('LastFailureMessage', '')[:80]}")
    if ri_arn and src and tgt:
        t = p.call("CreateReplicationTask(full-load-and-cdc)", dms.create_replication_task,
                   ReplicationTaskIdentifier=p.name("task"), SourceEndpointArn=sa, TargetEndpointArn=ta,
                   ReplicationInstanceArn=ri_arn, MigrationType="full-load-and-cdc",
                   TableMappings=json.dumps({"rules": [{"rule-type": "selection", "rule-id": "1", "rule-name": "1",
                                                        "object-locator": {"schema-name": "shop", "table-name": "%"},
                                                        "rule-action": "include"}]}))
        if t:
            tarn = t["ReplicationTask"]["ReplicationTaskArn"]

            def _del_task() -> None:
                dms.delete_replication_task(ReplicationTaskArn=tarn)
                wait_until(lambda: not dms.describe_replication_tasks(Filters=[{"Name": "replication-task-arn",
                                                                               "Values": [tarn]}])["ReplicationTasks"], 15, 1)

            p.cleanup("task", _del_task)


def run_budgets(p: Probe) -> None:
    b = p.client("budgets")
    name = p.name("monthly")
    r = p.call("CreateBudget(월 COST 100 USD + 80% 알림)", b.create_budget, AccountId="000000000000", Budget={
        "BudgetName": name, "BudgetLimit": {"Amount": "100", "Unit": "USD"}, "TimeUnit": "MONTHLY", "BudgetType": "COST"},
        NotificationsWithSubscribers=[{"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                                                        "Threshold": 80, "ThresholdType": "PERCENTAGE"},
                                       "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "ops@example.com"}]}])
    if r is not None:
        p.cleanup("budget", lambda: b.delete_budget(AccountId="000000000000", BudgetName=name))
        d = p.call("DescribeBudgets", b.describe_budgets, AccountId="000000000000")
        if d:
            mine = [x for x in d.get("Budgets", []) if x["BudgetName"] == name]
            p.behavior("예산 조회(CalculatedSpend 포함?)", bool(mine), str(mine[0].get("CalculatedSpend") if mine else None)[:120])
        p.call("DescribeNotificationsForBudget", b.describe_notifications_for_budget, AccountId="000000000000", BudgetName=name)
        p.call("DescribeBudgetPerformanceHistory", b.describe_budget_performance_history, AccountId="000000000000",
               BudgetName=name)
    ce = p.client("ce")
    today = dt.date.today()
    p.call("ce GetCostAndUsage", ce.get_cost_and_usage, TimePeriod={"Start": str(today.replace(day=1)),
                                                                    "End": str(today + dt.timedelta(days=1))},
           Granularity="MONTHLY", Metrics=["UnblendedCost"])


def run_tagging(p: Probe) -> None:
    tg = p.client("resourcegroupstaggingapi")
    s3, sqs, ddb, ec2 = p.client("s3"), p.client("sqs"), p.client("dynamodb"), p.client("ec2")
    tag = {"Key": "cost-center", "Value": f"probe-{p.suffix}"}
    b = p.name("tag")
    s3.create_bucket(Bucket=b)
    s3.put_bucket_tagging(Bucket=b, Tagging={"TagSet": [tag]})
    p.cleanup("b", lambda: s3.delete_bucket(Bucket=b))
    q = sqs.create_queue(QueueName=p.name("tag"), tags={tag["Key"]: tag["Value"]})["QueueUrl"]
    p.cleanup("q", lambda: sqs.delete_queue(QueueUrl=q))
    t = ddb.create_table(TableName=p.name("tag"), BillingMode="PAY_PER_REQUEST",
                         AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                         KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}], Tags=[tag])["TableDescription"]
    p.cleanup("t", lambda: ddb.delete_table(TableName=p.name("tag")))
    vpc = ec2.create_vpc(CidrBlock="10.96.0.0/16", TagSpecifications=[{"ResourceType": "vpc", "Tags": [tag]}])["Vpc"]["VpcId"]
    p.cleanup("vpc", lambda: ec2.delete_vpc(VpcId=vpc))
    untagged = sqs.create_queue(QueueName=p.name("untagged"))["QueueUrl"]
    p.cleanup("uq", lambda: sqs.delete_queue(QueueUrl=untagged))
    r = p.call("GetResources(TagFilters)", tg.get_resources, TagFilters=[{"Key": tag["Key"], "Values": [tag["Value"]]}])
    if r is not None:
        arns = [x["ResourceARN"] for x in r["ResourceTagMappingList"]]
        found = {k: any(k in a for a in arns) for k in ("s3", "sqs", "dynamodb", "ec2")}
        p.behavior("태그로 S3·SQS·DynamoDB·VPC를 한 번에 찾음", all(found.values()), str(found))
    qarn = sqs.get_queue_attributes(QueueUrl=untagged, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    if p.call("TagResources(태그 없는 큐에 일괄 태깅)", tg.tag_resources, ResourceARNList=[qarn, t["TableArn"]],
              Tags={"owner": "orders-team"}) is not None:
        got = sqs.list_queue_tags(QueueUrl=untagged).get("Tags", {})
        p.behavior("TagResources가 대상 서비스(SQS)에 실제 반영", got.get("owner") == "orders-team", str(got))
    p.call("GetTagKeys", tg.get_tag_keys)


def run_misc(p: Probe) -> None:
    """시험 범위의 기타 서비스: 존재(호출 가능) 여부만 빠르게 기록한다."""
    c = lambda n, region="us-east-1": boto3.client(n, region_name=region, config=_CFG)  # noqa: E731
    ec2 = c("ec2")
    vpc_id = ec2.create_vpc(CidrBlock="10.77.0.0/16")["Vpc"]["VpcId"]
    subnet_id = ec2.create_subnet(VpcId=vpc_id, CidrBlock="10.77.1.0/24", AvailabilityZone="us-east-1a")["Subnet"]["SubnetId"]
    calls = [
        ("elasticbeanstalk CreateApplication", lambda: c("elasticbeanstalk").create_application(ApplicationName=p.name("eb"))),
        ("lightsail GetRegions", lambda: c("lightsail").get_regions()),
        ("batch CreateComputeEnvironment(FARGATE)", lambda: c("batch").create_compute_environment(
            computeEnvironmentName=p.name("batch"), type="MANAGED", computeResources={
                "type": "FARGATE", "maxvCpus": 4, "subnets": ["subnet-00000000"], "securityGroupIds": ["sg-00000000"]})),
        ("storagegateway ListGateways", lambda: c("storagegateway").list_gateways()),
        ("datasync ListTasks", lambda: c("datasync").list_tasks()),
        ("fsx CreateFileSystem(LUSTRE)", lambda: c("fsx").create_file_system(
            FileSystemType="LUSTRE", StorageCapacity=1200, SubnetIds=[subnet_id],
            LustreConfiguration={"DeploymentType": "SCRATCH_2"})),
        ("redshift CreateCluster", lambda: c("redshift").create_cluster(
            ClusterIdentifier=p.name("rs"), NodeType="ra3.xlplus", MasterUsername="admin", MasterUserPassword="Passw0rd1",
            ClusterType="single-node")),
        ("opensearch CreateDomain", lambda: c("opensearch").create_domain(DomainName=f"probe{p.suffix}")),
        ("emr ListClusters", lambda: c("emr").list_clusters()),
        ("kafka ListClustersV2", lambda: c("kafka").list_clusters_v2()),
        ("mq CreateBroker", lambda: c("mq").create_broker(
            BrokerName=p.name("mq"), EngineType="ACTIVEMQ", EngineVersion="5.18", HostInstanceType="mq.t3.micro",
            DeploymentMode="SINGLE_INSTANCE", PubliclyAccessible=False, AutoMinorVersionUpgrade=True,
            Users=[{"Username": "admin", "Password": "Passw0rd1234"}])),
        ("appflow ListFlows", lambda: c("appflow").list_flows()),
        ("transfer CreateServer(SFTP)", lambda: c("transfer").create_server(Protocols=["SFTP"])),
        ("servicecatalog ListPortfolios", lambda: c("servicecatalog").list_portfolios()),
        ("ram CreateResourceShare", lambda: c("ram").create_resource_share(name=p.name("share"))),
        ("ds CreateDirectory(SimpleAD)", lambda: c("ds").create_directory(
            Name=f"corp{p.suffix}.todayorder.example", Password="Passw0rd1!", Size="Small")),
        ("sso-admin ListInstances", lambda: c("sso-admin").list_instances()),
        ("service-quotas GetServiceQuota(Lambda 동시 실행)", lambda: c("service-quotas").get_service_quota(
            ServiceCode="lambda", QuotaCode="L-B99A9384")),
        ("compute-optimizer GetEnrollmentStatus", lambda: c("compute-optimizer").get_enrollment_status()),
        ("controltower ListLandingZones", lambda: c("controltower").list_landing_zones()),
        ("lakeformation GetDataLakeSettings", lambda: c("lakeformation").get_data_lake_settings()),
        ("quicksight ListDashboards", lambda: c("quicksight").list_dashboards(AwsAccountId="000000000000")),
        ("comprehend DetectSentiment", lambda: c("comprehend").detect_sentiment(Text="Delivery was fast. Great!", LanguageCode="en")),
        ("translate TranslateText", lambda: c("translate").translate_text(
            Text="Hello", SourceLanguageCode="en", TargetLanguageCode="ko")),
        ("rekognition ListCollections", lambda: c("rekognition").list_collections()),
        ("polly SynthesizeSpeech", lambda: c("polly").synthesize_speech(Text="안녕하세요", OutputFormat="mp3", VoiceId="Seoyeon")),
        ("sagemaker ListNotebookInstances", lambda: c("sagemaker").list_notebook_instances()),
        ("wellarchitected ListWorkloads", lambda: c("wellarchitected").list_workloads()),
        ("license-manager ListLicenseConfigurations", lambda: c("license-manager").list_license_configurations()),
    ]
    for label, fn in calls:
        p.call(label, fn)
    # 실제 AWS에서도 같은 상황이면 같은 오류를 내는 호출: 오류 자체가 '재현된 동작'이다.
    p.expect_error("DescribeSourceServers", c("drs").describe_source_servers, "UninitializedAccountException",
                   what="drs: 초기화 전 호출 → UninitializedAccountException (AWS와 동일)")
    p.expect_error("DescribeSourceServers", c("mgn").describe_source_servers, "UninitializedAccountException",
                   what="mgn: 초기화 전 호출 → UninitializedAccountException (AWS와 동일)")
    p.expect_error("DescribeEvents", c("health").describe_events, "SubscriptionRequiredException",
                   what="health: Business 이상 지원 플랜 필요 → SubscriptionRequiredException (AWS와 동일)")
    p.expect_error("DescribeTrustedAdvisorChecks", lambda: c("support").describe_trusted_advisor_checks(language="en"),
                   "SubscriptionRequiredException",
                   what="support(Trusted Advisor API): 유료 지원 플랜 필요 → SubscriptionRequiredException (AWS와 동일)")


CHECKS = {
    "cloudwatch": run_cloudwatch,
    "logs": run_logs,
    "cloudformation": run_cloudformation,
    "glue": run_glue,
    "athena": run_athena,
    "backup": run_backup,
    "dms": run_dms,
    "budgets": run_budgets,
    "tagging": run_tagging,
    "misc-optional": run_misc,
}
