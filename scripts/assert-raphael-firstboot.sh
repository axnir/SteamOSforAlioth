#!/usr/bin/env bash
# 断言 raphael 的首次开机扩根这一层是自洽的（静态断言，不需要 root / 真机）。
#
# 真正危险的是两处常量漂移：GPT 里 p2 的大小（make-raphael-nested-gpt.ps1 的
# $P2_SECS）和 firstboot 里 resize2fs 的上限（unit 的 RAPHAEL_ROOT_SECS）。
# 上限大于 p2 → resize2fs 会盖掉 userdata 尾部的 backup GPT；上限小于 p2 →
# 白扩。第 3 条专门守这个。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FB="${ROOT}/scripts/raphael-overlay/usr/lib/steamos-arm/raphael-firstboot"
UNIT="${ROOT}/scripts/raphael-overlay/etc/systemd/system/raphael-firstboot.service"
GPT="${ROOT}/scripts/make-raphael-nested-gpt.ps1"
BUILD="${ROOT}/scripts/build-raphael-reference.sh"
NTP="${ROOT}/scripts/raphael-overlay/etc/systemd/timesyncd.conf.d/50-raphael-ntp.conf"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

[[ -f "$FB" ]] && pass "firstboot 脚本" "存在" || fail "firstboot 脚本" "缺失"
[[ -f "$UNIT" ]] && pass "firstboot unit" "存在" || fail "firstboot unit" "缺失"

# 1. 哨兵：先检查、resize2fs 之后才删 —— 顺序错了断电就会留下永远 12 GiB 的根。
chk=$(grep -n 'SENTINEL" ]\]' "$FB" | head -1 | cut -d: -f1)
rsz=$(grep -nE '^[[:space:]]*resize2fs ' "$FB" | head -1 | cut -d: -f1)
del=$(grep -n 'rm -f "\$SENTINEL"' "$FB" | head -1 | cut -d: -f1)
if [[ -n "$chk" && -n "$rsz" && -n "$del" && $chk -lt $rsz && $rsz -lt $del ]]; then
  pass "哨兵顺序" "检查($chk) → resize2fs($rsz) → 删($del)"
else
  fail "哨兵顺序" "检查=$chk resize=$rsz 删=$del"
fi

# 2. unit 必须带上限，且挂在 sysinit。
grep -q 'Environment=RAPHAEL_ROOT_SECS=' "$UNIT" && pass "unit 有上限" "RAPHAEL_ROOT_SECS" \
  || fail "unit 有上限" "缺失（resize2fs 会盖掉 backup GPT）"
grep -qx 'WantedBy=sysinit.target' "$UNIT" && pass "unit 挂 sysinit" "WantedBy" \
  || fail "unit 挂 sysinit" "缺失"
grep -q 'ConditionPathExists=/var/lib/raphael-firstboot-pending' "$UNIT" \
  && pass "unit 有哨兵条件" "ConditionPathExists" || fail "unit 有哨兵条件" "缺失"

# 3. 上限 == GPT 的 p2 大小。两处数字必须逐字相等。
unit_secs=$(grep -o 'RAPHAEL_ROOT_SECS=[0-9]*' "$UNIT" | head -1 | cut -d= -f2)
gpt_secs=$(grep -oE '\$P2_SECS[[:space:]]*=[[:space:]]*[0-9]+' "$GPT" | head -1 | grep -oE '[0-9]+$')
if [[ -n "$unit_secs" && "$unit_secs" == "$gpt_secs" ]]; then
  pass "p2 大小一致" "unit 与 GPT 都是 $unit_secs 个 4K 扇区"
else
  fail "p2 大小一致" "unit=$unit_secs GPT=$gpt_secs"
fi
# userdata 实测 122,857,467 个 4K 扇区，必须留余量给尾部 34 扇区 backup GPT。
if [[ -n "$gpt_secs" && $gpt_secs -lt 122857467 ]]; then
  pass "p2 未越过 userdata" "$gpt_secs < 122857467"
else
  fail "p2 未越过 userdata" "gpt=$gpt_secs"
fi

# 4. 构建时必须把哨兵带进镜像，否则脚本永远不跑。
grep -q 'touch "$TREE/var/lib/raphael-firstboot-pending"' "$BUILD" \
  && pass "构建放哨兵" "touch" || fail "构建放哨兵" "缺失"
grep -q 'raphael-firstboot.service' "$BUILD" && pass "构建建 enable 链接" "sysinit.target.wants" \
  || fail "构建建 enable 链接" "缺失"

# 5. 无 CR（shebang 带 \r 会 203/EXEC，raphael 已经在这上面栽过）。
bad=""
for f in "$FB" "$UNIT" "$NTP"; do
  [[ -f "$f" ]] && grep -q $'\r' "$f" && bad="$bad $f"
done
[[ -z "$bad" ]] && pass "无 CRLF" "3 个文件" || fail "无 CRLF" "有 CR:$bad"

# 6. NTP：用 NTP= 而不是 FallbackNTP=（后者在这份镜像里永远够不着）。
[[ -f "$NTP" ]] && pass "NTP drop-in" "存在" || fail "NTP drop-in" "缺失"
grep -qE '^NTP=.+' "$NTP" 2>/dev/null && pass "NTP= 有服务器" "非空" \
  || fail "NTP= 有服务器" "缺失或为空"

echo
if [[ $fails -gt 0 ]]; then echo "${fails} 条断言失败"; exit 1; fi
echo "全部断言通过"
