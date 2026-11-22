#!/usr/bin/env python3
"""把 Steam 的 CM 端口接到 Mac 的 SOCKS5 上（临时方案，重启失效）。

为什么需要它：国内网络对 Steam CM（TCP 27015-27050）是阻断的，设备直连
`cm0.steampowered.com:27017` 超时（实测），但同一个目标经 Mac 的 SOCKS5
能连上（`SOCKS rep=0`）。Steam 客户端只认 HTTP 代理、而且只给商店/更新用，
CM 连接完全不看代理设置 —— 所以只能在设备本机把这些端口接住，转出去。

配合（两件事缺一不可）：
  1. /etc/hosts: 127.0.0.1 cm0.steampowered.com … cm4.steampowered.com
  2. 本脚本监听 27015-27019，把每个连接经 SOCKS5 转给真正的 CM

它只影响 Steam 的 CM 连接，不动别的流量；kill 掉或重启即恢复原状。

**状态（2026-11-22 20:15）：没成功，留着备用。** 当时的做法是 hosts 列出
58 个 `(cmp|ext)*.steamserver.net`，结果 Steam 下一次连的 `ext2-jnb1` 不在名单里，
转发器一个连接都没接到 —— CM 域名有上百个且动态变化，hosts 这条路的覆盖面
不够。真正可用的做法是在 DNS 层劫持整片 `*.steamserver.net`（设备上有 dnsmasq，
但需要临时停 `systemd-resolved`），或者给内核补 `CONFIG_IP_NF_NAT` 走 iptables
透明代理。转发器本身（SOCKS5 + 端口保持）是好的，换任何一种劫持方式都能复用。
"""

import select
import socket
import struct
import sys
import threading

PROXY = ("192.168.5.7", 7890)
# 目标固定成 cm0 —— CM 之间是等价的（同一个后端），所以本地收到哪个端口就用
# 哪个端口连 cm0：27018 进来的继续连 cm0:27018，443 进来的连 cm0:443。
# 实测这五个端口经 SOCKS5 全部 rep=0。
TARGET_HOST = "cm0.steampowered.com"
PORTS = list(range(27015, 27051)) + [443]


def socks5_connect(host, port, timeout=8):
    s = socket.create_connection(PROXY, timeout)
    s.sendall(b"\x05\x01\x00")
    if s.recv(2)[:2] != b"\x05\x00":
        raise OSError("socks5 greeting failed")
    h = host.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + struct.pack(">H", port))
    r = s.recv(4)
    if len(r) < 2 or r[1] != 0:
        raise OSError("socks5 connect rc=%s" % (r[1] if len(r) > 1 else "?"))
    # 消费掉剩余地址字段（ATYP 可能是域名/IPv4/IPv6）
    atyp = r[3] if len(r) > 3 else 1
    need = {1: 4 + 2, 3: (r[4] if len(r) > 4 else 0) + 2, 4: 16 + 2}.get(atyp, 0)
    got = len(r) - 4
    while got < need:
        got += len(s.recv(need - got))
    return s


def pump(a, b):
    """双向搬运，直到任一端关闭。"""
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 120)
            if not r:
                break
            for src in r:
                data = src.recv(8192)
                if not data:
                    return
                (b if src is a else a).sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass


def handle(client, port):
    try:
        upstream = socks5_connect(TARGET_HOST, port)
    except Exception as e:  # noqa: BLE001 - 一条连接失败不影响别的
        print("cm-proxy: upstream fail: %s" % e, file=sys.stderr)
        client.close()
        return
    pump(client, upstream)


def serve(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    print("cm-proxy: listening 127.0.0.1:%d -> %s:%d via %s:%d"
          % (port, TARGET_HOST, port, PROXY[0], PROXY[1]), file=sys.stderr)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, port), daemon=True).start()


if __name__ == "__main__":
    for p in PORTS:
        threading.Thread(target=serve, args=(p,), daemon=True).start()
    threading.Event().wait()
