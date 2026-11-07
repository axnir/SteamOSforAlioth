#!/usr/bin/env python3
"""打 Android boot image v2（带独立的 DTB 段）。

为什么要 v2：raphael 上那版 U-Boot 的 `fastboot boot` 走的是 bootm 的
Android 镜像路径，它在解析时明确要求

    Error: header_version must be >= 2 to get dtb

—— v1 头没有 dtb_size / dtb_addr 字段，于是 `Working FDT set to 0`，
接着 bootm 因为没有设备树直接 `FDT and ATAGS support not compiled in`
并 `ERROR: Please RESET the board`。

v2 在 v1（1648 字节）后面再加 dtb_size(4) + dtb_addr(8)，共 1660 字节，
然后把 DTB 作为一个独立段放在 recovery_dtbo 之后。这样 bootm 能取到
设备树并交给内核。

段顺序（每段按 page_size 对齐）：
    header | kernel | ramdisk | second | recovery_dtbo | dtb
"""
import argparse
import hashlib
import struct
from pathlib import Path

PAGE = 4096


def pad(data: bytes, page: int) -> bytes:
    rem = len(data) % page
    return data if rem == 0 else data + b"\0" * (page - rem)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--pagesize", type=lambda v: int(v, 0), default=PAGE)
    ap.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=0x8000)
    ap.add_argument("--ramdisk-addr", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--tags-addr", type=lambda v: int(v, 0), default=0x100)
    ap.add_argument("--second-addr", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--dtb-addr", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--os-version", type=lambda v: int(v, 0), default=0x16000155)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    kernel = Path(a.kernel).read_bytes()
    dtb = Path(a.dtb).read_bytes()
    ps = a.pagesize

    cmdline = a.cmdline.encode()
    assert len(cmdline) < 512, "cmdline 太长"
    cmdline = cmdline.ljust(512, b"\0")

    header = bytearray(1660)
    header[0:8] = b"ANDROID!"
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 12, a.kernel_addr)
    struct.pack_into("<I", header, 16, 0)                 # ramdisk_size
    struct.pack_into("<I", header, 20, a.ramdisk_addr)
    struct.pack_into("<I", header, 24, 0)                 # second_size
    struct.pack_into("<I", header, 28, a.second_addr)
    struct.pack_into("<I", header, 32, a.tags_addr)
    struct.pack_into("<I", header, 36, ps)
    struct.pack_into("<I", header, 40, 2)                 # header_version = 2
    struct.pack_into("<I", header, 44, a.os_version)
    header[48:64] = b"steamos\0".ljust(16, b"\0")
    header[64:64 + 512] = cmdline
    # id 字段 32 字节，sha1 只有 20 —— 按长度切片赋值，别撑大/缩小 bytearray
    digest = hashlib.sha1(kernel + dtb).digest()
    header[608:608 + len(digest)] = digest
    struct.pack_into("<I", header, 1632, 0)               # recovery_dtbo_size
    struct.pack_into("<Q", header, 1636, 0)               # recovery_dtbo_offset
    struct.pack_into("<I", header, 1644, 1660)            # header_size
    struct.pack_into("<I", header, 1648, len(dtb))        # dtb_size
    struct.pack_into("<Q", header, 1652, a.dtb_addr)      # dtb_addr

    body = pad(bytes(header), ps) + pad(kernel, ps) + pad(dtb, ps)
    Path(a.out).write_bytes(body)
    print(f"{a.out}: {len(body)} 字节  (header v2 1660, kernel {len(kernel)}, dtb {len(dtb)})")


if __name__ == "__main__":
    main()
