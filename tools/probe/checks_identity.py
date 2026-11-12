"""M01: IAM / STS / Organizations 그리고 클라이언트 설정(엔드포인트) 관련 탐침."""

from __future__ import annotations

import json
import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError

from lib import Probe

ASSUME_DOC = json.dumps({
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::000000000000:root"}, "Action": "sts:AssumeRole"}],
})


def _policy(effect: str, action: str, resource: str = "*") -> str:
    return json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": effect, "Action": action, "Resource": resource}]})


def run_iam(p: Probe) -> None:
    iam = p.client("iam")
    user, group, role = p.name("user"), p.name("group"), p.name("role")

    if p.call("CreateUser", iam.create_user, UserName=user) is not None:
        p.cleanup("user", lambda: iam.delete_user(UserName=user))
    if p.call("CreateGroup", iam.create_group, GroupName=group) is not None:
        p.cleanup("group", lambda: iam.delete_group(GroupName=group))
    if p.call("AddUserToGroup", iam.add_user_to_group, GroupName=group, UserName=user) is not None:
        p.cleanup("ug", lambda: iam.remove_user_from_group(GroupName=group, UserName=user))

    pol = p.call("CreatePolicy", iam.create_policy, PolicyName=p.name("s3read"),
                 PolicyDocument=_policy("Allow", "s3:GetObject"))
    pol_arn = pol["Policy"]["Arn"] if pol else None
    if pol_arn:
        p.cleanup("policy", lambda: iam.delete_policy(PolicyArn=pol_arn))
        if p.call("AttachGroupPolicy", iam.attach_group_policy, GroupName=group, PolicyArn=pol_arn) is not None:
            p.cleanup("agp", lambda: iam.detach_group_policy(GroupName=group, PolicyArn=pol_arn))
        p.call("CreatePolicyVersion", iam.create_policy_version, PolicyArn=pol_arn,
               PolicyDocument=_policy("Allow", "s3:*"), SetAsDefault=True)
        p.call("ListPolicyVersions", iam.list_policy_versions, PolicyArn=pol_arn)
    p.call("ListAttachedGroupPolicies", iam.list_attached_group_policies, GroupName=group)
    p.call("PutUserPolicy (인라인)", iam.put_user_policy, UserName=user, PolicyName="inline",
           PolicyDocument=_policy("Allow", "sqs:SendMessage"))
    p.cleanup("inline", lambda: iam.delete_user_policy(UserName=user, PolicyName="inline"))
    p.call("PutUserPermissionsBoundary", iam.put_user_permissions_boundary, UserName=user,
           PermissionsBoundary="arn:aws:iam::aws:policy/ReadOnlyAccess")
    p.call("CreateLoginProfile", iam.create_login_profile, UserName=user, Password="Todayorder-Pass-123!")
    p.cleanup("lp", lambda: iam.delete_login_profile(UserName=user))
    p.call("CreateVirtualMFADevice", iam.create_virtual_mfa_device, VirtualMFADeviceName=p.name("mfa"))
    p.call("GetAccountPasswordPolicy/UpdateAccountPasswordPolicy", iam.update_account_password_policy,
           MinimumPasswordLength=14, RequireSymbols=True)
    p.call("GetPolicy (AWS 관리형 ReadOnlyAccess)", iam.get_policy, PolicyArn="arn:aws:iam::aws:policy/ReadOnlyAccess")
    p.call("GenerateCredentialReport", iam.generate_credential_report)

    r = p.call("CreateRole", iam.create_role, RoleName=role, AssumeRolePolicyDocument=ASSUME_DOC)
    role_arn = r["Role"]["Arn"] if r else None
    if r:
        p.cleanup("role", lambda: iam.delete_role(RoleName=role))
    p.call("PutRolePolicy", iam.put_role_policy, RoleName=role, PolicyName="inline",
           PolicyDocument=_policy("Allow", "s3:ListAllMyBuckets"))
    p.cleanup("rp", lambda: iam.delete_role_policy(RoleName=role, PolicyName="inline"))
    ip = p.name("ip")
    if p.call("CreateInstanceProfile", iam.create_instance_profile, InstanceProfileName=ip) is not None:
        p.cleanup("ip", lambda: iam.delete_instance_profile(InstanceProfileName=ip))
        if p.call("AddRoleToInstanceProfile", iam.add_role_to_instance_profile, InstanceProfileName=ip, RoleName=role) is not None:
            p.cleanup("ipr", lambda: iam.remove_role_from_instance_profile(InstanceProfileName=ip, RoleName=role))

    # 정책 시뮬레이터
    sim = p.call("SimulateCustomPolicy", iam.simulate_custom_policy,
                 PolicyInputList=[_policy("Allow", "s3:*"), _policy("Deny", "s3:DeleteBucket")],
                 ActionNames=["s3:GetObject", "s3:DeleteBucket", "ec2:RunInstances"])
    if sim:
        got = {e["EvalActionName"]: e["EvalDecision"] for e in sim["EvaluationResults"]}
        want = {"s3:GetObject": "allowed", "s3:DeleteBucket": "explicitDeny", "ec2:RunInstances": "implicitDeny"}
        p.behavior("SimulateCustomPolicy가 명시적 Deny/암묵적 Deny를 판정", got == want, f"결과 {got}")
    if pol_arn:
        sim2 = p.call("SimulatePrincipalPolicy", iam.simulate_principal_policy,
                      PolicySourceArn=f"arn:aws:iam::000000000000:user/{user}",
                      ActionNames=["s3:GetObject", "ec2:RunInstances"])
        if sim2:
            got = {e["EvalActionName"]: e["EvalDecision"] for e in sim2["EvaluationResults"]}
            p.behavior("SimulatePrincipalPolicy가 그룹 정책을 반영", got.get("s3:GetObject") == "allowed"
                       and got.get("ec2:RunInstances") == "implicitDeny", f"결과 {got}")

    # 정책이 실제로 집행되는가: 권한 없는 사용자의 키로 호출
    keys = p.call("CreateAccessKey", iam.create_access_key, UserName=user)
    if keys:
        ak = keys["AccessKey"]
        p.cleanup("ak", lambda: iam.delete_access_key(UserName=user, AccessKeyId=ak["AccessKeyId"]))
        sess = boto3.session.Session(aws_access_key_id=ak["AccessKeyId"], aws_secret_access_key=ak["SecretAccessKey"],
                                     region_name="us-east-1")
        cfg = Config(retries={"max_attempts": 1})
        who = sess.client("sts", config=cfg).get_caller_identity()
        p.behavior("IAM 사용자 액세스 키로 서명한 요청을 받아 줌", who["Arn"].endswith(f"user/{user}"), who["Arn"])
        # 이 사용자는 s3:GetObject/s3:*, sqs:SendMessage 만 허용(그룹/인라인). ec2/iam 은 암묵적 Deny 여야 한다.
        try:
            sess.client("iam", config=cfg).create_user(UserName=p.name("escalate"))
            iam.delete_user(UserName=p.name("escalate"))
            p.behavior("권한 없는 사용자의 iam:CreateUser가 거부됨(암묵적 Deny)", False,
                       "허용됨 — IAM 정책이 집행되지 않는다")
        except ClientError as e:
            p.behavior("권한 없는 사용자의 iam:CreateUser가 거부됨(암묵적 Deny)", e.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException"),
                       e.response["Error"]["Code"])
        # S3 는 IAM 정책을 평가하는가: 권한이 전혀 없는 두 번째 사용자로 S3/SQS/DynamoDB 호출
        u2 = p.name("noperm")
        iam.create_user(UserName=u2)
        k2 = iam.create_access_key(UserName=u2)["AccessKey"]
        p.cleanup("u2", lambda: (iam.delete_access_key(UserName=u2, AccessKeyId=k2["AccessKeyId"]), iam.delete_user(UserName=u2)))
        s2 = boto3.session.Session(aws_access_key_id=k2["AccessKeyId"], aws_secret_access_key=k2["SecretAccessKey"],
                                   region_name="us-east-1")
        for svc, label, fn in (
            ("s3", "s3:ListAllMyBuckets", lambda c: c.list_buckets()),
            ("sqs", "sqs:ListQueues", lambda c: c.list_queues()),
            ("dynamodb", "dynamodb:ListTables", lambda c: c.list_tables()),
            ("ec2", "ec2:DescribeVpcs", lambda c: c.describe_vpcs()),
            ("iam", "iam:ListUsers", lambda c: c.list_users()),
            ("kms", "kms:ListKeys", lambda c: c.list_keys()),
        ):
            name = f"정책 없는 사용자의 {label} 거부(암묵적 Deny)"
            try:
                fn(s2.client(svc, config=cfg))
                p.behavior(name, False, "허용됨 — 이 서비스는 IAM 정책을 평가하지 않는다")
            except ClientError as e:
                code = e.response["Error"]["Code"]
                p.behavior(name, "AccessDenied" in code or code == "UnauthorizedOperation", code)
        # 명시적 Deny가 Allow를 이기는가 (IAM 자체 액션으로)
        iam.put_user_policy(UserName=user, PolicyName="allow-iam-list", PolicyDocument=_policy("Allow", "iam:ListUsers"))
        p.cleanup("ail", lambda: iam.delete_user_policy(UserName=user, PolicyName="allow-iam-list"))
        uiam = sess.client("iam", config=cfg)
        try:
            uiam.list_users()
            p.behavior("Allow iam:ListUsers 를 붙이면 허용됨", True, "허용")
        except ClientError as e:
            p.behavior("Allow iam:ListUsers 를 붙이면 허용됨", False, e.response["Error"]["Code"])
        iam.put_user_policy(UserName=user, PolicyName="deny-iam-list", PolicyDocument=_policy("Deny", "iam:ListUsers"))
        p.cleanup("dil", lambda: iam.delete_user_policy(UserName=user, PolicyName="deny-iam-list"))
        try:
            uiam.list_users()
            p.behavior("명시적 Deny iam:ListUsers 가 Allow를 이김", False, "허용됨")
        except ClientError as e:
            p.behavior("명시적 Deny iam:ListUsers 가 Allow를 이김", "AccessDenied" in e.response["Error"]["Code"], e.response["Error"]["Code"])
        # 명시적 Deny
        iam.put_user_policy(UserName=user, PolicyName="deny-s3", PolicyDocument=_policy("Deny", "s3:*"))
        p.cleanup("deny", lambda: iam.delete_user_policy(UserName=user, PolicyName="deny-s3"))
        try:
            sess.client("s3", config=cfg).list_buckets()
            p.behavior("명시적 Deny(s3:*)가 ListBuckets를 막음", False, "허용됨 — 명시적 Deny도 집행되지 않는다")
        except ClientError as e:
            p.behavior("명시적 Deny(s3:*)가 ListBuckets를 막음", e.response["Error"]["Code"] in ("AccessDenied",),
                       e.response["Error"]["Code"])


def run_sts(p: Probe) -> None:
    sts, iam = p.client("sts"), p.client("iam")
    who = p.call("GetCallerIdentity", sts.get_caller_identity)
    if who:
        p.behavior("계정 ID가 000000000000", who["Account"] == "000000000000", who["Arn"])
    role = p.name("assume")
    r = p.call("CreateRole(사전)", iam.create_role, RoleName=role, AssumeRolePolicyDocument=ASSUME_DOC)
    if r:
        p.cleanup("role", lambda: iam.delete_role(RoleName=role))
        cred = p.call("AssumeRole", sts.assume_role, RoleArn=r["Role"]["Arn"], RoleSessionName="probe", DurationSeconds=900)
        if cred:
            c = cred["Credentials"]
            p.behavior("AssumeRole 임시 자격 증명(SessionToken, Expiration 포함)",
                       bool(c.get("SessionToken")) and "Expiration" in c,
                       f"AccessKeyId 접두사={c['AccessKeyId'][:4]} (실제 AWS는 ASIA)")
            s2 = boto3.client("sts", aws_access_key_id=c["AccessKeyId"], aws_secret_access_key=c["SecretAccessKey"],
                              aws_session_token=c["SessionToken"], region_name="us-east-1")
            who2 = s2.get_caller_identity()
            p.behavior("임시 자격 증명으로 호출하면 assumed-role ARN", ":assumed-role/" in who2["Arn"], who2["Arn"])
        # 신뢰 정책이 허용하지 않는 주체
        deny_trust = json.dumps({"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
                                 "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]})
        role2 = p.name("ec2only")
        r2 = p.call("CreateRole(EC2 전용 신뢰 정책)", iam.create_role, RoleName=role2, AssumeRolePolicyDocument=deny_trust)
        if r2:
            p.cleanup("role2", lambda: iam.delete_role(RoleName=role2))
            p.expect_error("AssumeRole", sts.assume_role, "AccessDenied", RoleArn=r2["Role"]["Arn"], RoleSessionName="probe",
                           what="신뢰 정책에 없는 주체의 AssumeRole이 거부됨")
    p.call("GetSessionToken", sts.get_session_token, DurationSeconds=900)
    p.call("GetAccessKeyInfo", sts.get_access_key_info, AccessKeyId="AKIAIOSFODNN7EXAMPLE")


def run_organizations(p: Probe) -> None:
    org = p.client("organizations")
    d = p.call("DescribeOrganization", org.describe_organization)
    if d is None:
        p.call("CreateOrganization", org.create_organization, FeatureSet="ALL")
    else:
        p.behavior("조직이 처음부터 존재함(CreateOrganization 불필요)", True,
                   f"FeatureSet={d['Organization'].get('FeatureSet')}")
    roots = p.call("ListRoots", org.list_roots)
    if not roots or not roots.get("Roots"):
        p.skip("OU/SCP", "루트 없음")
        return
    root_id = roots["Roots"][0]["Id"]
    p.call("EnablePolicyType(SCP)", org.enable_policy_type, RootId=root_id, PolicyType="SERVICE_CONTROL_POLICY")
    ou = p.call("CreateOrganizationalUnit", org.create_organizational_unit, ParentId=root_id, Name=p.name("ou"))
    scp = p.call("CreatePolicy(SCP)", org.create_policy, Name=p.name("scp"), Type="SERVICE_CONTROL_POLICY",
                 Description="deny leave", Content=_policy("Deny", "organizations:LeaveOrganization"))
    if ou and scp:
        ou_id, pid = ou["OrganizationalUnit"]["Id"], scp["Policy"]["PolicySummary"]["Id"]
        p.call("AttachPolicy", org.attach_policy, PolicyId=pid, TargetId=ou_id)
        t = p.call("ListPoliciesForTarget", org.list_policies_for_target, TargetId=ou_id, Filter="SERVICE_CONTROL_POLICY")
        if t:
            p.behavior("OU에 SCP가 연결되어 조회됨", any(x["Id"] == pid for x in t["Policies"]), f"{len(t['Policies'])}개")
        p.cleanup("detach", lambda: (org.detach_policy(PolicyId=pid, TargetId=ou_id), org.delete_policy(PolicyId=pid),
                                     org.delete_organizational_unit(OrganizationalUnitId=ou_id)))
    p.call("ListPolicies(SCP)", org.list_policies, Filter="SERVICE_CONTROL_POLICY")
    if ou:
        # SCP 생성이 501 이어도 AttachPolicy 자체가 구현됐는지 확인 (AWS 관리형 FullAWSAccess 정책 ID)
        p.call("AttachPolicy(FullAWSAccess → OU)", org.attach_policy, PolicyId="p-FullAWSAccess",
               TargetId=ou["OrganizationalUnit"]["Id"])
    acct = p.call("CreateAccount", org.create_account, Email="probe@example.com", AccountName=p.name("acct"))
    if acct:
        sid = acct["CreateAccountStatus"]["Id"]
        st = p.call("DescribeCreateAccountStatus", org.describe_create_account_status, CreateAccountRequestId=sid)
        if st:
            p.behavior("CreateAccount 상태 조회", True, st["CreateAccountStatus"]["State"])
    p.call("ListAccounts", org.list_accounts)


def run_client_config(p: Probe) -> None:
    """CURRICULUM §3 의 클라이언트 설정 주의 사항 확인."""
    ep = os.environ["AWS_ENDPOINT_URL"]
    port = ep.rsplit(":", 1)[-1]
    cfg = Config(retries={"max_attempts": 1}, connect_timeout=3, read_timeout=10)

    # 1) localhost 로 S3 를 부르면?
    s3 = p.client("s3")
    b = p.name("cfgbucket")
    if p.call("CreateBucket(127.0.0.1)", s3.create_bucket, Bucket=b) is not None:
        p.cleanup("b", lambda: s3.delete_bucket(Bucket=b))
        s3_local = boto3.client("s3", endpoint_url=f"https://localhost:{port}", config=cfg)
        try:
            s3_local.head_bucket(Bucket=b)
            p.behavior("boto3 + localhost 엔드포인트로 S3 HeadBucket", True,
                       "boto3(Python)는 localhost여도 경로 방식으로 보내 성공한다 (JS/Java/Go SDK는 가상 호스트 방식이라 실패한다고 문서에 명시)")
        except Exception as e:  # noqa: BLE001
            p.behavior("boto3 + localhost 엔드포인트로 S3 HeadBucket", False, f"{type(e).__name__}: {str(e)[:120]}")
        s3_vh = boto3.client("s3", endpoint_url=f"https://localhost:{port}",
                             config=cfg.merge(Config(s3={"addressing_style": "virtual"})))
        try:
            s3_vh.head_bucket(Bucket=b)
            p.behavior("가상 호스트 방식(<bucket>.localhost)은 실패해야 함", False, "성공했다")
        except Exception as e:  # noqa: BLE001
            p.behavior("가상 호스트 방식(<bucket>.localhost)은 실패해야 함", True, f"{type(e).__name__}: {str(e)[:120]}")

    # 2) S3 Control (계정 ID가 호스트명에 붙음)
    s3c = boto3.client("s3control", config=cfg)
    try:
        s3c.get_public_access_block(AccountId="000000000000")
        p.behavior("S3 Control은 에뮬레이터에 도달하지 못함", False, "도달했다(문서와 다름)")
    except EndpointConnectionError as e:
        p.behavior("S3 Control은 에뮬레이터에 도달하지 못함", True, f"EndpointConnectionError: {str(e)[:120]}")
    except ClientError as e:
        p.behavior("S3 Control은 에뮬레이터에 도달하지 못함", False, f"응답을 받음: {e.response['Error'].get('Code')}")
    except Exception as e:  # noqa: BLE001
        p.behavior("S3 Control은 에뮬레이터에 도달하지 못함", True, f"{type(e).__name__}: {str(e)[:120]}")

    # 3) 호스트 접두사 주입 (Step Functions StartSyncExecution → sync-127.0.0.1)
    sfn_prefixed = boto3.client("stepfunctions", config=cfg.merge(Config(inject_host_prefix=True)))
    try:
        sfn_prefixed.start_sync_execution(stateMachineArn="arn:aws:states:us-east-1:000000000000:stateMachine:nope")
        p.behavior("호스트 접두사 주입을 켜면 sync- 접두사로 연결 실패", False, "도달했다")
    except EndpointConnectionError as e:
        p.behavior("호스트 접두사 주입을 켜면 sync- 접두사로 연결 실패", True, str(e)[:120])
    except Exception as e:  # noqa: BLE001
        p.behavior("호스트 접두사 주입을 켜면 sync- 접두사로 연결 실패", "sync-" in str(e), f"{type(e).__name__}: {str(e)[:120]}")

    # 4) 서명 안 된 요청 / 다른 키
    bad = boto3.client("sts", aws_access_key_id="EMULATOR000000000000", aws_secret_access_key="0" * 40,
                       region_name="us-east-1", config=cfg)
    p.expect_error("GetCallerIdentity(엉뚱한 키)", bad.get_caller_identity, "InvalidClientTokenId",
                   what="에뮬레이터 키가 아닌 키로 서명하면 거부")


CHECKS = {
    "client-config": run_client_config,
    "iam": run_iam,
    "sts": run_sts,
    "organizations": run_organizations,
}
