#!/usr/bin/env python3
"""在 OnePlus 8 Pro 的 USB 串口上跑一条命令 —— macOS/Linux 版。

Windows 那台用 scripts/op8p-sh.ps1（COM3 = 内核 console / ttyGS0，COM4 = 专用
root shell / ttyGS1）。换到 macOS 之后同一根线枚举成 /dev/cu.usbmodem*，**设备
节点名不带端口号**，所以没法靠命名区分那两个 ACM 口 —— 先用 --list 看一眼，
再拿 `uname -a` 试一下哪个输出干净（console 那个会混进 dmesg 噪声）。

    scripts/op8p-sh.py --list
    scripts/op8p-sh.py 'uname -a'
    scripts/op8p-sh.py -p /dev/cu.usbmodem143301 -t 6 'cat /proc/cmdline'
    scripts/op8p-sh.py -r 'dmesg | tail -30'        # 不追加完成标记

只依赖 python3 标准库（termios + select），不需要 pyserial —— 这台机器上装
pyserial 反而是多一个要去记的依赖。

退出码：0 = 收到完成标记；1 = 超时（"设备没说话"）；2 = 参数/环境问题。
分开的意义：超时和"返回了空字符串"在调试时是两件不同的事。
"""

import argparse
import glob
import os
import re
import select
import sys
import termios
import time
import uuid

# macOS 上 USB CDC ACM 会同时给 cu.* 和 tty.*。cu.* 是"callout"设备，不会因为
# 载波信号（DCD）而阻塞 —— 用 tty.* 在没有载波时会直接卡在 open()。
CANDIDATES = ["/dev/cu.usbmodem*", "/dev/cu.usbserial*", "/dev/ttyACM*"]


def find_ports():
    ports = []
    for pat in CANDIDATES:
        ports.extend(sorted(glob.glob(pat)))
    return ports


def configure(fd, baud):
    """原始模式 + 8N1，无流控。USB CDC 的波特率其实被忽略，但 termios 还得设。"""
    speed = getattr(termios, "B%d" % baud)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                        # iflag: 不要 \n 转换
    attrs[1] = 0                                        # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                        # lflag: 不要回显处理
    attrs[4] = speed
    attrs[5] = speed
    # cc 数组的布局各家不同（macOS 是 20 项），不能整个替换成 2 项 ——
    # 只动 VMIN/VTIME 两个下标，其余保持驱动给的默认值。
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def drain(fd, quiet_for=0.25, cap=2.0):
    """读掉进终端之前积压的东西（登录横幅、上次的命令尾巴、dmesg）。

    不做这一步，第一次读回来的是积压内容，答案看起来像被截断了。
    """
    deadline = time.time() + cap
    last = time.time()
    while time.time() < deadline and time.time() - last < quiet_for:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                if not os.read(fd, 65536):
                    break
            except OSError:
                break
            last = time.time()


def run(port, command, timeout, raw, baud):
    marker = "OP8P_" + uuid.uuid4().hex[:8] + "_DONE"
    payload = command if raw else "%s; echo %s" % (command, marker)
    # 完成标记必须**独占一行**才算数。设备会把我们写进去的命令回显一遍，而那
    # 一行里就带着 marker —— 只做子串匹配的话，"设备根本没回"会被读成"成功
    # 返回空"。这个错在 pty 上复现过：超时用例返回了 0 和一行空输出。
    mark_re = re.compile(rb"(?:^|\n)" + re.escape(marker.encode()) + rb"\r?(?:\n|$)")

    try:
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        print("打不开 %s: %s" % (port, e), file=sys.stderr)
        return 2
    try:
        configure(fd, baud)
        drain(fd)

        os.write(fd, (payload + "\n").encode())

        acc = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.12)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            acc += chunk
            if not raw and mark_re.search(acc):
                break
    finally:
        os.close(fd)

    text = acc.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    # 串口默认会把我们写进去的命令回显一遍；连完成标记那行一起去掉，
    # 否则调用方拿到的第一行永远是自己的命令。
    out = []
    for line in lines:
        if not raw and line.strip() == marker:      # echo 标记输出那一行
            continue
        if line.strip() == payload.strip():          # 回显的命令行
            continue
        out.append(line)
    print("\n".join(out).strip("\n"))

    if not raw and not mark_re.search(acc):
        print("op8p-sh: 超时 %ss 没等到完成标记 —— 设备可能没在跑 shell，"
              "或者换另一个 ACM 口试试" % timeout, file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("command", nargs="?", help="要执行的命令")
    ap.add_argument("-p", "--port", help="设备节点（默认自动挑第一个 usbmodem）")
    ap.add_argument("-t", "--timeout", type=float, default=3.0, help="秒，默认 3")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-r", "--raw", action="store_true",
                    help="不追加完成标记（命令自己带输出边界时用）")
    ap.add_argument("-l", "--list", action="store_true", help="列出候选串口后退出")
    a = ap.parse_args()

    ports = find_ports()
    if a.list:
        if not ports:
            print("没找到 USB 串口。检查：\n"
                  "  * 手机是否用数据线连着（充电线不行）；\n"
                  "  * cmdline 里有没有 steamos.usbshell=1（没有它就没有 ttyGS1 的 shell）；\n"
                  "  * iOS 的 usbmuxd 有时会抢走设备 —— 换一根口试试。")
            return 1
        print("候选串口：")
        for p in ports:
            print("  " + p)
        print("\n其中一个是 ttyGS0（内核 console，混着 dmesg），另一个是 ttyGS1"
              "（root shell）。用 `%s -p <端口> 'uname -a'` 试哪个干净。" % sys.argv[0])
        return 0

    if not a.command:
        ap.error("要么给一条命令，要么用 --list")

    port = a.port
    if not port:
        if not ports:
            print("没找到 USB 串口 —— 先跑 --list 看原因", file=sys.stderr)
            return 2
        port = ports[0]
        if len(ports) > 1:
            print("op8p-sh: 用了 %s（还有 %s；不对就 -p 指定）"
                  % (port, ", ".join(ports[1:])), file=sys.stderr)

    return run(port, a.command, a.timeout, a.raw, a.baud)


if __name__ == "__main__":
    sys.exit(main())
