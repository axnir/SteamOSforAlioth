#!/usr/bin/env python3
"""把 U-Boot 的默认环境改成「开机直接进 fastboot」，重打成 boot 镜像。

为什么改默认环境而不是 saveenv：这版 U-Boot 没有可写的 env 后端（镜像里找不到
uboot.env 之类的字符串），`saveenv` 没有落点，默认环境是编译进 .rodata 的一段
纯字符串数组 —— 那就直接改它。

为什么安全：环境里自带

    button_cmd_0_name=Volume Down
    button_cmd_0=run menucmd

按住音量下开机会直接进菜单。所以即使 bootcmd 变成 fastboot，菜单和 shell 都还在。

前置（work/uboot/ 里要有这三样）：

    python3 - <<'PY'
    import struct, zlib
    d = open("work/uboot/u-boot.img","rb").read()
    ks, = struct.unpack("<I", d[8:12]); ps = 4096
    o = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = o.decompress(d[ps:ps+ks]) + o.flush()
    open("work/uboot/u-boot.bin","wb").write(raw)
    open("work/uboot/uboot.dtb","wb").write(o.unused_data[:108704])
    PY

产出 u-boot-fastboot.img = 原头部（v0，page 4096，kernel_addr 0x8000）+ gzip(改过的
u-boot.bin) + 原样追加的 DTB。写 boot 分区用，回退是 stock-boot.img。
"""
import gzip
import struct
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent / "work" / "uboot"
SRC_IMG = BASE / "u-boot.img"
SRC_BIN = BASE / "u-boot.bin"
DTB = BASE / "uboot.dtb"
OUT_BIN = BASE / "u-boot-fastboot.bin"
OUT_IMG = BASE / "u-boot-fastboot.img"

NEW_BOOTCMD = b"bootcmd=run fastboot"
ENTRY = b"bootcmd="


def extract_env(data: bytes):
    """默认环境是一串 NUL 结尾的 key=value，以两个 NUL 收尾。"""
    i = data.find(ENTRY)
    if i < 0:
        sys.exit("找不到 bootcmd=，和预期的镜像不一样")
    end = data.find(b"\x00\x00", i)
    if end < 0:
        sys.exit("环境块没有双 NUL 结尾")
    end += 1
    entries = [e for e in data[i:end].split(b"\x00") if e]
    return i, end, entries


def main() -> None:
    bin_data = bytearray(SRC_BIN.read_bytes())
    start, end, entries = extract_env(bytes(bin_data))

    old = entries[0]
    if not old.startswith(ENTRY):
        sys.exit(f"第一条不是 bootcmd：{old!r}")
    print(f"原 bootcmd : {old.decode()}")
    print(f"新 bootcmd : {NEW_BOOTCMD.decode()}")
    if len(NEW_BOOTCMD) > len(old):
        sys.exit("新值比原值长，会顶掉后面的条目 —— 换个更短的写法")

    entries[0] = NEW_BOOTCMD
    blob = b"".join(e + b"\x00" for e in entries) + b"\x00"
    if len(blob) > end - start:
        sys.exit(f"新环境 {len(blob)} 字节超过原区段 {end - start} 字节")
    blob = blob.ljust(end - start, b"\x00")     # 尾部补 NUL，长度不变
    bin_data[start:end] = blob

    OUT_BIN.write_bytes(bin_data)
    print(f"写出 {OUT_BIN} ({len(bin_data)} 字节，环境 {start}..{end})")

    # 按原镜像的头部重新打包：header | gzip | dtb，全部页对齐
    orig = SRC_IMG.read_bytes()
    hdr = struct.unpack("<8s10I16s512s32s1024s", orig[:1632])
    page = hdr[8]
    payload = gzip.compress(bytes(bin_data), 9, mtime=0) + DTB.read_bytes()

    new_hdr = bytearray(orig[:page])
    struct.pack_into("<I", new_hdr, 8, len(payload))          # kernel_size
    struct.pack_into("<I", new_hdr, 16, 0)                    # ramdisk_size
    body = bytes(new_hdr) + payload
    pad = (-len(body)) % page
    body += b"\x00" * pad
    OUT_IMG.write_bytes(body)
    print(f"写出 {OUT_IMG} ({len(body)} 字节，payload {len(payload)}，page {page})")


if __name__ == "__main__":
    main()
