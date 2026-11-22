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
# flash userdata 只允许出现在 --install 分支里。它曾经是全局禁止的（那时
# --install 还没实现）；现在它存在，但仍然必须被 ERASE + TTY 守着，而且
# 不能被别的模式顺带执行到。
awk '/== --install/,/^fi$/' "$FLASH" | grep -q 'fastboot flash userdata' \
  && ok "flash userdata 在 --install 分支里" || bad "flash userdata 不在 install 分支"
if awk '/== --install/{on=1} /^fi$/{on=0} !on' "$FLASH" | grep -q 'flash userdata'; then
  bad "install 分支之外也有 flash userdata"
else
  ok "install 之外没有任何路径能写 userdata"
fi

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

echo "== install：唯一会毁数据的模式"
# 这三个是 --install 的全部安全属性。它们各自都曾经在别人的脚本里缺过，
# 结果都是"一句话下去，Android 的数据没了"。
grep -q -- '--install' "$ROOT/flash-op8p.sh" && ok "--install 模式存在" \
  || bad "flash-op8p.sh 没有 --install"
grep -q 'read -r -p "输入 ERASE 继续: "' "$ROOT/flash-op8p.sh" \
  && ok "确认词是 ERASE（不是 YES）" || bad "确认词不是 ERASE"
grep -q '\[\[ "\$ans" == ERASE \]\]' "$ROOT/flash-op8p.sh" \
  && ok "ERASE 之后才继续" || bad "确认词没有真的拦住"
grep -q '必须来自 TTY' "$ROOT/flash-op8p.sh" \
  && ok "非 TTY 时拒绝（echo ERASE | 不能刷）" || bad "没有 TTY 检查"
awk '/== --install/,/^fi$/' "$ROOT/flash-op8p.sh" | grep -q '不可逆' \
  && ok "提示里写明了不可逆" || bad "install 提示没说不可逆"
grep -q 'fastboot flash userdata' "$ROOT/flash-op8p.sh" \
  && ok "写的是 userdata 分区" || bad "没有 flash userdata"
# 它不该碰 super / abl：Android 能刷回去全靠这一点。
awk '/== --install/,/^fi$/' "$ROOT/flash-op8p.sh" | grep -q 'flash super' \
  && bad "install 会写 super —— Android 就回不去了" || ok "不碰 super"

echo "== 刷机前的断言门禁（门禁自己也要被断言） =="
# 门禁如果被某次"简化"删掉，其余所有断言就退化成仓库里躺着的文档 —— 那正是
# OP8P 在 2026-11-22 之前的真实状态：五套断言全绿，却没有任何东西在刷机
# 之前执行它们。所以门禁本身也得钉住。
grep -q 'assert-op8p-flash.sh' "$FLASH" \
  && ok "flash 会跑自身规则断言" || bad "flash 不跑 assert-op8p-flash.sh"
grep -q 'assert-op8p-boot-image.sh' "$FLASH" \
  && ok "flash 会跑镜像断言" \
  || bad "flash 不跑 assert-op8p-boot-image.sh —— 改了 DTS 刷旧镜像没人拦"
# 必须把真正要刷的那个镜像传进去：不带 $IMG 的话，--img 指向任何文件都会
# 绕过检查，而 --img 恰好是最常用的调试入口。
grep -q 'OP8P_BOOT_IMAGE="\$IMG"' "$FLASH" \
  && ok "镜像断言检查的是 \$IMG（不是默认路径）" || bad "镜像断言没拿到 \$IMG"
# 跳过必须靠显式环境变量。有默认跳过路径的断言等于没有。
grep -q 'OP8P_SKIP_ASSERT:-0' "$FLASH" \
  && ok "跳过需要显式 OP8P_SKIP_ASSERT=1" || bad "存在默认跳过断言的路径"
grep -q 'assert-op8p-boot-image.sh' "$MAKE" \
  && ok "make-op8p.sh 打包后也验镜像" || bad "打包后不验镜像（坏镜像要到刷机才发现）"

echo "== rootfs 镜像的生成"
RFS="$ROOT/scripts/make-op8p-rootfs.sh"
[[ -f "$RFS" ]] && ok "scripts/make-op8p-rootfs.sh 存在" || bad "缺 rootfs 生成脚本"
grep -q 'mkfs.ext4' "$RFS" && ok "用 mkfs.ext4 造文件系统" || bad "没有 mkfs.ext4"
# 这个容器没有 CAP_SYS_ADMIN，任何 loop mount 都会失败，所以必须是 -d。
grep -q 'mkfs.ext4 .*-d ' "$RFS" && ok "用 -d 灌目录（不 loop 挂载）" \
  || bad "不是 mkfs.ext4 -d，容器里跑不了"
grep -q 'x-systemd.growfs' "$RFS" \
  && ok "fstab 带 x-systemd.growfs（首启扩到全分区）" || bad "没有 growfs，装完只有几 GB"
grep -q 'lib/modules' "$RFS" && ok "会装内核模块" || bad "没装模块（起来也是个壳）"
grep -q 'firmware' "$RFS" && ok "会装固件" || bad "没装固件"

echo
if [[ $fail == 0 ]]; then
  echo "全部通过"
else
  echo "有断言失败 —— 不要刷机"
fi
exit $fail
