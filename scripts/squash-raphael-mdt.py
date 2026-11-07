#!/usr/bin/env python3
"""把 Qualcomm 的 .mdt + .bNN 分段固件拼成单个 ELF/.mbn。

和 scripts/extract-alioth-firmware.sh 里的 squash() 同一套算法（等价
pil-squasher）：.mdt 是剥掉段内容的 ELF 头 + program header 表，第 i 段的
内容在 .bNN 里，按 p_offset 写回去，再把 ELF 头原样抄到前面。

用法: python3 squash-mdt.py <prefix> <out>
  prefix 形如 work/raphael-fw/modem-image/adsp  （会自动找 .mdt/.bNN）
"""
import struct
import sys
from pathlib import Path

prefix = Path(sys.argv[1])
out = Path(sys.argv[2])
mdt = prefix.with_suffix(".mdt")
d = mdt.read_bytes()
if d[:4] != b"\x7fELF":
    sys.exit(f"{mdt}: 不是 ELF")

if d[4] == 1:                                   # ELF32
    phoff, = struct.unpack_from("<I", d, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x2A)
    def ph(i):
        vals = struct.unpack_from("<8I", d, phoff + i * phentsize)
        return vals[1], vals[4]                 # p_offset, p_filesz
else:                                           # ELF64
    phoff, = struct.unpack_from("<Q", d, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
    def ph(i):
        vals = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        return vals[2], vals[5]

img = bytearray()
for i in range(phnum):
    off, size = ph(i)
    if not size:
        continue
    seg = prefix.with_suffix(f".b{i:02d}")
    data = seg.read_bytes() if seg.exists() else d[off:off + size]
    if len(img) < off + len(data):
        img.extend(b"\0" * (off + len(data) - len(img)))
    img[off:off + len(data)] = data

hdr = phoff + phnum * phentsize
img[:hdr] = d[:hdr]
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(img)
print(f"{out}: {len(img)} 字节 ({phnum} 段)")
