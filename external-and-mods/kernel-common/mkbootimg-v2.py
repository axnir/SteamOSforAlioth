#!/usr/bin/env python3
"""Android boot image, **header version 2**, with a DTB segment.

Written for OnePlus 8 Pro (instantnoodlep), whose stock ABL takes a v2 header
and wants the device tree in the image's own `dtb` slot, rather than appended
after the kernel (that is alioth's Xiaomi ABL, and what mkbootimg-v0.py does).

Header layout, from AOSP
system/tools/mkbootimg/include/bootimg/bootimg.h -- all fields are
__attribute__((packed)), little-endian:

  boot_img_hdr_v0                                    1632 bytes
    magic[8] kernel_size kernel_addr ramdisk_size ramdisk_addr
    second_size second_addr tags_addr page_size header_version os_version
    name[16] cmdline[512] id[32] extra_cmdline[1024]
  boot_img_hdr_v1 : v0 +                              16 bytes
    recovery_dtbo_size(u32) recovery_dtbo_offset(u64) header_size(u32)
  boot_img_hdr_v2 : v1 +                              12 bytes
    dtb_size(u32) dtb_addr(u64)

  -> v1 = 1648, v2 = 1660

Note recovery_dtbo_offset and dtb_addr are **uint64**, not uint32. Getting
that wrong shifts header_size and the bootloader silently starts reading the
kernel from the middle of the header.

Image layout (everything page-aligned):
  header (1 page) | kernel | ramdisk | second | recovery_dtbo | dtb
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import struct
from pathlib import Path

BOOT_MAGIC = b"ANDROID!"

# Sizes computed from the packed struct definitions above, asserted below so
# a future edit cannot silently drift.
HDR_V0 = 8 + 10 * 4 + 16 + 512 + 32 + 1024      # 1632
HDR_V1 = HDR_V0 + 4 + 8 + 4                     # 1648
HDR_V2 = HDR_V1 + 4 + 8                         # 1660
assert (HDR_V0, HDR_V1, HDR_V2) == (1632, 1648, 1660)


def pad(data: bytes, page: int) -> bytes:
    rem = len(data) % page
    return data if rem == 0 else data + b"\0" * (page - rem)


def os_version_field(major: int, minor: int, patch: int, year: int, month: int) -> int:
    # A[31:25] B[24:18] C[17:11] (Y-2000)[10:4] M[3:0]
    return (((major & 0x7F) << 25) | ((minor & 0x7F) << 18) | ((patch & 0x7F) << 11)
            | (((year - 2000) & 0x7F) << 4) | (month & 0xF))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk")
    ap.add_argument("--dtb", required=True,
                    help="device tree blob; goes in the v2 dtb slot")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--pagesize", type=int, default=4096)
    ap.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=0x00008000)
    ap.add_argument("--ramdisk-addr", type=lambda v: int(v, 0), default=0x01000000)
    ap.add_argument("--tags-addr", type=lambda v: int(v, 0), default=0x00000100)
    ap.add_argument("--second-addr", type=lambda v: int(v, 0), default=0x00F00000)
    ap.add_argument("--dtb-addr", type=lambda v: int(v, 0), default=0x01F00000)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    kernel = Path(a.kernel).read_bytes()
    ramdisk = Path(a.ramdisk).read_bytes() if a.ramdisk else b"dummy"
    dtb = Path(a.dtb).read_bytes()
    cmd = a.cmdline.encode("ascii")
    if len(cmd) >= 512:
        raise SystemExit(f"cmdline too long ({len(cmd)} >= 512)")
    if not dtb.startswith(b"\xd0\x0d\xfe\xed"):
        raise SystemExit(f"{a.dtb} does not start with the FDT magic")
    if not kernel:
        raise SystemExit("empty kernel")

    # SOURCE_DATE_EPOCH keeps os_version (and therefore the whole image)
    # reproducible; without it the same kernel yields a different checksum
    # tomorrow, which makes SHA256SUMS useless for telling builds apart.
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    today = (datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).date()
             if epoch else datetime.date.today())

    # id: SHA1 over each segment in layout order, each followed by its LE
    # size -- what AOSP mkbootimg does. For v1+ the dtb is part of the image,
    # so it belongs in the digest.
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, b"", b"", dtb):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))

    v0 = struct.pack(
        "<8s10I16s512s32s1024s",
        BOOT_MAGIC,
        len(kernel), a.kernel_addr,
        len(ramdisk), a.ramdisk_addr,
        0, a.second_addr,
        a.tags_addr,
        a.pagesize,
        2,                                          # header_version
        os_version_field(12, 0, 0, today.year, today.month),
        b"",
        cmd,
        sha.digest().ljust(32, b"\0"),
        b"",
    )
    assert len(v0) == HDR_V0, f"v0 field is {len(v0)}, expected {HDR_V0}"

    v1 = v0 + struct.pack("<IQI", 0, 0, HDR_V2)     # no recovery_dtbo; header_size
    assert len(v1) == HDR_V1, f"v1 field is {len(v1)}, expected {HDR_V1}"

    v2 = v1 + struct.pack("<IQ", len(dtb), a.dtb_addr)
    assert len(v2) == HDR_V2, f"v2 field is {len(v2)}, expected {HDR_V2}"

    img = (pad(v2, a.pagesize)
           + pad(kernel, a.pagesize)
           + pad(ramdisk, a.pagesize)
           + struct.pack("<I", len(dtb))            # dtb_size prefix, then the blob
           + pad(dtb, a.pagesize))
    Path(a.out).write_bytes(img)
    print(f"{a.out}: {len(img)} bytes  kernel={len(kernel)} ramdisk={len(ramdisk)} "
          f"dtb={len(dtb)} hdr_v2={HDR_V2} page={a.pagesize}")


if __name__ == "__main__":
    main()
