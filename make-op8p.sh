#!/usr/bin/env bash
# Build a boot image for OnePlus 8 Pro (instantnoodlep).
#
# Two packings are available, and the difference matters:
#
#   --gzip  (default)  gzip(Image) ++ the DTS's DTBs, wrapped in a **v0**
#                      header at the addresses pmOS is known to boot with.
#                      This is the packing alioth proved on a Qualcomm ABL
#                      and the one ROCKNIX's own KERNEL uses.
#
#   --v2               gzip(Image) in the kernel slot, the DTB in the
#                      header v2 `dtb` slot (mkbootimg-v2.py). This is what
#                      pmaports' deviceinfo asks for on this device
#                      (header_version 2, dtb_offset 0x01f00000).
#
# Why gzip at all: CONFIG_EFI_ZBOOT=y in this config, and with it
# `make Image` emits an EFI PE wrapper whose first bytes are "MZ". A
# bootloader without EFI cannot unpack that -- it is the bug pmaports'
# README calls "THE IMPOSTOR". (The wrapper does keep the ARM\x64 header at
# offset 0x38, so an ABL that scans for it may still cope; there is no
# reason to rely on that when gzip is the proven path.)
#
# Do NOT gzip the kernel's own Image.gz: with EFI_ZBOOT that file is the
# same PE wrapper, not a gzip stream. What is gzipped here is the raw
# Image's payload after the 0x40-byte arm64 header, which is what
# ROCKNIX's pack_kernel_img does.
#
# Usage:
#   ./make-op8p.sh [--v2] [--debug] [--out DIR]
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCOMMON="${PORT_ROOT}/external-and-mods/kernel-common"
SOC_DIR="${PORT_ROOT}/external-and-mods/kernel-sm8250"
DTB_NAME=sm8250-oneplus-instantnoodlep

KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"
[[ -n "$KOUT" ]] || KOUT="${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}"
OUT="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-op8p"

PACK=gzip
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gzip)  PACK=gzip ;;
    --v2)    PACK=v2 ;;
    --quiet) QUIET=1 ;;
    --out)   OUT="$2"; shift ;;
    *) echo "make-op8p: 不认识的参数: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "make-op8p: $*" >&2; exit 1; }

img="${KOUT}/boot/Image"
dtb="${KOUT}/dtbs/${DTB_NAME}.dtb"
[[ -s "$img" ]] || die "没有 $img —— 先跑 ./build-alioth-kernel.sh"
[[ -s "$dtb" ]] || die "没有 $dtb —— soc.env 的 DTBS 里要有 ${DTB_NAME}"

mkdir -p "$OUT"

# Load addresses: pmaports' deviceinfo for this device, which is the only
# set a boot image is known to have started with here.
PAGESIZE=4096
KERNEL_ADDR=0x00008000
RAMDISK_ADDR=0x01000000
TAGS_ADDR=0x00000100
SECOND_ADDR=0x00F00000
DTB_ADDR=0x01F00000

# The kernel payload every packing starts from: the whole `Image`, gzipped.
#
# This looks like it should be wrong and is not. CONFIG_EFI_ZBOOT=y makes
# `make Image` emit a PE/COFF wrapper (starts "MZ", PE header at 0x40,
# machine 0xaa64, two sections) instead of a bare arm64 Image -- and a
# Qualcomm ABL has no EFI, so an unmodified copy would never run.
#
# But ROCKNIX ships exactly that: its KERNEL's kernel segment, decompressed,
# is byte-for-byte the same 35883520-byte "MZ..." file our build produces
# (verified 2026-10-25 against output/.../boot/KERNEL). ROCKNIX's ABL path
# is the one pmaports' boot recipe for this phone was validated against, so
# matching it is the lower-risk choice, and it is also the only packing
# alioth has proven on a stock Qualcomm bootloader.
#
# The zboot wrapper keeps the arm64 header ("ARM\x64" at 0x38) intact, so a
# bootloader that knows how to handle an EFI zboot image -- or one that just
# scans for that magic -- still finds it. Do NOT "fix" this by extracting
# the .text section: that produces a payload with no arm64 header at all,
# which is strictly worse for any load path.
#
# The sanity check below only asserts that the ARM\x64 magic is where a
# zboot/raw arm64 image keeps it, so a future toolchain change that drops
# the wrapper fails loudly instead of silently producing a bad image.
stage_payload() {
  local payload="${OUT}/Image.gz"
  python3 - "$img" "$payload" <<'PY'
import gzip, sys

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()

if d[0x38:0x3C] != b"ARM\x64":
    sys.exit(f"{src}: no ARM\\x64 magic at 0x38 -- not a zboot/raw arm64 Image")

with gzip.GzipFile(dst, "wb", compresslevel=9, mtime=0) as g:
    g.write(d)
# Progress goes to stderr: stdout is captured by the caller to get the path.
print(f"payload: Image {len(d)} -> {__import__('os').path.getsize(dst)} bytes (gzip)",
      file=sys.stderr)
PY
  echo "$payload"
}

# The cmdline. Mirrors alioth's reasoning, adapted:
#
#   CMDLINE_QUIET=0   the panel console is one of only two log channels in
#                     phase 1, and the default `quiet loglevel=0` silences
#                     exactly that.
#   steamos.usbshell=1  the single switch that starts the USB gadget shell
#                     (ACM serial + a root shell on 172.16.42.1). This
#                     phone's USB is drd/super-speed, so the gadget works.
#   steamos.root=     the ABL appends its own args after ours and initramfs
#                     init takes the last root= it sees; steamos.root= wins.
#                     PARTLABEL=userdata resolves (the partition exists),
#                     the ext4 probe then fails read-only on Android's f2fs,
#                     and we land in a shell. That failure IS phase 1.
#   steamos.bootlabel=  a GPT name that cannot exist here, so the initramfs
#                     can never find a partition to write a log into.
#   panic=120         CONFIG_PANIC_TIMEOUT=0 would hang forever; a warm
#                     reboot preserves DRAM so pstore records survive.
#   initcall_blacklist=simpledrm_platform_driver_init
#                     MangoHud hardcodes /sys/kernel/debug/dri/0/perf_now,
#                     and simpledrm takes minor 0 during early boot. Costs
#                     the pre-msm framebuffer console; on this device the
#                     DTS's chosen/framebuffer@9c000000 still gives us one
#                     until msm binds.
#   clk_ignore_unused pd_ignore_unused
#                     Without these the kernel's late init disables every
#                     clock and power domain nothing has claimed yet. On
#                     this phone that kills the DSI PLL's reference clock
#                     before the panel ever drives it:
#
#                       dsi0_phy_pll_out_dsiclk already disabled
#                       dsi0_phy_pll_out_dsiclk already unprepared
#                       DSI PLL(0) lock failed, status=0x00000000
#
#                     and the register reads back all zero rather than a
#                     "not locked" bit -- nothing is clocking it at all.
#                     postmarketOS carries both tokens in its
#                     kernel-cmdline.conf for a reason; docs/alioth.md
#                     also mentions CMDLINE_SOC deliberately omitting them
#                     for ROCKNIX, but ROCKNIX does not enable dispcc.
EXTRA="clk_ignore_unused pd_ignore_unused steamos.usbshell=1 steamos.root=PARTLABEL=userdata steamos.bootlabel=steamos-arm-no-boot-partition panic=120 initcall_blacklist=simpledrm_platform_driver_init"

# CMDLINE_QUIET=0 by default, unlike alioth's make script.
#
# alioth defaults to quiet because its image is also its release image. This
# script only ever produces a **phase-1 debug image** right now -- there is
# no rootfs, no Game Mode, nothing to hide -- and the whole point of the
# first flash is to read what the kernel says on the panel and over ACM.
# `quiet loglevel=0 systemd.show_status=0` silences exactly that. Use
# --quiet once this device actually boots into Steam.
cmdline="$(
  CMDLINE_QUIET=$([[ $QUIET == 1 ]] && echo 1 || echo 0) \
  KERNEL_CMDLINE_EXTRA="$EXTRA" \
  bash -c "source '${SOC_DIR}/soc.env'; source '${KCOMMON}/cmdline.sh'; build_cmdline PARTLABEL=userdata"
)"

payload="$(stage_payload)"

# Reproducible: without SOURCE_DATE_EPOCH the header's os_version carries
# today's date, so an unchanged kernel yields a different image and a
# different checksum tomorrow.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -f %m "$img" 2>/dev/null || stat -c %Y "$img")}"

case "$PACK" in
  gzip)
    # gzip(Image body) ++ the DTB, appended the way ABL scans for it.
    withdtb="${OUT}/Image.gz-dtb"
    cat "$payload" "$dtb" >"$withdtb"
    name=boot-op8p-gzip.img
    python3 "${KCOMMON}/mkbootimg-v0.py" \
      --kernel "$withdtb" \
      --cmdline "$cmdline" \
      --pagesize "$PAGESIZE" \
      --kernel-addr "$KERNEL_ADDR" \
      --ramdisk-addr "$RAMDISK_ADDR" \
      --tags-addr "$TAGS_ADDR" \
      --second-addr "$SECOND_ADDR" \
      --out "${OUT}/${name}"
    rm -f "$withdtb"
    ;;
  v2)
    name=boot-op8p-v2.img
    python3 "${KCOMMON}/mkbootimg-v2.py" \
      --kernel "$payload" \
      --dtb "$dtb" \
      --cmdline "$cmdline" \
      --pagesize "$PAGESIZE" \
      --kernel-addr "$KERNEL_ADDR" \
      --ramdisk-addr "$RAMDISK_ADDR" \
      --tags-addr "$TAGS_ADDR" \
      --second-addr "$SECOND_ADDR" \
      --dtb-addr "$DTB_ADDR" \
      --out "${OUT}/${name}"
    ;;
esac

rm -f "$payload"

# SHA256SUMS covers everything currently in OUT. flash-op8p.sh runs
# `sha256sum -c` on it, and only writing our own file would leave the other
# packing's entry stale.
( cd "$OUT" && rm -f SHA256SUMS && sha256sum -- *.img >SHA256SUMS 2>/dev/null || \
  ( cd "$OUT" && shasum -a 256 -- *.img >SHA256SUMS ) )

echo
echo "镜像:  ${OUT}/${name}"
echo "大小:  $(stat -f %z "${OUT}/${name}" 2>/dev/null || stat -c %s "${OUT}/${name}") 字节"
echo "打包:  $PACK  (header $([[ $PACK == v2 ]] && echo v2 || echo v0), page $PAGESIZE)"
echo "DTB:   $DTB_NAME ($(stat -f %z "$dtb" 2>/dev/null || stat -c %s "$dtb") 字节)"
echo "cmdline: $cmdline"
echo
echo "刷机:  ./flash-op8p.sh --test    （写非活动槽，当前活动槽是 \$(fastboot getvar current-slot)）"
