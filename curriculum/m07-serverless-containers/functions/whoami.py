"""JWT 권한 부여자를 통과한 요청의 사용자 정보를 돌려주는 함수 (M07 lab07).

HTTP API 의 JWT 권한 부여자가 토큰을 검증하면, 토큰의 클레임을 event.requestContext.authorizer.jwt.claims 로 넘겨준다.
함수는 토큰을 직접 검증하지 않는다 — 그 일은 API Gateway 가 이미 했다.
"""

import json


def handler(event, context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    body = {"sub": claims.get("sub"), "email": claims.get("email"), "token_use": claims.get("token_use")}
    return {"statusCode": 200, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}
