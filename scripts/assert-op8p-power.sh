#!/usr/bin/env bash
# Assert the rules the OnePlus 8 Pro power / haptics / flash path must keep.
#
# These three are the ones where "it compiles and boots" says nothing: an
# unequipped node (a compatible no driver matches) and a correctly equipped
# one look identical at boot. Two of the three currently have no driver in
# this kernel tree, so the assertions check the device tree contract and say
# so explicitly rather than pretending the hardware works.
#
# Usage: scripts/assert-op8p-power.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
DTS="${MOD}/dts/sm8250-oneplus-instantnoodlep.dts"
CONF="${MOD}/steamos.config"
fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

echo "== 电量计（这条链里现在唯一有驱动的部分）"
grep -q 'fuel-gauge@55' "$DTS" && ok "i2c16 上有 fuel-gauge@55" || bad "电量计节点没了"
grep -q '"ti,bq27541"' "$DTS" && ok "compatible 是 ti,bq27541" || bad "电量计 compatible 变了"
awk '
  /fuel-gauge@55 \{/ { on = 1 }
  on && /monitored-battery = <&battery>/ { found = 1 }
  on && /^\t};/ { on = 0 }
  END { exit(found ? 0 : 1) }' "$DTS" \
  && ok "电量计绑了 monitored-battery" || bad "电量计没绑电池（容量会算错）"
grep -qx 'CONFIG_BATTERY_BQ27XXX=y' "$CONF" && ok "BQ27XXX 是 =y" \
  || bad "BQ27XXX 没开（power_supply 不会出现）"
grep -qx 'CONFIG_BATTERY_BQ27XXX_I2C=y' "$CONF" && ok "BQ27XXX_I2C 是 =y" \
  || bad "BQ27XXX_I2C 没开"

echo "== 充电器（节点就绪，驱动待补）"
awk '
  /&pm8150b_charger \{/ { on = 1 }
  on && /status = "okay"/ { okay = 1 }
  on && /monitored-battery = <&battery>/ { bat = 1 }
  on && /power-supplies = <&pm8150b_typec>/ { ps = 1 }
  on && /qcom,fuel-gauge = <&smart_battery>/ { fg = 1 }
  on && /^};/ { on = 0 }
  END { exit(okay && bat && ps && fg ? 0 : 1) }' "$DTS" \
  && ok "charger: okay + 电池 + typec + 由电量计决定满充" \
  || bad "charger 节点缺项（status/电池/typec/fuel-gauge 之一）"
grep -q 'constant-charge-current-max-microamp = <2000000>' "$DTS" \
  && ok "电池限流 2000 mA 写上了" || bad "电池没有 constant-charge-current（会用默认值）"

echo "== 振动（节点就绪，驱动待补）"
grep -q 'haptics@5a' "$DTS" && ok "i2c11 上有 haptics@5a" || bad "振动节点没了"
grep -q '"awinic,aw8697"' "$DTS" && ok "compatible 是 awinic,aw8697" || bad "振动 compatible 变了"
grep -q 'reset-gpios = <&tlmm 72 GPIO_ACTIVE_HIGH>' "$DTS" \
  && ok "reset 是 gpio72 高有效" || bad "振动 reset 引脚变了"
grep -q 'interrupts-extended = <&tlmm 118 IRQ_TYPE_EDGE_FALLING>' "$DTS" \
  && ok "IRQ 是 gpio118 下降沿" || bad "振动 IRQ 引脚/触发方式变了"
grep -q 'haptics_irq_default:' "$DTS" && ok "有 gpio118 的 pinctrl" || bad "缺振动 IRQ pinctrl"
grep -q 'awinic,drive-level = <54>' "$DTS" && ok "drive level 54（LRA0619）" \
  || bad "drive level 变了（会过热或感觉不到）"
grep -q 'awinic,f0-preset = <1700>' "$DTS" && ok "f0 170 Hz" || bad "f0 预设变了"

echo "== 闪光灯（驱动在树里）"
awk '
  /&pm8150l_flash \{/ { on = 1 }
  on && /status = "okay"/ { okay = 1 }
  on && /led-0 \{/ { l0 = 1 }
  on && /led-1 \{/ { l1 = 1 }
  on && /^};/ { on = 0 }
  END { exit(okay && l0 && l1 ? 0 : 1) }' "$DTS" \
  && ok "pm8150l_flash: okay + 两个通道" || bad "闪光灯节点缺项"
[[ "$(grep -c 'led-sources = <1>\|led-sources = <2>' "$DTS")" == 2 ]] \
  && ok "两个通道各占一个 source" || bad "led-sources 不对（会两路同时亮）"
[[ "$(grep -c 'flash-max-microamp = <1500000>' "$DTS")" == 2 ]] \
  && ok "闪光上限 1500 mA（厂商值）" || bad "闪光电流不是厂商值"
[[ "$(grep -c 'flash-max-timeout-us = <1280000>' "$DTS")" == 2 ]] \
  && ok "闪光超时 1280 ms" || bad "闪光超时不对"
grep -qx 'CONFIG_LEDS_QCOM_FLASH=y' "$CONF" && ok "LEDS_QCOM_FLASH 是 =y" \
  || bad "LEDS_QCOM_FLASH 没开（节点不会 probe）"

echo "== 振动驱动（patches/0031）"
# 驱动本身。上游有 aw86927（另一代、寄存器不同），没有 aw8697；这份是
# 2026-09 还没合入的 series，所以在 patches/ 里。
AH="$MOD/drivers/aw8697.c"
AHP="$MOD/patches/0031-Input-aw8697-add-the-Awinic-AW8697-haptics-driver.patch"
[[ -f "$AH" ]] && ok "drivers/aw8697.c 存在" || bad "振动驱动源码不见了"
grep -q '"awinic,aw8697"' "$AH" && ok "compatible 是 awinic,aw8697（与 DTS 一致）" \
  || bad "驱动 compatible 变了（节点不会再 probe）"
grep -q 'input_ff_create_memless' "$AH" && ok "注册 force feedback" \
  || bad "没注册 ff-memless（不会震）"
for f in Kconfig Makefile aw8697.c; do
  grep -q "^+++ b/drivers/input/misc/$f\$" "$AHP" \
    && ok "0031 里有 $f" || bad "0031 缺 $f"
done
grep -qx 'CONFIG_INPUT_AW8697=y' "$CONF" && ok "INPUT_AW8697 是 =y" \
  || bad "INPUT_AW8697 没开（节点不会 probe）"

echo "== 驱动缺口的记录"
# 充电器仍然是缺口，这条提醒必须留着；振动已经不是了。
grep -q '充电器的驱动不在 mainline 7.2.8' "$CONF" \
  && ok "config 里写明了充电器的驱动缺口" || bad "缺少充电器缺口的说明"
grep -q 'aw8697 series\|patches/0031' "$CONF" \
  && ok "config 里记录了振动驱动的来源" || bad "没写振动驱动来自哪"

[[ $fail == 0 ]] && echo && echo "全部通过" || { echo; echo "有规则被破坏"; exit 1; }
