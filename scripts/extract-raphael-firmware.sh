#!/usr/bin/env bash
# 从 raphael 自己的 Android 分区里取机内固件。
#
# 和 alioth 那套同源的原则：这些文件是 Xiaomi/Qualcomm 签名的，走 PAS 验签，
# linux-firmware 里的同名通用签名文件 TrustZone 会拒收 —— 所以只能 bring your
# own。**不可再分发**，不进 git（work/ 已被 .gitignore 覆盖）。
#
# 用法：手机开机进 Android（Magisk root，和提取时一致），数据线连电脑，然后
#
#   scripts/extract-raphael-firmware.sh [OUT]
#
# OUT 默认 ${STEAMOS_WORK:-<repo>/work}/raphael-fw
#
# 三个来源（都是 Android 已经挂好的）：
#   /vendor/firmware         GPU（a640_gmu.bin、a640_zap.*）、tfa98xx、goodix 触摸
#   /vendor/firmware_mnt     modem_a 的挂载点：adsp.*、cdsp.*、modem、wcnss
#   /mnt/vendor/persist      WLAN MAC（wlan_mac.bin）、传感器/显示校准
#
# 注意 shell 用户读不了这些路径（SELinux），所以先 `su -c cp` 到 /data/local/tmp
# 再 adb pull；直接 `adb pull /vendor/firmware` 会报 Permission denied。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${STEAMOS_WORK:-${ROOT}/work}/raphael-fw}"

command -v adb >/dev/null || { echo "缺 adb" >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "手机不在线（adb）" >&2; exit 1; }

for f in /vendor/firmware /vendor/firmware_mnt/image /mnt/vendor/persist; do
  adb shell "su -c 'test -d $f'" || { echo "手机上没有 $f（root？）" >&2; exit 1; }
done

mkdir -p "$OUT"
echo "==> 拷到 /data/local/tmp（root）"
adb shell "su -c 'rm -rf /data/local/tmp/fw-vendor /data/local/tmp/fw-modem /data/local/tmp/fw-persist
  cp -a /vendor/firmware /data/local/tmp/fw-vendor
  cp -a /vendor/firmware_mnt/image /data/local/tmp/fw-modem
  cp -a /mnt/vendor/persist /data/local/tmp/fw-persist
  chmod -R a+rX /data/local/tmp/fw-*'"

echo "==> pull 到 $OUT"
mkdir -p "$OUT"
adb pull /data/local/tmp/fw-vendor "$OUT/vendor-firmware"
adb pull /data/local/tmp/fw-modem "$OUT/modem-image"
adb pull /data/local/tmp/fw-persist "$OUT/persist"

echo "==> 清理手机侧"
adb shell "su -c 'rm -rf /data/local/tmp/fw-vendor /data/local/tmp/fw-modem /data/local/tmp/fw-persist'"

echo "==> 核对关键文件（缺任何一个，后面黑屏/没声/没 WiFi 都怪它）"
for f in a640_gmu.bin a640_zap.mdt; do
  [[ -s "$OUT/vendor-firmware/$f" ]] || { echo "缺 $OUT/vendor-firmware/$f" >&2; exit 1; }
done
ls "$OUT/modem-image/adsp.mdt" >/dev/null || { echo "缺 modem-image/adsp.mdt" >&2; exit 1; }
echo "完成：$(du -sh "$OUT" | cut -f1)  ->  $OUT"
echo "提醒：这些文件 Xiaomi 签名、不可再分发；不要提交、不要上传。"
