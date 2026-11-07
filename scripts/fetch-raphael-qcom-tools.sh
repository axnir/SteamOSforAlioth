#!/usr/bin/env bash
# 下载 Qualcomm 用户态三件套（qrtr-ns / rmtfs / tqftpserv）的 Debian arm64 预编译包，
# 解出二进制放到 work/qcom-tools/stage/{bin,lib}，由 build-raphael-reference.sh
# 装进 rootfs 的 /opt/raphael/qcom。
#
# 为什么要它们：modem 通过 rmtfs 访问 EFS（modemst1/modemst2/fsg/fsc），通过
# tqftpserv 向 AP 取自己的运行时文件，靠 qrtr 做服务注册。SteamOS 的 rootfs
# 里一样都没有，于是 modem 起来后每 40 秒 fatal error 崩一次，ath10k_snoc 的
# QMI WLFW 永远握不上手 —— WiFi 就一直是 lo usb0。
#
# 用发行版预编译而不是自己交叉编译：这几个都是上游 linux-msm 的小工具，
# Debian 有 arm64 包，glibc 版本也和 SteamOS 兼容。
#
# .deb 是 ar 归档：Linux 侧用 ar，Windows 侧退回 bsdtar（C:\Windows\System32\tar.exe
# 就是 bsdtar，能直接读 ar）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/work/qcom-tools}"
B="https://deb.debian.org/debian/pool/main"
mkdir -p "$OUT"
cd "$OUT"

debs=(
  "r/rmtfs/rmtfs_1.3-1_arm64.deb"
  "t/tqftpserv/tqftpserv_1.3-1_arm64.deb"
  "q/qrtr/qrtr-tools_1.2-1_arm64.deb"
  "q/qrtr/libqrtr1_1.2-1_arm64.deb"
)
for d in "${debs[@]}"; do
  f="$(basename "$d")"
  if [ -s "$f" ]; then echo "已存在 $f"; else
    echo "下载 $f"
    curl -fsSL --max-time 180 -o "$f" "$B/$d"
    echo "  $(stat -c%s "$f") B"
  fi
done

extract() { # $1=deb $2=目标目录
  local f="$1" d="$2"
  rm -rf "$d"; mkdir -p "$d"
  if command -v ar >/dev/null 2>&1; then
    ( cd "$d" && ar x "../$f" && tar xf data.tar.* )
  elif [ -x /c/Windows/System32/tar.exe ]; then
    /c/Windows/System32/tar.exe -xf "$f" -C "$d" data.tar.xz
    # Windows 上建不了符号链接（libqrtr.so.1 → libqrtr.so.1.2），这一步会报错，
    # 但真实文件已经解出来了，stage 里我们会把 .so.1.2 复制成 .so.1
    /c/Windows/System32/tar.exe -xf "$d/data.tar.xz" -C "$d" 2>/dev/null ||
      echo "   （符号链接跳过，Windows 限制）"
  else
    echo "需要 ar 或 bsdtar 才能解 .deb" >&2; exit 1
  fi
}

for d in "${debs[@]}"; do
  f="$(basename "$d" .deb)"
  extract "$(basename "$d")" "$f"
done

rm -rf stage && mkdir -p stage/bin stage/lib
cp rmtfs_1.3-1_arm64/usr/bin/rmtfs \
   tqftpserv_1.3-1_arm64/usr/bin/tqftpserv \
   qrtr-tools_1.2-1_arm64/usr/bin/qrtr-ns \
   qrtr-tools_1.2-1_arm64/usr/bin/qrtr-lookup \
   qrtr-tools_1.2-1_arm64/usr/bin/qrtr-cfg stage/bin/
cp libqrtr1_1.2-1_arm64/usr/lib/aarch64-linux-gnu/libqrtr.so.1.2 stage/lib/libqrtr.so.1

echo "工具就绪: $OUT/stage"
ls -l stage/bin stage/lib
