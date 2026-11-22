#!/usr/bin/env bash
# 断言「即将刷进 boot 分区的那一个镜像」是对的。
#
# 用法: scripts/assert-op8p-boot-image.sh [IMG]
#       OP8P_BOOT_IMAGE=/path/to.img scripts/assert-op8p-boot-image.sh
#
# 为什么需要它（这是 OP8P 与 alioth 最明显的差距）：其余 assert-op8p-*.sh
# 查的都是**源码**（DTS、config、flash 脚本）。可刷机时真正写进分区的是
# 一个几十分钟前打出来的 .img，源码后来改没改、改完有没有重新打包，它们
# 全看不见。alioth 有 assert-alioth-boot-image.sh 专门堵这个洞，OP8P 之前
# 没有 —— 于是"改了 DTS 却刷了旧镜像"这一类错误没有任何东西会拦。
#
# 每条断言都对应一个在真机上只表现为「15 秒后弹回 fastboot」或「黑屏、
# 一句日志都没有」的失败，所以文案里写清楚是哪一种：
#
#   * page_size 必须是 4096 —— 镜像内各段的偏移由它算，错了就是 Load Error，
#     ABL 不会告诉你是页大小的问题；
#   * ramdisk_size 必须 > 0 —— 这个 ramdisk 只装 GPU 微码（a650 zap 四件套）。
#     没有它，msm 在 initramfs 阶段 probe 时拿不到 zap，Vulkan 设备创建失败，
#     gamescope 不做 modeset，屏幕**全黑且没有任何报错**（§28 的血泪）；
#   * payload 尾部的 DTB 必须**逐字节**等于当前产物里的 dtb —— 否则刷的是
#     旧设备树：分辨率、触摸、电量计、振动全都回到上一版的状态；
#   * cmdline 里不能出现 quiet/loglevel=0 —— 第一次刷机全靠面板和 ttyGS0
#     上的日志定位问题，静掉等于把唯一的观测手段关掉。
set -uo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-op8p"
IMG="${1:-${OP8P_BOOT_IMAGE:-${IMG_DIR}/boot-op8p-gzip.img}}"
KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"

# boot_a 的大小，从这台手机自己的 fastboot 上读的（flash-op8p.sh 也用它）。
BOOT_PART_SIZE=$((0x6000000))

size_of() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

fails=0
note=0
check() { # check <0|1> <label> <detail>
  if [[ "$1" == 1 ]]; then printf '  ok   %s — %s\n' "$2" "$3"
  else printf '  FAIL %s — %s\n' "$2" "$3"; fails=$((fails + 1)); fi
}
skip() { printf '  SKIP %s — %s\n' "$1" "$2"; note=$((note + 1)); }

if [[ ! -s "$IMG" ]]; then
  echo "  FAIL 镜像存在 — 没有 $IMG（先跑 ./make-op8p.sh --gzip）"
  exit 1
fi
echo "  镜像 $IMG（$(size_of "$IMG") 字节）"

# 镜像结构、payload、cmdline、ramdisk —— 全在一个 python 里做，因为它们
# 共享同一份解析；分成几次读文件只会让偏移算法出现两个版本。
python3 - "$IMG" "$KOUT" "$BOOT_PART_SIZE" <<'PY'
import os, struct, sys, zlib

img, kout, part_size = sys.argv[1], sys.argv[2], int(sys.argv[3])
blob = open(img, "rb").read()
name = os.path.basename(img)
fails = notes = 0

def check(ok, label, detail):
    global fails
    print(("  ok   " if ok else "  FAIL ") + label + " — " + detail)
    if not ok:
        fails += 1

def skip(label, detail):
    global notes
    print("  SKIP " + label + " — " + detail)
    notes += 1

print("== 分区与头部 ==")
check(len(blob) <= part_size, "装得进 boot 分区",
      "%d / %d 字节" % (len(blob), part_size))

magic = blob[:8]
check(magic == b"ANDROID!", "boot magic", repr(magic))

(ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page, hdrv) = \
    struct.unpack_from("<9I", blob, 8)
cmdline = struct.unpack_from("<512s", blob, 8 + 16 + 64)[0].split(b"\0")[0].decode()

# v0 = gzip 打包（Image.gz ++ DTB 塞进 kernel 段），v2 = 独立 dtb 段。
want_v2 = "v2" in name
check(hdrv == (2 if want_v2 else 0), "header_version",
      "%d（%s 打包要求 %d）" % (hdrv, name, 2 if want_v2 else 0))
check(page == 4096, "page_size", "%d（必须是 4096，偏移全靠它）" % page)
for got, want, label in ((kaddr, 0x00008000, "kernel_addr"),
                         (raddr, 0x01000000, "ramdisk_addr"),
                         (taddr, 0x00000100, "tags_addr"),
                         (saddr, 0x00F00000, "second_addr")):
    check(got == want, label, "0x%x（期望 0x%x）" % (got, want))
check(ssize == 0, "second_size", "%d（期望 0，bootloader 不在那里加载任何东西）" % ssize)

print("== cmdline ==")
args = cmdline.split()
check(len(cmdline) < 512, "长度", "%d 字符（上限 512）" % len(cmdline))
for need, why in (
    ("root=PARTLABEL=userdata", "根分区；用 PARTLABEL 是因为 ABL 会追加自己的参数、UUID 也对不上"),
    ("rootwait", "ext4 在 UFS 上枚举比内核慢"),
    ("console=ttyGS0", "串口 console —— 面板黑掉时唯一的观测手段"),
    ("console=tty0", "面板 console"),
    ("loglevel=7", "调试镜像要能看到 udev/USB 枚举这类 info 级日志"),
    ("initcall_blacklist=simpledrm_platform_driver_init", "simpledrm 抢 DRM minor 0 会让 msm 落在 dri/1，MangoHud 读不到 GPU 占用率"),
    ("steamos.usbshell=1", "initramfs 里起 USB gadget shell 的开关"),
):
    check(need in args, need, why)
for bad, why in (("quiet", "会压掉面板上的内核日志"),
                 ("loglevel=0", "同上")):
    check(bad not in args, "不含 " + bad, why)

print("== kernel 段 ==")
payload = blob[page:page + ksize]
check(payload[:2] == b"\x1f\x8b", "payload 是 gzip",
      payload[:2].hex() + ("（Image.gz）" if payload[:2] == b"\x1f\x8b" else ""))

print("== GPU 微码 ramdisk ==")
# ramdisk 紧跟 kernel 段，两者都按 page 向上取整。
rd_off = page + ((ksize + page - 1) // page) * page
check(rsize > 0, "ramdisk 存在",
      "%d 字节" % rsize + ("" if rsize else " —— 没有它 GPU 拿不到 zap，屏幕全黑且无报错"))
if rsize > 0:
    rd = blob[rd_off:rd_off + rsize]
    check(rd[:2] == b"\x1f\x8b", "ramdisk 是 gzip", rd[:2].hex())
    try:
        cpio = zlib.decompress(rd, 31)
    except zlib.error as e:
        cpio = b""
        check(False, "ramdisk 能解压", str(e))
    if cpio:
        i, names = 0, set()
        while i + 110 <= len(cpio) and cpio[i:i+6] in (b"070701", b"070702"):
            fsize = int(cpio[i+54:i+62], 16)
            nsize = int(cpio[i+94:i+102], 16)
            names.add(cpio[i+110:i+110+nsize-1].decode("utf-8", "replace"))
            i += 110 + nsize
            i = (i + 3) & ~3
            i += fsize
            i = (i + 3) & ~3
        # updates/ 的优先级高于 lib/firmware，两份都在才是驱动实际会用的那份；
        # 少了 updates 里那份，留在 rootfs 上的旧微码就会赢。
        for need in ("lib/firmware/updates/qcom/a650_zap.mdt",
                     "lib/firmware/updates/qcom/a650_sqe.fw",
                     "lib/firmware/updates/qcom/a650_gmu.bin",
                     "lib/firmware/qcom/a650_zap.mdt"):
            check(need in names, "ramdisk 含 " + need, "共 %d 个条目" % len(names))
        check("init" in names, "ramdisk 含 init", "cpio 的入口文件")

print("== 设备树 ==")
if want_v2:
    dtb_size = struct.unpack_from("<I", blob, 1648)[0] if len(blob) > 1652 else 0
    dtb_off = page * (1 + (ksize + page - 1)//page + (rsize + page - 1)//page
                      + (ssize + page - 1)//page)
    dtb = blob[dtb_off:dtb_off + dtb_size]
    check(dtb_size > 0 and dtb[:4] == b"\xd0\x0d\xfe\xed", "独立 dtb 段",
          "%d 字节, magic %s" % (dtb_size, dtb[:4].hex()))
else:
    # v0：kernel 段 = gzip 流 + 直接追加的 DTB。用 zlib 找出 gzip 流的终点，
    # 而不是猜 —— 猜错时"尾部还有几百 KB"会被误判成"多了第二个 DTB"。
    d = zlib.decompressobj(31)
    try:
        d.decompress(payload)
        dtb = d.unused_data
    except zlib.error as e:
        dtb = b""
        check(False, "payload 能解压", str(e))
    check(dtb[:4] == b"\xd0\x0d\xfe\xed", "gzip 之后是 DTB", dtb[:4].hex())
    total, n = 0, 0
    while total + 8 <= len(dtb) and dtb[total:total+4] == b"\xd0\x0d\xfe\xed":
        sz = struct.unpack_from(">I", dtb, total + 4)[0]
        if sz == 0:
            check(False, "DTB totalsize", "第 %d 个是 0（会死循环）" % (n + 1))
            break
        total += sz
        n += 1
    check(n == 1, "只有一个 DTB",
          "%d 个（只给这台机器的设备树）" % n)
    check(total == len(dtb), "DTB 之后没有多余字节",
          "%d / %d 字节被解释" % (total, len(dtb)))

# DTB 的 strings 块是明文，直接查 compatible —— 比反编译简单，也不需要 dtc。
# 这三条是这台机器上「曾经装错、症状离原因很远」的三个节点。
cur = os.path.join(kout, "dtbs", "sm8250-oneplus-instantnoodlep.dtb")
if dtb[:4] == b"\xd0\x0d\xfe\xed":
    for s, why in ((b"awinic,aw8697", "振动（reset 极性修好后才 probe 得到）"),
                   (b"ti,bq27411", "第二电量计（bq27541 是错表）"),
                   (b"samsung,s6sy761", "触摸"),
                   (b"qcom,sm8250", "SoC 根节点")):
        check(dtb.count(s) >= 1, "dtb 含 " + s.decode(), why)

    # 与当前产物逐字节比对：这是"改了 DTS 却刷了旧镜像"唯一的拦法。
    if os.path.isfile(cur):
        now = open(cur, "rb").read()
        if dtb == now:
            check(True, "DTB 与当前产物一致", "逐字节相同（%d 字节）" % len(now))
        else:
            check(False, "DTB 与当前产物一致",
                  "镜像里 %d 字节 / 产物 %d 字节 —— 镜像比源码旧，重新打包再刷"
                  % (len(dtb), len(now)))
    else:
        skip("DTB 与当前产物比对", "找不到 %s（没编译过？）" % cur)
else:
    skip("dtb 字符串检查", "没有可解析的 DTB")
    skip("DTB 与当前产物比对", "没有可解析的 DTB")

sys.exit(min(fails, 100))
PY
fails=$((fails + $?))

echo
if (( fails )); then
  echo "  $fails 条失败"
  [[ "$note" -gt 0 ]] && echo "  （另有 $note 条跳过 —— 跳过不等于通过）"
  exit 1
fi
echo "  全部通过"
[[ "$note" -gt 0 ]] && echo "  （有 $note 条被跳过 —— 跳过不等于通过，看上面 SKIP 的原因）"
exit 0
