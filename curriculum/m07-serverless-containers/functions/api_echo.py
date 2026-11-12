"""API Gateway 프록시 통합이 넘겨주는 이벤트를 요약해 돌려주는 함수 (M07 lab03).

REST API(페이로드 1.0)와 HTTP API(페이로드 2.0)는 이벤트 모양이 다르다. 둘 다 처리해 본다.
프록시 통합의 응답은 {"statusCode", "headers", "body"(문자열)} 형식이어야 한다.
"""

import json


def handler(event, context):
    if event.get("version") == "2.0":  # HTTP API
        http = event["requestContext"]["http"]
        summary = {"api": "HTTP API (payload 2.0)", "routeKey": event.get("routeKey"),
                   "method": http["method"], "path": event.get("rawPath")}
    else:  # REST API 프록시 (payload 1.0)
        summary = {"api": "REST API (payload 1.0)", "resource": event.get("resource"),
                   "method": event.get("httpMethod"), "path": event.get("path"),
                   "stage": event.get("requestContext", {}).get("stage")}
    summary["pathParameters"] = event.get("pathParameters")
    return {"statusCode": 200, "headers": {"content-type": "application/json"}, "body": json.dumps(summary)}
