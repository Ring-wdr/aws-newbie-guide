"""aws-emulator 충실도 탐침(fidelity probe).

커리큘럼 실습이 쓰는 오퍼레이션과 서비스 간 동작을 실제로 호출해 보고
OK / 501 / 오류 / 동작 관찰 결과를 tools/probe/results.json 에 기록한 뒤
docs/FIDELITY.md 를 다시 만든다.

사용법 (저장소 루트에서, 깨끗한 에뮬레이터 권장):
    export EMULATOR_PORT=9297
    scripts/emulator-reset.sh
    source scripts/env.sh
    uv run python tools/probe/probe.py                  # 전체
    uv run python tools/probe/probe.py --service s3,sqs # 일부만 (나머지 결과는 유지)
    uv run python tools/probe/probe.py --list           # 서비스 목록
    uv run python tools/probe/probe.py --report-only    # results.json 으로 보고서만 재생성
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib
import json
import os
import pkgutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import boto3  # noqa: E402

import report  # noqa: E402
from lib import Probe, assert_emulator  # noqa: E402

RESULTS = HERE / "results.json"


def load_checks() -> dict[str, Callable[[Probe], None]]:
    checks: dict[str, Callable[[Probe], None]] = {}
    for m in sorted(pkgutil.iter_modules([str(HERE)]), key=lambda m: m.name):
        if m.name.startswith("checks_"):
            mod = importlib.import_module(m.name)
            for k, fn in getattr(mod, "CHECKS", {}).items():
                if k in checks:
                    raise SystemExit(f"서비스 키 중복: {k} ({m.name})")
                checks[k] = fn
    return checks


def emulator_version(port: str) -> dict[str, str]:
    try:
        out = subprocess.run(
            ["docker", "exec", f"aws-emulator-{port}", "aws-emulator", "--version"],
            capture_output=True, text=True, timeout=20, check=True,
        ).stdout
    except Exception as e:  # noqa: BLE001
        return {"error": f"버전 조회 실패: {e}"}
    info: dict[str, str] = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip().lower().replace(" ", "_")] = v.strip()
    return info


def aws_cli_version() -> str:
    try:
        return subprocess.run(["aws", "--version"], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--service", "-s", default="", help="쉼표로 구분한 서비스 키 (기본: 전체)")
    ap.add_argument("--list", action="store_true", help="서비스 키 목록만 출력")
    ap.add_argument("--report-only", action="store_true", help="탐침 없이 results.json 으로 FIDELITY.md 만 재생성")
    ap.add_argument("--quiet", "-q", action="store_true")
    ap.add_argument("--dry", action="store_true",
                    help="results.json·FIDELITY.md 를 쓰지 않는다 (탐침 코드를 고치는 중에, 또는 병렬 실행 시)")
    args = ap.parse_args()

    checks = load_checks()
    if args.list:
        print("\n".join(checks))
        return 0
    if args.report_only:
        report.generate(json.loads(RESULTS.read_text()))
        print(f"보고서 생성: {report.OUT}")
        return 0

    endpoint = assert_emulator()
    port = os.environ.get("EMULATOR_PORT", endpoint.rsplit(":", 1)[-1])

    selected = [s.strip() for s in args.service.split(",") if s.strip()] or list(checks)
    unknown = [s for s in selected if s not in checks]
    if unknown:
        raise SystemExit(f"알 수 없는 서비스: {unknown}. --list 로 확인하세요.")

    probe = Probe(verbose=not args.quiet)
    for key in selected:
        with probe.service(key):
            checks[key](probe)

    new = probe.to_dicts()
    if args.dry:
        print(f"\n(--dry) 저장하지 않음: {len(new)}건")
        return 0
    data: dict[str, Any] = {"meta": {}, "results": []}
    if RESULTS.exists() and len(selected) != len(checks):
        data = json.loads(RESULTS.read_text())
        data["results"] = [r for r in data["results"] if r["service"] not in selected]
    data["results"].extend(new)
    order = {k: i for i, k in enumerate(checks)}
    data["results"].sort(key=lambda r: order.get(r["service"], 999))
    data["meta"] = {
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "emulator": emulator_version(port),
        "aws_cli": aws_cli_version(),
        "boto3": boto3.__version__,
        "python": sys.version.split()[0],
        "partial_run": selected if len(selected) != len(checks) else [],
    }
    RESULTS.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    report.generate(data)

    counts: dict[str, int] = {}
    for r in new:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"\n완료: {len(new)}건 {counts}")
    print(f"결과: {RESULTS.relative_to(HERE.parent.parent)} · 보고서: {report.OUT.relative_to(HERE.parent.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
