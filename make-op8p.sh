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
#   ./make-op8p.sh --install     # 造 work/steamos-op8p/userdata.img（SteamOS 根）
#   ./make-op8p.sh --verify      # 只读校验上面那个镜像，不刷机
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
INSTALL=0
VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gzip)  PACK=gzip ;;
    --v2)    PACK=v2 ;;
    --quiet) QUIET=1 ;;
    --install) INSTALL=1 ;;
    --verify)  VERIFY=1 ;;
    --out)   OUT="$2"; shift ;;
    *) echo "make-op8p: 不认识的参数: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "make-op8p: $*" >&2; exit 1; }

# python3 here can be a *native Windows* interpreter (WorkBuddy's bundled
# 3.13 was first on PATH on 2026-11-21), and a win32 python has no idea what
# "/d/Developer/..." means -- it resolves it against the current drive and
# reports a perfectly good file as missing. Every path-ish argument therefore
# goes through cygpath first; on Linux (no cygpath) they pass through as-is.
python3w() {
  if ! command -v cygpath >/dev/null 2>&1; then
    python3 "$@"
    return
  fi
  local -a conv=()
  local a
  for a in "$@"; do
    if [[ "$a" == /* ]]; then conv+=("$(cygpath -w -- "$a")"); else conv+=("$a"); fi
  done
  python3 "${conv[@]}"
}

# --install builds the rootfs image instead of the boot image. It needs
# e2fsprogs (mkfs.ext4) and, the first time, squashfs-tools (unsquashfs, to
# unpack Valve's RAUC bundle) -- neither exists on a Windows box, so it runs
# in the same container the kernel build uses. Both steps are idempotent:
# the download skips what is already there, the copy skips with --skip-copy.
if [[ $INSTALL == 1 ]]; then
  WSLC="${WSLC:-/c/Program Files/WSL/wslc}"
  WSLC_IMAGE="${WSLC_IMAGE:-proxy.vvvv.ee/library/fedora:43}"
  if command -v mkfs.ext4 >/dev/null 2>&1 && command -v unsquashfs >/dev/null 2>&1; then
    [[ -x "${PORT_ROOT}/work/rootfs/usr/bin/bash" ]] \
      || bash "${PORT_ROOT}/scripts/fetch-steamos-rootfs.sh"
    exec bash "${PORT_ROOT}/scripts/make-op8p-rootfs.sh"
  fi
  [[ -x "$WSLC" ]] || die "--install 需要 mkfs.ext4+unsquashfs（Linux）或 wslc（Windows）—— 两个都没有"
  echo "make-op8p: 在容器里做 rootfs（首次会下几 GB 的 Valve 官方 rootfs，可以中断重跑）"
  # -v 要 Windows 路径：PORT_ROOT 是 Git Bash 的 /d/... 形式，而
  # MSYS_NO_PATHCONV=1 关掉了自动转换，直接传会挂成空目录（第一次就是这样，
  # 容器里报 "No such file or directory"）。
  WIN_ROOT="$(cygpath -w "$PORT_ROOT" 2>/dev/null || printf '%s' "$PORT_ROOT")"
  # 整棵树放在容器的 /scratch 里，不放 /repo：/repo 是 Windows 目录，DrvFs
  # 不保留 Unix 权限位，restore 出来的 bash 会是 -rw-r--r--，mkfs -d 装进
  # 镜像后系统起不来。只有最终的 userdata.img 写回 /repo（单个文件，权限
  # 无关）。代价是容器要能放下 rootfs + 镜像两份，约 20 GB。
  MSYS_NO_PATHCONV=1 "$WSLC" run --rm --dns 223.5.5.5 \
    -v "${WIN_ROOT}:/repo" "$WSLC_IMAGE" bash -c '
      set -e
      # 缓存的 repodata 会坏，而且这条线路上 metadata 本身也会被截断
      # （"Unable to read zchunk lead"），所以清缓存 + 重试，不能一次定生死。
      ok=0
      for i in 1 2 3 4 5; do
        rm -rf /var/cache/libdnf5 /var/cache/dnf
        if dnf install -y squashfs-tools rsync e2fsprogs btrfs-progs util-linux \
             python3 python3-requests python3-zstandard curl; then
          ok=1; break
        fi
        echo "make-op8p: dnf 第 $i 次失败，重试" >&2
        sleep 3
      done
      [[ $ok == 1 ]] || { echo "make-op8p: 容器里装依赖失败（重试 5 次）" >&2; exit 1; }
      mkdir -p /scratch
      export SCRATCH=/scratch
      IMG="$(ls /repo/work/steamos-*/rootfs.img 2>/dev/null | head -1)"
      echo "make-op8p: IMG=[$IMG]"
      if [ -z "$IMG" ]; then
        bash /repo/scripts/fetch-steamos-rootfs.sh /scratch/rootfs
      else
        rm -rf /scratch/rootfs
        mkdir -p /scratch/rootfs
        # 参数照 11-07 raphael 那次真机验过的配方：-i 跳过打不开的文件、
        # -m 恢复属主与权限（不加它 /usr/bin/bash 会落成 644，系统起不来）、
        # -S 保留 sparse、-x 不搬 btrfs 自己的 xattr（目标文件系统不支持）。
        # 不用 -v：十万行日志会把进程拖死（11-21 踩过）。
        btrfs restore -i -m -S -x "$IMG" /scratch/rootfs >/scratch/restore.log 2>&1 || true
        files=$(find /scratch/rootfs -type f 2>/dev/null | wc -l)
        echo "make-op8p: restore size=$(du -sh /scratch/rootfs 2>/dev/null | cut -f1) files=$files"
        # 判据用「bash 能执行 + 文件数够」，不数日志里的 ERROR —— restore 会
        # 对 symlink 目录报无害错误，数它没有意义。
        [ -x /scratch/rootfs/usr/bin/bash ] || {
          tail -5 /scratch/restore.log
          echo "make-op8p: restore 没有产出可执行的 /usr/bin/bash" >&2; exit 1; }
        [ "$files" -ge 185000 ] || {
          echo "make-op8p: 只恢复出 $files 个文件（应 ≥185000），树不完整" >&2; exit 1; }
      fi
      mkdir -p /scratch/work
      # 树和镜像都放容器本地：DrvFs 不保留 Unix 权限位，往 /repo 里造等于
      # 把刚恢复好的属主和 execute 位再丢一次。最后只搬一个文件出去。
      # KERNEL_OUT 必须显式给：STEAMOS_WORK 改成 /scratch 之后，脚本会去
      # /scratch/work/kernel-sm8250 找模块，那里没有东西（11-21 第一次跑就
      # 撞在 "没有已编译的模块" 上）。
      STEAMOS_WORK=/scratch/work \
      KERNEL_OUT=/repo/work/kernel-sm8250/output/current \
      STEAMOS_SRC_ROOTFS=/scratch/rootfs \
      STEAMOS_ROOTFS=/scratch/rootfs-op8p \
        bash /repo/scripts/make-op8p-rootfs.sh
      OUT_IMG=/scratch/work/steamos-op8p/userdata.img
      [ -s "$OUT_IMG" ] || { echo "make-op8p: 没有产出 $OUT_IMG" >&2; exit 1; }
      echo "make-op8p: 搬回 Windows（单个文件，几分钟）"
      mkdir -p /repo/work/steamos-op8p
      cp "$OUT_IMG" /repo/work/steamos-op8p/userdata.img
      a=$(sha256sum "$OUT_IMG" | cut -d" " -f1)
      b=$(sha256sum /repo/work/steamos-op8p/userdata.img | cut -d" " -f1)
      echo "make-op8p: sha256 容器内 $a"
      echo "make-op8p: sha256 磁盘上 $b"
      [ "$a" = "$b" ] || { echo "make-op8p: 搬回来的文件和源不一致" >&2; exit 1; }
      echo "make-op8p: 镜像完成 $OUT_IMG"
    '
  exit $?
fi

# --verify checks the finished userdata.img without booting it: superblock,
# fstab UUID, executable bits (the btrfs-restore -m trap), overlay files,
# modules/firmware, then a read-only e2fsck. Same reason as --install it runs
# in the container: Windows has no debugfs/e2fsck.
if [[ $VERIFY == 1 ]]; then
  WSLC="${WSLC:-/c/Program Files/WSL/wslc}"
  WSLC_IMAGE="${WSLC_IMAGE:-proxy.vvvv.ee/library/fedora:43}"
  IMG_WIN="$(cygpath -w "${OUT}/userdata.img" 2>/dev/null || printf '%s' "${OUT}/userdata.img")"
  [[ -s "${OUT}/userdata.img" ]] || die "没有 ${OUT}/userdata.img —— 先跑 ./make-op8p.sh --install"
  if command -v dumpe2fs >/dev/null 2>&1; then
    exec bash "${PORT_ROOT}/scripts/verify-op8p-userdata.sh" "${OUT}/userdata.img"
  fi
  [[ -x "$WSLC" ]] || die "--verify 需要 e2fsprogs（Linux）或 wslc（Windows）—— 两个都没有"
  WIN_ROOT="$(cygpath -w "$PORT_ROOT" 2>/dev/null || printf '%s' "$PORT_ROOT")"
  MSYS_NO_PATHCONV=1 "$WSLC" run --rm --dns 223.5.5.5 \
    -v "${WIN_ROOT}:/repo" "$WSLC_IMAGE" bash -c '
      set -e
      ok=0
      for i in 1 2 3; do
        rm -rf /var/cache/libdnf5 /var/cache/dnf
        if dnf install -y e2fsprogs util-linux >/dev/null; then ok=1; break; fi
        echo "make-op8p: dnf 第 $i 次失败，重试" >&2
        sleep 3
      done
      [[ $ok == 1 ]] || { echo "make-op8p: 容器里装 e2fsprogs 失败" >&2; exit 1; }
      bash /repo/scripts/verify-op8p-userdata.sh /repo/work/steamos-op8p/userdata.img
    '
  exit $?
fi

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
  python3w - "$img" "$payload" <<'PY' || return 1
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

payload="$(stage_payload)" || die "gzip(${img}) 失败 —— payload 没生成"

# Reproducible: without SOURCE_DATE_EPOCH the header's os_version carries
# today's date, so an unchanged kernel yields a different image and a
# different checksum tomorrow.
#
# GNU stat first, BSD second. The other order looks harmless and is not:
# GNU stat accepts `-f` as "file system status", prints a block of prose to
# stdout and exits 0, so the `||` fallback never runs and the variable ends
# up holding "  File: ...\nBlock size: ..." -- which the packer then feeds to
# int(). Cost: one failed packing run on Windows (2026-11-21).
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$img" 2>/dev/null || stat -f %m "$img")}"

case "$PACK" in
  gzip)
    # gzip(Image body) ++ the DTB, appended the way ABL scans for it.
    withdtb="${OUT}/Image.gz-dtb"
    cat "$payload" "$dtb" >"$withdtb"
    name=boot-op8p-gzip.img
    # GPU microcode has to be reachable *before* the root is mounted.
    #
    # msm is built into the Image (CONFIG_DRM_MSM=y), so its probe runs in
    # the initramfs at ~1.3 s; the ext4 root is mounted at ~3.6 s. The a650
    # firmware lives on the root filesystem, so every early probe fails:
    #
    #   Direct firmware load for qcom/a650_sqe.fw failed with error -2
    #   adreno: Unable to load a650_zap.mdt
    #   msm_dpu: gpu hw init failed: -2
    #   TU: could not get GPU ID (VK_ERROR_INITIALIZATION_FAILED)
    #   gamescope: Failed to create backend.
    #
    # ...and with no Vulkan device gamescope never enables the panel, so the
    # screen stays black. FW_BUILTIN=0 in soc.env is right for ROCKNIX's
    # flow, not this one.
    #
    # The kernel unpacks the built-in initramfs first and any ramdisk from
    # the boot image after it, so a small ramdisk carrying just these three
    # files is enough. Built by the container step that writes it; absent
    # that file the packing stays exactly as before.
    rd_arg=()
    if [[ ! -f "${OUT}/gpu-fw-ramdisk.cpio.gz" ]]; then
      # 缺了它 GPU 一定起不来（见上面那串日志），所以先尝试现做一份。
      # 做不出来就明确告警 —— 静默跳过的结果是一块全黑的屏幕。
      bash "${PORT_ROOT}/scripts/make-op8p-gpu-ramdisk.sh" "${OUT}" \
        || echo "make-op8p: WARNING 没有 gpu-fw-ramdisk.cpio.gz，GPU 在 initramfs 阶段拿不到 zap，屏幕必黑" >&2
    fi
    if [[ -f "${OUT}/gpu-fw-ramdisk.cpio.gz" ]]; then
      rd_arg=(--ramdisk "${OUT}/gpu-fw-ramdisk.cpio.gz")
    fi
    python3w "${KCOMMON}/mkbootimg-v0.py" \
      --kernel "$withdtb" \
      ${rd_arg[@]+"${rd_arg[@]}"} \
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
    python3w "${KCOMMON}/mkbootimg-v2.py" \
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
echo "大小:  $(stat -c %s "${OUT}/${name}" 2>/dev/null || stat -f %z "${OUT}/${name}") 字节"
echo "打包:  $PACK  (header $([[ $PACK == v2 ]] && echo v2 || echo v0), page $PAGESIZE)"
echo "DTB:   $DTB_NAME ($(stat -c %s "$dtb" 2>/dev/null || stat -f %z "$dtb") 字节)"
echo "cmdline: $cmdline"
echo
echo "刷机:  ./flash-op8p.sh --test    （写非活动槽，当前活动槽是 \$(fastboot getvar current-slot)）"
