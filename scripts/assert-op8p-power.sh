#!/usr/bin/env bash
# Assert the rules the OnePlus 8 Pro power / haptics / flash path must keep.
#
# These three are the ones where "it compiles and boots" says nothing: an
# unequipped node (a compatible no driver matches) and a correctly equipped
# one look identical at boot.  The assertions check the device tree contract
# and say explicitly what is only a contract.
#
# The expectations below are not guesses: each one was settled by a real-boot
# measurement on 2026-11-22, and three of them are the *opposite* of what this
# file said before that date.  Changing one back reproduces a silent failure,
# so the comments say which one:
#
#   1. gauge compatible = ti,bq27411   (was ti,bq27541)  -- README §30.9
#      Seven registers sampled at the same instant against the PMIC fuel
#      gauge as an independent baseline: the bq27411 table hits on every
#      discriminating register, the bq27541 table misses all of them.  With
#      the wrong table the driver reports a plausible, stable, wrong 37 %.
#   2. charger qcom,fuel-gauge = &pm8150b_fg   (was &smart_battery)  -- §30.8
#      The bq27541 table read a current register that never moved off
#      -2142 mA across two boots 10 h apart.  The full-charge decision reads
#      TEMP/VOLTAGE/CURRENT only; all three are live on the PMIC fg.
#   3. haptics reset-gpios = GPIO_ACTIVE_LOW   (was GPIO_ACTIVE_HIGH)  -- §33
#      aw8697_hw_reset() leaves the line at logical 0 (drivers/aw8697.c:569
#      asserts 1, :571 drives 0, then devm_gpiod_get(GPIOD_OUT_HIGH)).  With
#      ACTIVE_HIGH that final 0 is *physically* low = RSTN asserted, so the
#      chip stays held in reset and every i2c11 transfer NACKs.
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

echo "== 电量计（第二意见，主源是 PMIC fg）"
grep -q 'fuel-gauge@55' "$DTS" && ok "i2c16 上有 fuel-gauge@55" || bad "电量计节点没了"
# 2026-11-22 定案：这颗是 bq27411。改回 bq27541 不会报错、不会黑屏，
# 只会让容量/电流变成"自洽的错值"（§30.7 就是这么被误导了一轮）。
grep -q '"ti,bq27411"' "$DTS" && ok "compatible 是 ti,bq27411（不是 bq27541）" \
  || bad "电量计 compatible 变了（改回 bq27541 = 读错寄存器表，读数自洽但全错）"
if grep -q '"ti,bq27541"' "$DTS"; then
  bad "DTS 里还留着 ti,bq27541（同一节点不能有两套寄存器表）"
fi
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

echo "== 充电器（0033 驱动链已在真机注册）"
awk '
  /&pm8150b_charger \{/ { on = 1 }
  on && /status = "okay"/ { okay = 1 }
  on && /monitored-battery = <&battery>/ { bat = 1 }
  on && /power-supplies = <&pm8150b_typec>/ { ps = 1 }
  on && /qcom,fuel-gauge = <&pm8150b_fg>/ { fg = 1 }
  on && /^};/ { on = 0 }
  END { exit(okay && bat && ps && fg ? 0 : 1) }' "$DTS" \
  && ok "charger: okay + 电池 + typec + 满充判定用 PMIC fg" \
  || bad "charger 节点缺项（status/电池/typec/fuel-gauge=<&pm8150b_fg> 之一）"
# 指向电量计芯片是 §30.8 之前的写法：那颗芯片的电流寄存器读不出活值，
# 满充检测会一直认为"还没满"。
awk '
  /&pm8150b_charger \{/ { on = 1 }
  on && /qcom,fuel-gauge = <&smart_battery>/ { bad_fg = 1 }
  on && /^};/ { on = 0 }
  END { exit(bad_fg ? 1 : 0) }' "$DTS" \
  && ok "满充判定没有退回 &smart_battery" \
  || bad "qcom,fuel-gauge 指回了 &smart_battery（电流无活值，满充永远不会成立）"
grep -q 'constant-charge-current-max-microamp = <2000000>' "$DTS" \
  && ok "电池限流 2000 mA 写上了" || bad "电池没有 constant-charge-current（会用默认值）"
# 充电器能注册的前提：typec 的 power_supply 必须先存在，否则
# devm_power_supply_register 拿着这个 fwnode 永远 defer（§30.1，误判三次）。
awk '
  /&pm8150b_typec \{/ { on = 1 }
  on && /status = "okay"/ { okay = 1 }
  on && /^};/ { on = 0 }
  END { exit(okay ? 0 : 1) }' "$DTS" \
  && ok "pm8150b_typec 是 okay（charger 的 power-supplies 依赖它）" \
  || bad "pm8150b_typec 没启用 → charger 注册永远 deferring"

echo "== 振动（0031 驱动已在真机 probe）"
grep -q 'haptics@5a' "$DTS" && ok "i2c11 上有 haptics@5a" || bad "振动节点没了"
grep -q '"awinic,aw8697"' "$DTS" && ok "compatible 是 awinic,aw8697" || bad "振动 compatible 变了"
# GPIO_ACTIVE_LOW 是实测结论，不是偏好：驱动在 hw_reset 末尾把逻辑值写成 0
# （aw8697.c:569 =1 拉复位，:571 =0 释放，devm_gpiod_get 的初值是 HIGH）。
# ACTIVE_HIGH 时那个 0 是物理低 = RSTN 有效，芯片被一直摁在复位里，
# i2c11 整条总线 NACK、节点不 probe（2026-11-22 就是这么查了半宿）。
grep -q 'reset-gpios = <&tlmm 72 GPIO_ACTIVE_LOW>' "$DTS" \
  && ok "reset 是 gpio72 低有效（物理低=RSTN 有效）" \
  || bad "振动 reset 极性变了（改回 ACTIVE_HIGH = 芯片留在复位里，i2c11 全 NACK）"
grep -q 'interrupts-extended = <&tlmm 118 IRQ_TYPE_EDGE_FALLING>' "$DTS" \
  && ok "IRQ 是 gpio118 下降沿" || bad "振动 IRQ 引脚/触发方式变了"
grep -q 'haptics_irq_default:' "$DTS" && ok "有 gpio118 的 pinctrl" || bad "缺振动 IRQ pinctrl"
# 下面这几个 awinic,* 参数当前的 0031 驱动**一个都不解析**（只读
# compatible + reset + irq，见 aw8697.c 的 of_* 调用）。它们留着是硬件档案：
# 换用会解析它们的驱动（Nura 0074 那类）时，这些值就是契约。
# 所以这里的失败含义是"档案被改了"，不是"手感会变"。
for kv in 'awinic,drive-level = <54>' 'awinic,f0-preset = <1700>'; do
  grep -q "$kv" "$DTS" && ok "厂商参数留档：$kv" \
    || bad "厂商参数留档被改：$kv（当前驱动不解析，但换驱动后就是契约）"
done

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

echo "== 驱动来源的记录"
# 这两段注释是后来人唯一能查到的"驱动从哪来"，比 CONFIG 符号更重要：
# 充电器驱动来自 ROCKNIX 补丁而不是 mainline，qcom_fg 也不在这里写符号。
grep -q '充电器驱动不在 mainline 7.2.8' "$CONF" \
  && ok "config 里写明充电器驱动的来源（ROCKNIX 0011 + 我们的 0033）" \
  || bad "缺少充电器驱动来源的说明（会有人以为 mainline 里有）"
grep -q 'CONFIG_CHARGER_QCOM_SMB5' "$CONF" \
  && ok "config 里点明了它为什么没有独立符号" \
  || bad "没写 CONFIG_CHARGER_QCOM_SMB5 的处置（后人会以为漏开）"
grep -q 'aw8697 series\|patches/0031' "$CONF" \
  && ok "config 里记录了振动驱动的来源" || bad "没写振动驱动来自哪"
grep -q 'GPIO_ACTIVE_LOW' "$CONF" \
  && ok "config 里记下了 reset 极性的实测结论" \
  || bad "没记 reset 极性为什么必须 ACTIVE_LOW（会被'好心'改回去）"

[[ $fail == 0 ]] && echo && echo "全部通过" || { echo; echo "有规则被破坏"; exit 1; }
