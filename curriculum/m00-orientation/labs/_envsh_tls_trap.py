"""M00 verify.sh 의 거부 시험용 루프백 "TLS 종단 프록시" (_envsh_refusal_check.sh 가 띄운다. 직접 실행할 일은 없다).

CONNECT 를 받으면 200 을 돌려주고 직접 TLS 서버 역할(시험마다 만드는 임시 자체 서명 인증서)을 한다. 아무 데도 전달하지 않는다.
클라이언트가 인증서를 믿지 않으면 핸드셰이크가 실패해 HTTP 요청은 오지 않는다. 받은 CONNECT 와 결과를 파일에 적는다.
사용법: python _envsh_tls_trap.py <기록 파일> <포트 파일> <cert.pem> <key.pem>
"""
import socket
import ssl
import sys
import threading

log_path, port_path, cert, key = sys.argv[1:5]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(64)
open(port_path, "w").write(str(srv.getsockname()[1]))


def log(s: str) -> None:
    with open(log_path, "a") as f:
        f.write(s + "\n")


def handle(c: socket.socket) -> None:
    try:
        c.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = c.recv(1024)
            if not chunk:
                return
            data += chunk
        first = data.split(b"\r\n", 1)[0].decode("latin-1")
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        try:
            t = ctx.wrap_socket(c, server_side=True)
        except Exception as e:
            log(f"{first} -> TLS 핸드셰이크 실패({type(e).__name__}): HTTP 요청 없음")
            return
        req = t.recv(4096).split(b"\r\n")
        auth = [h for h in req if h.lower().startswith(b"authorization")]
        log(f"{first} -> TLS 성립, HTTP 요청 받음: {req[0][:80]!r} authorization={'있음' if auth else '없음'}")
        t.close()
    except Exception as e:
        log(f"오류 {type(e).__name__}: {e}")
    finally:
        c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
