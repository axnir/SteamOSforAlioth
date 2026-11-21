#!/usr/bin/env bash
# Verify work/steamos-op8p/userdata.img without mounting it (no CAP_SYS_ADMIN).
# Runs inside the build container: e2fsck -fn + debugfs reads.
#
# 两个解析上的坑（都踩过，别再改回去）：
#   * debugfs 的 `stat` 把 Mode 打在 Inode 那一行里（`Inode: 5591  Type:
#     regular  Mode:  0755  Flags: ...`），所以既不能 `sed 's/^Mode: //'`
#     也不能 `grep '^Mode'` —— 那会把所有文件判成"不存在"（11-21 就是这样
#     误报了 8 项）。解析用 `s/.*Mode: *\([0-7]\{3,7\}\).*/\1/`，判断存在用
#     `^Inode:`。
#   * `.ko` 在 /lib/modules/<krel>/ 下面是分层的（kernel/drivers/...），
#     `ls -l` 顶层只看得到 kernel/ 和 modules.*，数它永远是 0。用
#     modules.dep 的行数代替。
#
# Usage (host): ./make-op8p.sh --verify  (or run this inside the container)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-${ROOT}/work/steamos-op8p/userdata.img}"

fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }

[[ -s "$IMG" ]] || { echo "没有 $IMG" >&2; exit 1; }

echo "镜像 $IMG ($(du -h "$IMG" | cut -f1))"

# 1. superblock
echo "[1] superblock"
hdr="$(dumpe2fs -h "$IMG" 2>/dev/null)"
uuid="$(sed -n 's/^Filesystem UUID: *//p' <<<"$hdr")"
blocks="$(sed -n 's/^Block count: *//p' <<<"$hdr")"
bsize="$(sed -n 's/^Block size: *//p' <<<"$hdr")"
state="$(sed -n 's/^Filesystem state: *//p' <<<"$hdr")"
free_blocks="$(sed -n 's/^Free blocks: *//p' <<<"$hdr")"
echo "     uuid=$uuid blocks=$blocks bsize=$bsize state=$state"
[[ "$bsize" == 4096 ]] && ok "块大小 4096" || bad "块大小 $bsize"
[[ "$state" == clean ]] && ok "文件系统干净" || bad "状态 $state（mkfs 可能被打断）"
if [[ -n "$blocks" && -n "$free_blocks" ]]; then
  used_pct=$(( (blocks - free_blocks) * 100 / blocks ))
  echo "     已用 ${used_pct}%（内容灌进去了才会 > 50%）"
  (( used_pct > 50 )) && ok "镜像不是空的" || bad "镜像只用了 ${used_pct}%，mkfs -d 可能没灌完"
fi

# 2. fstab 的 UUID 必须等于镜像 UUID —— 否则首启找不到 root
echo "[2] /etc/fstab"
fstab="$(debugfs -R 'cat /etc/fstab' "$IMG" 2>/dev/null)"
if grep -q "$uuid" <<<"$fstab"; then ok "fstab UUID 与镜像一致"; else
  bad "fstab UUID 不匹配：$(tr '\n' '|' <<<"$fstab")"; fi
grep -q 'x-systemd.growfs' <<<"$fstab" && ok "有 growfs" || bad "缺 x-systemd.growfs"
upper="$(debugfs -R 'cat /var/lib/overlays/etc/upper/fstab' "$IMG" 2>/dev/null)"
if grep -q "$uuid" <<<"$upper"; then ok "upper 层 fstab 也写了"; else
  bad "缺 /var/lib/overlays/etc/upper/fstab（overlay 会盖住 /etc/fstab）"; fi

# 3. 可执行位：btrfs restore 不加 -m 时全变 644，系统起不来
echo "[3] 关键文件"
dbg_mode() {
  debugfs -R "stat $1" "$IMG" 2>/dev/null \
    | sed -n 's/.*Mode: *\([0-7]\{3,7\}\).*/\1/p' | head -1
}
dbg_exists() {
  debugfs -R "stat $1" "$IMG" 2>/dev/null | grep -q '^Inode:'
}
check_exec() {
  local mode; mode="$(dbg_mode "$1")"
  if [[ -z "$mode" ]]; then bad "$1 不存在"; return; fi
  if (( 8#$mode & 8#111 )); then ok "$1 mode=$mode"; else bad "$1 mode=$mode 没有执行位"; fi
}
# systemd 的二进制在 /usr/lib/systemd/systemd，/usr/bin/systemd 本来就不存在
# （之前那条检查是照着想当然写的，会误报）。
for f in /usr/bin/bash /usr/lib/systemd/systemd /usr/bin/steam /lib/systemd/systemd; do
  check_exec "$f"
done
check_exec /usr/lib/steamos-arm/op8p-firstboot

# 4. overlay 有没有真的进去
echo "[4] overlay 与首启"
for f in /etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf \
         /etc/NetworkManager/system-connections/usb0.nmconnection \
         /etc/systemd/system/op8p-firstboot.service \
         /var/lib/op8p-firstboot-pending; do
  dbg_exists "$f" && ok "$f" || bad "$f 缺失"
done
want="/usr/lib/systemd/system/multi-user.target.wants/serial-getty@ttyGS0.service"
if debugfs -R "stat $want" "$IMG" 2>/dev/null | grep -qi 'Fast link dest'; then
  ok "serial-getty 已 enable"
else
  bad "serial-getty 软链缺失"
fi
want="/etc/systemd/system/sysinit.target.wants/op8p-firstboot.service"
if debugfs -R "stat $want" "$IMG" 2>/dev/null | grep -qi 'Fast link dest'; then
  ok "op8p-firstboot 已 enable"
else
  bad "op8p-firstboot 软链缺失"
fi

# 5. 机器身份：每台刷了这份镜像的机器不能是同一个 machine-id
echo "[5] machine-id"
mid="$(debugfs -R 'cat /etc/machine-id' "$IMG" 2>/dev/null | tr -d '\n')"
[[ -z "$mid" ]] && ok "/etc/machine-id 是空的" || bad "/etc/machine-id 非空（$mid）"

# 6. 内核模块与固件：没有它们起来只有串口 shell，没有显示和声音
echo "[6] 模块与固件"
kdir="$(ls -1 "${ROOT}/work/kernel-sm8250/output/current/modules/" 2>/dev/null | head -1)"
if [[ -n "$kdir" ]]; then
  dep_lines="$(debugfs -R "cat /lib/modules/$kdir/modules.dep" "$IMG" 2>/dev/null | wc -l)"
  echo "     /lib/modules/$kdir/modules.dep 有 $dep_lines 行"
  (( dep_lines > 200 )) && ok "模块清单在（$dep_lines 个条目）" || bad "modules.dep 行数只有 $dep_lines"
else
  echo "     (宿主机上看不到模块目录，跳过比对)"
fi
if debugfs -R 'ls -l /lib/firmware' "$IMG" 2>/dev/null | grep -q '^ '; then
  ok "/lib/firmware 有内容"
else
  bad "/lib/firmware 空"
fi

# 7. 全盘一致性 —— 放最后，最慢
echo "[7] e2fsck -fn（只读，不改）"
if e2fsck -fn "$IMG" >/tmp/fsck.out 2>&1; then
  ok "e2fsck 无错误"
else
  bad "e2fsck 报错："; tail -20 /tmp/fsck.out | sed 's/^/     /'
fi

echo
if (( fail )); then echo "结论：$fail 项不通过"; exit 1; fi
echo "结论：userdata.img 可以刷"
