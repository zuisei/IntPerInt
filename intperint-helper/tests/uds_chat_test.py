#!/usr/bin/env python3
import socket
import json
import time

SOCK = "/tmp/intperint.sock"

def recv_lines(sock):
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        while True:
            i = buf.find(b"\n")
            if i < 0:
                break
            line = buf[:i]
            buf = buf[i+1:]
            if not line:
                continue
            try:
                obj = json.loads(line.decode('utf-8'))
            except Exception:
                print("bad json:", line)
                continue
            yield obj


def main():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    jid = hex(int(time.time()))[2:]
    req = {
        "op": "start_chat",
        "model": "llm_20b",
        "prompt": "Hello from test",
        "tokens": 32,
        "stream": True,
        "jobid": jid,
    }
    s.sendall((json.dumps(req) + "\n").encode("utf-8"))

    got_token = False
    for obj in recv_lines(s):
        print(obj)
        if obj.get("op") == "token":
            got_token = True
        if obj.get("op") == "done":
            break
    s.close()
    assert got_token, "no token events received"
    print("OK: streaming tokens received")

if __name__ == "__main__":
    main()
