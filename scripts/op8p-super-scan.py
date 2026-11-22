import struct
f = open("/dev/disk/by-partlabel/super", "rb")
off = 0
found = 0
while True:
    f.seek(off)
    d = f.read(4096 + 2048)
    if len(d) < 2048: break
    for k in range(0, 4096, 4096):
        m = d[k + 1024: k + 1028]
        kind = None
        if m == b"\x53\xef": kind = "ext4"
        elif m == b"\xf2\xf5\x20\x10": kind = "f2fs"
        elif m == b"\xe2\xe1\xf5\xe0": kind = "erofs"
        if kind:
            fs_start = off + k
            info = ""
            if kind == "ext4":
                sb0 = d[k + 1024: k + 1024 + 264]
                blocks = struct.unpack_from("<I", sb0, 4)[0]
                bs = 1024 << struct.unpack_from("<I", sb0, 24)[0]
                vol = sb0[112:128].rstrip(b"\0")
                info = "blocks=%d bs=%d sizeMB=%d vol=%r" % (blocks, bs, blocks*bs//1048576, vol)
            elif kind == "erofs":
                # erofs sb: magic@0, checksum u32@4, feature u32@8, blkszbits u8@12, root nid u16@13...
                blkszbits = d[k + 1024 + 12]
                info = "blksz=%d" % (1 << blkszbits)
            print("%s fs_start=%d %s" % (kind, fs_start, info))
            found += 1
    off += 4096
    if off > 20 * 1024**3: break
print("scan done, found", found)
