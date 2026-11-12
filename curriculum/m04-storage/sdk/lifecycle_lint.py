"""M04 — 수명 주기 규칙 점검기 (boto3).

수명 주기 규칙은 "저장이 됐다"고 끝이 아니다. 실제 AWS가 거부하는 규칙도 있고, 저장은 되지만
최소 보관 기간 요금으로 돈이 새는 규칙도 있다. 이 스크립트는 버킷의 수명 주기 설정을 읽어
현재 버전 전환(Transitions)과 이전 버전 전환(NoncurrentVersionTransitions)을 모두 점검한다.

  ERROR  실제 AWS가 거부하는 규칙 (S3 사용 설명서 "Constraints and considerations for transitions")
         - 한 규칙 안에서 다음 전환이 이전 클래스의 최소 보관 기간보다 빨리 옴
           (예: Glacier IR 4일 → Deep Archive 20일. 94일 이후여야 함) — 첫 전환이 0일이어도 검사한다
         - 폭포(waterfall) 방향을 거스르는 전환 (예: GLACIER → STANDARD_IA)
  WARN   저장은 되지만 돈이 새는 규칙
         - 마지막 클래스의 최소 보관 기간이 끝나기 전에 만료(삭제) → 조기 삭제 요금
  INFO   알아 둘 것
         - 128 KB 미만 객체는 기본적으로 전환되지 않는다(2024-09 이후 기본값)
         - Standard-IA·One Zone-IA 를 30일 전에 전환하는 규칙: 현재 버전은 2026-07부터 허용되지만
           (예전에는 InvalidArgument), 시험 자료·옛 IaC 검사기는 여전히 30일 최소로 볼 수 있다.
           이전 버전(NoncurrentDays)은 발표가 언급하지 않아 "확인 필요"로만 알린다

에뮬레이터 1.0.322 는 위 ERROR 두 종류를 실제 AWS처럼 거부한다(lab02 11·12단계). 그래서 데모는
에뮬레이터가 받아 주는 "돈이 새는" 규칙을 버킷에 저장해 점검하고, 거부되는 규칙은 규칙 사전으로 점검한다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m04-storage/sdk/lifecycle_lint.py            # 데모 버킷을 만들어 점검
    uv run python curriculum/m04-storage/sdk/lifecycle_lint.py <버킷>     # 기존 버킷 점검(읽기만)
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

DEMO_BUCKET = "todayorder-m04-lifecycle-lint"

# 최소 보관 기간(일). 이보다 먼저 옮기거나 지우면 남은 기간만큼 요금이 나온다.
MIN_DAYS: dict[str, int] = {
    "STANDARD": 0,
    "INTELLIGENT_TIERING": 0,
    "STANDARD_IA": 30,
    "ONEZONE_IA": 30,
    "GLACIER_IR": 90,
    "GLACIER": 90,
    "DEEP_ARCHIVE": 180,
}
# 폭포 모델: 각 클래스에서 수명 주기로 갈 수 있는 클래스
ALLOWED_NEXT: dict[str, set[str]] = {
    "STANDARD": {"STANDARD_IA", "INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"},
    "STANDARD_IA": {"INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"},
    "INTELLIGENT_TIERING": {"ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"},
    "ONEZONE_IA": {"GLACIER", "DEEP_ARCHIVE"},
    "GLACIER_IR": {"GLACIER", "DEEP_ARCHIVE"},
    "GLACIER": {"DEEP_ARCHIVE"},
    "DEEP_ARCHIVE": set(),
}


@dataclass(frozen=True)
class Finding:
    level: str  # ERROR | WARN | INFO
    rule_id: str
    message: str


def _lint_chain(rid: str, label: str, steps: list[tuple[int, str]], expire: int | None) -> list[Finding]:
    """steps = [(일, 클래스)] (일 오름차순). label 은 '현재 버전' / '이전 버전'."""
    out: list[Finding] = []
    prev_class, prev_day, has_prev = "STANDARD", 0, False
    for day, cls in steps:
        if cls in ("STANDARD_IA", "ONEZONE_IA") and day < 30:
            if label == "현재 버전":
                msg = "2026-07부터 허용(예전 최소 30일). 옛 시험 자료·검사기와 다를 수 있음"
            else:
                msg = "2026-07 발표는 현재 버전만 언급 — 이전 버전의 최소 일수는 실제 계정에서 확인"
            out.append(Finding("INFO", rid, f"[{label}] {cls} 전환 {day}일 — {msg}"))
        if cls not in ALLOWED_NEXT.get(prev_class, set()):
            out.append(Finding("ERROR", rid, f"[{label}] {prev_class} → {cls} 전환은 폭포 모델에 없음"))
        elif has_prev and day - prev_day < MIN_DAYS[prev_class]:
            out.append(Finding("ERROR", rid, f"[{label}] {prev_class}({prev_day}일) → {cls}({day}일): "
                               f"{prev_class} 최소 보관 {MIN_DAYS[prev_class]}일보다 빠름 — 한 규칙에서는 거부됨"))
        prev_class, prev_day, has_prev = cls, day, True
    if expire is not None and steps:
        last_day, last_cls = steps[-1]
        if expire <= last_day:
            out.append(Finding("WARN", rid, f"[{label}] 만료({expire}일)가 마지막 전환({last_day}일)보다 빠르거나 같음 — 전환이 의미 없음"))
        elif expire - last_day < MIN_DAYS[last_cls]:
            short = MIN_DAYS[last_cls] - (expire - last_day)
            out.append(Finding("WARN", rid, f"[{label}] {last_cls} 에 {expire - last_day}일만 두고 삭제 → 최소 보관 "
                               f"{MIN_DAYS[last_cls]}일 중 남은 {short}일치 조기 삭제 요금"))
    return out


def lint_rule(rule: dict[str, Any]) -> list[Finding]:
    rid = rule.get("ID", "(no id)")
    current = sorted((t["Days"], t["StorageClass"]) for t in rule.get("Transitions", []) if "Days" in t)
    noncurrent = sorted(
        (t["NoncurrentDays"], t["StorageClass"]) for t in rule.get("NoncurrentVersionTransitions", [])
        if "NoncurrentDays" in t
    )
    out = _lint_chain(rid, "현재 버전", current, rule.get("Expiration", {}).get("Days"))
    out += _lint_chain(rid, "이전 버전", noncurrent, rule.get("NoncurrentVersionExpiration", {}).get("NoncurrentDays"))
    if (current or noncurrent) and "ObjectSize" not in str(rule.get("Filter", {})):
        out.append(Finding("INFO", rid, "128 KB 미만 객체는 기본적으로 전환되지 않음(작은 객체는 전환 요청 비용이 절감액보다 큼)"))
    return out


def lint_bucket(s3: Any, bucket: str) -> list[Finding]:
    try:
        rules = s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchLifecycleConfiguration":
            return []
        raise
    return [f for r in rules if r.get("Status") == "Enabled" for f in lint_rule(r)]


def print_findings(title: str, findings: list[Finding]) -> None:
    print(f"[{title}] 점검 결과 {len(findings)}건")
    for f in findings:
        print(f"  {f.level:5} {f.rule_id}: {f.message}")


def demo(s3: Any) -> None:
    # 1) 에뮬레이터(그리고 AWS)가 저장해 주지만 돈이 새는 규칙
    try:
        s3.head_bucket(Bucket=DEMO_BUCKET)
        s3.delete_bucket_lifecycle(Bucket=DEMO_BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=DEMO_BUCKET)
    s3.put_bucket_lifecycle_configuration(
        Bucket=DEMO_BUCKET,
        LifecycleConfiguration={
            "Rules": [
                {   # 좋은 규칙: 30 → 90 → 365, 7년 후 삭제
                    "ID": "receipts-good", "Status": "Enabled",
                    "Filter": {"And": {"Prefix": "receipts/", "ObjectSizeGreaterThan": 131072}},
                    "Transitions": [
                        {"Days": 30, "StorageClass": "STANDARD_IA"},
                        {"Days": 90, "StorageClass": "GLACIER_IR"},
                        {"Days": 365, "StorageClass": "DEEP_ARCHIVE"},
                    ],
                    "Expiration": {"Days": 2555},
                },
                {   # Deep Archive 로 보내고 30일 뒤 삭제 → 180일 최소 보관 요금
                    "ID": "logs-deep-then-delete", "Status": "Enabled", "Filter": {"Prefix": "logs/"},
                    "Transitions": [{"Days": 0, "StorageClass": "DEEP_ARCHIVE"}],
                    "Expiration": {"Days": 30},
                },
                {   # 이전 버전을 10일 뒤 IA 로, 20일 뒤 삭제 → IA 최소 보관 30일 요금
                    "ID": "menu-old-versions", "Status": "Enabled", "Filter": {"Prefix": "menu/"},
                    "NoncurrentVersionTransitions": [{"NoncurrentDays": 10, "StorageClass": "STANDARD_IA"}],
                    "NoncurrentVersionExpiration": {"NoncurrentDays": 20},
                },
            ]
        },
    )
    print(f"데모 버킷 {DEMO_BUCKET} 에 규칙 3개 저장 — 모두 저장됐다")
    stored = lint_bucket(s3, DEMO_BUCKET)
    print_findings(DEMO_BUCKET, stored)
    assert not [f for f in stored if f.level == "ERROR"], stored
    assert {f.rule_id for f in stored if f.level == "WARN"} == {"logs-deep-then-delete", "menu-old-versions"}, stored

    # 2) 저장 전에 걸러야 하는 규칙 (에뮬레이터는 InvalidArgument. AWS는 현재 버전 기준으로 문서화) — 규칙 사전으로 점검
    rejected = [
        {"ID": "gir-4-da-20", "Transitions": [
            {"Days": 4, "StorageClass": "GLACIER_IR"}, {"Days": 20, "StorageClass": "DEEP_ARCHIVE"}]},
        {"ID": "gir-0-da-30", "Transitions": [  # 첫 전환이 0일이어도 최소 보관 기간 검사
            {"Days": 0, "StorageClass": "GLACIER_IR"}, {"Days": 30, "StorageClass": "DEEP_ARCHIVE"}]},
        {"ID": "nc-gir-5-da-20", "NoncurrentVersionTransitions": [
            {"NoncurrentDays": 5, "StorageClass": "GLACIER_IR"}, {"NoncurrentDays": 20, "StorageClass": "DEEP_ARCHIVE"}]},
        {"ID": "backwards", "Transitions": [
            {"Days": 30, "StorageClass": "GLACIER"}, {"Days": 60, "StorageClass": "STANDARD_IA"}]},
    ]
    pre = [f for r in rejected for f in lint_rule(r) if f.level == "ERROR"]
    print_findings("저장 전 점검(규칙 사전)", pre)
    assert {f.rule_id for f in pre} == {r["ID"] for r in rejected}, pre
    # 실제로 에뮬레이터도 거부하는지 하나씩 확인
    for r in rejected:
        try:
            s3.put_bucket_lifecycle_configuration(
                Bucket=DEMO_BUCKET, LifecycleConfiguration={"Rules": [{**r, "Status": "Enabled", "Filter": {}}]})
            raise AssertionError(f"{r['ID']} 가 저장됨 — 에뮬레이터 동작이 바뀜")
        except ClientError as e:
            assert e.response["Error"]["Code"] == "InvalidArgument", e
    print(f"에뮬레이터도 {len(rejected)}개 모두 InvalidArgument 로 거부")

    s3.delete_bucket_lifecycle(Bucket=DEMO_BUCKET)
    s3.delete_bucket(Bucket=DEMO_BUCKET)
    print("정리 완료")


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료
    s3 = boto3.client("s3")
    if len(sys.argv) > 1:
        print_findings(sys.argv[1], lint_bucket(s3, sys.argv[1]))
        return
    demo(s3)
    print("SDK lifecycle_lint OK")


if __name__ == "__main__":
    main()
