#!/usr/bin/env bash
# Assert the rules flash-op8p.sh and make-op8p.sh must never break.
#
# Same principle as scripts/assert-alioth-flash.sh: a rule that lives only in
# a comment is a rule that gets violated by the next person in a hurry. These
# checks are cheap and they run before anything is written to a phone.
#
# Usage: scripts/assert-op8p-flash.sh
#   Exit 0 = every rule holds. Any failure prints the violated rule.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLASH="${ROOT}/flash-op8p.sh"
MAKE="${ROOT}/make-op8p.sh"
fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }

# Strip comments, heredoc bodies and the say()/echo() announcement lines
# before looking for commands. A warning that *names* abl_a is not a write;
# the heredoc that shows the user what will happen is not a write either.
# What is left is only the commands the script would actually run.
strip() {
  awk '
    BEGIN { inhd = 0 }
    {
      line = $0
      # a heredoc opener: everything until the terminator is prose
      if (!inhd && match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) ) {
        inhd = 1
        next
      }
      if (inhd) {
        if (line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) inhd = 0
        next
      }
      sub(/#.*/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      # announcements, not actions
      if (line ~ /^[[:space:]]*(say|echo|printf)[[:space:]]/) next
      print line
    }' "$1"
}

echo "== flash-op8p.sh 存在且可执行 =="
[[ -x "$FLASH" ]] && ok "可执行" || bad "$FLASH 不可执行"

body="$(strip "$FLASH")"

echo "== 禁止写入的分区 =="
for p in abl_a abl_b vbmeta vbmeta_a vbmeta_b super; do
  if printf '%s\n' "$body" | grep -qE "(flash|erase)[^|]*\b${p}\b"; then
    bad "代码里出现了对 $p 的写操作"
  else
    ok "不写 $p"
  fi
done

echo "== 只写一个 boot 槽，且必须是活动槽之外的那个 =="
n=$(printf '%s\n' "$body" | grep -cE 'fastboot flash "?boot_\$')
if [[ "$n" == 1 ]]; then
  ok "恰好一处 flash boot_<slot>"
else
  bad "flash boot_ 出现 $n 次（应恰好 1 次）"
fi
# Any flash/erase of a boot slot that is NOT the computed inactive one is a
# violation. Written this way because a mutation that adds
# `fastboot flash "boot_$active"` must be caught, and an earlier version of
# this check only looked for the literal string "active".
# Count individual boot_<slot> write targets, not lines: a mutation can add
# a second flash to the same line as the legitimate one, and a whole-line
# filter would miss it. Every target found must be boot_${inactive}.
# BSD grep -E (macOS) rejects \{\} escapes, so avoid them entirely: take
# every boot_ token and strip anything after it, then compare the set.
bad_targets="$(printf '%s\\n' "$body" \
  | grep 'fastboot flash' \
  | grep -o 'boot_[A-Za-z_${}]*' \
  | sort -u)"
if [[ "$bad_targets" == 'boot_${inactive}' ]]; then
  ok "所有 boot 槽写入都指向 \${inactive}"
elif [[ -z "$bad_targets" ]]; then
  bad "找不到任何 boot_\${inactive} 的写入目标"
else
  bad "存在写非 inactive 槽的目标: $(echo "$bad_targets" | tr '\n' ' ')"
fi

# The slot must be READ from the phone, and the surrounding logic must not
# be stubbed out. Check the assignment is still a getvar call, not that some
# assignment exists -- a mutation that hardcodes `active=b` keeps the name.
printf '%s\n' "$body" | grep -qE '^[[:space:]]*active="\$\(getvar current-slot\)"' \
  && ok "活动槽来自 getvar current-slot" || bad "current-slot 不是从设备读的"
# Device identity. `getvar product` alone is NOT a usable check on this
# phone -- it answers `product: kona` (the SoC) and `getvar all` contains no
# model string at all, so a product-only guard can never fire and every
# SM8250 device would pass it. The check therefore keys on partition
# geometry read from the device, which is per-device.
printf '%s\n' "$body" | grep -qE '^[[:space:]]*soc="\$\(getvar product\)"' \
  && ok "SoC 来自 getvar product" || bad "SoC 不是从设备读的"
# expect_size() builds the getvar name at runtime as "partition-size:$p",
# so match the helper and the boot_a assertion rather than a literal string.
printf '%s\n' "$body" | grep -q 'partition-size:\$p' \
  && ok "用分区几何校验机型" || bad "没有用分区几何校验机型"
printf '%s\n' "$body" | grep -q 'partition-size:abl_a' \
  && ok "要求 abl_a 存在（OnePlus A/B 布局）" || bad "没有检查 abl_a"
printf '%s\n' "$body" | grep -qE 'kona\|\*sm8250|kona\).*;;' \
  && ok "SoC 不匹配时会拒绝" || bad "SoC 校验没有拒绝分支"
printf '%s\n' "$body" | grep -q 'expect_size boot_a' \
  && ok "boot_a 期望尺寸被断言" || bad "没有断言 boot_a 尺寸"

echo "== 禁止整机写操作 =="
printf '%s\n' "$body" | grep -qE 'fastboot +(-w|--wipe|erase userdata|format userdata)' \
  && bad "出现了整机/用户数据写操作" || ok "没有 -w / erase userdata"
printf '%s\n' "$body" | grep -qE 'fastboot +flash +userdata' \
  && bad "出现了 flash userdata" || ok "没有 flash userdata"

echo "== 确认必须来自 TTY =="
printf '%s\n' "$body" | grep -q '\[\[ ! -t 0 \]\]' \
  && ok "非 TTY 时拒绝" || bad "缺少 [[ ! -t 0 ]] 守卫"
printf '%s\n' "$body" | grep -q 'read -r -p' \
  && ok "有交互式确认" || bad "缺少 read -p 确认"

echo "== 声明 EDL / 切槽恢复路径 =="
grep -q 'set-active' "$FLASH" && ok "说明了 set-active 退路" || bad "没有说明 set-active"
grep -qE 'EDL|9008' "$FLASH" && ok "说明了 EDL 9008 退路" || bad "没有说明 EDL"

echo "== make-op8p.sh 的镜像参数 =="
[[ -x "$MAKE" ]] && ok "可执行" || bad "$MAKE 不可执行"
mbody="$(strip "$MAKE")"
for want in 'PAGESIZE=4096' 'KERNEL_ADDR=0x00008000' 'RAMDISK_ADDR=0x01000000' 'TAGS_ADDR=0x00000100'; do
  printf '%s\n' "$mbody" | grep -qF "$want" && ok "$want" || bad "缺少 $want"
done
# The cmdline must not silence the only two log channels phase 1 has.
if printf '%s\n' "$mbody" | grep -q 'CMDLINE_QUIET=\$(\[\[ \$QUIET == 1 \]\]'; then
  ok "默认不静音（QUIET=0）"
else
  bad "cmdline 默认可能是静音的"
fi
# The cmdline is assembled by kernel-common/cmdline.sh: CMDLINE_QUIET=0 is
# what emits `console=ttyGS0 console=tty0 loglevel=7`. Check the pairing
# rather than the literal text, which lives in the shared helper.
if grep -q 'CMDLINE_QUIET=stty' /dev/null 2>/dev/null; then :; fi
grep -q 'CMDLINE_QUIET=' "$ROOT/external-and-mods/kernel-common/cmdline.sh" \
  && grep -q 'console=ttyGS0 console=tty0 loglevel=7' "$ROOT/external-and-mods/kernel-common/cmdline.sh" \
  && ok "CMDLINE_QUIET=0 分支会输出 console=ttyGS0/tty0 loglevel=7" \
  || bad "cmdline.sh 的静音/详细分支不符合预期"

echo
if [[ $fail == 0 ]]; then
  echo "全部通过"
else
  echo "有断言失败 —— 不要刷机"
fi
exit $fail
