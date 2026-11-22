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
    # 起止双标记，取两者**之间**的输出。为什么不是"一个 marker + 子串匹配"：
    #   1. 设备会把命令回显一遍，回显行里就含 marker —— 子串匹配会把"设备根本
    #      没回"读成"成功、输出为空"（pty 上复现过：超时用例返回 0 和一行空）；
    #   2. 命令一长，回显会在终端 80 列处折行，只删"整行等于命令"会留下残片
    #      （真机上第一次跑就看到了半截 `oot /proc/1/root ...`）。
    # 用独占行的两端标记，回显（不论折不折行）天然落在 start 之前，整段丢掉。
    tag = uuid.uuid4().hex[:8]
    start = "OP8P" + tag + "S"
    end = "OP8P" + tag + "E"
    payload = command if raw else "echo %s; %s; echo %s" % (start, command, end)
    if os.environ.get("OP8P_DEBUG"):
        # 串口调试的第一原则：先确认自己发出去的是什么字节。
        print("payload=%r (%d 字符)" % (payload, len(payload)), file=sys.stderr)
    # 两端都必须是**独占一行**才算数。只找 "END\n" 这种子串会在回显阶段就
    # 成立 —— 回显行是 `echo STARTS; cmd; echo ENDE`，它自己就带着 END 和
    # 一个换行，于是循环第一次读到回显就 break，然后 start 行还没到，被当成
    # "超时"。真机上稳定复现（raw 模式反而正常，因为 raw 不检查标记，一直
    # 读到超时，所以看得到输出）。pty 假设备上没暴露，因为它在同一次 write
    # 里就把回显和执行结果都吐出来了。
    start_re = re.compile(rb"(?m)^" + re.escape(start.encode()) + rb"\r?$")
    end_re = re.compile(rb"(?m)^" + re.escape(end.encode()) + rb"\r?$")

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
            if not raw:
                norm = acc.replace(b"\r\n", b"\n")
                if start_re.search(norm) and end_re.search(norm):
                    break
    finally:
        os.close(fd)

    text = acc.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")

    if raw:
        print(text.strip("\n"))
        return 0

    try:
        i = lines.index(start) if start in lines else -1
    except ValueError:
        i = -1
    if i < 0:
        # 没看到起始行：要么设备没回，要么命令把 start 那行吃掉了。原文照出，
        # 让人自己看 —— 静默吞掉一段输出比多打几行糟得多。
        print(text.strip("\n"))
        print("op8p-sh: 超时 %ss 没等到起始标记 —— 设备可能没在跑 shell，"
              "或者换另一个 ACM 口试试" % timeout, file=sys.stderr)
        return 1

    body = lines[i + 1:]
    if end in body:
        body = body[:body.index(end)]
        rc = 0
    else:
        print("op8p-sh: 看到起始标记但 %ss 内没等到结束标记 —— 命令可能还在跑，"
              "用 -t 加长" % timeout, file=sys.stderr)
        rc = 1
    print("\n".join(body).strip("\n"))
    return rc


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
