#!/usr/bin/env python3
"""对 Steam 的 CEF 调试端口做一次 Runtime.evaluate。

比 `ps | grep steam` 可靠得多：进程在跑不代表界面有内容。

用法:
    python3 raphael-cdp-eval.py                        # 主 BPM 页面的标题/URL/可见文本
    python3 raphael-cdp-eval.py "document.title"       # 自定义表达式
    python3 raphael-cdp-eval.py --list                 # 只列页面
"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.request

HOST = "127.0.0.1"
PORT = 8080


def pages():
    url = "http://%s:%d/json" % (HOST, PORT)
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def pick(sub="big picture"):
    ps = pages()
    for p in ps:
        if sub.lower() in p.get("title", "").lower():
            return p
    return ps[0]


def _recv(sock, buf, n):
    while len(buf) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("socket closed")
        buf += chunk
    out = bytes(buf[:n])
    del buf[:n]
    return out


def _read_msg(sock, buf):
    b1, b2 = _recv(sock, buf, 2)
    opcode = b1 & 0x0F
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", _recv(sock, buf, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", _recv(sock, buf, 8))[0]
    mask = _recv(sock, buf, 4) if b2 & 0x80 else None
    data = _recv(sock, buf, length)
    if mask:
        data = bytes(x ^ mask[i % 4] for i, x in enumerate(data))
    return opcode, data


def evaluate(ws_url, expr, timeout=8.0):
    rest = ws_url[len("ws://"):]
    hostport, path = rest.split("/", 1)
    host, port = hostport.split(":")
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        "GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key)
    )
    sock.sendall(req.encode())
    buf = bytearray()
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    head, _, tail = bytes(buf).partition(b"\r\n\r\n")
    buf = bytearray(tail)
    if b"101" not in head.split(b"\r\n")[0]:
        raise SystemExit("handshake failed: %r" % head[:160])

    payload = json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": expr, "returnByValue": True},
    }).encode()
    mask = os.urandom(4)
    n = len(payload)
    frame = bytearray([0x81])
    if n < 126:
        frame.append(0x80 | n)
    elif n < 65536:
        frame.append(0x80 | 126)
        frame += struct.pack(">H", n)
    else:
        frame.append(0x80 | 127)
        frame += struct.pack(">Q", n)
    frame += mask
    frame += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(frame))

    reply = None
    for _ in range(64):
        opcode, data = _read_msg(sock, buf)
        if opcode == 1 and data:
            try:
                msg = json.loads(data.decode("utf-8", "replace"))
            except ValueError:
                continue
            if msg.get("id") == 1:
                reply = msg
                break
    sock.close()
    return reply


def main():
    args = [a for a in sys.argv[1:]]
    if args and args[0] == "--list":
        for p in pages():
            print("%s | %s" % (p.get("title"), p.get("type")))
        return
    expr = args[0] if args else (
        "[document.title, location.href, "
        "(document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 300) : '')]"
        ".join(' ||| ')"
    )
    page = pick()
    print("page: %s" % page.get("title"))
    reply = evaluate(page["webSocketDebuggerUrl"], expr)
    if reply is None:
        print("no reply")
        return
    if "error" in reply:
        print("error: %s" % json.dumps(reply["error"], ensure_ascii=False))
        return
    result = reply.get("result", {})
    if "exceptionDetails" in result:
        print("exception: %s" % json.dumps(result["exceptionDetails"], ensure_ascii=False)[:400])
        return
    value = result.get("result", {}).get("value")
    print("value: %s" % (value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)))


if __name__ == "__main__":
    main()
