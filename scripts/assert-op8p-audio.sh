#!/usr/bin/env bash
# Assert the rules the OnePlus 8 Pro audio path must never lose.
#
# Same principle as assert-op8p-panel.sh: these are properties that, when
# they silently change, still compile, still boot, and produce a phone with
# no sound card and no error message. The whole path is a chain -- LPASS
# macros -> SoundWire -> wcd938x -> tertiary MI2S -> tfa9874 -- and every
# link fails quietly.
#
# Usage: scripts/assert-op8p-audio.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
DRV="${MOD}/drivers/tfa987x.c"
PATCH="${MOD}/patches/0030-ASoC-codecs-add-the-NXP-TFA9872-TFA9874-driver.patch"
DTS="${MOD}/dts/sm8250-oneplus-instantnoodlep.dts"
CONF="${MOD}/steamos.config"
fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

echo "== 驱动源码"
[[ -f "$DRV" ]] && ok "drivers/tfa987x.c 存在" || bad "驱动源码不见了"
grep -q '"nxp,tfa9874"' "$DRV" && ok "compatible 有 nxp,tfa9874" \
  || bad "驱动不再认 tfa9874"
grep -q 'TFA987X_REV' "$DRV" && ok "读 revision 寄存器" \
  || bad "驱动不再校验 revision"
grep -q 'regmap_update_bits' "$DRV" && ok "有寄存器初始化写入" \
  || bad "驱动没有寄存器初始化"
grep -q 'devm_snd_soc_register_component' "$DRV" && ok "注册 ASoC component" \
  || bad "没有注册 component（等于没有声音）"
grep -q 'MODULE_LICENSE' "$DRV" && ok "有 MODULE_LICENSE" || bad "缺 license"

echo "== 补丁"
for f in Kconfig Makefile tfa987x.c; do
  grep -q "^+++ b/sound/soc/codecs/$f\$" "$PATCH" \
    && ok "0030 里有 $f 的 hunk" || bad "0030 缺 $f（编译进去也是空壳）"
done
[[ "$(grep -c '^+++ b/' "$PATCH")" == 3 ]] \
  && ok "0030 只有三个文件头" || bad "0030 被拼接了两份 diff"

echo "== 设备树：codec"
grep -q 'wcd938x: audio-codec' "$DTS" && ok "有 wcd938x 节点" || bad "wcd938x 节点没了"
grep -q '"qcom,wcd9385-codec"' "$DTS" && ok "compatible 是 wcd9385" \
  || bad "codec compatible 不对"
for p in vdd-buck-supply vdd-rxtx-supply vdd-io-supply vdd-mic-bias-supply; do
  grep -q "$p" "$DTS" && ok "codec 有 $p" || bad "codec 缺 $p"
done
grep -q 'reset-gpios = <&tlmm 32 GPIO_ACTIVE_LOW>' "$DTS" \
  && ok "codec reset 是 gpio32 ACTIVE_LOW" || bad "codec reset 引脚变了"
grep -q 'qcom,rx-device = <&wcd_rx>' "$DTS" && grep -q 'qcom,tx-device = <&wcd_tx>' "$DTS" \
  && ok "codec 挂在 swr 的 rx/tx 端口上" || bad "codec 的 rx/tx 端口丢了"

echo "== 设备树：功放"
grep -q 'top_spkr: tfa9874@34' "$DTS" && ok "top_spkr@34" || bad "缺 top_spkr"
grep -q 'bottom_spkr: tfa9874@35' "$DTS" && ok "bottom_spkr@35" || bad "缺 bottom_spkr"
grep -q 'reset-gpios = <&tlmm 91 GPIO_ACTIVE_HIGH>' "$DTS" \
  && ok "top 的 reset 是 gpio91 高有效" || bad "top reset 引脚变了"
grep -q 'reset-gpios = <&tlmm 99 GPIO_ACTIVE_HIGH>' "$DTS" \
  && ok "bottom 的 reset 是 gpio99 高有效" || bad "bottom reset 引脚变了"
grep -q 'sound-channel = <0>' "$DTS" && grep -q 'sound-channel = <1>' "$DTS" \
  && ok "两颗功放的声道是 0/1" || bad "sound-channel 丢了（两只会放同一个声道）"
grep -q '&i2c15' "$DTS" && ok "功放挂在 i2c15" || bad "i2c15 节点没了"

echo "== 设备树：MI2S 与声卡"
for p in mi2s2_sck mi2s2_data0 mi2s2_data1 mi2s2_ws; do
  grep -q "\"$p\"" "$DTS" && ok "pinctrl 有 $p" || bad "pinctrl 缺 $p"
done
grep -q 'TERTIARY_MI2S_RX' "$DTS" && grep -q 'TERTIARY_MI2S_TX' "$DTS" \
  && ok "q6afedai 有 tertiary MI2S 两端" || bad "tertiary MI2S 的 dai 丢了"
for dai in 'MSM_FRONTEND_DAI_MULTIMEDIA1' 'MSM_FRONTEND_DAI_MULTIMEDIA5'; do
  grep -q "$dai" "$DTS" && ok "q6asmdai 有 $dai" || bad "缺 $dai"
done
for link in mm1-dai-link mm2-dai-link mm3-dai-link mm4-dai-link mm5-dai-link; do
  grep -q "$link" "$DTS" && ok "sound 有 $link" || bad "缺 $link"
done
grep -q '"qcom,sm8250-sndcard"' "$DTS" && ok "compatible 是 sm8250-sndcard" \
  || bad "machine driver compatible 不对"
grep -q 'pinctrl-0 = <&tert_mi2s_active>' "$DTS" && ok "声卡绑了 mi2s active" \
  || bad "声卡没绑 mi2s pinctrl"
for st in '&rxmacro' '&txmacro' '&swr1' '&swr2'; do
  awk -v lbl="$st {" '
    index($0, lbl) { on = 1 }
    on && /status = "okay"/ { found = 1 }
    on && /^};/ { on = 0 }
    END { exit(found ? 0 : 1) }' "$DTS" \
    && ok "$st 是 okay" || bad "$st 不是 okay（codec 挂不上）"
done
# vamacro 在 sm8250.dtsi 里**没有** status 属性（默认可用），rxmacro 才是
# 显式 disabled 的那个。所以这里只要求它没被关掉，不要求写 okay。
awk '
  /^&vamacro \{/ { on = 1 }
  on && /status = "disabled"/ { bad = 1 }
  on && /^};/ { on = 0 }
  END { exit(bad ? 1 : 0) }' "$DTS" \
  && ok "&vamacro 没被关掉（dtsi 默认可用了，不写 status）" \
  || bad "&vamacro 被 disabled 了"

echo "== 设备树：不能有的东西"
# mainline 7.2.8 的 sm8250.dtsi 没有 q6usbdai；参考 DTS 的 usb-dai-link
# 引用了它，dtc 会直接 abort。USB-C 音频与 DP 一起做时再加。
# 只在节点定义上匹配 —— 注释里提到这个名字不算。
grep -qE '^[[:space:]]*usb-dai-link \{' "$DTS" \
  && bad "usb-dai-link 回来了（q6usbdai 不存在，dtc 会 abort）" \
  || ok "没有引用不存在的 q6usbdai"

echo "== 内核配置"
grep -qx 'CONFIG_SND_SOC_TFA987X=y' "$CONF" && ok "TFA987X 是 =y" \
  || bad "TFA987X 不是 =y（阶段 1 没有 modprobe）"
for m in RX TX VA; do
  grep -qx "CONFIG_SND_SOC_LPASS_${m}_MACRO=m" "$CONF" \
    && ok "LPASS ${m} macro 是 =m" || bad "LPASS ${m} macro 没开"
done
grep -q 'CONFIG_SND_SOC_TFA98XX' "$CONF" \
  && bad "又出现了不存在的 SND_SOC_TFA98XX 符号" || ok "没有凭空写 TFA98XX 符号"

[[ $fail == 0 ]] && echo && echo "全部通过" || { echo; echo "有规则被破坏"; exit 1; }
