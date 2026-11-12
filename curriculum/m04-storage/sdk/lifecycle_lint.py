"""M04 — 수명 주기 규칙 점검기 (boto3).

에뮬레이터는 "STANDARD_IA 로 10일 만에 전환" 같은, 실제 AWS라면 InvalidArgument 로 거부할
규칙도 받아 준다(레슨 2). 그래서 에뮬레이터에서 통과한 규칙을 그대로 실제 계정에 배포하면
그때 처음 실패한다. 이 스크립트는 버킷의 수명 주기 설정을 읽어 다음을 점검한다.

  ERROR  실제 AWS가 거부하는 규칙
         - STANDARD_IA / ONEZONE_IA 전환이 생성 후 30일 미만
         - 한 규칙 안에서 다음 전환이 이전 클래스의 최소 보관 기간보다 빨리 옴
         - 폭포(waterfall) 방향을 거스르는 전환 (예: GLACIER → STANDARD_IA)
  WARN   받아 주지만 돈이 새는 규칙
         - 마지막 클래스의 최소 보관 기간이 끝나기 전에 만료(삭제) → 조기 삭제 요금
  INFO   알아 둘 것
         - 128 KB 미만 객체는 기본적으로 전환되지 않는다(2024-09 이후 기본값)

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


def lint_rule(rule: dict[str, Any]) -> list[Finding]:
    rid = rule.get("ID", "(no id)")
    out: list[Finding] = []
    transitions = sorted(
        (t for t in rule.get("Transitions", []) if "Days" in t), key=lambda t: t["Days"]
    )
    prev_class, prev_day = "STANDARD", 0
    for t in transitions:
        cls, day = t["StorageClass"], t["Days"]
        if cls in ("STANDARD_IA", "ONEZONE_IA") and day < 30:
            out.append(Finding("ERROR", rid, f"{cls} 전환이 {day}일 — AWS는 생성 후 30일 이상만 허용 (InvalidArgument)"))
        if cls not in ALLOWED_NEXT.get(prev_class, set()):
            out.append(Finding("ERROR", rid, f"{prev_class} → {cls} 전환은 폭포 모델에 없음"))
        elif prev_day and day - prev_day < MIN_DAYS[prev_class]:
            out.append(Finding("ERROR", rid, f"{prev_class}({prev_day}일) → {cls}({day}일): "
                               f"{prev_class} 최소 보관 {MIN_DAYS[prev_class]}일보다 빠름 — 한 규칙에서는 거부됨"))
        prev_class, prev_day = cls, day
    exp = rule.get("Expiration", {}).get("Days")
    if exp is not None and transitions:
        last_cls, last_day = transitions[-1]["StorageClass"], transitions[-1]["Days"]
        if exp <= last_day:
            out.append(Finding("WARN", rid, f"만료({exp}일)가 마지막 전환({last_day}일)보다 빠르거나 같음 — 전환이 의미 없음"))
        elif exp - last_day < MIN_DAYS[last_cls]:
            short = MIN_DAYS[last_cls] - (exp - last_day)
            out.append(Finding("WARN", rid, f"{last_cls} 에 {exp - last_day}일만 두고 삭제 → 최소 보관 {MIN_DAYS[last_cls]}일 중 "
                               f"남은 {short}일치 조기 삭제 요금"))
    if transitions and "ObjectSizeGreaterThan" not in str(rule.get("Filter", {})):
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


def print_findings(bucket: str, findings: list[Finding]) -> None:
    print(f"[{bucket}] 점검 결과 {len(findings)}건")
    for f in findings:
        print(f"  {f.level:5} {f.rule_id}: {f.message}")


def demo(s3: Any) -> None:
    """에뮬레이터가 받아 주는 '잘못된' 규칙을 일부러 넣고 점검한다."""
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
                    "ID": "receipts-good", "Status": "Enabled", "Filter": {"Prefix": "receipts/"},
                    "Transitions": [
                        {"Days": 30, "StorageClass": "STANDARD_IA"},
                        {"Days": 90, "StorageClass": "GLACIER_IR"},
                        {"Days": 365, "StorageClass": "DEEP_ARCHIVE"},
                    ],
                    "Expiration": {"Days": 2555},
                },
                {   # 나쁜 규칙 1: IA 를 10일 만에 (에뮬레이터는 받아 준다)
                    "ID": "thumbs-ia-10d", "Status": "Enabled", "Filter": {"Prefix": "thumbs/"},
                    "Transitions": [{"Days": 10, "StorageClass": "STANDARD_IA"}],
                },
                {   # 나쁜 규칙 2: Deep Archive 로 보내고 30일 뒤 삭제 → 180일 최소 보관 위반(요금)
                    "ID": "logs-deep-then-delete", "Status": "Enabled", "Filter": {"Prefix": "logs/"},
                    "Transitions": [{"Days": 0, "StorageClass": "DEEP_ARCHIVE"}],
                    "Expiration": {"Days": 30},
                },
            ]
        },
    )
    print(f"데모 버킷 {DEMO_BUCKET} 에 규칙 3개 저장 — 에뮬레이터는 모두 받아 줬다")
    findings = lint_bucket(s3, DEMO_BUCKET)
    print_findings(DEMO_BUCKET, findings)

    errors = {f.rule_id for f in findings if f.level == "ERROR"}
    warns = {f.rule_id for f in findings if f.level == "WARN"}
    assert errors == {"thumbs-ia-10d"}, errors
    assert warns == {"logs-deep-then-delete"}, warns
    # 단위 확인: 한 규칙 안에서 최소 보관 기간보다 빠른 연쇄 전환 (AWS 문서의 4일 → 20일 예)
    chained = lint_rule({"ID": "gir-4-da-20", "Transitions": [
        {"Days": 4, "StorageClass": "GLACIER_IR"}, {"Days": 20, "StorageClass": "DEEP_ARCHIVE"}]})
    assert any(f.level == "ERROR" and "최소 보관 90일" in f.message for f in chained), chained
    backwards = lint_rule({"ID": "backwards", "Transitions": [
        {"Days": 30, "StorageClass": "GLACIER"}, {"Days": 60, "StorageClass": "STANDARD_IA"}]})
    assert any("폭포" in f.message for f in backwards), backwards

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
