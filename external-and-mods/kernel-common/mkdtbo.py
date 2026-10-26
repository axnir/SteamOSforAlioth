#!/usr/bin/env python3
"""Pack one or more DTBs into an Android DTBO (dtbo.img) table.

    mkdtbo.py --dtb stub.dtb --out dtbo.img
    mkdtbo.py --dtb a.dtb --dtb b.dtb --out dtbo.img --id 0

Why this exists: the OnePlus ABL reads the `dtbo` partition as an AOSP
DTBO *table*, not as a raw FDT. Flashing a bare .dtb there gets you

    Dtbo hdr magic mismatch EDFE0DD0, with D7B7AB1E

in the bootloader log -- EDFE0DD0 is a little-endian read of the FDT
magic d00dfeed, and D7B7AB1E is what the table header must start with.
Measured on this phone on 2026-10-25.

Layout, from AOSP system/libufdt/mkdtimg/dtimg.c (dt_table_header):

    struct dt_table_header {          // 32 bytes, big-endian
        uint32_t magic;               // 0xd7b7ab1e
        uint32_t total_size;          // header + all entries, padded to page
        uint32_t header_size;         // 32
        uint32_t dt_entry_size;       // 32
        uint32_t dt_entry_count;
        uint32_t dt_entries_offset;   // 32
        uint32_t page_size;           // 4096
        uint32_t version;             // 0
    };

    struct dt_table_entry {           // 32 bytes, big-endian
        uint32_t dt_size;
        uint32_t dt_offset;           // absolute, from file start
        uint32_t id;
        uint32_t rev;
        uint32_t custom[4];           // 0 unless -c is used
    };

Note the field order differs from what one might assume: dt_size comes
before dt_offset. Everything is big-endian ("network order"), which is
also how the FDT blob itself is stored.

The stock partition on this phone holds 11 entries and dtbo_idx=5 picks
one of them. A single-entry table with id 0 is what the ABL needs here:
it selects by index, and there is nothing to select between.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

MAGIC = 0xD7B7AB1E
HDR = 32
ENTRY = 32
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def pad(n: int, page: int) -> int:
    return (n + page - 1) // page * page


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dtb", action="append", required=True,
                    help="DTB to embed; repeatable, embedded in order")
    ap.add_argument("--id", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--rev", type=lambda v: int(v, 0), default=0)
    ap.add_argument("--page-size", type=int, default=4096)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    blobs = []
    for p in a.dtb:
        d = Path(p).read_bytes()
        if not d.startswith(FDT_MAGIC):
            sys.exit(f"{p}: not an FDT (magic {d[:4].hex()})")
        blobs.append(d)

    n = len(blobs)
    entries_end = HDR + n * ENTRY
    offsets, cur = [], entries_end
    for b in blobs:
        offsets.append(cur)
        cur += len(b)

    total = pad(cur, a.page_size)

    out = bytearray()
    out += struct.pack(">8I", MAGIC, total, HDR, ENTRY, n, HDR,
                       a.page_size, 0)
    for b, off in zip(blobs, offsets):
        out += struct.pack(">8I", len(b), off, a.id, a.rev, 0, 0, 0, 0)
    for b in blobs:
        out += b
    out += b"\0" * (total - len(out))

    Path(a.out).write_bytes(bytes(out))
    print(f"{a.out}: {len(out)} bytes, {n} entries, "
          f"sizes={[len(b) for b in blobs]}")


if __name__ == "__main__":
    main()
