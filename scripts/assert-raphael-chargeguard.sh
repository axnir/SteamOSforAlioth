#!/usr/bin/env bash
# raphael-charge-guard 的断言。全部指到一棵假的 power_supply 树上跑 ——
# 不在真机上真的去压充电电流（那要插着充电器等温度）。
#
# 每条断言对应一个会真的出事的情况：
#   - 该降档却不降   -> 边充边玩电池过热，而驱动不实现 JEITA（没有硬件兜底）
#   - 该恢复却不恢复 -> 充电永远慢，而且没有任何界面提示是这个服务留下的
#   - 读不到温度当"不热" -> 最坏的情况被当成最好的情况
#   - 满档写死       -> 换一块板子/换一版 DTS 就写成驱动不接受的值
set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${RAPHAEL_GUARD_BIN:-$SP/../scripts/raphael-overlay/usr/lib/steamos-arm/raphael-charge-guard}"
UNIT="$SP/../scripts/raphael-overlay/usr/lib/systemd/system/raphael-charge-guard.service"
BUILD="$SP/../scripts/build-raphael-reference.sh"

fails=0
check() { # check <名字> <条件结果> <证据>
  if [[ "$2" == ok ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n      %s\n' "$1" "$3"
    fails=$((fails + 1))
  fi
}

[[ -x "$GUARD" ]] || { echo "找不到可执行的 $GUARD（chmod 755？）"; exit 2; }

T="$(mktemp -d)"
# 理由同 assert-raphael-gametune.sh：Git Bash 的 $TMPDIR 是 Windows 形式，
# 带盘符的路径会被 rm 包装器拒绝，假 sysfs 就会在用例之间残留。
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

FULL=3300000

mkfake() { # 干净的一棵树：charger 满档 + 电池 25.0 °C
  rm -rf "$T/ps" "$T/run"
  mkdir -p "$T/ps/battery" "$T/ps/pm8150b-charger" "$T/run"
  echo "$FULL" >"$T/ps/pm8150b-charger/current_max"
  echo 250 >"$T/ps/battery/temp"
}

icl() { cat "$T/ps/pm8150b-charger/current_max"; }
set_temp() { echo "$1" >"$T/ps/battery/temp"; }

run_once() {
  RAPHAEL_GUARD_PS_ROOT="$T/ps" \
  RAPHAEL_GUARD_BATT="$T/ps/battery" \
  RAPHAEL_GUARD_SNAP="$T/run/snap" \
    "$GUARD" --once >/dev/null 2>&1
}

# 1. 凉 -> 不动（满档）
mkfake
run_once
check "25.0 °C 保持满档 $FULL" \
  "$([[ "$(icl)" == "$FULL" ]] && echo ok)" "current_max=$(icl)"

# 2. 三档依次收紧。40/43/45 °C 是 alioth 实测过的分界，抄的是结论不是拍脑袋。
mkfake
set_temp 405; run_once
check "40.5 °C -> 1.5 A" "$([[ "$(icl)" == 1500000 ]] && echo ok)" "current_max=$(icl)"
set_temp 435; run_once
check "43.5 °C -> 1.0 A" "$([[ "$(icl)" == 1000000 ]] && echo ok)" "current_max=$(icl)"
set_temp 460; run_once
check "46.0 °C -> 0.5 A" "$([[ "$(icl)" == 500000 ]] && echo ok)" "current_max=$(icl)"

# 3. 迟滞：39.0 °C 落在 40 °C 与 38 °C 之间，必须保持现状，不能来回抖。
run_once
check "39.0 °C 在迟滞区，保持 0.5 A" \
  "$([[ "$(icl)" == 500000 ]] && echo ok)" "current_max=$(icl)"

# 4. 凉下来 -> 恢复满档
set_temp 370; run_once
check "37.0 °C 恢复到满档 $FULL" \
  "$([[ "$(icl)" == "$FULL" ]] && echo ok)" "current_max=$(icl)"

# 5. 读不到温度 = 最热档，不是"不热"
mkfake
rm -f "$T/ps/battery/temp"
run_once
check "读不到电池温度时压到 0.5 A" \
  "$([[ "$(icl)" == 500000 ]] && echo ok)" "current_max=$(icl)"

# 6. 服务重启（Restart=always 的真实场景）：current_max 停在降档值，而 /run
#    里的「进入限流时记住的值」还在。重新启动必须按它恢复 —— 否则充电从此
#    永远慢，且没有任何症状。
mkfake
set_temp 460; run_once          # 进入限流，记住 3300000
printf '500000\n' >"$T/ps/pm8150b-charger/current_max"
set_temp 370; run_once
check "服务重启后恢复到 $FULL（不把降档值当满档）" \
  "$([[ "$(icl)" == "$FULL" ]] && echo ok)" \
  "current_max=$(icl) 状态=$(cat "$T/run/snap" 2>/dev/null | tr '\n' '/')"

# 6b. SDP → DCP。插在电脑上时 ICL 只有 500 mA；换了 33 W 头，驱动会重新协商成
#     3 A。脚本在限流中必须把「记住的值」跟着更新，否则降温恢复会把大电源又
#     压回 500 mA —— 用户看到的是「充电莫名其妙变慢」。
mkfake
printf '500000\n' >"$T/ps/pm8150b-charger/current_max"
set_temp 460; run_once                        # SDP 下进入限流，记住 500000
printf '3000000\n' >"$T/ps/pm8150b-charger/current_max"   # 换成 DCP，驱动调高
run_once                                       # 应该把记住的值更新成 3000000，再压回 0.5 A
check "换大电源时先更新记住的值再压回去" \
  "$([[ "$(icl)" == 500000 && "$(sed -n 1p "$T/run/snap")" == 3000000 ]] && echo ok)" \
  "current_max=$(icl) 状态=$(tr '\n' '/' < "$T/run/snap")"
set_temp 370; run_once
check "降温后恢复的是 DCP 的 3 A（不是 SDP 的 500 mA）" \
  "$([[ "$(icl)" == 3000000 ]] && echo ok)" "current_max=$(icl)"

# 7. 没有 charger 节点时什么都不做，而且退出码是 0 —— 这不该让 unit 进
#    failed 状态刷日志（真机上换了内核就可能是这样）。
rm -rf "$T/ps"
mkdir -p "$T/ps"
RAPHAEL_GUARD_PS_ROOT="$T/ps" RAPHAEL_GUARD_BATT="$T/ps/battery" \
RAPHAEL_GUARD_SNAP="$T/run/snap2" "$GUARD" --once >/dev/null 2>&1
rc=$?
check "找不到 charger 时退出 0 且什么都不写" \
  "$([[ $rc -eq 0 ]] && echo ok)" "rc=$rc"

# 7b. 真机形态：power_supply 下只有 battery 和 usb，输入侧属性在 usb 上
#     （2026-11-08 21:10 实测）。必须能选中 usb 并写它的 current_max。
rm -rf "$T/ps" "$T/run"
mkdir -p "$T/ps/battery" "$T/ps/usb" "$T/run"
echo "$FULL" >"$T/ps/usb/current_max"
echo 460 >"$T/ps/battery/temp"
RAPHAEL_GUARD_PS_ROOT="$T/ps" RAPHAEL_GUARD_BATT="$T/ps/battery" \
RAPHAEL_GUARD_SNAP="$T/run/snap3" "$GUARD" --once >/dev/null 2>&1
check "真机形态：选中 usb 节点并降到 0.5 A" \
  "$([[ "$(cat "$T/ps/usb/current_max")" == 500000 ]] && echo ok)" \
  "usb/current_max=$(cat "$T/ps/usb/current_max" 2>/dev/null)"

# 7c. 闸门的选择规则（静态断言）。真机上 current_max 是 0444、input_current_limit
#     是 0644，而 **root 下 `[ -w ]` 对 0444 也返回真** —— 2026-11-08 21:15 就是
#     这么让服务写了半个小时的 Permission denied。Windows 上 chmod 不起作用，
#     所以这条只能查代码，不能靠假 sysfs 演。
check "闸门候选里 input_current_limit 在前、current_max 兜底" \
  "$(grep -q 'for f in "$CHG/input_current_limit" "$CHG/current_max"' "$GUARD" && echo ok)" \
  "$(grep -n 'for f in' "$GUARD" | head -2)"
check "用权限位判可写，不用 [ -w（root 下会误报）" \
  "$(grep -v '^[[:space:]]*#' "$GUARD" | grep -qE '\[[[:space:]]+-w[[:space:]]' && echo no || echo ok)" \
  "$(grep -vn '^[[:space:]]*#' "$GUARD" | grep -E '\[[[:space:]]+-w[[:space:]]' | head -2)"

# 8. 满档不许写死：**代码行**里不能出现 3300000 这个字面量（那是 alioth 的
#    DCP 值）。注释里提到它是解释「为什么不写死」，不算。
check "代码里没有写死 3300000" \
  "$(grep -v '^[[:space:]]*#' "$GUARD" | grep -q 3300000 && echo no || echo ok)" \
  "$(grep -vn '^[[:space:]]*#' "$GUARD" | grep 3300000 | head -3)"

# 9. unit 必须走 SIGTERM 恢复，否则停了服务之后输入上限一直停在降档值上。
check "unit 用 SIGTERM 停止并留了停止超时" \
  "$(grep -q '^KillSignal=SIGTERM' "$UNIT" && grep -q '^TimeoutStopSec=' "$UNIT" \
     && echo ok)" \
  "$(grep -E 'KillSignal|TimeoutStopSec' "$UNIT" | tr '\n' ' ')"

# 10. 构建脚本要 enable 它。
check "build 脚本里有 enable 链接" \
  "$(grep -qE '^ *for u in .*raphael-charge-guard' "$BUILD" && echo ok)" \
  "$BUILD 里没有那段 for 循环"

echo
if [[ $fails -eq 0 ]]; then echo "全部通过"; else echo "$fails 条失败"; fi
exit $(( fails > 0 ? 1 : 0 ))
