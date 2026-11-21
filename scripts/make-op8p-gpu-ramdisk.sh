#!/usr/bin/env bash
# 生成 work/steamos-op8p/gpu-fw-ramdisk.cpio.gz —— 只装 a650 的 6 个文件。
#
# 为什么需要：CONFIG_DRM_MSM=y，msm 在 initramfs 阶段（约 1.3 s）就 probe，
# 而 ext4 根要到约 3.6 s 才挂上。a650 的微码放在根文件系统里，于是每次早
# probe 都失败：
#
#   Direct firmware load for qcom/a650_sqe.fw failed with error -2
#   adreno: Unable to load a650_zap.mdt
#   msm_dpu: gpu hw init failed: -2
#   TU: could not get GPU ID (VK_ERROR_INITIALIZATION_FAILED)
#   gamescope: Failed to create backend.
#
# 没有 Vulkan 设备 gamescope 就不点面板，屏幕纯黑。所以这 6 个文件必须随
# boot 镜像的 ramdisk 走：内核先解内建 initramfs，再覆盖 boot 镜像自带的
# ramdisk，后者的优先级够早。
#
# 为什么 zap 必须本机签名：linux-firmware 里那份 a650_zap.mbn 是通用签名，
# TrustZone 直接拒（qcom_scm_pas_init_image 返回 -22 EINVAL）。可用的四件套
# 只存在于本机 super 的 vendor_a 里：
#
#   /vendor/firmware_mnt/image/a650_zap.mdt
#   /vendor/firmware_mnt/image/a650_zap.b00  .b01  .b02
#
# 提取要点（解析 liblp 元数据，geometry 在 super 偏移 0x1000、header 在
# 0x3000，这块 2026-11-21 的 vendor_a 是偏移 3492806656 / 大小 1622464624，
# 换机器或换 Android 版本必然不同，不要照抄）：
#
#   python3 work/op8p-find-vendor.py /path/to/super.img     # 打印偏移和大小
#   dd if=super.img of=vendor_a.img bs=1M skip=... count=...
#
# 然后用 file/strings 在 vendor_a.img 里找到这四个文件的开头，按 Android
# vendor 镜像内的路径偏移取出。产物放 work/op8p-firmware/。
#
# 踩过的坑：cpio 里只有文件条目、没有目录条目时，内核解包会**静默跳过整个
# ramdisk**（不报错，只是找不到固件）。所以这里用 find | cpio，让目录条目
# 自然带上；不要手写 cpio 流。
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${OP8P_GPU_FW:-${PORT_ROOT}/work/op8p-firmware}"
LFW="${OP8P_LFW:-}"
OUT="${1:-${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-op8p}"
WSLC="${WSLC:-/c/Program Files/WSL/wslc}"
WSLC_IMAGE="${WSLC_IMAGE:-proxy.vvvv.ee/library/fedora:43}"

# sqe / gmu 来自 linux-firmware（通用，不需要本机签名）；zap 必须来自本机。
if [[ -z "$LFW" ]]; then
  LFW="$(find "${PORT_ROOT}/work/cache" -maxdepth 2 -type d -name 'linux-firmware-*' 2>/dev/null | head -1)"
fi

missing=()
for f in "${FW}/a650_zap.mdt" "${FW}/a650_zap.b00" "${FW}/a650_zap.b01" "${FW}/a650_zap.b02" \
         "${LFW}/qcom/a650_sqe.fw" "${LFW}/qcom/a650_gmu.bin"; do
  [[ -f "$f" ]] || missing+=("$f")
done
if ((${#missing[@]})); then
  echo "make-op8p-gpu-ramdisk: 缺这些文件，无法生成：" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "  zap 四件套见脚本头部注释（必须从本机 vendor_a 提取）；" >&2
  echo "  sqe/gmu 来自 work/cache/linux-firmware-*/qcom/。" >&2
  exit 1
fi

mkdir -p "$OUT"
# 绝对路径：容器把 /out 挂到这里，相对路径在 wslc 的 -v 下会解析到别处。
OUT_DIR="$(cd "$OUT" && pwd)"
OUT="${OUT_DIR}/gpu-fw-ramdisk.cpio.gz"

# 容器里做：Windows 没有 cpio。树里铺 qcom/ 和 updates/qcom/ 两处，
# 覆盖内核的两级固件搜索路径。
WIN_ROOT="$(cygpath -w "$PORT_ROOT" 2>/dev/null || printf '%s' "$PORT_ROOT")"
WIN_FW="$(cygpath -w "$FW" 2>/dev/null || printf '%s' "$FW")"
WIN_LFW="$(cygpath -w "$LFW" 2>/dev/null || printf '%s' "$LFW")"
WIN_OUTDIR="$(cygpath -w "$OUT_DIR" 2>/dev/null || printf '%s' "$OUT_DIR")"

MSYS_NO_PATHCONV=1 "$WSLC" run --rm \
  -v "${WIN_ROOT}:/repo" \
  -v "${WIN_FW}:/fw:ro" \
  -v "${WIN_LFW}:/lfw:ro" \
  -v "${WIN_OUTDIR}:/out" \
  "$WSLC_IMAGE" bash -c '
  set -e
  dnf install -y cpio gzip >/dev/null 2>&1
  T=$(mktemp -d)
  for base in qcom updates/qcom; do
    mkdir -p "$T/$base"
    cp /fw/a650_zap.mdt /fw/a650_zap.b00 /fw/a650_zap.b01 /fw/a650_zap.b02 "$T/$base/"
    cp /lfw/qcom/a650_sqe.fw /lfw/qcom/a650_gmu.bin "$T/$base/"
  done
  ( cd "$T" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 ) > /out/gpu-fw-ramdisk.cpio.gz
  rm -rf "$T"
  ls -l /out/gpu-fw-ramdisk.cpio.gz
'

[[ -s "$OUT" ]] || { echo "make-op8p-gpu-ramdisk: 没产出 $OUT" >&2; exit 1; }
echo "make-op8p-gpu-ramdisk: $OUT ($(du -h "$OUT" | cut -f1))"
