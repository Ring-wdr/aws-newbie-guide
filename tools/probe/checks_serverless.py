"""M07: Lambda / API Gateway v1·v2 / ECR / ECS / Cognito 탐침."""

from __future__ import annotations

import io
import json
import os
import ssl
import time
import urllib.error
import urllib.request
import zipfile
from typing import Any

from lib import Probe, wait_until

HANDLER = '''
import json, os

def handler(event, context):
    return {"statusCode": 200, "body": json.dumps({"echo": event, "env": os.environ.get("STAGE")})}
'''


def _zip(src: str = HANDLER) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("app.py", src)
    return buf.getvalue()


def _role(p: Probe, base: str, service: str, actions: list[str] | None = None) -> str:
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


def _https(url: str, method: str = "GET", body: bytes | None = None, headers: dict[str, str] | None = None) -> tuple[int, str]:
    ctx = ssl.create_default_context(cafile=os.environ["AWS_CA_BUNDLE"])
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


# ---------------------------------------------------------------- Lambda
def run_lambda(p: Probe) -> None:
    lam, sqs = p.client("lambda"), p.client("sqs")
    role = _role(p, "lambdarole", "lambda.amazonaws.com", ["sqs:*", "logs:*"])
    fn = p.name("fn")[:64]
    r = p.call("CreateFunction(python3.12, zip)", lam.create_function, FunctionName=fn, Runtime="python3.12",
               Role=role, Handler="app.handler", Code={"ZipFile": _zip()}, Timeout=10, MemorySize=128,
               Environment={"Variables": {"STAGE": "dev"}})
    if not r:
        p.skip("Lambda 동작", "CreateFunction 실패")
        return
    p.cleanup("fn", lambda: lam.delete_function(FunctionName=fn))
    first = r.get("State")
    active = wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("State") == "Active", timeout=20)
    p.behavior("함수 상태 Pending → Active", active, f"생성 직후 State={first}")
    p.call("GetFunction", lam.get_function, FunctionName=fn)
    p.call("UpdateFunctionConfiguration(env, 256MB, 900s)", lam.update_function_configuration, FunctionName=fn,
           Environment={"Variables": {"STAGE": "prod"}}, MemorySize=256, Timeout=900)
    wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("LastUpdateStatus") != "InProgress", timeout=10)
    p.expect_error("UpdateFunctionConfiguration(Timeout=901)", lam.update_function_configuration,
                   "ValidationException", FunctionName=fn, Timeout=901, what="타임아웃 15분(900초) 초과 거부")
    p.call("UpdateFunctionCode", lam.update_function_code, FunctionName=fn, ZipFile=_zip(HANDLER + "\n# v2\n"))
    wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("LastUpdateStatus") != "InProgress", timeout=10)
    v1 = p.call("PublishVersion", lam.publish_version, FunctionName=fn)
    p.call("UpdateFunctionCode(v3)", lam.update_function_code, FunctionName=fn, ZipFile=_zip(HANDLER + "\n# v3\n"))
    wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("LastUpdateStatus") != "InProgress", timeout=10)
    v2 = p.call("PublishVersion(2)", lam.publish_version, FunctionName=fn)
    if v1 and v2:
        p.behavior("버전 번호가 1, 2로 증가", (v1["Version"], v2["Version"]) == ("1", "2"), f"{v1['Version']}, {v2['Version']}")
        al = p.call("CreateAlias(live → v1, v2 10% 가중치)", lam.create_alias, FunctionName=fn, Name="live",
                    FunctionVersion=v1["Version"],
                    RoutingConfig={"AdditionalVersionWeights": {v2["Version"]: 0.1}})
        if al:
            g = lam.get_alias(FunctionName=fn, Name="live")
            p.behavior("별칭 라우팅 가중치가 저장됨", g.get("RoutingConfig", {}).get("AdditionalVersionWeights") == {"2": 0.1},
                       json.dumps(g.get("RoutingConfig")))
    p.call("ListVersionsByFunction", lam.list_versions_by_function, FunctionName=fn)
    p.call("PutFunctionConcurrency(5)", lam.put_function_concurrency, FunctionName=fn, ReservedConcurrentExecutions=5)
    p.call("PutProvisionedConcurrencyConfig(live, 1)", lam.put_provisioned_concurrency_config, FunctionName=fn,
           Qualifier="live", ProvisionedConcurrentExecutions=1)
    p.call("GetAccountSettings", lam.get_account_settings)

    # Invoke
    inv = p.call("Invoke(RequestResponse)", lam.invoke, FunctionName=fn, Payload=json.dumps({"orderId": "o-1"}).encode())
    if inv:
        body = inv["Payload"].read().decode()
        p.behavior("Invoke가 핸들러를 실제로 실행해 결과 반환", "o-1" in body and inv.get("StatusCode") == 200,
                   f"StatusCode={inv.get('StatusCode')} FunctionError={inv.get('FunctionError')} payload={body[:120]}")
    bad = p.name("boom")[:64]
    if p.call("CreateFunction(예외를 던지는 핸들러)", lam.create_function, FunctionName=bad, Runtime="python3.12", Role=role,
              Handler="app.handler", Code={"ZipFile": _zip("def handler(e, c):\n    raise ValueError('boom')\n")}) is not None:
        p.cleanup("bad", lambda: lam.delete_function(FunctionName=bad))
        wait_until(lambda: lam.get_function(FunctionName=bad)["Configuration"].get("State") == "Active", timeout=20)
        bi = p.call("Invoke(예외)", lam.invoke, FunctionName=bad, Payload=b"{}")
        if bi:
            bp = bi["Payload"].read().decode()
            p.behavior("핸들러 예외 → FunctionError=Unhandled, errorType 반환", bi.get("FunctionError") == "Unhandled" and "ValueError" in bp,
                       f"FunctionError={bi.get('FunctionError')} payload={bp[:100]}")
    logs = p.client("logs")
    lg = wait_until(lambda: bool(logs.describe_log_groups(logGroupNamePrefix=f"/aws/lambda/{fn}")["logGroups"]), timeout=10)
    p.behavior("Invoke 후 /aws/lambda/<함수> 로그 그룹이 생김(실행 역할에 logs:* 권한이 있을 때)", lg)
    dry = p.call("Invoke(DryRun)", lam.invoke, FunctionName=fn, InvocationType="DryRun")
    if dry:
        p.behavior("DryRun은 204 반환(실행 없이 권한·파라미터만 검사)", dry.get("StatusCode") == 204, f"StatusCode={dry.get('StatusCode')}")
    ev = p.call("Invoke(Event, 비동기)", lam.invoke, FunctionName=fn, InvocationType="Event", Payload=b"{}")
    if ev:
        p.behavior("비동기 Invoke는 202 반환", ev.get("StatusCode") == 202, f"StatusCode={ev.get('StatusCode')}")
    p.expect_error("Invoke(없는 함수)", lam.invoke, "ResourceNotFoundException", FunctionName=p.name("nope")[:64],
                   what="없는 함수 Invoke → ResourceNotFoundException")

    # 이벤트 소스 매핑 SQS → Lambda
    q = sqs.create_queue(QueueName=p.name("esm"), Attributes={"VisibilityTimeout": "60"})
    qurl = q["QueueUrl"]
    p.cleanup("q", lambda: sqs.delete_queue(QueueUrl=qurl))
    qarn = sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    p.expect_error("CreateEventSourceMapping(큐 가시성 60s < 함수 타임아웃 900s)", lam.create_event_source_mapping,
                   "InvalidParameterValueException", EventSourceArn=qarn, FunctionName=fn,
                   what="큐 가시성 타임아웃이 함수 타임아웃보다 짧으면 매핑 거부")
    sqs.set_queue_attributes(QueueUrl=qurl, Attributes={"VisibilityTimeout": "900"})
    esm = p.call("CreateEventSourceMapping(SQS)", lam.create_event_source_mapping, EventSourceArn=qarn,
                 FunctionName=fn, BatchSize=5)
    if esm:
        uid = esm["UUID"]
        p.cleanup("esm", lambda: lam.delete_event_source_mapping(UUID=uid))
        en = wait_until(lambda: lam.get_event_source_mapping(UUID=uid)["State"] == "Enabled", timeout=15)
        p.behavior("이벤트 소스 매핑 상태 Creating → Enabled", en, lam.get_event_source_mapping(UUID=uid)["State"])
        sqs.send_message(QueueUrl=qurl, MessageBody=json.dumps({"orderId": "esm-1"}))
        consumed = wait_until(lambda: int(sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["All"])["Attributes"]
                                          ["ApproximateNumberOfMessages"]) == 0
                              and int(sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["All"])["Attributes"]
                                      ["ApproximateNumberOfMessagesNotVisible"]) == 0, timeout=20, interval=1)
        a = sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["All"])["Attributes"]
        p.behavior("SQS 메시지가 매핑을 통해 Lambda로 소비되어 큐에서 사라짐", consumed,
                   f"visible={a['ApproximateNumberOfMessages']} inflight={a['ApproximateNumberOfMessagesNotVisible']}")
        p.call("UpdateEventSourceMapping(Enabled=False)", lam.update_event_source_mapping, UUID=uid, Enabled=False)

    p.call("AddPermission(s3.amazonaws.com)", lam.add_permission, FunctionName=fn, StatementId="s3invoke",
           Action="lambda:InvokeFunction", Principal="s3.amazonaws.com", SourceArn="arn:aws:s3:::todayorder-images")
    pol = p.call("GetPolicy(리소스 기반 정책)", lam.get_policy, FunctionName=fn)
    if pol:
        p.behavior("AddPermission이 리소스 기반 정책에 반영", "s3invoke" in pol.get("Policy", ""))
    lay = p.call("PublishLayerVersion", lam.publish_layer_version, LayerName=p.name("layer")[:64],
                 Content={"ZipFile": _zip("x = 1\n")}, CompatibleRuntimes=["python3.12"])
    if lay:
        p.call("UpdateFunctionConfiguration(Layers)", lam.update_function_configuration, FunctionName=fn,
               Layers=[lay["LayerVersionArn"]])
        wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("LastUpdateStatus") != "InProgress", timeout=10)
    url = p.call("CreateFunctionUrlConfig(AuthType=NONE)", lam.create_function_url_config, FunctionName=fn, AuthType="NONE")
    if url:
        p.behavior("함수 URL 발급", bool(url.get("FunctionUrl")), url.get("FunctionUrl", ""))
    dq = sqs.create_queue(QueueName=p.name("dest"))
    p.cleanup("dq", lambda: sqs.delete_queue(QueueUrl=dq["QueueUrl"]))
    darn = sqs.get_queue_attributes(QueueUrl=dq["QueueUrl"], AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    p.call("PutFunctionEventInvokeConfig(OnFailure → SQS)", lam.put_function_event_invoke_config, FunctionName=fn,
           MaximumRetryAttempts=1, DestinationConfig={"OnFailure": {"Destination": darn}})
    p.call("ListFunctions", lam.list_functions)


# ---------------------------------------------------------------- API Gateway v1 (REST)
def run_apigateway(p: Probe) -> None:
    ag = p.client("apigateway")
    api = p.call("CreateRestApi(REGIONAL)", ag.create_rest_api, name=p.name("rest"), endpointConfiguration={"types": ["REGIONAL"]})
    if not api:
        p.skip("REST API 동작", "CreateRestApi 실패")
        return
    api_id = api["id"]
    p.cleanup("api", lambda: ag.delete_rest_api(restApiId=api_id))
    res = p.call("GetResources", ag.get_resources, restApiId=api_id)
    root = next((r["id"] for r in (res or {}).get("items", []) if r["path"] == "/"), None)
    if not root:
        p.skip("리소스", "루트 리소스 없음")
        return
    orders = p.call("CreateResource(/orders)", ag.create_resource, restApiId=api_id, parentId=root, pathPart="orders")
    if not orders:
        return
    rid = orders["id"]
    p.call("PutMethod(GET, NONE)", ag.put_method, restApiId=api_id, resourceId=rid, httpMethod="GET", authorizationType="NONE",
           apiKeyRequired=False)
    p.call("PutIntegration(MOCK)", ag.put_integration, restApiId=api_id, resourceId=rid, httpMethod="GET", type="MOCK",
           requestTemplates={"application/json": '{"statusCode": 200}'})
    p.call("PutMethodResponse(200)", ag.put_method_response, restApiId=api_id, resourceId=rid, httpMethod="GET", statusCode="200")
    p.call("PutIntegrationResponse(200)", ag.put_integration_response, restApiId=api_id, resourceId=rid, httpMethod="GET",
           statusCode="200", responseTemplates={"application/json": '{"orders": ["o-1", "o-2"]}'})
    dep = p.call("CreateDeployment(stage=dev)", ag.create_deployment, restApiId=api_id, stageName="dev")
    if dep:
        p.call("GetStage", ag.get_stage, restApiId=api_id, stageName="dev")
        p.call("UpdateStage(스로틀링 100rps/200burst)", ag.update_stage, restApiId=api_id, stageName="dev", patchOperations=[
            {"op": "replace", "path": "/*/*/throttling/rateLimit", "value": "100"},
            {"op": "replace", "path": "/*/*/throttling/burstLimit", "value": "200"}])
        p.call("TestInvokeMethod", ag.test_invoke_method, restApiId=api_id, resourceId=rid, httpMethod="GET", pathWithQueryString="/orders")
        port = os.environ["AWS_ENDPOINT_URL"].rsplit(":", 1)[-1]
        tried = []
        hit = None
        for u in (f"https://127.0.0.1:{port}/restapis/{api_id}/dev/_user_request_/orders",
                  f"https://127.0.0.1:{port}/_aws/execute-api/{api_id}/dev/orders",
                  f"https://127.0.0.1:{port}/dev/orders"):
            try:
                code, body = _https(u)
            except Exception as e:  # noqa: BLE001
                code, body = -1, f"{type(e).__name__}: {e}"
            tried.append(f"{u.split(port, 1)[1]}→{code}")
            if code == 200 and "o-1" in body:
                hit = u
                break
        # 호스트 기반: <api-id>.execute-api.<region>.amazonaws.com 을 Host 헤더로
        if not hit:
            try:
                code, body = _https(f"https://127.0.0.1:{port}/dev/orders",
                                    headers={"Host": f"{api_id}.execute-api.us-east-1.amazonaws.com"})
            except Exception as e:  # noqa: BLE001
                code, body = -1, str(e)
            tried.append(f"Host 헤더 방식→{code}")
            if code == 200 and "o-1" in body:
                hit = "Host: <id>.execute-api.us-east-1.amazonaws.com + /dev/orders"
        p.behavior("배포된 REST API(MOCK)를 HTTPS로 실제 호출", bool(hit), f"성공 URL={hit}" if hit else "; ".join(tried)[:280])
    # 사용량 계획 + API 키
    key = p.call("CreateApiKey", ag.create_api_key, name=p.name("key"), enabled=True)
    plan = p.call("CreateUsagePlan(throttle+quota)", ag.create_usage_plan, name=p.name("plan"),
                  apiStages=[{"apiId": api_id, "stage": "dev"}] if dep else [],
                  throttle={"rateLimit": 10, "burstLimit": 20}, quota={"limit": 1000, "period": "DAY"})
    if key and plan:
        p.cleanup("plan", lambda: ag.delete_usage_plan(usagePlanId=plan["id"]))
        p.cleanup("key", lambda: ag.delete_api_key(apiKey=key["id"]))
        p.call("CreateUsagePlanKey", ag.create_usage_plan_key, usagePlanId=plan["id"], keyId=key["id"], keyType="API_KEY")
    p.call("CreateAuthorizer(COGNITO_USER_POOLS)", ag.create_authorizer, restApiId=api_id, name="cognito",
           type="COGNITO_USER_POOLS", providerARNs=["arn:aws:cognito-idp:us-east-1:000000000000:userpool/us-east-1_example"],
           identitySource="method.request.header.Authorization")


# ---------------------------------------------------------------- API Gateway v2 (HTTP / WebSocket)
def run_apigatewayv2(p: Probe) -> None:
    ag = p.client("apigatewayv2")
    api = p.call("CreateApi(HTTP)", ag.create_api, Name=p.name("http"), ProtocolType="HTTP")
    if api:
        aid = api["ApiId"]
        p.cleanup("http", lambda: ag.delete_api(ApiId=aid))
        p.behavior("HTTP API 엔드포인트 URL 발급", bool(api.get("ApiEndpoint")), api.get("ApiEndpoint", ""))
        integ = p.call("CreateIntegration(HTTP_PROXY)", ag.create_integration, ApiId=aid, IntegrationType="HTTP_PROXY",
                       IntegrationMethod="GET", IntegrationUri="https://orders.todayorder.invalid/orders", PayloadFormatVersion="1.0")
        if integ:
            p.call("CreateRoute(GET /orders)", ag.create_route, ApiId=aid, RouteKey="GET /orders",
                   Target=f"integrations/{integ['IntegrationId']}")
        p.call("CreateStage($default, AutoDeploy)", ag.create_stage, ApiId=aid, StageName="$default", AutoDeploy=True)
        p.call("GetRoutes", ag.get_routes, ApiId=aid)
        p.call("CreateAuthorizer(JWT)", ag.create_authorizer, ApiId=aid, Name="jwt", AuthorizerType="JWT",
               IdentitySource=["$request.header.Authorization"],
               JwtConfiguration={"Audience": ["client"], "Issuer": "https://issuer.todayorder.invalid/us-east-1_example"})
    # HTTP API → Lambda 프록시 통합을 실제로 호출
    lam = p.client("lambda")
    fn = p.name("apifn")[:64]
    role = _role(p, "apifnrole", "lambda.amazonaws.com")
    f = p.call("CreateFunction(API용)", lam.create_function, FunctionName=fn, Runtime="python3.12", Role=role,
               Handler="app.handler", Code={"ZipFile": _zip()}, Environment={"Variables": {"STAGE": "api"}})
    papi = p.call("CreateApi(HTTP, Lambda 프록시)", ag.create_api, Name=p.name("httplam"), ProtocolType="HTTP")
    if f and papi:
        p.cleanup("apifn", lambda: lam.delete_function(FunctionName=fn))
        pid = papi["ApiId"]
        p.cleanup("papi", lambda: ag.delete_api(ApiId=pid))
        wait_until(lambda: lam.get_function(FunctionName=fn)["Configuration"].get("State") == "Active", timeout=20)
        pi = p.call("CreateIntegration(AWS_PROXY → Lambda, 2.0)", ag.create_integration, ApiId=pid, IntegrationType="AWS_PROXY",
                    IntegrationUri=f["FunctionArn"], PayloadFormatVersion="2.0")
        if pi:
            ag.create_route(ApiId=pid, RouteKey="GET /orders", Target=f"integrations/{pi['IntegrationId']}")
            ag.create_stage(ApiId=pid, StageName="$default", AutoDeploy=True)
            try:
                code, body = _https(papi["ApiEndpoint"] + "/orders?id=7")
            except Exception as e:  # noqa: BLE001
                code, body = -1, str(e)
            p.behavior("HTTP API → Lambda 프록시를 HTTPS로 호출하면 함수가 실행되어 응답 (AddPermission 없이도 성공)",
                       code == 200 and '"routeKey": "GET /orders"' in body,
                       f"{papi['ApiEndpoint']}/orders → {code} {body[:90]}")
            if code == 200:
                logs = p.client("logs")
                time.sleep(2)
                no_lg = not logs.describe_log_groups(logGroupNamePrefix=f"/aws/lambda/{fn}")["logGroups"]
                p.behavior("실행 역할에 logs 권한이 없으면 /aws/lambda/<함수> 로그 그룹이 생기지 않음(AWS와 동일)", no_lg,
                           "생기지 않음" if no_lg else "생겼다")
    ws = p.call("CreateApi(WEBSOCKET)", ag.create_api, Name=p.name("ws"), ProtocolType="WEBSOCKET",
                RouteSelectionExpression="$request.body.action")
    if ws:
        wid = ws["ApiId"]
        p.cleanup("ws", lambda: ag.delete_api(ApiId=wid))
        p.call("CreateRoute($connect)", ag.create_route, ApiId=wid, RouteKey="$connect")


# ---------------------------------------------------------------- ECR
def run_ecr(p: Probe) -> None:
    ecr = p.client("ecr")
    name = p.name("api")
    r = p.call("CreateRepository(scanOnPush, IMMUTABLE)", ecr.create_repository, repositoryName=name,
               imageScanningConfiguration={"scanOnPush": True}, imageTagMutability="IMMUTABLE")
    if not r:
        return
    p.cleanup("repo", lambda: ecr.delete_repository(repositoryName=name, force=True))
    p.behavior("저장소 URI 발급", bool(r["repository"].get("repositoryUri")), r["repository"].get("repositoryUri", ""))
    p.call("PutLifecyclePolicy", ecr.put_lifecycle_policy, repositoryName=name, lifecyclePolicyText=json.dumps({"rules": [{
        "rulePriority": 1, "description": "keep 10", "selection": {"tagStatus": "any", "countType": "imageCountMoreThan",
                                                                    "countNumber": 10}, "action": {"type": "expire"}}]}))
    p.call("GetLifecyclePolicy", ecr.get_lifecycle_policy, repositoryName=name)
    p.call("PutImageScanningConfiguration", ecr.put_image_scanning_configuration, repositoryName=name,
           imageScanningConfiguration={"scanOnPush": False})
    p.call("GetAuthorizationToken", ecr.get_authorization_token)
    p.call("DescribeImages", ecr.describe_images, repositoryName=name)
    p.call("SetRepositoryPolicy", ecr.set_repository_policy, repositoryName=name, policyText=json.dumps({
        "Version": "2012-10-17", "Statement": [{"Sid": "pull", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::000000000000:root"},
                                                "Action": ["ecr:BatchGetImage"]}]}))


# ---------------------------------------------------------------- ECS
def run_ecs(p: Probe) -> None:
    ecs, ec2 = p.client("ecs"), p.client("ec2")
    cl = p.name("cluster")
    if p.call("CreateCluster(FARGATE 용량 공급자)", ecs.create_cluster, clusterName=cl,
              capacityProviders=["FARGATE", "FARGATE_SPOT"]) is None:
        p.skip("ECS 동작", "CreateCluster 실패")
        return
    p.cleanup("cluster", lambda: ecs.delete_cluster(cluster=cl))
    exec_role = _role(p, "ecsexec", "ecs-tasks.amazonaws.com", ["ecr:*", "logs:*"])
    td = p.call("RegisterTaskDefinition(Fargate, awsvpc)", ecs.register_task_definition, family=p.name("api"),
                requiresCompatibilities=["FARGATE"], networkMode="awsvpc", cpu="256", memory="512",
                executionRoleArn=exec_role,
                containerDefinitions=[{"name": "api", "image": "registry.invalid/todayorder/nginx:latest", "essential": True,
                                       "portMappings": [{"containerPort": 80, "protocol": "tcp"}]}])
    if not td:
        return
    td_arn = td["taskDefinition"]["taskDefinitionArn"]
    p.cleanup("td", lambda: ecs.deregister_task_definition(taskDefinition=td_arn))
    vpc = ec2.create_vpc(CidrBlock="10.90.0.0/16")["Vpc"]["VpcId"]
    sub = ec2.create_subnet(VpcId=vpc, CidrBlock="10.90.1.0/24")["Subnet"]["SubnetId"]
    p.cleanup("vpc", lambda: (ec2.delete_subnet(SubnetId=sub), ec2.delete_vpc(VpcId=vpc)))
    net = {"awsvpcConfiguration": {"subnets": [sub], "assignPublicIp": "DISABLED"}}
    svc = p.call("CreateService(desired=2, FARGATE)", ecs.create_service, cluster=cl, serviceName="api", taskDefinition=td_arn,
                 desiredCount=2, launchType="FARGATE", networkConfiguration=net)
    if svc:
        def _rm() -> None:
            ecs.update_service(cluster=cl, service="api", desiredCount=0)
            ecs.delete_service(cluster=cl, service="api", force=True)
        p.cleanup("svc", _rm)
        ok = wait_until(lambda: len(ecs.list_tasks(cluster=cl, serviceName="api")["taskArns"]) >= 2, timeout=20)
        tasks = ecs.list_tasks(cluster=cl, serviceName="api")["taskArns"]
        status = [t["lastStatus"] for t in ecs.describe_tasks(cluster=cl, tasks=tasks)["tasks"]] if tasks else []
        p.behavior("서비스가 desiredCount만큼 태스크를 만듦", ok, f"lastStatus={status}")
        p.call("UpdateService(desired=3)", ecs.update_service, cluster=cl, service="api", desiredCount=3)
    rt = p.call("RunTask(FARGATE)", ecs.run_task, cluster=cl, taskDefinition=td_arn, launchType="FARGATE", networkConfiguration=net)
    if rt and rt.get("tasks"):
        tarn = rt["tasks"][0]["taskArn"]
        p.cleanup("task", lambda: ecs.stop_task(cluster=cl, task=tarn))
        seen: list[str] = []

        def settled() -> bool:
            t = ecs.describe_tasks(cluster=cl, tasks=[tarn])["tasks"][0]
            if not seen or seen[-1] != t["lastStatus"]:
                seen.append(t["lastStatus"])
            return t["lastStatus"] in ("RUNNING", "STOPPED")
        wait_until(settled, timeout=30, interval=1)
        t = ecs.describe_tasks(cluster=cl, tasks=[tarn])["tasks"][0]
        p.behavior("RunTask 태스크가 RUNNING까지 전이 (실제로 이미지를 받아 실행하려 함)", t["lastStatus"] == "RUNNING",
                   f"전이 {' → '.join(seen)}; stoppedReason={str(t.get('stoppedReason'))[:110]}")
    p.call("ListClusters", ecs.list_clusters)


# ---------------------------------------------------------------- Cognito
def run_cognito(p: Probe) -> None:
    idp = p.client("cognito-idp")
    pool = p.call("CreateUserPool", idp.create_user_pool, PoolName=p.name("users"), AutoVerifiedAttributes=["email"],
                  UsernameAttributes=["email"], Policies={"PasswordPolicy": {"MinimumLength": 8}})
    if not pool:
        p.skip("Cognito 동작", "CreateUserPool 실패")
        return
    pid = pool["UserPool"]["Id"]
    p.cleanup("pool", lambda: idp.delete_user_pool(UserPoolId=pid))
    cl = p.call("CreateUserPoolClient(USER_PASSWORD_AUTH)", idp.create_user_pool_client, UserPoolId=pid, ClientName="web",
                ExplicitAuthFlows=["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"])
    p.call("AdminCreateUser", idp.admin_create_user, UserPoolId=pid, Username="admin@example.com",
           TemporaryPassword="Temp-Pass-123!", MessageAction="SUPPRESS")
    if not cl:
        return
    cid = cl["UserPoolClient"]["ClientId"]
    su = p.call("SignUp", idp.sign_up, ClientId=cid, Username="user@example.com", Password="User-Pass-123!",
                UserAttributes=[{"Name": "email", "Value": "user@example.com"}])
    if su:
        p.behavior("SignUp 직후 미확인 상태", su.get("UserConfirmed") is False, f"UserConfirmed={su.get('UserConfirmed')}")
        p.expect_error("InitiateAuth(미확인 사용자)", idp.initiate_auth, "UserNotConfirmedException", ClientId=cid,
                       AuthFlow="USER_PASSWORD_AUTH", AuthParameters={"USERNAME": "user@example.com", "PASSWORD": "User-Pass-123!"},
                       what="확인 전 로그인 → UserNotConfirmedException")
        p.call("AdminConfirmSignUp", idp.admin_confirm_sign_up, UserPoolId=pid, Username="user@example.com")
        auth = p.call("InitiateAuth(USER_PASSWORD_AUTH)", idp.initiate_auth, ClientId=cid, AuthFlow="USER_PASSWORD_AUTH",
                      AuthParameters={"USERNAME": "user@example.com", "PASSWORD": "User-Pass-123!"})
        if auth:
            ar = auth.get("AuthenticationResult", {})
            idt = ar.get("IdToken", "")
            p.behavior("로그인 성공 시 JWT(Id/Access/Refresh 토큰) 발급", idt.count(".") == 2 and bool(ar.get("AccessToken"))
                       and bool(ar.get("RefreshToken")), f"IdToken {len(idt)}자, ExpiresIn={ar.get('ExpiresIn')}")
            if ar.get("AccessToken"):
                p.call("GetUser(AccessToken)", idp.get_user, AccessToken=ar["AccessToken"])
        p.expect_error("InitiateAuth(틀린 비밀번호)", idp.initiate_auth, "NotAuthorizedException", ClientId=cid,
                       AuthFlow="USER_PASSWORD_AUTH", AuthParameters={"USERNAME": "user@example.com", "PASSWORD": "Wrong-Pass-1!"},
                       what="틀린 비밀번호 → NotAuthorizedException")
    p.call("CreateGroup", idp.create_group, UserPoolId=pid, GroupName="admins")
    ci = p.client("cognito-identity")
    ipool = p.call("CreateIdentityPool", ci.create_identity_pool, IdentityPoolName=p.name("ids").replace("-", "_"),
                   AllowUnauthenticatedIdentities=True,
                   CognitoIdentityProviders=[{"ProviderName": f"cognito-idp.us-east-1.amazonaws.com/{pid}", "ClientId": cid}])
    if ipool:
        ipid = ipool["IdentityPoolId"]
        p.cleanup("ipool", lambda: ci.delete_identity_pool(IdentityPoolId=ipid))
        iam = p.client("iam")
        rname = p.name("cogunauth")
        unauth = iam.create_role(RoleName=rname, AssumeRolePolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [{
            "Effect": "Allow", "Principal": {"Federated": "cognito-identity.amazonaws.com"},
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {"StringEquals": {"cognito-identity.amazonaws.com:aud": ipid},
                          "ForAnyValue:StringLike": {"cognito-identity.amazonaws.com:amr": "unauthenticated"}}}]}))["Role"]["Arn"]
        p.cleanup("cogrole", lambda: iam.delete_role(RoleName=rname))
        p.call("SetIdentityPoolRoles", ci.set_identity_pool_roles, IdentityPoolId=ipid,
               Roles={"unauthenticated": unauth, "authenticated": unauth})
        gid = p.call("GetId(비인증)", ci.get_id, IdentityPoolId=ipid)
        if gid:
            cr = p.call("GetCredentialsForIdentity", ci.get_credentials_for_identity, IdentityId=gid["IdentityId"])
            if cr:
                p.behavior("자격 증명 풀이 임시 AWS 자격 증명 발급", bool(cr.get("Credentials", {}).get("SessionToken")))


CHECKS = {
    "lambda": run_lambda,
    "apigateway": run_apigateway,
    "apigatewayv2": run_apigatewayv2,
    "ecr": run_ecr,
    "ecs": run_ecs,
    "cognito": run_cognito,
}
