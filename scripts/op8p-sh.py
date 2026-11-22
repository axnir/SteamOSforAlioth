#!/usr/bin/env python3
"""在 OnePlus 8 Pro 的 USB 串口上跑命令、推文件 —— macOS/Linux 版。

Windows 那台用 scripts/op8p-sh.ps1（COM3 = 内核 console / ttyGS0，COM4 = 专用
root shell / ttyGS1）。换到 macOS 之后同一根线枚举成 /dev/cu.usbmodem*，**设备
节点名不带端口号**，所以没法靠命名区分那两个 ACM 口 —— 先用 --list 看一眼，
再拿 `uname -a` 试一下哪个输出干净（console 那个会混进 dmesg 噪声）。

    scripts/op8p-sh.py --list
    scripts/op8p-sh.py 'uname -a'
    scripts/op8p-sh.py -p /dev/cu.usbmodem143301 -t 6 'cat /proc/cmdline'
    scripts/op8p-sh.py -r 'dmesg | tail -30'            # 不追加完成标记
    scripts/op8p-sh.py --push 本地文件:/proc/1/root/etc/xxx:644

实测（2026-11-22）：/dev/cu.usbmodem101 = ttyGS0 内核 console；
/dev/cu.usbmodem103 = ttyGS1 的**initramfs 救援 shell**（根里有 /newroot、/dbg，
没有 /usr，PATH 只有 /bin）—— 所以要碰真实系统，路径得写
/proc/1/root/...，或者 `/dbg/bin/busybox chroot /proc/1/root <命令>`。

只依赖 python3 标准库（termios + select + base64），不需要 pyserial。

退出码：0 = 成功；1 = 超时（"设备没说话"）；2 = 参数/环境问题。
分开的意义：超时和"返回了空字符串"在调试时是两件不同的事。
"""

import argparse
import base64
import errno
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


def write_all(fd, data):
    """把字节写进端口，遇到 EAGAIN 就等可写再继续。

    端口是 O_NONBLOCK 打开的（否则 open 会卡在 DCD 上），于是"缓冲满"表现为
    EAGAIN 而不是阻塞。分块推几 KB 时碰不到，推 MB 级数据时第一次就撞上：
    Errno 35，而端口完全健康。这一层必须处理，不能把它当成设备没了。
    """
    view = memoryview(data)
    while view:
        try:
            view = view[os.write(fd, view):]
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                select.select([], [fd], [], 0.5)
                continue
            raise


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


class Link:
    """一条已打开的串口连接，可以连续发多条命令（推文件时不必反复开关端口）。"""

    def __init__(self, port, baud):
        self.port = port
        self.baud = baud
        self.fd = None

    def __enter__(self):
        # EAGAIN/EBUSY 是"上一个进程刚关、排他锁还没释放"的瞬间。它出现过一次：
        # 连续两次调用时第二次直接报 Errno 35，而端口本身完全正常。open 是可重试
        # 的，所以这里重试而不是把这个当成"设备没了"。
        for attempt in range(20):
            try:
                self.fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
                break
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EBUSY) and attempt < 19:
                    time.sleep(0.15)
                    continue
                raise
        configure(self.fd, self.baud)
        drain(self.fd)
        return self

    def __exit__(self, *exc):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def cmd(self, command, timeout=3.0, raw=False):
        """跑一条命令，返回 (退出码, 输出文本)。raw 时不加标记、读到超时为止。

        为什么用**两个**起止标记，而且两端都要求独占一行：
          1. 设备会把命令回显一遍，回显行里就含标记 —— 只做子串匹配的话，
             "设备根本没回"会被读成"成功、输出为空"（pty 上复现过）；
          2. 只要求 END + "\n" 这个子串同样会成立：回显行
             `echo STARTS; cmd; echo ENDE` 自己就带着 END 和换行，于是循环
             第一次读到回显就 break，此时 start 行还没到，被判成超时。真机上
             稳定复现，而 **raw 模式反而正常**（raw 不检查标记，一直读到超时，
             所以看得见输出）—— 这个不对称是最误导人的地方。
          3. 命令一长，回显会在终端 80 列处折行，只删"整行等于命令"会留下
             残片（第一次上机就看到了半截 `oot /proc/1/root ...`）。
        """
        tag = uuid.uuid4().hex[:8]
        start = "OP8P" + tag + "S"
        end = "OP8P" + tag + "E"
        payload = command if raw else "echo %s; %s; echo %s" % (start, command, end)
        if os.environ.get("OP8P_DEBUG"):
            # 串口调试的第一原则：先确认自己发出去的是什么字节。
            print("payload=%r (%d 字符)" % (payload, len(payload)), file=sys.stderr)
        start_re = re.compile(rb"(?m)^" + re.escape(start.encode()) + rb"\r?$")
        end_re = re.compile(rb"(?m)^" + re.escape(end.encode()) + rb"\r?$")

        write_all(self.fd, (payload + "\n").encode())

        acc = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], 0.12)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            acc += chunk
            if not raw:
                norm = acc.replace(b"\r\n", b"\n")
                if start_re.search(norm) and end_re.search(norm):
                    break

        text = acc.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
        lines = text.split("\n")
        if raw:
            return 0, text.strip("\n")

        if start not in lines:
            # 没看到起始行：要么设备没回，要么命令把 start 那行吃掉了。原文照出，
            # 让人自己看 —— 静默吞掉一段输出比多打几行糟得多。
            return 1, text.strip("\n")
        body = lines[lines.index(start) + 1:]
        if end in body:
            return 0, "\n".join(body[:body.index(end)]).strip("\n")
        return 1, "\n".join(body).strip("\n") + "\n[没等到结束标记]"


def run(port, command, timeout, raw, baud):
    try:
        with Link(port, baud) as link:
            rc, text = link.cmd(command, timeout, raw)
    except OSError as e:
        print("打不开 %s: %s" % (port, e), file=sys.stderr)
        return 2
    if text:
        print(text)
    if rc != 0:
        print("op8p-sh: %s（%ss）—— 设备可能没在跑 shell，或换另一个 ACM 口试试"
              % ("超时" if raw else "没等到标记", timeout), file=sys.stderr)
    return rc


def push_stream(link, data, remote, timeout=600, chunk=4096):
    """流式推大文件：让设备先开一个"解码管道 + 定长 head"，然后连续灌数据。

    为什么不能沿用分块：分块每条命令都要等一个起止标记，400 字节一块意味着
    15 MB 要三万多次往返。这里只有一次命令往返，剩下纯数据。

    三个必须的细节：
      1. 设备 tty 会把收到的每个字节**回显**一遍。15 MB 的数据就有 15 MB 回显，
         不读的话设备侧输出缓冲几 KB 就满，然后写阻塞、死锁。所以先 `stty -echo`。
      2. 接收端用 `head -c N` 而不是读到 EOF：串口没有 EOF。解压后正好 N 字节，
         head 拿够就退出，上游收到的 SIGPIPE 正好关掉管道。
      3. 数据长度必须**精确**：多发的字节在管道关闭后会落到 shell 里被当命令执行。
         所以最后只补一个换行（base64 忽略它），不再追加任何东西。

    base64(gzip(data)) 而不是裸 base64：固件是 ELF，gzip 能省一半，串口上这是
    实打实的时间。
    """
    import gzip
    packed = gzip.compress(data, 9)
    b64 = base64.b64encode(packed)
    done = "OP8PPUSH" + uuid.uuid4().hex[:8]
    # 用**裸命令名**：流式推送只对完整系统 shell 有意义（initramfs 里没有
    # base64/gzip/head，只能用 /dbg/bin/busybox，而那套只适合几 KB 的分块）。
    # 这一点踩过：命令里写死 /dbg/bin/busybox，在 ttyGS0 的 bash 上整条管道
    # 直接 "No such file or directory"，一个字节都没传。
    # 必须 `stty raw`，不只是 `-echo`：getty 登录后的 tty 是 canonical 模式，
    # 输入要遇到换行才交给读进程，而 base64 数据是没有换行的 —— 于是全部堆在
    # 行缓冲里，超过 4 KB 就被丢掉。表现为"传了 21 秒、文件是空的"，且看不出
    # 任何错误。raw 之后字节直接给管道，多余的尾部数据也不会被 shell 当命令。
    cmd = ("stty raw -echo; base64 -d | gzip -d | head -c %d > %s; "
           "stty sane; echo %s" % (len(data), remote, done))
    print("流式推送 %d 字节（gzip %d → base64 %d 字符）"
          % (len(data), len(packed), len(b64)), file=sys.stderr)

    write_all(link.fd, (cmd + "\n").encode())
    time.sleep(0.6)          # 让 shell 建好管道；太短会有一截数据被 shell 吃掉

    for i in range(0, len(b64), chunk):
        write_all(link.fd, b64[i:i + chunk])
    write_all(link.fd, b"\n")

    want = done.encode()
    acc = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([link.fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk_out = os.read(link.fd, 65536)
        except OSError:
            break
        if not chunk_out:
            break
        acc += chunk_out
        if want in acc.replace(b"\r\n", b"\n"):
            break

    # 设备侧大小校验比"我们发完了"可信：数据在串口上是可能丢的。
    rc, out = link.cmd("wc -c < %s" % remote, 20)
    got = out.strip().split()[0] if out.strip() else "?"
    if got != str(len(data)):
        print("大小不符：远端 %s / 本地 %d —— 串口丢字节，重试" % (got, len(data)),
              file=sys.stderr)
        return 1
    print("OK  %s（%d 字节）" % (remote, len(data)), file=sys.stderr)
    return 0


def push(port, local, remote, mode, baud, chunk=400):
    """把本地文件推到设备上（base64 分块 + 同一条连接）。

    设备侧只有 /dbg/bin/busybox 保证可用（initramfs 的 /bin 里没有 cat/base64），
    所以每一步都走它。remote 是**救援 shell 视角**的路径 —— 要写真实系统就
    写 /proc/1/root/usr/...。
    """
    data = open(local, "rb").read()
    # 大文件走流式：分块方式适合几 KB（每一步都能校验），但 15 MB 要几万次
    # 往返，光等待就把时间耗光了。64 KB 是两者的分界，不是精确值。
    if len(data) > 65536:
        try:
            with Link(port, baud) as link:
                rc = push_stream(link, data, remote)
        except OSError as e:
            # 这里也可能是写的时候出错，不一定是 open —— 文案别写成"打不开"，
            # 上一次就是这样把 EAGAIN（写满）误读成端口占用。
            print("串口出错 %s: %s" % (port, e), file=sys.stderr)
            return 2
        if rc == 0:
            try:
                with Link(port, baud) as link:
                    link.cmd("/dbg/bin/busybox chmod %s %s" % (mode, remote), 8)
            except OSError:
                pass
        return rc

    b64 = base64.b64encode(data).decode()
    # 临时文件放在**目标文件所在目录**：救援 shell 的根是 initramfs，那里根本没有
    # /tmp（只有 /bin /boot /dbg /dev /lib /newroot /proc /sys），写 /tmp 会得到
    # "nonexistent directory"。目标目录一定是可写的（否则它自己也写不进去）。
    tmpdir = os.path.dirname(remote) or "/"
    tmp = "%s/.op8p-push-%s" % (tmpdir, uuid.uuid4().hex[:6])
    blocks = [b64[i:i + chunk] for i in range(0, len(b64), chunk)]

    print("推送 %s → %s（%d 字节, %d 块）" % (local, remote, len(data), len(blocks)),
          file=sys.stderr)
    try:
        with Link(port, baud) as link:
            # busybox 只在 initramfs 里（/dbg/bin）；完整系统 shell 有的是
            # base64/printf/chmod/wc 的原生版本，没有 busybox。写死任何一边都会
            # 在另一边失败（101 上就是这么报 "-bash: /dbg/bin/busybox: No such"），
            # 所以先问一句。
            rc, probe = link.cmd("test -x /dbg/bin/busybox && echo HAVE_BB || echo NO_BB", 8)
            bb = "/dbg/bin/busybox " if "HAVE_BB" in probe else ""
            rc, out = link.cmd(": > %s" % tmp, 3)
            if rc != 0:
                print("清空临时文件失败: %s" % out, file=sys.stderr)
                return 1
            for n, part in enumerate(blocks, 1):
                # base64 的字符集里没有单引号，可以直接用单引号包。printf 的 %s
                # 写成 %%s：这一串要经过 python 的 % 格式化。
                rc, out = link.cmd("%sprintf %%s '%s' >> %s" % (bb, part, tmp), 6)
                if rc != 0:
                    print("第 %d/%d 块失败: %s" % (n, len(blocks), out), file=sys.stderr)
                    return 1
            rc, out = link.cmd(
                # wc 读 stdin 只吐数字：带文件名的话解析要多一步，而这一步已经
                # 错过一次（split()[-1] 拿到的是路径，报"大小不符"，文件其实是好的）。
                "%sbase64 -d %s > %s && %schmod %s %s && %swc -c < %s"
                % (bb, tmp, remote, bb, mode, remote, bb, remote), 15)
            if rc != 0:
                print("装配失败（base64 -d / chmod / wc）: %s" % out, file=sys.stderr)
                return 1
            link.cmd("%srm -f %s" % (bb, tmp), 3)
    except OSError as e:
        print("打不开 %s: %s" % (port, e), file=sys.stderr)
        return 2

    got = out.strip().split()[0] if out.strip() else "?"
    if got != str(len(data)):
        print("大小不符：远端 %s 字节，本地 %d 字节" % (got, len(data)), file=sys.stderr)
        return 1
    print("OK  %s（%s 字节, mode %s）" % (remote, got, mode), file=sys.stderr)
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
    ap.add_argument("--push", metavar="LOCAL:REMOTE[:MODE]",
                    help="推一个文件到设备（base64 分块，用同一条连接）")
    a = ap.parse_args()

    ports = find_ports()
    if a.list:
        if not ports:
            print("没找到 USB 串口。检查：\n"
                  "  * 手机是否用数据线连着（充电线不行）；\n"
                  "  * cmdline 里有没有 steamos.usbshell=1（没有它就没有 ttyGS1 的 shell）。")
            return 1
        print("候选串口：")
        for p in ports:
            print("  " + p)
        print("\n一个通常是 ttyGS0（内核 console，混着 dmesg），另一个是 ttyGS1"
              "（救援 shell）。用 `%s -p <端口> 'uname -a'` 试哪个干净。" % sys.argv[0])
        return 0

    port = a.port
    if not port:
        if not ports:
            print("没找到 USB 串口 —— 先跑 --list 看原因", file=sys.stderr)
            return 2
        port = ports[0]
        if len(ports) > 1:
            print("op8p-sh: 用了 %s（还有 %s；不对就 -p 指定）"
                  % (port, ", ".join(ports[1:])), file=sys.stderr)

    if a.push:
        parts = a.push.split(":")
        if len(parts) < 2:
            ap.error("--push 需要 LOCAL:REMOTE[:MODE]")
        local, remote = parts[0], parts[1]
        mode = parts[2] if len(parts) > 2 else "644"
        return push(port, local, remote, mode, a.baud)

    if not a.command:
        ap.error("要么给一条命令，要么用 --push / --list")
    return run(port, a.command, a.timeout, a.raw, a.baud)


if __name__ == "__main__":
    sys.exit(main())
