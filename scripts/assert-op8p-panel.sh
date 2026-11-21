#!/usr/bin/env bash
# Assert the rules the OnePlus 8 Pro display path must never lose.
#
# Same principle as the other assert-* scripts: a rule that lives only in a
# commit message is a rule the next person breaks. Everything here is a
# property that, when it silently changes, still compiles and still boots --
# and produces a black screen with no error anywhere.
#
# Usage: scripts/assert-op8p-panel.sh
#   Exit 0 = every rule holds. Any failure prints the violated rule.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
DRV="${MOD}/drivers/panel-samsung-ams678uw01.c"
BIND="${MOD}/bindings/samsung,ams678uw01.yaml"
PATCH="${MOD}/patches/0029-drm-panel-add-the-samsung-ams678uw01-panel.patch"
DTS="${MOD}/dts/sm8250-oneplus-instantnoodlep.dts"
CONF="${MOD}/steamos.config"
fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

echo "== 驱动源码"
[[ -f "$DRV" ]] && ok "drivers/panel-samsung-ams678uw01.c 存在" \
  || bad "驱动源码不见了"

# The two flags that make this panel work. Command mode was the state in which
# every indicator was green and the screen was black.
grep -q 'MIPI_DSI_MODE_VIDEO_BURST' "$DRV" \
  && ok "mode_flags 里有 VIDEO_BURST" \
  || bad "driver no longer sets VIDEO_BURST"
grep -q 'MIPI_DSI_CLOCK_NON_CONTINUOUS' "$DRV" \
  && ok "mode_flags 里有 CLOCK_NON_CONTINUOUS" \
  || bad "driver no longer sets CLOCK_NON_CONTINUOUS"

# LPM must not be permanent: it is added in on() and cleared in off().
grep -q 'mode_flags |= MIPI_DSI_MODE_LPM' "$DRV" \
  && ok "on() 里临时打开 LPM" \
  || bad "LPM 不再在 on() 里切换"
# LPM must not be permanent: it is added in on() and cleared in off(). A
# permanent LPM together with VIDEO_BURST is the combination that was black
# on hardware.
if awk '/dsi->mode_flags = MIPI_DSI_MODE_VIDEO_BURST/,/;/' "$DRV" | grep -q 'MIPI_DSI_MODE_LPM'; then
  bad "base mode_flags 又带上了常驻 LPM"
else
  ok "base mode_flags 不含常驻 LPM"
fi

# Both DSC packet types: the vendor 0x9e write and the standard PPS packet.
grep -q 'mipi_dsi_picture_parameter_set' "$DRV" \
  && ok "prepare() 发 DTYPE_PPS" \
  || bad "no mipi_dsi_picture_parameter_set"
grep -q '0x9e' "$DRV" \
  && ok "init 序列里仍有厂商 0x9e PPS" \
  || bad "init 序列的 0x9e PPS 不见了"
grep -q 'mipi_dsi_compression_mode' "$DRV" \
  && ok "开压缩模式" \
  || bad "no compression_mode"

# Rails this board references nowhere else: dropping one from this table turns
# the regulator off at late init and the panel loses a supply.
for s in vdd vddio vci px-v18r; do
  grep -q "\"$s\"" "$DRV" \
    && ok "supply $s 在表里" \
    || bad "supply $s 从表里消失了"
done

tail_line="$(tail -n 1 "$DRV" | tr -d '[:space:]')"
[[ "$tail_line" == 'MODULE_LICENSE("GPL");' ]] \
  && ok "驱动以 MODULE_LICENSE 结尾（没被截断）" \
  || bad "驱动结尾是 '$tail_line'，可能被截断"

grep -q 'module_mipi_dsi_driver' "$DRV" \
  && ok "有 module_mipi_dsi_driver（否则 probe 永不发生）" \
  || bad "module_mipi_dsi_driver 不见了"

grep -q $'\r' "$DRV" && bad "驱动里有 CRLF" || ok "驱动无 CRLF"

echo "== 补丁 0029"
[[ -f "$PATCH" ]] && ok "patches/0029 存在" || bad "patches/0029 不见了"
for f in \
  Documentation/devicetree/bindings/display/panel/samsung,ams678uw01.yaml \
  drivers/gpu/drm/panel/Kconfig \
  drivers/gpu/drm/panel/Makefile \
  drivers/gpu/drm/panel/panel-samsung-ams678uw01.c; do
  grep -q "^+++ b/$f\$" "$PATCH" 2>/dev/null \
    && ok "补丁含 $f" \
    || bad "补丁缺 $f 的 hunk"
done

# A driver file without the Makefile hunk compiles into nothing, and the
# panel simply never probes -- indistinguishable from a hardware fault.
grep -q 'CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01' "$PATCH" \
  && grep -q 'panel-samsung-ams678uw01.o' "$PATCH" \
  && ok "Kconfig 与 Makefile 都加了这一项" \
  || bad "补丁没把驱动挂进构建"

# +1,N must equal the number of '+' lines, in both new files.
check_new_file() {
  local rel="$1" dec actual
  read -r dec actual < <(awk -v f="+++ b/$rel" '
    $0 == f { on = 1; next }
    on && /^\+\+\+ / { on = 0 }
    on && match($0, /\+1,[0-9]+/) { dec = substr($0, RSTART + 3, RLENGTH - 3) + 0 }
    on && /^\+/ { c++ }
    END { printf "%d %d\n", dec + 0, c + 0 }' "$PATCH")
  [[ "$dec" -gt 0 && "$dec" == "$actual" ]] \
    && ok "$rel: $dec 行，与 hunk 头一致" \
    || bad "$rel: hunk 头 $dec 行，实际 $actual 行 —— 补丁被截断或手改过"
}
check_new_file drivers/gpu/drm/panel/panel-samsung-ams678uw01.c
check_new_file Documentation/devicetree/bindings/display/panel/samsung,ams678uw01.yaml

# The source of truth is the .c, never the patch.
if [[ $(wc -l <"$DRV") -ne $(awk -v f="+++ b/drivers/gpu/drm/panel/panel-samsung-ams678uw01.c" '
      $0 == f { on = 1; next } on && /^\+\+\+ / { on = 0 } on && /^\+/ { c++ }
      END { print c + 0 }' "$PATCH") ]]; then
  bad "补丁里的驱动与 drivers/ 下的源码不一致 —— 跑 scripts/regen-op8p-panel-patch.sh"
else
  ok "补丁与驱动源码一致"
fi

echo "== 绑定"
[[ -f "$BIND" ]] && ok "binding 存在" || bad "binding 不见了"
grep -q 'const: samsung,ams678uw01' "$BIND" \
  && ok "compatible 是 samsung,ams678uw01" \
  || bad "compatible 变了"
grep -q 'px-v18r-supply' "$BIND" \
  && ok "binding 认识 px-v18r 这一路" \
  || bad "binding 没声明 px-v18r，dtbs_check 会报 unevaluated 属性"

echo "== 设备树"
grep -q 'compatible = "samsung,ams678uw01"' "$DTS" \
  && ok "panel@0 用上游驱动" \
  || bad "panel@0 的 compatible 不是 samsung,ams678uw01"

for s in vdd vddio vci px-v18r; do
  grep -q "$s-supply" "$DTS" \
    && ok "DTS 里有 $s-supply" \
    || bad "DTS 缺 $s-supply"
done

grep -q 'qcom,mdss-dsc-slice-per-pkt' "$DTS" \
  && bad "DTS 还有 qcom,mdss-dsc-slice-per-pkt（0030 已删，这个属性没人读）" \
  || ok "没有 0030 的属性残留"

grep -q 'iris-abyp-ready-gpios' "$DTS" \
  && bad "DTS 还有 iris-abyp-ready-gpios（新驱动不读它）" \
  || ok "没有 iris 残留"

# The framebuffer loses its clocks the moment dispcc probes without these.
awk '/framebuffer@9c000000/,/};/' "$DTS" | grep -q 'clocks = ' \
  && ok "simple-framebuffer 带 clocks" \
  || bad "simple-framebuffer 没有 clocks，dispcc probe 后画面会冻住"
awk '/framebuffer@9c000000/,/};/' "$DTS" | grep -q 'power-domains = <&dispcc MDSS_GDSC>' \
  && ok "simple-framebuffer 带 MDSS_GDSC" \
  || bad "simple-framebuffer 没有 MDSS_GDSC"

grep -q 'reset-gpios = <&tlmm 75 GPIO_ACTIVE_LOW>' "$DTS" \
  && ok "reset 是 gpio75 ACTIVE_LOW" \
  || bad "reset GPIO 或极性被改了"

echo "== 内核配置"
grep -q '^CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01=y' "$CONF" \
  && ok "CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01=y" \
  || bad "内核配置没打开这个驱动"
grep -q 'CONFIG_DRM_PANEL_ONEOPLUS_ANA6706' "$CONF" \
  && bad "配置里还有已删除的 ANA6706 符号（build.sh 会 WARN）" \
  || ok "没有已删除的 ANA6706 符号"

echo
if [[ $fail == 0 ]]; then
  echo "全部通过"
else
  echo "有断言失败 —— 不要刷机"
fi
exit $fail
