#!/usr/bin/env bash
# 下载 raphael 需要的固件（两批来源），落到 work/fw-ext/，
# build-raphael-reference.sh 会把它整体装进 rootfs 的 /usr/lib/firmware/。
#
# 1) linux-firmware（kernel.org，可再分发）：ath10k 的 IE 容器、通用 board data
# 2) firmware-xiaomi-raphael（github，机内厂商件）：goodix 触控的 cfg、
#    ath10k 的 board.bin、qca 的厂商版 rampatch/NVM
#
# 为什么厂商件要从那个仓库取：Android 下这些由 modem 通过 tqftpserv 从 vendor
# 分区提供，我们把 /data 覆盖后取不回来了。那个 repo 是这台机器 k20pro-linux
# 移植的配套固件集（DTS 注释里就引用了它）。
#
# 只取 cfg 不取 fw：goodix_gt9886_fw_f11.bin 会让这个驱动版本的
# goodix_fw_update_thread 空指针（实测 oops），而控制器出厂固件本来就匹配
# （PID 9886 / VID 03 04 02 29），cfg 到位后 stage2 init 就成功了。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/work/fw-ext}"
KERNEL_ORG="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
# GitHub raw 直连常常 TLS 握手失败，先走镜像，失败再退回直连
MIRROR="https://ghfast.top/https://raw.githubusercontent.com/GengWei1997/firmware-xiaomi-raphael/HEAD/lib/firmware"
DIRECT="https://raw.githubusercontent.com/GengWei1997/firmware-xiaomi-raphael/HEAD/lib/firmware"

fetch() { curl -fsSL --max-time 180 -o "$2" "$1"; }

# 通用件：相对路径:最小字节数（min 用来识别「下到了错误页」而不是真文件）
common=(
  "ath10k/WCN3990/hw1.0/firmware-5.bin:60"
  "ath10k/WCN3990/hw1.0/board-2.bin:800000"
)
for entry in "${common[@]}"; do
  rel="${entry%:*}"
  min="${entry##*:}"
  dst="$OUT/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -s "$dst" ] && [ "$(stat -c%s "$dst")" -ge "$min" ]; then
    echo "已存在 $rel ($(stat -c%s "$dst") B)"
    continue
  fi
  fetch "$KERNEL_ORG/$rel" "$dst.tmp" || { echo "  ! 下载失败: $rel" >&2; rm -f "$dst.tmp"; exit 1; }
  size=$(stat -c%s "$dst.tmp")
  if [ "$size" -lt "$min" ]; then
    echo "  ! $rel 只有 $size B，不像完整文件" >&2; rm -f "$dst.tmp"; exit 1
  fi
  mv "$dst.tmp" "$dst"
  echo "下载 $rel ($size B)"
done

# 厂商件：优先镜像，退回直连。qca 的 rampatch 用厂商版（229 KB 比通用版 177 KB 匹配）
vendor=(
  "qca/crbtfw21.tlv:200000"
  "qca/crnv21.bin:4000"
  "goodix_gt9886_cfg_f11.bin:1000"
  "ath10k/WCN3990/hw1.0/board.bin:20000"
)
for entry in "${vendor[@]}"; do
  rel="${entry%:*}"
  min="${entry##*:}"
  dst="$OUT/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -s "$dst" ] && [ "$(stat -c%s "$dst")" -ge "$min" ]; then
    echo "已存在 $rel ($(stat -c%s "$dst") B)"
    continue
  fi
  ok=""
  fetch "$MIRROR/$rel" "$dst.tmp" 2>/dev/null && ok=1
  [ -n "$ok" ] || { fetch "$DIRECT/$rel" "$dst.tmp" 2>/dev/null && ok=1; }
  if [ -z "$ok" ]; then
    echo "  ! 下载失败（厂商件）: $rel" >&2
    rm -f "$dst.tmp"
    exit 1
  fi
  size=$(stat -c%s "$dst.tmp")
  if [ "$size" -lt "$min" ]; then
    echo "  ! $rel 只有 $size B，不像完整文件" >&2; rm -f "$dst.tmp"; exit 1
  fi
  mv "$dst.tmp" "$dst"
  echo "下载 $rel ($size B)"
done

echo "固件就绪: $OUT"
find "$OUT" -type f -printf '  %-46p %s\n'
