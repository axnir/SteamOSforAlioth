#!/usr/bin/env bash
# 断言 scripts/apply-raphael-devr.sh 把去 VR 化层正确装进一棵 rootfs。
# 用假目录树，不碰真镜像、不需要 root、毫秒级。照 assert-alioth-devr.sh。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/scripts/apply-raphael-devr.sh"
OV="${ROOT}/scripts/raphael-overlay"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

R="$(mktemp -d -p "$ROOT/work")"
LFS="$R/.apply.lf.sh"
trap 'rm -rf "$R"' EXIT

mkdir -p "$R/usr/lib/steamos" "$R/usr/bin" "$R/etc"
echo 'stock' > "$R/usr/lib/steamos/gamescope-session"

# 脚本本身可能是 CRLF（git checkout），先去 CR；RAPHAEL_REPO 保证能找到 steamos-overlay。
tr -d '\r' < "$APPLY" > "$LFS"
out="$(RAPHAEL_REPO="$ROOT" bash "$LFS" "$R" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "脚本执行" "退出码 0" || fail "脚本执行" "rc=$rc: ${out:0:300}"

want=(
  usr/lib/steamos/gamescope-session
  usr/lib/steamos/gamescope-onready
  usr/lib/steamos/panel-modes
  usr/bin/start-gamescope-session
  usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf
  usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf
  usr/lib/systemd/user/steam.service.d/61-gamescope-env-wait.conf
  usr/lib/systemd/user/steamos-manager-session-cleanup.service.d/10-steamos-arm-timeout.conf
)
missing=()
for f in "${want[@]}"; do [[ -f "$R/$f" ]] || missing+=("$f"); done
[[ ${#missing[@]} -eq 0 ]] && pass "10 个去 VR 化文件" "齐全" \
  || fail "10 个去 VR 化文件" "缺少: ${missing[*]}"

# 最关键的一条：shebang 带 CR 会让 sddm-helper 以 126 退出（2026-11-07 实测）。
bad=()
for f in "${want[@]}"; do
  [[ -f "$R/$f" ]] || continue
  grep -q $'\r' "$R/$f" && bad+=("$f")
done
[[ ${#bad[@]} -eq 0 ]] && pass "全部去 CR" "无 CRLF" \
  || fail "全部去 CR" "仍有 CR: ${bad[*]}"

notexec=()
for f in usr/lib/steamos/gamescope-session usr/lib/steamos/gamescope-onready \
         usr/lib/steamos/panel-modes usr/bin/start-gamescope-session; do
  [[ -x "$R/$f" ]] || notexec+=("$f")
done
[[ ${#notexec[@]} -eq 0 ]] && pass "可执行位" "4 个脚本都可执行" \
  || fail "可执行位" "不可执行: ${notexec[*]}"

grep -q 'qcom,sm8150' "$R/usr/lib/steamos/gamescope-session" \
  && pass "sm8150 zink 判断" "已加入" || fail "sm8150 zink 判断" "缺失"
grep -q 'TimeoutStartSec=45' "$R/usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf" \
  && pass "45 秒启动超时" "已装" || fail "45 秒启动超时" "缺失"
[[ -f "$R/usr/lib/systemd/user/steamos-manager-session-cleanup.service.d/10-steamos-arm-timeout.conf" ]] \
  && pass "cleanup 8 秒超时" "已装" || fail "cleanup 8 秒超时" "缺失"

nuser=$(find "$R/etc/systemd/user" -type l 2>/dev/null | wc -l)
nsys=$(find "$R/etc/systemd/system" -type l 2>/dev/null | wc -l)
[[ $nuser -eq 5 ]] && pass "用户态 mask" "5 个" || fail "用户态 mask" "实际 $nuser"
[[ $nsys -eq 17 ]] && pass "系统态 mask" "17 个" || fail "系统态 mask" "实际 $nsys"
[[ ! -e "$R/etc/systemd/system/raphael-usb-gadget.service" ]] \
  && pass "调试通道未被 mask" "COM3 root shell 保留" || fail "调试通道未被 mask" "gadget 被 mask 了"
[[ -f "$R/var/lib/steamos-arm-stock/usr/lib/steamos/gamescope-session" ]] \
  && pass "Frame 原件备份" "已留" || fail "Frame 原件备份" "缺失"

for f in etc/sddm.conf.d/zz-raphael.conf \
         etc/systemd/user/gamescope-session.service.d/99-raphael.conf \
         etc/systemd/user/steamos-manager.service.d/99-raphael.conf; do
  [[ -f "$OV/$f" ]] && pass "overlay: $f" "存在" || fail "overlay: $f" "缺失"
done
grep -q 'Type=simple' "$OV/etc/systemd/user/steamos-manager.service.d/99-raphael.conf" 2>/dev/null \
  && pass "manager Type=simple" "已配置" || fail "manager Type=simple" "缺失"

echo
if [[ $fails -gt 0 ]]; then echo "${fails} 条断言失败"; exit 1; fi
echo "全部断言通过"
