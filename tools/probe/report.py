"""results.json → docs/FIDELITY.md 생성기.

자동 생성 부분(표·목록)과 사람이 쓴 부분(tools/probe/notes.md)을 합친다.
notes.md 는 `<!-- section: 이름 -->` 표시로 나뉜다:
  summary  : 맨 앞 요약
  grades   : `| 서비스키 | 등급 | 한 줄 근거 |` 표 (등급 판정. 없는 서비스는 자동 제안 등급)
  facts    : "모듈별로 확인된 사실" 본문 (탐침 근거는 서비스 키, 탐침에 없는 것은 "모듈 저자 관찰 (mNN README)")
  env      : "환경 메모" (메모리 상한, 시계 어긋남, 컨테이너 내부 엔드포인트 등)
  cited    : 탐침이 다시 확인하지 않은 모듈 저자 관찰 목록
"""

from __future__ import annotations

import re
from collections import defaultdict
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "docs" / "FIDELITY.md"
NOTES = HERE / "notes.md"

# 서비스 키 → 커리큘럼 모듈 (보고서 정렬·표시용)
MODULE = {
    "client-config": "M00",
    "iam": "M01", "iam-enforcement": "M01", "iam-conditions": "M01", "sts": "M01", "organizations": "M01",
    "ec2-vpc": "M02", "vpc-gaps": "M02",
    "ec2-instances": "M03", "ebs-ami": "M03", "elbv2": "M03", "autoscaling": "M03", "compute-gaps": "M03",
    "s3": "M04", "s3-gaps": "M04", "efs": "M04",
    "rds": "M05", "dynamodb": "M05", "elasticache": "M05", "db-gaps": "M05",
    "sqs": "M06", "sns": "M06", "eventbridge": "M06", "stepfunctions": "M06", "kinesis": "M06", "integration-better": "M06",
    "lambda": "M07", "apigateway": "M07", "apigatewayv2": "M07", "ecr": "M07", "ecs": "M07", "cognito": "M07", "lambda-runtime": "M07", "lambda-permissions": "M07",
    "route53": "M08", "cloudfront": "M08", "globalaccelerator": "M08", "wafv2": "M08", "edge-better": "M08",
    "kms": "M09", "secretsmanager": "M09", "ssm": "M09", "acm": "M09", "cloudtrail": "M09", "config": "M09",
    "guardduty": "M09", "security-better": "M09",
    "cloudwatch": "M10", "logs": "M10", "cloudformation": "M10", "cfn-timing": "M10",
    "firehose": "M11", "glue": "M11", "athena": "M11", "analytics-gaps": "M11",
    "backup": "M12", "dms": "M12",
    "budgets": "M13", "tagging": "M13",
    "misc-optional": "기타",
}

ICON = {
    "OK": "✅",
    "NOT_IMPL": "⛔ 501",
    "ERROR": "❌",
    "BEHAVIOR_OK": "✅ 동작",
    "BEHAVIOR_DIFF": "⚠️ 다름",
    "SKIP": "⏭️",
}


def _sections() -> dict[str, str]:
    if not NOTES.exists():
        return {}
    text = NOTES.read_text()
    parts = re.split(r"<!--\s*section:\s*(\w+)\s*-->", text)
    out: dict[str, str] = {}
    for i in range(1, len(parts), 2):
        out[parts[i]] = parts[i + 1].strip()
    return out


def _manual_grades(table: str) -> dict[str, tuple[str, str]]:
    grades: dict[str, tuple[str, str]] = {}
    for line in table.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 3 and cells[0] and not cells[0].startswith("-") and cells[0] != "서비스":
            grades[cells[0].strip("`")] = (cells[1], cells[2])
    return grades


def _auto_grade(rows: list[dict[str, Any]]) -> str:
    api = [r for r in rows if r["kind"] == "api"]
    beh = [r for r in rows if r["kind"] == "behavior"]
    if not api or not any(r["status"] == "OK" for r in api):
        return "🔴"
    bad = [r for r in rows if r["status"] in ("NOT_IMPL", "ERROR", "BEHAVIOR_DIFF")]
    if not bad and all(r["status"] != "SKIP" for r in beh):
        return "🟢"
    return "🟡"


def _esc(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def generate(data: dict[str, Any]) -> None:
    meta = data.get("meta", {})
    results: list[dict[str, Any]] = data.get("results", [])
    by_svc_raw: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in results:
        by_svc_raw[r["service"]].append(r)
    keys = list(MODULE)
    by_svc = {k: by_svc_raw[k] for k in sorted(by_svc_raw, key=lambda k: (MODULE.get(k, "zz"), keys.index(k) if k in keys else 999))}

    sec = _sections()
    manual = _manual_grades(sec.get("grades", ""))
    emu = meta.get("emulator", {})

    L: list[str] = []
    L.append("# 에뮬레이터 충실도(FIDELITY) 보고서")
    L.append("")
    L.append("> 이 문서는 `tools/probe/probe.py` 실행 결과(`tools/probe/results.json`)와 "
             "사람이 쓴 판정(`tools/probe/notes.md`)으로 **자동 생성**된다. 직접 고치지 말고 두 파일을 고친 뒤 다시 생성한다.")
    L.append("")
    L.append("| 항목 | 값 |")
    L.append("|---|---|")
    L.append(f"| 에뮬레이터 버전 | `{emu.get('version', '?')}` (릴리스 {emu.get('release_date', '?')}) |")
    L.append(f"| 에뮬레이터 커밋 | `{emu.get('commit', '?')}` |")
    L.append(f"| 탐침 실행 시각 | {meta.get('generated_at', '?')} |")
    L.append(f"| 클라이언트 | `{meta.get('aws_cli', '?')}` · boto3 {meta.get('boto3', '?')} · Python {meta.get('python', '?')} |")
    dns = meta.get("container_dns")
    dns_txt = ("Docker 기본 리졸버" if dns == [] else f"`{', '.join(dns)}` (격리 — `EMULATOR_DNS`)" if dns else "?")
    L.append(f"| 컨테이너 DNS | {dns_txt} · 바깥 접속 확인 방법은 아래 \"환경 메모 → 외부 접속 위험\" |")
    if meta.get("partial_run"):
        L.append(f"| 마지막 부분 실행 | {', '.join(meta['partial_run'])} |")
    L.append("")
    L.append("다시 만들기:")
    L.append("")
    L.append("```bash")
    L.append("export EMULATOR_PORT=9297            # 자기 포트")
    L.append("scripts/emulator-reset.sh            # 깨끗한 에뮬레이터")
    L.append("source scripts/env.sh")
    L.append("uv run python tools/probe/probe.py   # 전체 (약 수 분) · 일부: --service s3,sqs")
    L.append("```")
    L.append("")
    L.append("탐침은 실행마다 새 이름(`todayorder-probe-*-<무작위>`)을 쓰고 끝나면 대부분 정리하므로 같은 에뮬레이터에서 다시 돌려도 된다. "
             "다만 계정에 한 번만 되는 호출(`iam GenerateCredentialReport`, `macie2 EnableMacie`, `securityhub EnableSecurityHub`)은 "
             "두 번째 실행부터 409 오류로 기록된다(AWS와 같은 동작). 보고서를 갱신할 때는 깨끗한 에뮬레이터에서 실행한다.")
    L.append("")
    L.append("등급 정의는 [CURRICULUM.md 3장](./CURRICULUM.md#3-에뮬레이터-충실도-등급): "
             "🟢 재현 · 🟡 부분(리소스는 만들어지지만 동작(실행·전달·차단)의 일부 또는 전부가 일어나지 않는다) · 🔴 개념(501이거나 의미 없음).")
    L.append("")
    if sec.get("summary"):
        L.append("## 요약")
        L.append("")
        L.append(sec["summary"])
        L.append("")

    # 서비스 표
    L.append("## 서비스별 결과")
    L.append("")
    L.append("API 열은 `성공/시도`, 동작 열은 `실제처럼 관찰/검사`. 등급 근거의 ✍️ 는 사람이 판정한 것, 🤖 는 자동 제안이다.")
    L.append("")
    L.append("| 모듈 | 서비스 | 등급 | API | 501 | 기타 오류 | 동작 | 근거 |")
    L.append("|---|---|---|---|---|---|---|---|")
    for svc, rows in by_svc.items():
        api = [r for r in rows if r["kind"] == "api"]
        beh = [r for r in rows if r["kind"] == "behavior" and r["status"] != "SKIP"]
        n_ok = sum(r["status"] == "OK" for r in api)
        n_501 = sum(r["status"] == "NOT_IMPL" for r in rows)
        n_err = sum(r["status"] == "ERROR" for r in rows)
        b_ok = sum(r["status"] == "BEHAVIOR_OK" for r in beh)
        if svc in manual:
            grade, why = manual[svc][0], "✍️ " + manual[svc][1]
        else:
            grade, why = _auto_grade(rows), "🤖 자동 제안"
        L.append(f"| {MODULE.get(svc, '?')} | [`{svc}`](#svc-{svc}) | {grade} | {n_ok}/{len(api)} | {n_501 or ''} | {n_err or ''} | "
                 f"{b_ok}/{len(beh)} | {_esc(why)} |")
    L.append("")

    if sec.get("facts"):
        L.append("## 모듈별로 확인된 사실 (저자·학습자 필독)")
        L.append("")
        L.append(sec["facts"])
        L.append("")
    if sec.get("cited"):
        L.append("## 탐침이 다시 확인하지 않은 모듈 저자 관찰")
        L.append("")
        L.append(sec["cited"])
        L.append("")
    if sec.get("env"):
        L.append("## 환경 메모")
        L.append("")
        L.append(sec["env"])
        L.append("")

    # 501 목록
    L.append("## 501 NotImplemented 오퍼레이션")
    L.append("")
    nimpl = [r for r in results if r["status"] == "NOT_IMPL"]
    if nimpl:
        L.append("| 모듈 | 서비스 | 오퍼레이션/동작 |")
        L.append("|---|---|---|")
        for svc in by_svc:
            for r in nimpl:
                if r["service"] == svc:
                    L.append(f"| {MODULE.get(svc, '?')} | `{svc}` | {_esc(r['name'])} |")
    else:
        L.append("없음.")
    L.append("")

    # 오류·다른 동작
    L.append("## 501 이외의 오류와 AWS와 다른 동작")
    L.append("")
    L.append("탐침 입력이 잘못됐을 가능성도 있으니, 실습에 쓰기 전에 직접 재현해 볼 것.")
    L.append("")
    diffs = [r for r in results if r["status"] in ("ERROR", "BEHAVIOR_DIFF")]
    if diffs:
        L.append("| 모듈 | 서비스 | 오퍼레이션/동작 | 상태 | 상세 |")
        L.append("|---|---|---|---|---|")
        for svc in by_svc:
            for r in diffs:
                if r["service"] == svc:
                    L.append(f"| {MODULE.get(svc, '?')} | `{svc}` | {_esc(r['name'])} | {ICON[r['status']]} | {_esc(r['detail'])} |")
    else:
        L.append("없음.")
    L.append("")

    # 상세
    L.append("## 서비스별 상세")
    L.append("")
    for svc, rows in by_svc.items():
        L.append(f'<a id="svc-{svc}"></a>')
        L.append("")
        L.append(f"### {MODULE.get(svc, '?')} · {svc}")
        L.append("")
        L.append("| 종류 | 오퍼레이션/동작 | 결과 | 상세 |")
        L.append("|---|---|---|---|")
        for r in rows:
            kind = "API" if r["kind"] == "api" else "동작"
            L.append(f"| {kind} | {_esc(r['name'])} | {ICON[r['status']]} | {_esc(r['detail'])} |")
        L.append("")

    OUT.write_text("\n".join(L).rstrip() + "\n")
