"""M10 — 구조화 로그 전송기 (boto3).

주문 API가 요청마다 JSON 한 줄 로그를 남기고, 그 로그를 CloudWatch Logs로 **묶어서** 보낸다.
로그 한 줄에 EMF(Embedded Metric Format) 블록을 함께 넣으면, CloudWatch가 로그에서 지표를 뽑아
PutMetricData 를 따로 부르지 않아도 지표(TodayOrder/EMF Latency)가 생긴다.

실행 (저장소 루트에서):
    source scripts/env.sh
    uv run python curriculum/m10-monitoring-iac/sdk/structured_logger.py

실제 서버에서는 보통 CloudWatch 에이전트(EC2)나 Lambda 런타임이 stdout 로그를 대신 보내 준다.
이 예제는 "로그가 어떤 API로 어떻게 들어가는지"를 보여 주려고 PutLogEvents 를 직접 부른다.
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import boto3
from botocore.exceptions import ClientError

from emulator_guard import require_emulator

LOG_GROUP = "/todayorder/sdk/api"
EMF_NAMESPACE = "TodayOrder/EMF"


@dataclass
class StructuredLogger:
    """JSON 로그를 버퍼에 모았다가 PutLogEvents 한 번으로 보낸다."""

    logs: Any
    group: str
    stream: str
    run_id: str = ""  # 실행마다 바뀌는 EMF 차원 값 (지표는 지울 수 없어서, 이전 실행의 지표로 단언이 통과하지 않게)
    batch_size: int = 50
    _buffer: list[dict[str, Any]] = field(default_factory=list)
    sent: int = 0

    def setup(self, retention_days: int = 14) -> None:
        try:
            self.logs.create_log_group(logGroupName=self.group)
        except ClientError as e:
            if e.response["Error"]["Code"] != "ResourceAlreadyExistsException":
                raise
        # 보존 기간을 정하지 않으면 로그는 영구 보관된다(= 요금이 계속 쌓인다).
        self.logs.put_retention_policy(logGroupName=self.group, retentionInDays=retention_days)
        self.logs.create_log_stream(logGroupName=self.group, logStreamName=self.stream)

    def log(self, level: str, route: str, status: int, latency_ms: int, **extra: Any) -> None:
        now_ms = int(time.time() * 1000)
        record: dict[str, Any] = {
            "level": level,
            "route": route,
            "status": status,
            "latency_ms": latency_ms,
            "run": self.run_id,
            **extra,
            # EMF: 이 블록이 있으면 CloudWatch가 latency_ms 값을 지표로 만든다(차원: route, run).
            "_aws": {
                "Timestamp": now_ms,
                "CloudWatchMetrics": [
                    {
                        "Namespace": EMF_NAMESPACE,
                        "Dimensions": [["route", "run"]],
                        "Metrics": [{"Name": "latency_ms", "Unit": "Milliseconds"}],
                    }
                ],
            },
        }
        self._buffer.append({"timestamp": now_ms, "message": json.dumps(record, ensure_ascii=False)})
        if len(self._buffer) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        if not self._buffer:
            return
        # PutLogEvents 규칙: 한 번에 같은 스트림, 시간순 정렬.
        batch = sorted(self._buffer, key=lambda e: e["timestamp"])
        resp = self.logs.put_log_events(logGroupName=self.group, logStreamName=self.stream, logEvents=batch)
        if resp.get("rejectedLogEventsInfo"):
            raise RuntimeError(f"거부된 로그가 있음: {resp['rejectedLogEventsInfo']}")
        self.sent += len(batch)
        self._buffer.clear()


def run_insights(logs: Any, group: str, query: str, timeout_s: float = 30) -> list[dict[str, str]]:
    """Logs Insights 쿼리를 실행하고 결과 행을 dict 목록으로 돌려준다."""
    now = int(time.time())
    qid = logs.start_query(logGroupName=group, startTime=now - 900, endTime=now + 60, queryString=query)["queryId"]
    deadline = time.time() + timeout_s
    while True:
        r = logs.get_query_results(queryId=qid)
        if r["status"] in ("Complete", "Failed", "Cancelled", "Timeout"):
            break
        if time.time() > deadline:
            raise TimeoutError(f"Insights 쿼리가 {timeout_s}초 안에 끝나지 않음 (상태 {r['status']})")
        time.sleep(1)
    if r["status"] != "Complete":
        raise RuntimeError(f"Insights 쿼리 실패: {r['status']}")
    return [{f["field"]: f["value"] for f in row if f["field"] != "@ptr"} for row in r["results"]]


def wait_for_emf_metric(cw: Any, route: str, run_id: str, timeout_s: float = 30) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        metrics = cw.list_metrics(
            Namespace=EMF_NAMESPACE,
            MetricName="latency_ms",
            Dimensions=[{"Name": "route", "Value": route}, {"Name": "run", "Value": run_id}],
        )["Metrics"]
        if metrics:
            return True
        time.sleep(1)
    return False


def main() -> None:
    require_emulator()  # 클라이언트를 만들기 전에: 에뮬레이터가 아니면 여기서 종료

    logs = boto3.client("logs")
    cw = boto3.client("cloudwatch")
    run_id = uuid.uuid4().hex[:8]
    stream = f"api-{run_id}"  # 실행마다 새 스트림
    logger = StructuredLogger(logs=logs, group=LOG_GROUP, stream=stream, run_id=run_id, batch_size=4)
    logger.setup()
    print(f"로그 그룹 {LOG_GROUP} / 스트림 {stream}")

    # 가짜 요청 7건: batch_size=4 이므로 4건째에서 자동 전송, 나머지는 flush() 로 전송
    logger.log("INFO", "POST /orders", 201, 130, order_id="A-2001")
    logger.log("INFO", "POST /orders", 201, 180, order_id="A-2002")
    logger.log("INFO", "GET /orders", 200, 35)
    logger.log("ERROR", "POST /orders", 500, 2100, msg="payment failed", order_id="A-2003")
    logger.log("INFO", "GET /orders", 200, 42)
    logger.log("WARN", "POST /orders", 201, 950, order_id="A-2004")
    logger.log("ERROR", "POST /orders", 504, 3000, msg="payment timeout", order_id="A-2005")
    logger.flush()
    print(f"보낸 로그: {logger.sent}건")

    rows = run_insights(
        logs,
        LOG_GROUP,
        f'filter @logStream = "{stream}" | stats count(*) as n, max(latency_ms) as max_ms by level | sort n desc',
    )
    print("Insights(레벨별):", json.dumps(rows, ensure_ascii=False))
    by_level = {r["level"]: r for r in rows}

    has_metric = wait_for_emf_metric(cw, "POST /orders", run_id)
    print(f"EMF 지표 {EMF_NAMESPACE}/latency_ms(route=POST /orders, run={run_id}) 생성: {has_metric}")

    assert logger.sent == 7, logger.sent
    assert by_level["ERROR"]["n"] == "2" and by_level["ERROR"]["max_ms"] == "3000", by_level
    assert by_level["INFO"]["n"] == "4", by_level
    assert has_metric, "EMF 로그에서 지표가 만들어지지 않음"

    logs.delete_log_group(logGroupName=LOG_GROUP)
    print("SDK structured_logger OK")


if __name__ == "__main__":
    main()
