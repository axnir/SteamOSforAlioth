#!/usr/bin/env python3
"""Android boot image (header v1) writer with Xiaomi's uncompressed-kernel wrapper.

这台机器（raphael）的 ABL 不收 alioth 那种 "gzip 流 + 后面拼 DTB" 的内核段。
第一次刷写：镜像能写进 boot，`fastboot flash` 全部 OKAY，但重启 6 秒回到
fastboot，没有任何内核日志 —— 加载期就拒了。

从原厂 boot.img 里解出来的真实格式（不是猜的，每个字段都在镜像里对上了）：

    kernel 段 = "UNCOMPRESSED_IMG"          16 字节 ASCII
              + u32  dtb_offset             DTB 在 **Image 内**的偏移
              + Image                       裸 arm64 Image，不压缩
              + DTB(s)                      追加在 Image 后面

证据：
  * 段首是 ASCII "UNCOMPRESSED_IMG"，Image 从段内 +20 开始（0x38 处是 ARMd）
  * 段内 +20+u32 处正是 FDT 魔数 d00dfeed，后面跟着 4 个 DTB
  * 头部是 v1（header_size 1648），kernel_size 覆盖整个段

所以这个文件的职责是：给 Image + 一个 DTB 套上那 20 字节的头，算好偏移，
再写 v1 的 Android 头部。header 其余字段全部来自原厂镜像：

    page_size 4096  kernel_addr 0x8000  ramdisk_addr 0x0
    tags_addr 0x100  os_version 0x16000155
"""
from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

BOOT_MAGIC = b"ANDROID!"
HEADER_SIZE = 1648
XIAOMI_MAGIC = b"UNCOMPRESSED_IMG"


def pad(data: bytes, page: int) -> bytes:
    rem = len(data) % page
    return data if rem == 0 else data + b"\0" * (page - rem)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True, help="裸 arm64 Image")
    ap.add_argument("--dtb", required=True, help="追加到 Image 后面的 DTB")
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--pagesize", type=int, default=4096)
    ap.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=0x8000)
    ap.add_argument("--ramdisk-addr", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--tags-addr", type=lambda v: int(v, 0), default=0x100)
    ap.add_argument("--second-addr", type=lambda v: int(v, 0), default=0)
    # 原厂镜像声明的是 0x16000155（Android 11）。显式给值而不是按日期算：
    # 这个字段在 ABL 那边可能被比较，而"今天是几号"不是能对表的东西。
    ap.add_argument("--os-version", type=lambda v: int(v, 0), default=0x16000155)
    # 原厂 Image 头里 text_offset 是 0x80000（我们的内核编出来是 0，7.x 的可重定位
    # 内核默认就是 0）。ABL 可能拿它算加载位置：0 的话内核会落在 kernel_addr
    # 本身，和 tags(0x100)、DTB 挤在一起。要不要改由调用方决定，这里只提供手段。
    ap.add_argument("--image-text-offset", type=lambda v: int(v, 0), default=None)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    image = Path(a.image).read_bytes()
    if a.image_text_offset is not None:
        image = bytearray(image)
        struct.pack_into("<Q", image, 8, a.image_text_offset)
        image = bytes(image)
    dtb = Path(a.dtb).read_bytes()
    ramdisk = Path(a.ramdisk).read_bytes() if a.ramdisk else b"dummy"
    cmd = a.cmdline.encode("ascii")
    if len(cmd) >= 512:
        raise SystemExit(f"cmdline too long ({len(cmd)} >= 512)")

    # 小米的封装：魔数 + DTB 偏移 + Image + DTB。偏移相对 Image 起点，
    # 也就是 Image 的长度（DTB 紧贴在它后面）。
    dtb_offset = len(image)
    kernel = XIAOMI_MAGIC + struct.pack("<I", dtb_offset) + image + dtb

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, b""):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))

    hdr = struct.pack(
        "<8s10I16s512s32s1024s",
        BOOT_MAGIC,
        len(kernel), a.kernel_addr,
        len(ramdisk), a.ramdisk_addr,
        0, a.second_addr,
        a.tags_addr,
        a.pagesize,
        1,                             # header_version：原厂是 v1
        a.os_version,
        b"",                           # name
        cmd,
        sha.digest().ljust(32, b"\0"),
        b"",                           # extra cmdline
    )
    hdr += struct.pack("<IQI", 0, 0, HEADER_SIZE)
    assert len(hdr) == HEADER_SIZE, len(hdr)

    img = pad(hdr, a.pagesize) + pad(kernel, a.pagesize) + pad(ramdisk, a.pagesize)
    Path(a.out).write_bytes(img)
    print(f"{a.out}: {len(img)} bytes, kernel {len(kernel)} "
          f"(image {len(image)} + dtb {len(dtb)} at {dtb_offset}), cmdline {len(cmd)} chars")


if __name__ == "__main__":
    main()
