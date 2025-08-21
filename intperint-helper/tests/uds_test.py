#!/usr/bin/env python3
import os, socket, json, time
SOCK = "/tmp/intperint.sock"

def send(req: dict):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((json.dumps(req)+"\n").encode())
    data = b""
    while True:
        ch = s.recv(4096)
        if not ch: break
        data += ch
        if b"\n" in data:
            line, _, rest = data.partition(b"\n")
            return json.loads(line.decode())
    return None

if __name__ == "__main__":
    print("generate_image...")
    r = send({
        "op":"generate_image",
        "prompt":"a cat running in the field",
        "negative_prompt":"",
        "steps": 5,
        "w": 512,
        "h": 512
    })
    print("resp:", r)
    assert r and r.get("status") in ("ok","error")

    print("submit_video queue...")
    r2 = send({
        "op":"submit_video",
        "prompt":"a dog",
        "init_image":"/tmp/init.png",
        "motion_module":"animatediff_v1",
        "frames": 8
    })
    print("resp2:", r2)
    jid = r2.get("jobid")
    assert jid
    for _ in range(30):
        st = send({"op":"job_status","jobid":jid})
        print("status:", st)
        if st.get("status") in ("done","error"): break
        time.sleep(1)
    print("done")
