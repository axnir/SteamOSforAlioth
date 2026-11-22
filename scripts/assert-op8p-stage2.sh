#!/usr/bin/env bash
# 阶段 2（温控 / 电量计 / DSP 固件）的静态断言。
#
# 这些检查都在源码和构建产物上做，不需要设备 —— 目的是在刷机之前就把
# "改了但没生效" 的那一类错误挡掉：DTS 写了却没进 dtb、补丁放在目录里却
# 没被补丁循环读到、overlay 里有文件却没有 wants 链接。
#
# 用法: scripts/assert-op8p-stage2.sh [KOUT]
#
# 关于 set -e：这个脚本用 check() 手动累计失败，本不该被任何一条裸命令
# 终止。2026-11-22 换机后它就以退出码 1 静默结束了整整一轮 ——
# `DTB="$(find "$KOUT/dtbs" ...)"` 在 dtbs 目录不存在时让 find 返回 1，
# 赋值语句继承该状态，set -e 直接把脚本杀掉，一行输出都没有。所以：
# ① 所有可能"没得可查"的命令都显式兜底；② ERR trap 说明"是脚本自身
# 出错，不是断言失败"，免得把异常退出读成规则被破坏。
set -euo pipefail
trap 'rc=$?; printf "\n断言脚本自身在第 %s 行异常退出（rc=%s）—— 这不是断言失败，是脚本出错，请修脚本\n" "$LINENO" "$rc" >&2' ERR

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
# 三种状态要分开：没编译（跳过，明说）、编译了一半（失败，因为这正是
# "改了但没生效"的孪生症状）、完整（逐项查）。
skipped=""
if [[ ! -d "$KOUT" ]]; then
	skipped="KOUT 目录不存在（$KOUT）"
elif [[ ! -d "$KOUT/dtbs" ]]; then
	skipped="KOUT 里没有 dtbs/（$KOUT）"
elif ! compgen -G "$KOUT/config-*" >/dev/null; then
	skipped="KOUT 里没有 config-*（$KOUT）"
fi

if [[ -n "$skipped" ]]; then
	printf '  SKIP 产物检查：%s\n' "$skipped"
	printf '       → 先编译内核（scripts/op8p-build-docker.sh），否则"dtb 里到底有没有\n'
	printf '         这些节点"这一层完全没验过 —— 刷机前别把 SKIP 当通过\n'
else
	DTB="$(find "$KOUT/dtbs" -name 'sm8250-oneplus-instantnoodlep.dtb' 2>/dev/null | head -1 || true)"
	CONF_OUT="$(compgen -G "$KOUT/config-*" | head -1)"
	check "dtb 存在" "[[ -n '$DTB' ]]"
	check "config 里 AW8697 已开" "grep -q '^CONFIG_INPUT_AW8697=y' '$CONF_OUT'"
	check "config 里 CPU_THERMAL 已开" "grep -q '^CONFIG_CPU_THERMAL=y' '$CONF_OUT'"
	check "config 里 DEVFREQ_THERMAL 已开" "grep -q '^CONFIG_DEVFREQ_THERMAL=y' '$CONF_OUT'"
	# 产物里真的有这次改动才叫生效：源码树 grep 通过而 dtb 是旧的，
	# 是这套移植历史上最常见的一种"改了没生效"。
	if command -v dtc >/dev/null; then
		check "产出的 dtb 里带 aw8697 节点" \
			"dtc -I dtb -O dts '$DTB' 2>/dev/null | grep -q 'awinic,aw8697'"
	else
		printf '  SKIP dtb 内容检查：没有 dtc（brew install dtc / dnf install dtc）\n'
	fi
fi

echo "== overlay =="
check "dsp 固件脚本存在"   "[[ -x '${ROOT}/op8p-overlay/usr/lib/steamos-arm/op8p-dsp-firmware' ]]"
check "dsp 单元存在"       "[[ -f '${ROOT}/op8p-overlay/etc/systemd/system/op8p-dsp-firmware.service' ]]"
check "rootfs 构建会建 wants 链接" \
	"grep -q 'op8p-dsp-firmware.service' '${ROOT}/scripts/make-op8p-rootfs.sh'"
check "squash 脚本会进镜像" \
	"grep -q 'squash-qcom-mdt.py' '${ROOT}/scripts/make-op8p-rootfs.sh'"

printf '\n%d 通过, %d 失败\n' "$pass" "$fail"
if [[ -n "$skipped" ]]; then
	printf '产物检查被跳过（%s）—— 源码契约成立，但"编出来的东西对不对"没验\n' "$skipped"
fi
# 到这里为"正常收尾"：下面那个 exit 1 是断言失败的**结果**，不是脚本出错，
# 所以先把 ERR trap 摘掉，否则失败反而会打出一句误导人的"脚本自身异常"。
trap - ERR
[[ "$fail" == 0 ]]
