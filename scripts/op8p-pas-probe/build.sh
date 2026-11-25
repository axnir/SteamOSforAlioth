#!/bin/sh
# 在 Linux 构建环境（WSL 容器）里编译一次性 PAS 探测模块。
#
# 用法：
#   KDIR=/path/to/kernel-source ./build.sh
#   ./build.sh /path/to/kernel-source
#
# 注意：必须与真机跑的 7.2.8-sm8250-steamos 同一份内核源码树，
#       否则 struct qcom_scm_pas_context 的布局会不匹配。
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KDIR=${1:-${KDIR:-}}

if [ -z "$KDIR" ] || [ ! -f "$KDIR/Makefile" ]; then
    echo "用法: KDIR=<内核源码目录> $0 [内核源码目录]" >&2
    echo "当前 KDIR='${KDIR}'，不是内核源码树" >&2
    exit 1
fi

# Windows git checkout 可能变成 CRLF；.c/Makefile 都不能带 \r。
for f in op8p-pas-probe.c Makefile; do
    if grep -q "$(printf '\r')" "$HERE/$f" 2>/dev/null; then
        echo "清理 CRLF: $f"
        tr -d '\r' < "$HERE/$f" > "$HERE/$f.tmp"
        mv "$HERE/$f.tmp" "$HERE/$f"
    fi
done

cd "$HERE"
make -C "$KDIR" M="$HERE" modules

KO="$HERE/op8p-pas-probe.ko"
if [ ! -f "$KO" ]; then
    echo "编译结束但没找到 $KO" >&2
    exit 1
fi

echo
echo "OK: $KO"
echo "真机配置 CONFIG_MODULE_SIG is not set，模块不需要签名。"
echo "推到设备：主机起 HTTP 服务，设备 curl -o /tmp/op8p-pas-probe.ko <url>"
echo "然后：chmod +x /tmp/op8p-pas-probe.ko && /tmp/run-on-device.sh"
