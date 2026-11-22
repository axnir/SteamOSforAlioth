#!/usr/bin/env bash
# 阶段 2（温控 / 电量计 / DSP 固件）的静态断言。
#
# 这些检查都在源码和构建产物上做，不需要设备 —— 目的是在刷机之前就把
# "改了但没生效" 的那一类错误挡掉：DTS 写了却没进 dtb、补丁放在目录里却
# 没被补丁循环读到、overlay 里有文件却没有 wants 链接。
#
# 用法: scripts/assert-op8p-stage2.sh [KOUT]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOUT="${1:-${ROOT}/work/kernel-sm8250/output/current}"
DTS="${ROOT}/external-and-mods/kernel-sm8250/dts/sm8250-oneplus-instantnoodlep.dts"
PATCH="${ROOT}/external-and-mods/kernel-sm8250/patches/0032-power-supply-bq27xxx-tolerate-off-spec-soc-temp-units.patch"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== DTS 温控 =="
check "cluster0 补了 passive trip"   "grep -q 'cluster0_alert_passive' '$DTS'"
check "cluster1 补了 passive trip"   "grep -q 'cluster1_alert_passive' '$DTS'"
check "cluster0 绑了 cooling-device" "grep -A12 '/thermal-zones/cluster0-thermal} {' '$DTS' | grep -q 'cooling-device'"
check "cluster1 绑了 cooling-device" "grep -A12 '/thermal-zones/cluster1-thermal} {' '$DTS' | grep -q 'cooling-device'"
check "CPU 一档 84 °C"               "grep -q 'cpu0_alert0 { temperature = <84000>; }' '$DTS'"
check "CPU 二档 88 °C"               "grep -q 'cpu0_alert1 { temperature = <88000>; }' '$DTS'"
check "GPU 82 °C"                    "grep -q 'gpu_top_alert0 { temperature = <82000>; }' '$DTS'"
check "critical 仍是 110 °C（未改动）" "! grep -q 'cpu0_crit { temperature' '$DTS'"

echo "== 电量计补丁 =="
check "补丁文件存在"                "[[ -s '$PATCH' ]]"
check "含 SOC 单位换算"             "grep -q 'DIV_ROUND_CLOSEST(soc, 100)' '$PATCH'"
check "含温度 0.1 °C 回退"          "grep -q 'temp - 2731 < -1000' '$PATCH'"
check "含 FCC 哨兵兜底"             "grep -q '0xfffe \\* 1000' '$PATCH'"
check "含 Dead 判定收紧"            "grep -q 'di->cache.capacity <= 5' '$PATCH'"

echo "== 构建产物 =="
if [[ -d "$KOUT" ]]; then
	DTB="$(find "$KOUT/dtbs" -name 'sm8250-oneplus-instantnoodlep.dtb' 2>/dev/null | head -1)"
	check "dtb 存在" "[[ -n '$DTB' ]]"
	check "config 里 AW8697 已开" "grep -q '^CONFIG_INPUT_AW8697=y' '$KOUT'/config-*"
	check "config 里 CPU_THERMAL 已开" "grep -q '^CONFIG_CPU_THERMAL=y' '$KOUT'/config-*"
	check "config 里 DEVFREQ_THERMAL 已开" "grep -q '^CONFIG_DEVFREQ_THERMAL=y' '$KOUT'/config-*"
else
	echo "  （没有 $KOUT，跳过产物检查）"
fi

echo "== overlay =="
check "dsp 固件脚本存在"   "[[ -x '${ROOT}/op8p-overlay/usr/lib/steamos-arm/op8p-dsp-firmware' ]]"
check "dsp 单元存在"       "[[ -f '${ROOT}/op8p-overlay/etc/systemd/system/op8p-dsp-firmware.service' ]]"
check "rootfs 构建会建 wants 链接" \
	"grep -q 'op8p-dsp-firmware.service' '${ROOT}/scripts/make-op8p-rootfs.sh'"
check "squash 脚本会进镜像" \
	"grep -q 'squash-qcom-mdt.py' '${ROOT}/scripts/make-op8p-rootfs.sh'"

printf '\n%d 通过, %d 失败\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
