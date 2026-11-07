#!/usr/bin/env bash
# 下载 raphael 需要的通用无线固件（linux-firmware，可再分发）。
#
# 这些文件不在手机的 vendor/modem 分区里：Android 下是 modem 通过 tqftpserv 从
# vendor 分区取的，被我们覆盖后就没法再提取。好消息是 WCN3998/WCN3990 在 mainline
# 走 ath10k + btqca，用 linux-firmware 里的通用版本就能起来（射频校准是通用的，
# 性能和稳定性不如原厂校准）。
#
#   qca/crbtfw21.tlv + qca/crnv21.bin          蓝牙 rampatch / NVM
#   ath10k/WCN3990/hw1.0/firmware-5.bin        WCN3990 的 IE 容器（60 字节，正常）
#   ath10k/WCN3990/hw1.0/board-2.bin           board data（board_id 0xff）
#
# 落点：work/fw-ext/，build-raphael-reference.sh 会把它整体装进 rootfs 的
# /usr/lib/firmware/。也用于运行时热补：
#   tar -czf work/fw-ext.tar.gz -C work/fw-ext .   # 然后经 USB NCM 推给手机
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/work/fw-ext}"
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

files=(
  "ath10k/WCN3990/hw1.0/firmware-5.bin:60"     # IE 容器，本来就只有 60 字节
  "ath10k/WCN3990/hw1.0/board-2.bin:800000"
  "qca/crbtfw21.tlv:100000"
  "qca/crnv21.bin:4000"
)

for entry in "${files[@]}"; do
  rel="${entry%:*}"
  min="${entry##*:}"
  dst="$OUT/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -s "$dst" ] && [ "$(stat -c%s "$dst")" -ge "$min" ]; then
    echo "已存在 $rel ($(stat -c%s "$dst") B)"
    continue
  fi
  echo "下载 $rel"
  curl -fsSL --max-time 180 -o "$dst.tmp" "$BASE/$rel"
  size=$(stat -c%s "$dst.tmp")
  if [ "$size" -lt "$min" ]; then
    echo "  ! $rel 只有 $size B，不像是完整文件" >&2
    rm -f "$dst.tmp"
    exit 1
  fi
  mv "$dst.tmp" "$dst"
  echo "  $size B"
done

echo "固件就绪: $OUT"
find "$OUT" -type f -printf '  %-46p %s\n'
