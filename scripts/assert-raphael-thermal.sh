#!/usr/bin/env bash
# raphael-thermal 的断言。整套逻辑指到一棵假的 sysfs 上跑 —— 不在真机上把
# CPU 压到 1.1 GHz 来验证。
#
# 每条断言都对应一个会真的出事的情况：
#   - 温度正常却降频      -> 白白掉性能，而且是常开的
#   - 高温不降频          -> 就是它存在的全部理由（内核在 90 °C 前不降频）
#   - 贴着门槛抖动        -> sysfs 每 5 秒被重写一次，每次都是一轮调频决策
#   - 恢复时写死最高频    -> 原值比顶档低的时候（有人在别处限过频）会被悄悄抬高
#   - 服务重启把降档值当原值 -> 从此再也回不到真正的原值，且没有症状
#   - 退出不恢复          -> 停服务之后 CPU 一直停在低档
#   - 改 governor         -> 会和 game-tune 抢同一个属性
set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THERMAL="${RAPHAEL_THERMAL_BIN:-$SP/raphael-overlay/usr/lib/steamos-arm/raphael-thermal}"
UNIT="$SP/raphael-overlay/usr/lib/systemd/system/raphael-thermal.service"
BUILD="$SP/build-raphael-reference.sh"

fails=0
check() { # check <名字> <条件结果> <证据>
  if [[ "$2" == ok ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n      %s\n' "$1" "$3"
    fails=$((fails + 1))
  fi
}

[[ -x "$THERMAL" ]] || { echo "找不到可执行的 $THERMAL（chmod 755？）"; exit 2; }

T="$(mktemp -d)"
# mktemp 在 Git Bash 下返回 `C:\Users\...\Temp/tmp.xxx`，带盘符前缀的路径会被
# 沙盒的 rm 包装器拒绝，于是 mkfake 静默失败、上一轮的状态留着，断言给出假
# 失败。cd 之后取 pwd 得到 /tmp/tmp.xxx 这种 POSIX 形式。（同 gametune 的坑）
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

SNAP="$T/run/thermal.orig"
CPU="$T/sys/cpufreq"
ZONEROOT="$T/therm"

# 真机的频率表（2026-11-08 /sys/devices/system/cpu/cpufreq/policy*/）。档位里
# 的 cap 必须真的落在这张表上，否则「取 ≤ cap 的最高一档」这条逻辑就测不到。
F0='300000 403200 499200 576000 672000 768000 844800 940800 1036800 1113600 1209600 1305600 1382400 1478400 1555200 1632000 1708800 1785600'
F4='710400 825600 940800 1056000 1171200 1286400 1401600 1497600 1612800 1708800 1804800 1920000 2016000 2131200 2227200 2323200 2419200'
F7='825600 940800 1056000 1171200 1286400 1401600 1497600 1612800 1708800 1804800 1920000 2016000 2131200 2227200 2323200 2419200 2534400 2649600 2745600 2841600'

# 原值故意**不取顶档**（1632000 / 2323200 / 2745600）：只有这样才能区分
# 「恢复原值」和「恢复成写死的最高频」。三个值都高于各个降档 cap，所以不会
# 被「不往上抬」那条规则挡住。
mkfake() {
  rm -rf "$T/sys" "$T/therm" "$T/battery" "$T/run"
  mkdir -p "$CPU/policy0" "$CPU/policy4" "$CPU/policy7" "$T/run" "$T/battery"
  echo "$F0" >"$CPU/policy0/scaling_available_frequencies"
  echo "$F4" >"$CPU/policy4/scaling_available_frequencies"
  echo "$F7" >"$CPU/policy7/scaling_available_frequencies"
  echo 1632000 >"$CPU/policy0/scaling_max_freq"
  echo 2323200 >"$CPU/policy4/scaling_max_freq"
  echo 2745600 >"$CPU/policy7/scaling_max_freq"
  echo schedutil >"$CPU/policy0/scaling_governor"
  echo schedutil >"$CPU/policy4/scaling_governor"
  echo schedutil >"$CPU/policy7/scaling_governor"
  # 传感器名用真机上的 type。脚本只认 *-bottom-thermal 和 cluster0-thermal。
  mkdir -p "$ZONEROOT/thermal_zone5" "$ZONEROOT/thermal_zone12" "$ZONEROOT/thermal_zone15"
  echo cluster0-thermal >"$ZONEROOT/thermal_zone5/type"
  echo cpu5-bottom-thermal >"$ZONEROOT/thermal_zone12/type"
  echo gpu-top-thermal >"$ZONEROOT/thermal_zone15/type"
  echo 60000 >"$ZONEROOT/thermal_zone5/temp"
  echo 60000 >"$ZONEROOT/thermal_zone12/temp"
  echo 99000 >"$ZONEROOT/thermal_zone15/temp"   # top 那侧不参与判断
  echo Discharging >"$T/battery/status"
}

maxes() { cat "$CPU"/policy*/scaling_max_freq | tr '\n' ' '; }

# 等三个 policy 都到期望值。Git Bash 起一个 bash 进程要一两秒（fork 代价），
# 固定 sleep 会得到「还没开始动」的假失败。
wait_maxes() { # <期望> [超时秒]
  local want="$1" deadline=$((SECONDS + ${2:-10}))
  while (( SECONDS < deadline )); do
    [[ "$(maxes)" == "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}

run_once() { # [temp_mC]
  RAPHAEL_THERMAL_CPUFREQ="$CPU" \
  RAPHAEL_THERMAL_ROOT="$ZONEROOT" \
  RAPHAEL_THERMAL_BATTERY="$T/battery" \
  RAPHAEL_THERMAL_SNAP="$SNAP" \
  RAPHAEL_THERMAL_TEMP="${1:-}" \
    "$THERMAL" --once >/dev/null 2>&1
}

# 1. 温度正常 -> 一个数都不写。原值本来就不是顶档，所以「没动」和「写成顶档」
#    在这里是可区分的。
mkfake
run_once 70000
check "70 °C 时不动任何 policy" \
  "$([[ "$(maxes)" == "1632000 2323200 2745600 " ]] && echo ok)" "max=$(maxes)"

# 2. warm 档（≥78）：按 cap 取表里 ≤cap 的最高一档。
mkfake
run_once 79000
check "79 °C 落到 warm 档（1555200/1920000/2131200）" \
  "$([[ "$(maxes)" == "1555200 1920000 2131200 " ]] && echo ok)" "max=$(maxes)"

# 3. hot 档（≥84）
mkfake
run_once 85000
check "85 °C 落到 hot 档（1305600/1612800/1804800）" \
  "$([[ "$(maxes)" == "1305600 1612800 1804800 " ]] && echo ok)" "max=$(maxes)"

# 4. critical 档（≥88）
mkfake
run_once 90000
check "90 °C 落到 critical 档（1113600/1401600/1497600）" \
  "$([[ "$(maxes)" == "1113600 1401600 1497600 " ]] && echo ok)" "max=$(maxes)"

# 5. 迟滞只能走**常驻**那条路：--once 是无状态的，每次都从 0 档重新评估，
#    根本测不到迟滞。所以这里用真实的 zone 文件当输入，跑起来之后改温度。
mkfake
echo 79000 >"$ZONEROOT/thermal_zone12/temp"
RAPHAEL_THERMAL_CPUFREQ="$CPU" \
RAPHAEL_THERMAL_ROOT="$ZONEROOT" \
RAPHAEL_THERMAL_BATTERY="$T/battery" \
RAPHAEL_THERMAL_SNAP="$SNAP" \
RAPHAEL_THERMAL_INTERVAL=1 \
  "$THERMAL" >"$T/hyst.log" 2>&1 &
hyst=$!
wait_maxes "1555200 1920000 2131200 " 10
w1="$(maxes)"
echo 76000 >"$ZONEROOT/thermal_zone12/temp"   # 低于 enter(78)，高于 exit(72)
sleep 2
w2="$(maxes)"
echo 71000 >"$ZONEROOT/thermal_zone12/temp"   # 低于 exit(72)
wait_maxes "1632000 2323200 2745600 " 10
w3="$(maxes)"
kill -TERM "$hyst" 2>/dev/null
wait "$hyst" 2>/dev/null
check "常驻：79 °C 进 warm 档" \
  "$([[ "$w1" == "1555200 1920000 2131200 " ]] && echo ok)" "max=$w1"
check "常驻：降到 76 °C 仍保持 warm（迟滞不抖）" \
  "$([[ "$w2" == "1555200 1920000 2131200 " ]] && echo ok)" "max=$w2"
check "常驻：降到 71 °C 才退回原值" \
  "$([[ "$w3" == "1632000 2323200 2745600 " ]] && echo ok)" "max=$w3"

# 7. 充电时阈值下移 3 °C：75 °C 在放电时不该动，充电时就该进 warm。
mkfake
run_once 75000
dis="$(maxes)"
mkfake
echo Charging >"$T/battery/status"
run_once 75000
check "75 °C：放电不动，充电进 warm" \
  "$([[ "$dis" == "1632000 2323200 2745600 " && "$(maxes)" == "1555200 1920000 2131200 " ]] && echo ok)" \
  "放电=$dis 充电=$(maxes)"

# 8. 只想降不想升：原值本来就低于这一档的 cap 时，保持更低的那个。
mkfake
echo 1036800 >"$CPU/policy0/scaling_max_freq"
run_once 90000
check "原值低于 cap 时不往上抬（policy0 保持 1036800）" \
  "$([[ "$(cat "$CPU/policy0/scaling_max_freq")" == 1036800 ]] && echo ok)" \
  "policy0=$(cat "$CPU/policy0/scaling_max_freq")"

# 9. 服务重启：快照已记下原值，此时 CPU 正被压在 critical 档，重新评估到低温
#    必须回**原值**，不能把这时的 1113600 当原值。
mkfake
run_once 90000
mid="$(maxes)"
run_once 60000
check "被压着时重启，低温后回原值（不是降档值）" \
  "$([[ "$mid" == "1113600 1401600 1497600 " && "$(maxes)" == "1632000 2323200 2745600 " ]] && echo ok)" \
  "压档=$mid 恢复=$(maxes) 快照=$(cat "$SNAP" 2>/dev/null | tr '\n' '|')"

# 10. 传感器那套逻辑本身也要测：不给固定温度，让它去读 zone 文件。gpu-top 那
#     个 99 °C 不能被算进去（它不在 *-bottom / cluster0 里）。
mkfake
echo 88000 >"$ZONEROOT/thermal_zone12/temp"
run_once
check "从 *-bottom 传感器取值，且忽略 gpu-top" \
  "$([[ "$(maxes)" == "1113600 1401600 1497600 " ]] && echo ok)" \
  "max=$(maxes)（zone12=88 °C，zone5=60 °C，zone15/gpu-top=99 °C）"

# 11. 常驻模式：SIGTERM 必须恢复，并且把快照删掉。
mkfake
RAPHAEL_THERMAL_CPUFREQ="$CPU" \
RAPHAEL_THERMAL_ROOT="$ZONEROOT" \
RAPHAEL_THERMAL_BATTERY="$T/battery" \
RAPHAEL_THERMAL_SNAP="$SNAP" \
RAPHAEL_THERMAL_TEMP=90000 \
RAPHAEL_THERMAL_INTERVAL=1 \
  "$THERMAL" >"$T/daemon.log" 2>&1 &
daemon=$!
wait_maxes "1113600 1401600 1497600 " 10
mid="$(maxes)"
kill -TERM "$daemon" 2>/dev/null
wait "$daemon" 2>/dev/null
check "常驻模式：启动即按温度压档" \
  "$([[ "$mid" == "1113600 1401600 1497600 " ]] && echo ok)" "max=$mid"
check "常驻模式：SIGTERM 之后恢复原值" \
  "$([[ "$(maxes)" == "1632000 2323200 2745600 " ]] && echo ok)" "max=$(maxes)"
check "常驻模式：退出后快照被清掉" \
  "$([[ ! -e "$SNAP" ]] && echo ok)" "$SNAP 还在"

# 12. 节点缺失不能崩：换内核时这些路径会变，崩了就再也不会有人发现。
mkfake
rm -rf "$ZONEROOT"
rc=0
RAPHAEL_THERMAL_CPUFREQ="$CPU" \
RAPHAEL_THERMAL_ROOT="$T/nonexistent" \
RAPHAEL_THERMAL_BATTERY="$T/nonexistent-batt" \
RAPHAEL_THERMAL_SNAP="$SNAP" \
  "$THERMAL" --once >"$T/nosensor.log" 2>&1 || rc=$?
check "没有任何温度传感器时不崩、也不降频" \
  "$([[ $rc -eq 0 && "$(maxes)" == "1632000 2323200 2745600 " ]] && echo ok)" \
  "rc=$rc max=$(maxes) log=$(tr '\n' '|' <"$T/nosensor.log")"

# 13. 不碰 governor —— 那是 game-tune 的地盘，两个写者会互相夹掉对方的设定。
#     先去掉注释再 grep：脚本的说明里本来就要提到 scaling_governor，那是解释
#     「为什么不动它」，不是动它。
check "脚本里没有写 scaling_governor（注释不算）" \
  "$(sed 's/#.*//' "$THERMAL" | grep -q 'scaling_governor' && echo no || echo ok)" \
  "$(sed 's/#.*//' "$THERMAL" | grep -n 'scaling_governor' | head -3)"

# 14. unit 不能被 SIGKILL 收尾，否则恢复路径不会执行。
check "unit 用 SIGTERM 停止并留了停止超时" \
  "$(grep -q '^KillSignal=SIGTERM' "$UNIT" && grep -q '^TimeoutStopSec=' "$UNIT" && echo ok)" \
  "$(grep -E 'KillSignal|TimeoutStopSec' "$UNIT" | tr '\n' ' ')"

# 15. 构建脚本要把它放进开机 wants，而且要在 /usr/lib 下（/etc 是 overlayfs）。
check "build 脚本在 /usr/lib 的 wants 里启用了 raphael-thermal" \
  "$(grep -q 'for u in raphael-audio-route raphael-game-tune raphael-charge-guard raphael-thermal' "$BUILD" \
     && grep -q 'usr/lib/systemd/system/multi-user.target.wants' "$BUILD" && echo ok)" \
  "$(grep -n 'multi-user.target.wants\|raphael-thermal' "$BUILD" | head -5)"

echo
if [[ $fails -eq 0 ]]; then echo "全部通过"; else echo "$fails 条失败"; fi
exit $(( fails > 0 ? 1 : 0 ))
