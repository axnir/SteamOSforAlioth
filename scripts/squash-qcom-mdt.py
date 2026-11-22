#!/usr/bin/env python3
"""把 Qualcomm 的 .mdt + .bNN 段拼回一个 .mbn（ELF）。

    squash-qcom-mdt.py <in.mdt> <out.mbn>

.mdt 只有 ELF 头和 program header 表，段内容被剥到同目录的 <前缀>.bNN 里
（NN 是 program header 的序号，两位十进制）。把每段的字节按 p_offset 写回、
再把头部原样抄到前面，就得到完整镜像。

校验过（2026-11-21，op8p 的 a650_zap）：拿 vendor 的 .mdt+.bNN 跑一遍，输出
与 linux-firmware 里现成的 .mbn 长度一致（13964 B），哈希段与代码段逐字节
相同，**只有 b01 不同** —— b01 是签名段（X.509 证书链），两个来源的签名者
不同。所以这个工具只做「拼装」，不做「签名」：拼出来的镜像能否被 TZ 接受，
取决于原 .mdt 自带的那条证书链。

算法与 scripts/extract-alioth-firmware.sh 里的 squash()、linux-msm 的
pil-squasher 一致。之所以单独成文件，是因为 op8p 要直接在设备上跑
（机内有 python3，而 Windows 侧没有 python3）。

同时支持 ELF32（d[4] == 1）和 ELF64。
"""

import struct
import sys
from pathlib import Path


def program_headers(d: bytes):
    if d[4] == 1:
        phoff, = struct.unpack_from("<I", d, 0x1C)
        phentsize, phnum = struct.unpack_from("<HH", d, 0x2A)

        def ph(i):
            _, off, _, _, filesz, _, _, _ = struct.unpack_from(
                "<8I", d, phoff + i * phentsize)
            return off, filesz
    else:
        phoff, = struct.unpack_from("<Q", d, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", d, 0x36)

        def ph(i):
            _, _, off, _, _, filesz, _, _ = struct.unpack_from(
                "<IIQQQQQQ", d, phoff + i * phentsize)
            return off, filesz

    return phoff, phentsize, phnum, ph


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)

    mdt = Path(sys.argv[1])
    out = Path(sys.argv[2])

    d = mdt.read_bytes()
    if d[:4] != b"\x7fELF":
        sys.exit(f"{mdt}: not an ELF file")

    phoff, phentsize, phnum, ph = program_headers(d)

    img = bytearray()
    for i in range(phnum):
        off, size = ph(i)
        if not size:
            continue
        seg = mdt.with_suffix(f".b{i:02d}")
        data = seg.read_bytes() if seg.exists() else d[off:off + size]
        if len(img) < off + len(data):
            img.extend(b"\0" * (off + len(data) - len(img)))
        img[off:off + len(data)] = data

    hdr = phoff + phnum * phentsize
    img[:hdr] = d[:hdr]

    out.write_bytes(img)
    print(f"{out}: {len(img)} bytes from {phnum} phdrs", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
