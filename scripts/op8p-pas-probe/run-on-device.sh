#!/bin/sh
# 在真机上以 root 运行；按地址×大小矩阵逐组 insmod，结果看 dmesg。
# 模块 init 故意返回 -EAGAIN，insmod 必然报 "Invalid argument"，这是预期的。
#
# 用法：
#   sh run-on-device.sh /tmp/op8p-pas-probe.ko
#
# 安全级别：
#   第 1 段只测 mem_setup（不读固件、不启动 DSP）；
#   第 2 段加 do_init=1（验签，仍不启动 DSP）；
#   第 3 段 do_auth=1 会真的启动 DSP，默认注释掉，需要时手工放开。
set -u

KO=${1:-/tmp/op8p-pas-probe.ko}
FW=${FW:-postmarketos/adsp.mbn}
# PHASE=1：只跑第 1 段（mem_setup），不验签、不启动 DSP。
# 默认 all：跑第 1 + 第 2 段；第 3 段永远只打印、不执行。
PHASE=${PHASE:-all}

if [ ! -f "$KO" ]; then
    echo "没有 $KO" >&2
    exit 1
fi
chmod +x "$KO"

echo "=== 当前 adsp 状态（只读） ==="
for r in /sys/class/remoteproc/remoteproc*; do
    [ -r "$r/name" ] || continue
    printf '%s: %s / %s\n' "$r" "$(cat "$r/name")" "$(cat "$r/state" 2>/dev/null)"
done

echo
echo "=== 第 1 段：只测 mem_setup（安全） ==="
# 格式：地址 大小 备注。
# 2026-11-25 更正：op8p 的 adsp_mem 是 memory@91b00000 + 0x2500000（真机 DT 已核），
# 不是 raphael 的 0x8a100000；固件 p_paddr span = 0x1d00000（29 MiB）。
# 注意：内核 mdt_loader 只在 init_image() 成功后才对 relocate 固件调 mem_setup()，
# 因此不验签的裸 mem_setup 全 -22 是预期，仅能证明 SCM 通道活着，不能判地址对错。
for spec in \
    '0x91b00000 0x1d00000 真机 adsp_mem + 固件 p_paddr span' \
    '0x91b00000 0x2500000 真机 adsp_mem 全容量' \
    '0x8bb00000 0x1d00000 alioth 地址（对照，本机不存在）' \
    '0x8a100000 0x1d00000 raphael 地址（对照，本机不存在）' \
    '0x98900000 0x2700000 Tab S6 成功地址（对照）' \
    '0xc0000000 0x1d00000 高内存（对照）'
do
    set -- $spec
    addr=$1; size=$2; note=$3
    echo "--- mem_setup addr=$addr size=$size  # $note"
    dmesg -c >/dev/null 2>&1 || true
    insmod "$KO" pas_id=1 addr="$addr" size="$size" pre_shutdown=1 post_shutdown=1 || true
    dmesg | grep -E 'pas_probe:' | tail -n 8
    echo
done

if [ "$PHASE" != 1 ]; then
echo "=== 第 2 段：init_image + mem_setup（不启动 DSP） ==="
for spec in \
    '0x91b00000 0x1d00000 真机 adsp_mem + span' \
    '0x91b00000 0x2500000 真机 adsp_mem 全容量' \
    '0x98900000 0x2700000 Tab S6 地址（对照）'
do
    set -- $spec
    addr=$1; size=$2; note=$3
    echo "--- do_init=1 addr=$addr size=$size  # $note"
    dmesg -c >/dev/null 2>&1 || true
    insmod "$KO" pas_id=1 addr="$addr" size="$size" \
        do_init=1 fw_name="$FW" pre_shutdown=1 post_shutdown=1 || true
    dmesg | grep -E 'pas_probe:' | tail -n 12
    echo
done
fi

echo "=== 第 3 段：do_auth=1（危险，会真启动 DSP；默认不跑） ==="
echo "需要时手工执行下面这一行，并确保能接受死机重启："
echo "  insmod $KO pas_id=1 addr=0x8a100000 size=0xf00000 do_init=1 do_auth=1 || true"
echo "  dmesg | grep pas_probe"
