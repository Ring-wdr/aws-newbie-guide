"""M06: SQS / SNS / EventBridge / Step Functions / Kinesis / Firehose 탐침."""

from __future__ import annotations

import json
import time
from typing import Any

from lib import Probe, wait_until

ACCOUNT = "000000000000"
REGION = "us-east-1"


def _queue(p: Probe, base: str, attrs: dict[str, str] | None = None, fifo: bool = False) -> tuple[str, str] | None:
    """큐를 만들고 (url, arn) 반환. 실패하면 None."""
    sqs = p.client("sqs")
    name = p.name(base) + (".fifo" if fifo else "")
    a = dict(attrs or {})
    if fifo:
        a["FifoQueue"] = "true"
    r = p.call(f"CreateQueue({base}{'.fifo' if fifo else ''})", sqs.create_queue, QueueName=name, Attributes=a)
    if not r:
        return None
    url = r["QueueUrl"]
    p.cleanup(f"q-{base}", lambda: sqs.delete_queue(QueueUrl=url))
    arn = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    return url, arn


def _drain(sqs: Any, url: str, wait: float = 5.0, attr_names: bool = True) -> list[dict[str, Any]]:
    """wait 초 동안 큐에서 받을 수 있는 메시지를 모두 받아 삭제한다."""
    got: list[dict[str, Any]] = []
    end = time.monotonic() + wait
    while time.monotonic() < end:
        kw: dict[str, Any] = {"QueueUrl": url, "MaxNumberOfMessages": 10, "WaitTimeSeconds": 1}
        if attr_names:
            kw["MessageAttributeNames"] = ["All"]
            kw["AttributeNames"] = ["All"]
        msgs = sqs.receive_message(**kw).get("Messages", [])
        for m in msgs:
            got.append(m)
            sqs.delete_message(QueueUrl=url, ReceiptHandle=m["ReceiptHandle"])
        if not msgs and got:
            break
    return got


def _allow_send_policy(queue_arn: str, source_arn: str, service: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow", "Principal": {"Service": service}, "Action": "sqs:SendMessage",
            "Resource": queue_arn, "Condition": {"ArnEquals": {"aws:SourceArn": source_arn}},
        }],
    })


def _service_role(p: Probe, base: str, service: str, actions: list[str] | None) -> str:
    """service 가 맡을 수 있는 역할을 만들고 ARN 반환. actions 가 있으면 인라인 정책으로 허용한다.
    (에뮬레이터는 Step Functions·Pipes 등이 역할을 맡을 때 신뢰 정책과 권한 정책을 실제로 검사한다)"""
    iam = p.client("iam")
    role = p.name(base)
    arn = iam.create_role(RoleName=role, AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": service}, "Action": "sts:AssumeRole"}]}))["Role"]["Arn"]
    if actions:
        iam.put_role_policy(RoleName=role, PolicyName="allow", PolicyDocument=json.dumps({
            "Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": actions, "Resource": "*"}]}))
        p.cleanup(f"rp-{base}", lambda: iam.delete_role_policy(RoleName=role, PolicyName="allow"))
    p.cleanup(f"role-{base}", lambda: iam.delete_role(RoleName=role))
    return arn


# ---------------------------------------------------------------- SQS
def run_sqs(p: Probe) -> None:
    sqs = p.client("sqs")
    q = _queue(p, "std")
    if not q:
        p.skip("SQS 동작 전체", "CreateQueue 실패")
        return
    url, _arn = q
    attrs = p.call("GetQueueAttributes(All)", sqs.get_queue_attributes, QueueUrl=url, AttributeNames=["All"])
    if attrs:
        a = attrs["Attributes"]
        p.behavior("기본 속성 값 기록", True,
                   f"MaximumMessageSize={a.get('MaximumMessageSize')} VisibilityTimeout={a.get('VisibilityTimeout')} "
                   f"MessageRetentionPeriod={a.get('MessageRetentionPeriod')}")
    p.call("ListQueues", sqs.list_queues, QueueNamePrefix="todayorder-probe")
    p.call("GetQueueUrl", sqs.get_queue_url, QueueName=url.rsplit("/", 1)[-1])

    # 송수신 + 메시지 속성
    p.call("SendMessage(+MessageAttributes)", sqs.send_message, QueueUrl=url, MessageBody="order-1",
           MessageAttributes={"type": {"DataType": "String", "StringValue": "created"}})
    r = p.call("ReceiveMessage", sqs.receive_message, QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=2,
               VisibilityTimeout=2, MessageAttributeNames=["All"], AttributeNames=["All"])
    msgs = (r or {}).get("Messages", [])
    if not msgs:
        p.skip("가시성 타임아웃", "메시지를 받지 못함")
    else:
        m = msgs[0]
        p.behavior("본문·메시지 속성이 그대로 전달", m["Body"] == "order-1"
                   and m.get("MessageAttributes", {}).get("type", {}).get("StringValue") == "created", m["Body"])
        again = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=0).get("Messages", [])
        p.behavior("가시성 타임아웃 중에는 다른 소비자에게 안 보임", not again, f"즉시 재수신 {len(again)}건")
        time.sleep(3)
        red = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=2,
                                  AttributeNames=["ApproximateReceiveCount"]).get("Messages", [])
        cnt = red[0]["Attributes"].get("ApproximateReceiveCount") if red else None
        p.behavior("가시성 타임아웃(2초) 후 재전달, ApproximateReceiveCount=2", bool(red) and cnt == "2",
                   f"재수신 {len(red)}건, count={cnt}")
        if red:
            rh = red[0]["ReceiptHandle"]
            p.call("ChangeMessageVisibility(0)", sqs.change_message_visibility, QueueUrl=url, ReceiptHandle=rh,
                   VisibilityTimeout=0)
            back = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=1).get("Messages", [])
            p.behavior("ChangeMessageVisibility(0) 직후 다시 보임", bool(back), f"{len(back)}건")
            if back:
                p.call("DeleteMessage", sqs.delete_message, QueueUrl=url, ReceiptHandle=back[0]["ReceiptHandle"])
                gone = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=1).get("Messages", [])
                p.behavior("DeleteMessage 후 다시 오지 않음", not gone, f"{len(gone)}건")

    # 롱 폴링: 빈 큐에서 WaitTimeSeconds=2 가 실제로 기다리는가
    t0 = time.monotonic()
    sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=2)
    waited = time.monotonic() - t0
    p.behavior("롱 폴링: 빈 큐에서 WaitTimeSeconds=2 만큼 대기", waited >= 1.8, f"{waited:.1f}s 대기")

    # 지연 전송
    p.call("SendMessage(DelaySeconds=3)", sqs.send_message, QueueUrl=url, MessageBody="delayed", DelaySeconds=3)
    early = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=1, WaitTimeSeconds=1).get("Messages", [])
    late = _drain(sqs, url, wait=5)
    p.behavior("DelaySeconds=3: 처음엔 안 보이고 나중에 도착", not early and any(m["Body"] == "delayed" for m in late),
               f"즉시 {len(early)}건, 이후 {len(late)}건")

    p.call("SendMessageBatch", sqs.send_message_batch, QueueUrl=url,
           Entries=[{"Id": str(i), "MessageBody": f"b{i}"} for i in range(3)])
    p.call("PurgeQueue", sqs.purge_queue, QueueUrl=url)
    left = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=1).get("Messages", [])
    p.behavior("PurgeQueue 후 큐가 빔", not left, f"{len(left)}건 남음")

    # 메시지 크기 한도
    big = "x" * (1024 * 1024 + 1)
    p.expect_error("SendMessage(1 MiB + 1 byte)", sqs.send_message, "InvalidParameterValue", QueueUrl=url, MessageBody=big,
                   what="1 MiB 초과 메시지 거부")

    # DLQ
    dlq = _queue(p, "dlq")
    src = _queue(p, "src")
    if dlq and src:
        dlq_url, dlq_arn = dlq
        src_url, src_arn = src
        p.call("SetQueueAttributes(RedrivePolicy maxReceiveCount=2)", sqs.set_queue_attributes, QueueUrl=src_url,
               Attributes={"RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": "2"}),
                           "VisibilityTimeout": "1"})
        sqs.send_message(QueueUrl=src_url, MessageBody="poison")
        receives = 0
        for _ in range(5):
            got = sqs.receive_message(QueueUrl=src_url, MaxNumberOfMessages=1, WaitTimeSeconds=1).get("Messages", [])
            receives += len(got)
            time.sleep(1.2)
        in_dlq = _drain(sqs, dlq_url, wait=3)
        p.behavior("maxReceiveCount=2 초과 후 메시지가 DLQ로 이동", any(m["Body"] == "poison" for m in in_dlq),
                   f"원본 큐에서 {receives}번 수신, DLQ {len(in_dlq)}건")
        p.call("ListDeadLetterSourceQueues", sqs.list_dead_letter_source_queues, QueueUrl=dlq_url)
        # DLQ 재처리(redrive)
        sqs.send_message(QueueUrl=dlq_url, MessageBody="redrive-me")
        mt = p.call("StartMessageMoveTask", sqs.start_message_move_task, SourceArn=dlq_arn, DestinationArn=src_arn)
        if mt:
            moved = []
            wait_until(lambda: bool(moved.extend(_drain(sqs, src_url, wait=1)) or moved), timeout=10)
            p.behavior("StartMessageMoveTask로 DLQ → 원본 큐 재처리", any(m["Body"] == "redrive-me" for m in moved),
                       f"원본 큐 수신 {len(moved)}건")
            p.call("ListMessageMoveTasks", sqs.list_message_move_tasks, SourceArn=dlq_arn)

    # FIFO
    f = _queue(p, "orders", fifo=True)
    if f:
        furl, _ = f
        for i in range(3):
            sqs.send_message(QueueUrl=furl, MessageBody=f"m{i}", MessageGroupId="g1", MessageDeduplicationId=f"d{i}")
        sqs.send_message(QueueUrl=furl, MessageBody="m0-dup", MessageGroupId="g1", MessageDeduplicationId="d0")
        got = _drain(sqs, furl, wait=4)
        bodies = [m["Body"] for m in got]
        p.behavior("FIFO: 그룹 내 순서 유지", bodies[:3] == ["m0", "m1", "m2"], f"수신 순서 {bodies}")
        p.behavior("FIFO: 같은 MessageDeduplicationId 재전송은 버려짐", "m0-dup" not in bodies, f"수신 {bodies}")
        p.expect_error("SendMessage(FIFO, MessageGroupId 없음)", sqs.send_message, "MissingParameter",
                       QueueUrl=furl, MessageBody="x", MessageDeduplicationId="zz",
                       what="FIFO 큐에 MessageGroupId 없이 보내면 거부")
    f2 = _queue(p, "cbd", {"ContentBasedDeduplication": "true"}, fifo=True)
    if f2:
        furl2, _ = f2
        sqs.send_message(QueueUrl=furl2, MessageBody="same", MessageGroupId="g")
        sqs.send_message(QueueUrl=furl2, MessageBody="same", MessageGroupId="g")
        got = _drain(sqs, furl2, wait=3)
        p.behavior("FIFO ContentBasedDeduplication: 같은 본문 두 번 → 1건", len(got) == 1, f"{len(got)}건 수신")


# ---------------------------------------------------------------- SNS
def run_sns(p: Probe) -> None:
    sns, sqs = p.client("sns"), p.client("sqs")
    t = p.call("CreateTopic", sns.create_topic, Name=p.name("orders"))
    if not t:
        p.skip("SNS 동작 전체", "CreateTopic 실패")
        return
    topic = t["TopicArn"]
    p.cleanup("topic", lambda: sns.delete_topic(TopicArn=topic))
    p.call("GetTopicAttributes", sns.get_topic_attributes, TopicArn=topic)
    p.call("ListTopics", sns.list_topics)

    def sub_queue(base: str, raw: bool = False, filt: dict[str, Any] | None = None, scope: str | None = None,
                  policy: bool = True) -> str | None:
        q = _queue(p, base)
        if not q:
            return None
        url, arn = q
        if policy:
            sqs.set_queue_attributes(QueueUrl=url, Attributes={"Policy": _allow_send_policy(arn, topic, "sns.amazonaws.com")})
        attrs: dict[str, str] = {}
        if raw:
            attrs["RawMessageDelivery"] = "true"
        if filt is not None:
            attrs["FilterPolicy"] = json.dumps(filt)
        if scope:
            attrs["FilterPolicyScope"] = scope
        s = p.call(f"Subscribe(sqs:{base})", sns.subscribe, TopicArn=topic, Protocol="sqs", Endpoint=arn,
                   Attributes=attrs, ReturnSubscriptionArn=True)
        if not s:
            return None
        return url

    env_url = sub_queue("fan-envelope")
    raw_url = sub_queue("fan-raw", raw=True)
    filt_url = sub_queue("fan-filter", raw=True, filt={"eventType": ["order_paid"]})
    body_url = sub_queue("fan-bodyfilter", raw=True, filt={"amount": [{"numeric": [">=", 100]}]}, scope="MessageBody")
    nopol_url = sub_queue("fan-nopolicy", raw=True, policy=False)

    p.call("Publish(eventType=order_created)", sns.publish, TopicArn=topic, Message=json.dumps({"id": 1, "amount": 50}),
           MessageAttributes={"eventType": {"DataType": "String", "StringValue": "order_created"}})
    p.call("Publish(eventType=order_paid)", sns.publish, TopicArn=topic, Message=json.dumps({"id": 2, "amount": 150}),
           MessageAttributes={"eventType": {"DataType": "String", "StringValue": "order_paid"}})

    if env_url:
        got = _drain(sqs, env_url, wait=6)
        ok = False
        detail = f"{len(got)}건"
        if got:
            try:
                env = json.loads(got[0]["Body"])
                ok = env.get("Type") == "Notification" and env.get("TopicArn") == topic
                detail = f"{len(got)}건, 봉투 키={sorted(env)[:6]}"
            except ValueError:
                detail = f"{len(got)}건, 본문이 JSON 봉투가 아님: {got[0]['Body'][:60]}"
        p.behavior("SNS → SQS 팬아웃: 메시지가 구독 큐에 실제로 도착(SNS 봉투 JSON)", ok and len(got) == 2, detail)
    if raw_url:
        got = _drain(sqs, raw_url, wait=4)
        bodies = [m["Body"] for m in got]
        p.behavior("RawMessageDelivery=true: 원문 그대로 도착", len(got) == 2 and all(b.startswith("{\"id\"") for b in bodies),
                   f"{bodies}")
    if filt_url:
        got = _drain(sqs, filt_url, wait=4)
        bodies = [m["Body"] for m in got]
        p.behavior("FilterPolicy(MessageAttributes): order_paid 만 도착", len(got) == 1 and '"id": 2' in bodies[0],
                   f"{len(got)}건 {bodies}")
    if body_url:
        got = _drain(sqs, body_url, wait=4)
        bodies = [m["Body"] for m in got]
        p.behavior("FilterPolicyScope=MessageBody, amount>=100 만 도착", len(got) == 1 and '"id": 2' in bodies[0],
                   f"{len(got)}건 {bodies}")

    if nopol_url:
        got = _drain(sqs, nopol_url, wait=4)
        p.behavior("큐 정책(sqs:SendMessage 허용) 없는 구독 큐에는 전달되지 않음", not got,
                   f"{len(got)}건 도착" + (" — 리소스 정책이 평가되지 않는다" if got else ""))
    p.call("PublishBatch", sns.publish_batch, TopicArn=topic,
           PublishBatchRequestEntries=[{"Id": "a", "Message": "x"}, {"Id": "b", "Message": "y"}])
    if env_url:
        got = _drain(sqs, env_url, wait=4)
        p.behavior("PublishBatch 2건이 구독 큐에 도착", len(got) == 2, f"{len(got)}건")

    e = p.call("Subscribe(email)", sns.subscribe, TopicArn=topic, Protocol="email", Endpoint="dev@example.com",
               ReturnSubscriptionArn=True)
    if e:
        p.behavior("email 구독은 확인 대기 상태", "pending" in e["SubscriptionArn"].lower() or
                   sns.get_subscription_attributes(SubscriptionArn=e["SubscriptionArn"])["Attributes"].get("PendingConfirmation") == "true",
                   e["SubscriptionArn"][-40:])
    p.call("Subscribe(https)", sns.subscribe, TopicArn=topic, Protocol="https", Endpoint="https://example.com/hook")
    subs = p.call("ListSubscriptionsByTopic", sns.list_subscriptions_by_topic, TopicArn=topic)
    if subs:
        p.behavior("구독 목록 조회", len(subs["Subscriptions"]) >= 4, f"{len(subs['Subscriptions'])}개")

    # FIFO 토픽 → FIFO 큐
    ft = p.call("CreateTopic(FIFO)", sns.create_topic, Name=p.name("ordersf") + ".fifo",
                Attributes={"FifoTopic": "true", "ContentBasedDeduplication": "true"})
    fq = _queue(p, "fanf", fifo=True)
    if ft and fq:
        ftopic = ft["TopicArn"]
        p.cleanup("ftopic", lambda: sns.delete_topic(TopicArn=ftopic))
        furl, farn = fq
        sqs.set_queue_attributes(QueueUrl=furl, Attributes={"Policy": _allow_send_policy(farn, ftopic, "sns.amazonaws.com")})
        p.call("Subscribe(FIFO 큐, raw)", sns.subscribe, TopicArn=ftopic, Protocol="sqs", Endpoint=farn,
               Attributes={"RawMessageDelivery": "true"})
        for i in range(3):
            sns.publish(TopicArn=ftopic, Message=f"f{i}", MessageGroupId="g1")
        sns.publish(TopicArn=ftopic, Message="f0", MessageGroupId="g1")  # 내용 기반 중복
        got = [m["Body"] for m in _drain(sqs, furl, wait=5)]
        p.behavior("FIFO 토픽 → FIFO 큐: 순서 유지 + 중복 제거", got == ["f0", "f1", "f2"], f"{got}")


# ---------------------------------------------------------------- EventBridge
def run_eventbridge(p: Probe) -> None:
    ev, sqs = p.client("events"), p.client("sqs")
    bus = p.name("bus")
    b = p.call("CreateEventBus", ev.create_event_bus, Name=bus)
    if not b:
        p.skip("EventBridge 동작", "CreateEventBus 실패")
        return
    p.cleanup("bus", lambda: ev.delete_event_bus(Name=bus))
    rule = p.name("paid")
    pattern = {"source": ["todayorder.orders"], "detail-type": ["OrderPaid"], "detail": {"amount": [{"numeric": [">", 100]}]}}
    r = p.call("PutRule(이벤트 패턴)", ev.put_rule, Name=rule, EventBusName=bus, EventPattern=json.dumps(pattern))
    q = _queue(p, "ebtarget")
    if r and q:
        rule_arn = r["RuleArn"]
        url, arn = q
        sqs.set_queue_attributes(QueueUrl=url, Attributes={"Policy": _allow_send_policy(arn, rule_arn, "events.amazonaws.com")})
        p.call("PutTargets(SQS)", ev.put_targets, Rule=rule, EventBusName=bus, Targets=[{"Id": "q", "Arn": arn}])
        p.cleanup("targets", lambda: (ev.remove_targets(Rule=rule, EventBusName=bus, Ids=["q"]),
                                      ev.delete_rule(Name=rule, EventBusName=bus)))
        p.call("TestEventPattern", ev.test_event_pattern, EventPattern=json.dumps(pattern), Event=json.dumps({
            "id": "1", "account": ACCOUNT, "source": "todayorder.orders", "time": "2026-01-01T00:00:00Z",
            "region": REGION, "resources": [], "detail-type": "OrderPaid", "detail": {"amount": 150}}))
        entries = [
            {"Source": "todayorder.orders", "DetailType": "OrderPaid", "Detail": json.dumps({"amount": 150, "id": "match"}), "EventBusName": bus},
            {"Source": "todayorder.orders", "DetailType": "OrderPaid", "Detail": json.dumps({"amount": 50, "id": "small"}), "EventBusName": bus},
            {"Source": "todayorder.other", "DetailType": "OrderPaid", "Detail": json.dumps({"amount": 500, "id": "othersrc"}), "EventBusName": bus},
        ]
        pe = p.call("PutEvents", ev.put_events, Entries=entries)
        if pe:
            p.behavior("PutEvents FailedEntryCount=0", pe.get("FailedEntryCount") == 0, f"{pe.get('FailedEntryCount')}")
        got = _drain(sqs, url, wait=6)
        ids = []
        for m in got:
            try:
                ids.append(json.loads(m["Body"])["detail"]["id"])
            except (ValueError, KeyError):
                ids.append(m["Body"][:40])
        p.behavior("규칙 패턴과 일치하는 이벤트만 SQS 대상에 전달", ids == ["match"], f"수신 {ids}")
    p.call("PutRule(schedule rate(1 minute))", ev.put_rule, Name=p.name("cron"), ScheduleExpression="rate(1 minute)")
    p.cleanup("cron", lambda: ev.delete_rule(Name=p.name("cron")))
    p.call("ListRules", ev.list_rules, EventBusName=bus)
    p.call("CreateArchive", ev.create_archive, ArchiveName=p.name("arch")[:48],
           EventSourceArn=f"arn:aws:events:{REGION}:{ACCOUNT}:event-bus/{bus}")

    # Scheduler
    sch = p.client("scheduler")
    sch_role = _service_role(p, "schrole", "scheduler.amazonaws.com", ["sqs:SendMessage"])
    if q:
        sname = p.name("sched")
        if p.call("Scheduler CreateSchedule", sch.create_schedule, Name=sname, ScheduleExpression="rate(5 minutes)",
                  FlexibleTimeWindow={"Mode": "OFF"},
                  Target={"Arn": q[1], "RoleArn": sch_role, "Input": "{}"}) is not None:
            p.cleanup("sched", lambda: sch.delete_schedule(Name=sname))
            p.call("Scheduler GetSchedule", sch.get_schedule, Name=sname)
    # Pipes
    pipes = p.client("pipes")
    src, dst = _queue(p, "pipesrc"), _queue(p, "pipedst")
    if src and dst:
        # 잘못된 신뢰 정책(states.amazonaws.com)의 역할 → 실패해야 한다
        bad_role = _service_role(p, "pipebad", "states.amazonaws.com", ["sqs:*"])
        bname = p.name("pipebad")[:64]
        if p.call("Pipes CreatePipe(신뢰 정책이 틀린 역할)", pipes.create_pipe, Name=bname, RoleArn=bad_role,
                  Source=src[1], Target=dst[1]) is not None:
            p.cleanup("pipebad", lambda: pipes.delete_pipe(Name=bname))
            st: dict[str, Any] = {}
            wait_until(lambda: (st.update(pipes.describe_pipe(Name=bname)) or st["CurrentState"] not in ("CREATING",)), timeout=10)
            p.behavior("Pipes: 역할 신뢰 정책에 pipes.amazonaws.com 이 없으면 CREATE_FAILED", st.get("CurrentState") == "CREATE_FAILED",
                       f"{st.get('CurrentState')}: {str(st.get('StateReason'))[:120]}")
        role_arn = _service_role(p, "piperole", "pipes.amazonaws.com", ["sqs:*"])
        pname = p.name("pipe")[:64]
        if p.call("Pipes CreatePipe(SQS→SQS)", pipes.create_pipe, Name=pname, RoleArn=role_arn,
                  Source=src[1], Target=dst[1]) is not None:
            p.cleanup("pipe", lambda: pipes.delete_pipe(Name=pname))
            wait_until(lambda: pipes.describe_pipe(Name=pname)["CurrentState"] == "RUNNING", timeout=10)
            sqs.send_message(QueueUrl=src[0], MessageBody="via-pipe")
            got = _drain(sqs, dst[0], wait=8)
            p.behavior("Pipes: 원본 큐 메시지가 대상 큐로 전달", any("via-pipe" in m["Body"] for m in got), f"{len(got)}건")


# ---------------------------------------------------------------- Step Functions
def run_stepfunctions(p: Probe) -> None:
    sfn, sqs = p.client("stepfunctions"), p.client("sqs")
    role_arn = _service_role(p, "sfnrole", "states.amazonaws.com", None)       # 권한 정책 없음
    role_ok = _service_role(p, "sfnrole-sqs", "states.amazonaws.com", ["sqs:SendMessage"])

    definition = {
        "StartAt": "Init",
        "States": {
            "Init": {"Type": "Pass", "Result": {"amount": 150}, "ResultPath": "$.order", "Next": "Wait"},
            "Wait": {"Type": "Wait", "Seconds": 1, "Next": "Big?"},
            "Big?": {"Type": "Choice", "Choices": [{"Variable": "$.order.amount", "NumericGreaterThan": 100, "Next": "Big"}],
                     "Default": "Small"},
            "Big": {"Type": "Pass", "Result": "big", "ResultPath": "$.size", "Next": "Done"},
            "Small": {"Type": "Fail", "Error": "TooSmall", "Cause": "amount <= 100"},
            "Done": {"Type": "Succeed"},
        },
    }
    sm = p.call("CreateStateMachine(STANDARD, Pass/Wait/Choice/Succeed/Fail)", sfn.create_state_machine,
                name=p.name("order"), definition=json.dumps(definition), roleArn=role_arn)
    if sm:
        sm_arn = sm["stateMachineArn"]
        p.cleanup("sm", lambda: sfn.delete_state_machine(stateMachineArn=sm_arn))
        p.call("DescribeStateMachine", sfn.describe_state_machine, stateMachineArn=sm_arn)
        ex = p.call("StartExecution", sfn.start_execution, stateMachineArn=sm_arn, input=json.dumps({"id": "o-1"}))
        if ex:
            ea = ex["executionArn"]
            st: dict[str, Any] = {}

            def done() -> bool:
                st.update(sfn.describe_execution(executionArn=ea))
                return st["status"] != "RUNNING"
            wait_until(done, timeout=20)
            out = json.loads(st.get("output") or "{}")
            p.behavior("실행이 SUCCEEDED, 출력에 Pass 결과 반영", st.get("status") == "SUCCEEDED" and out.get("size") == "big",
                       f"status={st.get('status')} output={st.get('output')}")
            h = p.call("GetExecutionHistory", sfn.get_execution_history, executionArn=ea)
            if h:
                types = [e["type"] for e in h["events"]]
                p.behavior("실행 이력에 상태 전이 이벤트가 기록", "WaitStateEntered" in types and "ExecutionSucceeded" in types,
                           f"{len(types)}개 이벤트: {types[:4]}…")
    fail_def = {"StartAt": "F", "States": {"F": {"Type": "Fail", "Error": "PaymentFailed", "Cause": "card declined"}}}
    fm = p.call("CreateStateMachine(Fail)", sfn.create_state_machine, name=p.name("fail"),
                definition=json.dumps(fail_def), roleArn=role_arn)
    if fm:
        fm_arn = fm["stateMachineArn"]
        p.cleanup("fm", lambda: sfn.delete_state_machine(stateMachineArn=fm_arn))
        fx = sfn.start_execution(stateMachineArn=fm_arn)
        st2: dict[str, Any] = {}
        wait_until(lambda: (st2.update(sfn.describe_execution(executionArn=fx["executionArn"])) or st2["status"] != "RUNNING"),
                   timeout=15)
        p.behavior("Fail 상태 → 실행 FAILED, error 전달", st2.get("status") == "FAILED" and st2.get("error") == "PaymentFailed",
                   f"status={st2.get('status')} error={st2.get('error')}")

    # 서비스 통합: SQS SendMessage
    q = _queue(p, "sfntarget")
    if q:
        url, _arn = q
        task_def = {"StartAt": "Send", "States": {"Send": {
            "Type": "Task", "Resource": "arn:aws:states:::sqs:sendMessage",
            "Parameters": {"QueueUrl": url, "MessageBody.$": "$.msg"}, "End": True}}}
        for label, rarn, expect_ok in (("권한 없는 역할", role_arn, False), ("sqs:SendMessage 허용 역할", role_ok, True)):
            tm = p.call(f"CreateStateMachine(Task: sqs:sendMessage, {label})", sfn.create_state_machine,
                        name=p.name("sqs" + ("ok" if expect_ok else "no")), definition=json.dumps(task_def), roleArn=rarn)
            if not tm:
                continue
            tm_arn = tm["stateMachineArn"]
            p.cleanup(f"tm-{label}", lambda a=tm_arn: sfn.delete_state_machine(stateMachineArn=a))
            tx = sfn.start_execution(stateMachineArn=tm_arn, input=json.dumps({"msg": "from-sfn"}))
            st3: dict[str, Any] = {}
            wait_until(lambda: (st3.update(sfn.describe_execution(executionArn=tx["executionArn"])) or st3["status"] != "RUNNING"),
                       timeout=20)
            got = _drain(sqs, url, wait=3)
            sent = any(m["Body"] == "from-sfn" for m in got)
            if expect_ok:
                p.behavior("Task(sqs:sendMessage) 서비스 통합이 실제로 메시지를 보냄",
                           st3.get("status") == "SUCCEEDED" and sent,
                           f"status={st3.get('status')} 수신 {len(got)}건")
            else:
                p.behavior("실행 역할에 sqs:SendMessage 가 없으면 Task가 AccessDenied로 FAILED (IAM 평가됨)",
                           st3.get("status") == "FAILED" and not sent,
                           f"status={st3.get('status')} error={st3.get('error')} cause={str(st3.get('cause'))[:90]}")

    # EXPRESS + StartSyncExecution
    em = p.call("CreateStateMachine(EXPRESS)", sfn.create_state_machine, name=p.name("express"), type="EXPRESS",
                definition=json.dumps({"StartAt": "P", "States": {"P": {"Type": "Pass", "Result": {"ok": True}, "End": True}}}),
                roleArn=role_arn)
    if em:
        em_arn = em["stateMachineArn"]
        p.cleanup("em", lambda: sfn.delete_state_machine(stateMachineArn=em_arn))
        sx = p.call("StartSyncExecution", sfn.start_sync_execution, stateMachineArn=em_arn, input="{}")
        if sx:
            p.behavior("EXPRESS StartSyncExecution이 결과를 동기 반환", sx.get("status") == "SUCCEEDED",
                       f"status={sx.get('status')} output={sx.get('output')}")
    p.call("ListStateMachines", sfn.list_state_machines)


# ---------------------------------------------------------------- Kinesis
def run_kinesis(p: Probe) -> None:
    k = p.client("kinesis")
    name = p.name("events")
    if p.call("CreateStream(2 shards)", k.create_stream, StreamName=name, ShardCount=2) is None:
        p.skip("Kinesis 동작", "CreateStream 실패")
        return
    p.cleanup("stream", lambda: k.delete_stream(StreamName=name, EnforceConsumerDeletion=True))
    first = k.describe_stream_summary(StreamName=name)["StreamDescriptionSummary"]["StreamStatus"]
    active = wait_until(lambda: k.describe_stream_summary(StreamName=name)["StreamDescriptionSummary"]["StreamStatus"] == "ACTIVE",
                        timeout=20)
    p.behavior("스트림 상태 CREATING → ACTIVE", active, f"처음 상태={first}")
    if not active:
        return
    p.call("DescribeStreamSummary", k.describe_stream_summary, StreamName=name)
    shards = p.call("ListShards", k.list_shards, StreamName=name)
    seqs = []
    for i in range(3):
        r = p.call(f"PutRecord #{i}", k.put_record, StreamName=name, Data=f"order-{i}".encode(), PartitionKey="user-1")
        if r:
            seqs.append((r["ShardId"], r["SequenceNumber"]))
    if seqs:
        p.behavior("같은 파티션 키 → 같은 샤드, 시퀀스 번호 증가",
                   len({s for s, _ in seqs}) == 1 and [int(q) for _, q in seqs] == sorted(int(q) for _, q in seqs),
                   f"shard={seqs[0][0]}")
    pr = p.call("PutRecords(10)", k.put_records, StreamName=name,
                Records=[{"Data": f"bulk-{i}".encode(), "PartitionKey": f"k{i}"} for i in range(10)])
    if pr:
        p.behavior("PutRecords FailedRecordCount=0", pr.get("FailedRecordCount") == 0, f"{pr.get('FailedRecordCount')}")
    if seqs and shards:
        it = p.call("GetShardIterator(TRIM_HORIZON)", k.get_shard_iterator, StreamName=name, ShardId=seqs[0][0],
                    ShardIteratorType="TRIM_HORIZON")
        if it:
            gr = p.call("GetRecords", k.get_records, ShardIterator=it["ShardIterator"], Limit=100)
            if gr:
                data = [r["Data"].decode() for r in gr["Records"]]
                p.behavior("GetRecords가 넣은 순서대로 데이터를 반환", data[:3] == ["order-0", "order-1", "order-2"],
                           f"{len(data)}건 {data[:3]}")
        total = 0
        for sh in shards["Shards"]:
            itx = k.get_shard_iterator(StreamName=name, ShardId=sh["ShardId"], ShardIteratorType="TRIM_HORIZON")
            total += len(k.get_records(ShardIterator=itx["ShardIterator"], Limit=100)["Records"])
        p.behavior("모든 샤드 합계 = 13건", total == 13, f"{total}건")
    p.call("UpdateShardCount(4)", k.update_shard_count, StreamName=name, TargetShardCount=4, ScalingType="UNIFORM_SCALING")
    wait_until(lambda: k.describe_stream_summary(StreamName=name)["StreamDescriptionSummary"]["StreamStatus"] == "ACTIVE", timeout=20)
    s2 = k.describe_stream_summary(StreamName=name)["StreamDescriptionSummary"]
    p.behavior("UpdateShardCount 후 열린 샤드 4개", s2.get("OpenShardCount") == 4, f"OpenShardCount={s2.get('OpenShardCount')}")
    p.call("IncreaseStreamRetentionPeriod(48h)", k.increase_stream_retention_period, StreamName=name, RetentionPeriodHours=48)
    od = p.name("ondemand")
    if p.call("CreateStream(ON_DEMAND)", k.create_stream, StreamName=od, StreamModeDetails={"StreamMode": "ON_DEMAND"}) is not None:
        p.cleanup("od", lambda: k.delete_stream(StreamName=od))


# ---------------------------------------------------------------- Firehose
def run_firehose(p: Probe) -> None:
    fh, s3 = p.client("firehose"), p.client("s3")
    bucket = p.name("lake")
    if p.call("CreateBucket(대상)", s3.create_bucket, Bucket=bucket) is None:
        return

    def _empty() -> None:
        for o in s3.list_objects_v2(Bucket=bucket).get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=o["Key"])
        s3.delete_bucket(Bucket=bucket)
    p.cleanup("bucket", _empty)
    fh_role = _service_role(p, "fhrole", "firehose.amazonaws.com", ["s3:*"])
    name = p.name("orders")[:64]
    r = p.call("CreateDeliveryStream(S3, 버퍼 60초/1MB)", fh.create_delivery_stream, DeliveryStreamName=name,
               DeliveryStreamType="DirectPut",
               ExtendedS3DestinationConfiguration={
                   "RoleARN": fh_role, "BucketARN": f"arn:aws:s3:::{bucket}", "Prefix": "orders/",
                   "ErrorOutputPrefix": "errors/", "BufferingHints": {"SizeInMBs": 1, "IntervalInSeconds": 60}})
    if not r:
        return
    p.cleanup("fh", lambda: fh.delete_delivery_stream(DeliveryStreamName=name))
    active = wait_until(lambda: fh.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
                        ["DeliveryStreamStatus"] == "ACTIVE", timeout=20)
    p.behavior("전송 스트림 ACTIVE", active)
    p.call("PutRecord", fh.put_record, DeliveryStreamName=name, Record={"Data": b'{"id":1}\n'})
    p.call("PutRecordBatch", fh.put_record_batch, DeliveryStreamName=name,
           Records=[{"Data": f'{{"id":{i}}}\n'.encode()} for i in range(2, 5)])
    t0 = time.monotonic()
    arrived = wait_until(lambda: s3.list_objects_v2(Bucket=bucket).get("KeyCount", 0) > 0, timeout=75, interval=3)
    keys = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket).get("Contents", [])]
    p.behavior("버퍼 시간(60초) 안팎에 S3 객체가 실제로 생김", arrived,
               f"{time.monotonic() - t0:.0f}s 대기, 객체 {keys[:2]}")


CHECKS = {
    "sqs": run_sqs,
    "sns": run_sns,
    "eventbridge": run_eventbridge,
    "stepfunctions": run_stepfunctions,
    "kinesis": run_kinesis,
    "firehose": run_firehose,
}
