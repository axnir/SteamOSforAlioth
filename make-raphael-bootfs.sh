#!/usr/bin/env bash
# 做一块 U-Boot 能直接用的 FAT32 启动盘（写进 raphael 的 cache 分区）。
#
# 为什么是 cache：它是 256 MiB、Android 不挂载、丢了也无所谓的分区；
# 参考项目在这台机器上也用它当 /boot。U-Boot 那侧的用法见 docs/raphael.md §10。
#
# 依赖 mkfs.vfat 和 mcopy（dosfstools / mtools）。Windows 上没有，用容器：
#
#   MSYS_NO_PATHCONV=1 "/c/Program Files/WSL/wslc" run --rm \
#     -v "D:/Developer/Repo:/repo" -v "raphael-work:/work" \
#     proxy.vvvv.ee/library/fedora:43 bash -c '
#       dnf -q -y install dosfstools mtools >/dev/null 2>&1
#       bash /repo/SteamOSforAlioth/make-raphael-bootfs.sh'
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${STEAMOS_WORK:-${REPO}/work}"
KERNEL_OUT="${KERNEL_OUT:-${OUT}/kernel-raphael/output/current}"

# cache 的实际大小，fastboot getvar partition-size:cache 报的是 0x10000000。
# 刷写时镜像尺寸必须不超过它，也不该超过 —— 所以这里默认按它来。
SIZE="${SIZE:-0x10000000}"
if [[ "$SIZE" == 0x* ]]; then
  SIZE=$(( SIZE ))
fi

IMG="${KERNEL_OUT}/boot/Image"
DTB="${KERNEL_OUT}/dtbs/sm8150-xiaomi-raphael.dtb"
[[ -f "$IMG" ]] || { echo "缺 $IMG（先跑 build-raphael-kernel.sh）" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "缺 $DTB" >&2; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "缺 mkfs.vfat（dosfstools）" >&2; exit 1; }
command -v mcopy     >/dev/null || { echo "缺 mcopy（mtools）" >&2; exit 1; }

need=$(( $(stat -c %s "$IMG") + $(stat -c %s "$DTB") + 4*1024*1024 ))
(( SIZE > need )) || { echo "镜像 $SIZE 字节装不下（需要约 $need）" >&2; exit 1; }

mkdir -p "$OUT"
TMP="${OUT}/boot-fat.img"
rm -f "$TMP"
truncate -s "$SIZE" "$TMP"
mkfs.vfat -F 32 -n STEAMBOOT "$TMP" >/dev/null

mmd -i "$TMP" ::/extlinux
mcopy -i "$TMP" "$IMG" ::/Image
mcopy -i "$TMP" "$DTB" "::/$(basename "$DTB")"

# 不写 fdt 行 = 用 U-Boot 自己的控制设备树。这是参考项目验证过的组合
# （内核走 U-Boot 时，内存和设备由 U-Boot 提供，而不是内核树里那份 DTS）。
# 第一次能启动之后再谈换成我们自己的 DTB。
cat >"${OUT}/extlinux.conf" <<'EOF'
default steamos
timeout 30
menu title SteamOS on raphael

label steamos
    kernel /Image
    append console=tty0 steamos.usbshell=1
EOF
mcopy -i "$TMP" "${OUT}/extlinux.conf" ::/extlinux/extlinux.conf

echo "== ${TMP} ($(stat -c %s "$TMP") 字节) =="
mdir -i "$TMP" ::/
mdir -i "$TMP" ::/extlinux
echo
echo "刷写： fastboot flash cache ${TMP}"
echo "注意： U-Boot 目前不会把 cache 当启动候选，见 docs/raphael.md §10.4"
