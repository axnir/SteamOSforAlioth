#!/usr/bin/env bash
# raphael-game-tune 的断言。整套逻辑指到一棵假的 sysfs 上跑 —— 不在真机上
# 来回切调速器，理由和 assert-alioth-gametune.sh 相同：验证护栏的脚本自己不
# 该走上它要防的那条路。
#
# 每条断言都对应一个会真的出事的情况：
#   - 没游戏却提频      -> 小核钉在最高频待机耗电，而且没有任何症状
#   - 有游戏却不提频    -> 就是它存在的全部理由
#   - Steam 客户端被当成游戏 -> 等于常开
#   - 退出不恢复        -> 同上，而且是停服务之后还留着
#   - 恢复时写死 schedutil -> 内核默认一变就恢复错，且看不出来
#   - 碰亲和            -> 实测是负优化（36.79 vs 48.40 fps），绝不能偷偷加回来
set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNE="${RAPHAEL_TUNE_BIN:-$SP/../scripts/raphael-overlay/usr/lib/steamos-arm/raphael-game-tune}"
UNIT="$SP/../scripts/raphael-overlay/usr/lib/systemd/system/raphael-game-tune.service"
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

[[ -x "$TUNE" ]] || { echo "找不到可执行的 $TUNE（chmod 755？）"; exit 2; }

T="$(mktemp -d)"
# mktemp 在 Git Bash 下返回的是 `C:\Users\...\Temp/tmp.xxx`（$TMPDIR 是 Windows
# 形式），而带盘符前缀的路径会被沙盒的 rm 包装器拒绝（"embedded drive prefix"），
# 于是 mkfake 的 rm -rf 静默失败、上一轮的 scope 留着，断言会给出假的失败。
# cd 之后取 pwd 就得到 /tmp/tmp.xxx 这种 POSIX 形式。
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

APP="$T/cg/user.slice/user-1000.slice/user@1000.service/app.slice"
SESS="$T/cg/user.slice/user-1000.slice/user@1000.service/session.slice"
SNAP="$T/run/snap"

# 重建一棵干净的假 sysfs：三个 CPU policy + 一个 GPU devfreq。
# CPU 的「原值」故意用 powersave 而不是内核默认的 schedutil —— 只有这样才能
# 区分「恢复原值」和「恢复写死的 schedutil」。
mkfake() {
  rm -rf "$T/sys" "$T/cg" "$T/run"
  local p
  for p in 0 4 7; do
    mkdir -p "$T/sys/cpufreq/policy$p"
    echo powersave >"$T/sys/cpufreq/policy$p/scaling_governor"
    echo 'powersave performance schedutil' >"$T/sys/cpufreq/policy$p/available_governors"
  done
  mkdir -p "$T/sys/devfreq/2c00000.gpu"
  echo msm-adreno-tz >"$T/sys/devfreq/2c00000.gpu/governor"
  echo 'msm-adreno-tz performance simple_ondemand' >"$T/sys/devfreq/2c00000.gpu/available_governors"
  # 真机（2026-11-08 实测）也有这两个节点，min==max 就等于钉在顶档。
  echo 257000000 >"$T/sys/devfreq/2c00000.gpu/min_freq"
  echo 675000000 >"$T/sys/devfreq/2c00000.gpu/max_freq"
  mkdir -p "$APP" "$SESS" "$T/run"
}

govs() { cat "$T/sys/cpufreq"/policy*/scaling_governor | sort -u | tr '\n' ' '; }
gpugov() { cat "$T/sys/devfreq"/*gpu*/governor 2>/dev/null; }

run_once() {
  RAPHAEL_TUNE_CGROUP_ROOT="$T/cg" \
  RAPHAEL_TUNE_CPUFREQ="$T/sys/cpufreq" \
  RAPHAEL_TUNE_DEVFREQ_ROOT="$T/sys/devfreq" \
  RAPHAEL_TUNE_SNAP="$SNAP" \
    "$TUNE" --once >/dev/null 2>&1
}

# 1. 什么都没跑 -> 保持原样（不主动去改）
mkfake
run_once
check "没有游戏时不动调速器" \
  "$([[ "$(govs)" == "powersave " && "$(gpugov)" == msm-adreno-tz ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 2. Steam 客户端自己不算游戏。它在 session.slice/steam.service，而不是
#    app.slice 下的 scope —— 认错的话等于 performance 常开。
mkfake
mkdir -p "$SESS/steam.service" "$APP/steamos-manager.service" \
         "$APP/xdg-desktop-portal-gamescope.service"
run_once
check "Steam 客户端本身不触发提频" \
  "$([[ "$(govs)" == "powersave " ]] && echo ok)" \
  "cpu=$(govs)"

# 3. 游戏 scope 出现 -> CPU 与 GPU 都切 performance
mkfake
mkdir -p "$APP/app-steam-app3020347378-24239.scope"
run_once
check "有游戏时 CPU 与 GPU 都切到 performance" \
  "$([[ "$(govs)" == "performance " && "$(gpugov)" == performance ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 4. 游戏退出 -> 回到**原值**（powersave，不是写死的 schedutil）
rm -rf "$APP/app-steam-app3020347378-24239.scope"
run_once
check "游戏退出后恢复原值（不是写死的 schedutil）" \
  "$([[ "$(govs)" == "powersave " && "$(gpugov)" == msm-adreno-tz ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 5. 服务重启（Restart=on-failure 的真实场景）：调速器被留在 performance，而
#    /run 里的快照还在。重新启动必须按快照恢复，不能把 performance 当原值。
mkfake
mkdir -p "$APP/app-steam-app555-9.scope"
run_once                       # 这次生成快照并提频
rm -rf "$APP/app-steam-app555-9.scope"
printf 'performance\n' >"$T/sys/cpufreq/policy0/scaling_governor"
run_once
check "服务重启后仍按快照恢复（不把 performance 当原值）" \
  "$([[ "$(govs)" == "powersave " ]] && echo ok)" \
  "cpu=$(govs) 快照=$(cat "$SNAP" 2>/dev/null | tr '\n' '|')"

# 6. 常驻模式收到 SIGTERM 要恢复。这条最重要：服务被停掉之后还留着
#    performance，没有任何界面会告诉你。
mkfake
mkdir -p "$APP/app-steam-app12345-1.scope"
RAPHAEL_TUNE_CGROUP_ROOT="$T/cg" \
RAPHAEL_TUNE_CPUFREQ="$T/sys/cpufreq" \
RAPHAEL_TUNE_DEVFREQ_ROOT="$T/sys/devfreq" \
RAPHAEL_TUNE_SNAP="$SNAP" \
RAPHAEL_TUNE_INTERVAL=1 \
  "$TUNE" >"$T/daemon.log" 2>&1 &
daemon=$!
sleep 3
mid="$(govs)"
kill -TERM "$daemon" 2>/dev/null
wait "$daemon" 2>/dev/null
check "常驻模式：游戏在跑时确实提了频" \
  "$([[ "$mid" == "performance " ]] && echo ok)" "cpu=$mid"
check "常驻模式：SIGTERM 之后恢复原值" \
  "$([[ "$(govs)" == "powersave " && "$(gpugov)" == msm-adreno-tz ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"
check "常驻模式：退出后快照被清掉" \
  "$([[ ! -e "$SNAP" ]] && echo ok)" "$SNAP 还在"

# 7. GPU 节点不存在也不能崩 —— 换内核/换设备时这条路径会变，而 CPU 那半边
#    仍然应该生效。
mkfake
rm -rf "$T/sys/devfreq"
mkdir -p "$APP/app-steam-app777-2.scope"
run_once
rc=$?
check "GPU 节点缺失时不崩，CPU 仍然生效" \
  "$([[ $rc -eq 0 && "$(govs)" == "performance " ]] && echo ok)" \
  "rc=$rc cpu=$(govs)"

# 8. GPU 调速器里没有 performance（真机就是这样：只有 userspace 和
#    simple_ondemand）时，退回把 min_freq 顶到 max_freq —— simple_ondemand 算出
#    的目标频率会被 core clamp 到 [min,max]，min==max 等于钉在顶档。
mkfake
echo 'userspace simple_ondemand' >"$T/sys/devfreq/2c00000.gpu/available_governors"
echo simple_ondemand >"$T/sys/devfreq/2c00000.gpu/governor"
mkdir -p "$APP/app-steam-app888-3.scope"
run_once
check "GPU 没有 performance 时用 min_freq 钉顶" \
  "$([[ "$(govs)" == "performance " && "$(gpugov)" == simple_ondemand \
       && "$(cat "$T/sys/devfreq/2c00000.gpu/min_freq")" == 675000000 ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov) min=$(cat "$T/sys/devfreq/2c00000.gpu/min_freq" 2>/dev/null)"
rm -rf "$APP/app-steam-app888-3.scope"
run_once
check "min_freq 钉顶之后游戏退出能放回去" \
  "$([[ "$(cat "$T/sys/devfreq/2c00000.gpu/min_freq")" == 257000000 ]] && echo ok)" \
  "min=$(cat "$T/sys/devfreq/2c00000.gpu/min_freq" 2>/dev/null)"

# 9. 绝不碰 CPU 亲和。这是「量过之后决定不做」，不是「还没做」。
check "脚本里没有任何设置 CPU 亲和的代码" \
  "$(grep -qE '(^|[^-[:alnum:]_])(taskset|sched_setaffinity|cpuset\.cpus|AllowedCPUs)' "$TUNE" \
     && echo no || echo ok)" \
  "$(grep -nE '(taskset|sched_setaffinity|cpuset\.cpus|AllowedCPUs)' "$TUNE" | head -3)"

# 10. unit 不能让 systemd 用 SIGKILL 收尾，否则第 6 条的恢复路径根本不会执行。
check "unit 用 SIGTERM 停止并留了停止超时" \
  "$(grep -q '^KillSignal=SIGTERM' "$UNIT" && grep -q '^TimeoutStopSec=' "$UNIT" \
     && echo ok)" \
  "$(grep -E 'KillSignal|TimeoutStopSec' "$UNIT" | tr '\n' ' ')"

# 11. 构建脚本要真的把它 enable（raphael 的 enable 链接由 build 脚本建，
#     不放 overlay 目录 —— git 在 Windows 上 checkout 符号链接会变成文本文件）。
check "build 脚本里有 multi-user.target.wants 的 enable 链接" \
  "$(grep -qE '^ *for u in .*raphael-game-tune' "$BUILD" && echo ok)" \
  "$BUILD 里没有那段 for 循环"

echo
if [[ $fails -eq 0 ]]; then echo "全部通过"; else echo "$fails 条失败"; fi
exit $(( fails > 0 ? 1 : 0 ))
