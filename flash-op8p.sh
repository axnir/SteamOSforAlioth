#!/usr/bin/env bash
# Put a phase-1 boot image on OnePlus 8 Pro (instantnoodlep).
#
# The rules this script enforces are narrow on purpose, and every one of them
# is a rule that exists because breaking it costs a phone:
#
#   * It never writes `abl_a`/`abl_b`. That is the bootloader; a bad write
#     there is only recoverable over Qualcomm EDL 9008. This phone does reach
#     EDL cheaply (`adb reboot edl`, or vol-up+vol-down+power), which is
#     better than alioth -- but "cheap to recover" is not "safe to break".
#
#   * It never writes `super`. Android lives there. Keeping it is what makes
#     "flash back to stock" a three-command job instead of a full restore.
#
#   * It never writes `vbmeta`. This phone boots with verifiedbootstate
#     orange and has never needed it.
#
#   * --test writes only the INACTIVE slot and refuses if it cannot prove
#     which slot that is. Measured on the device: current happens to be `_b`,
#     so `--test` writes `boot_a`. That is a coincidence of this phone's
#     state, not an assumption -- the slot is read from the phone every run.
#
#   * --install (rootfs to userdata) is not implemented here yet. When it is,
#     it will live in a separate marked region and require the operator to
#     type the word at a TTY, exactly like flash-alioth.sh.
#
# Modes:
#
#   --boot    `fastboot boot <img>` -- writes nothing, changes no slot.
#             NOTE: on Qualcomm ABLs the OKAY for `boot` is sent before the
#             jump, so success here proves nothing about the image. alioth
#             measured this. Treat a --boot result as "no information".
#
#   --test    Write the inactive slot and start from it.
#
# RECOVERY -- read before --test:
#
#   Hold vol-down + power for fastboot, then `fastboot --set-active=<slot>`
#   to go back. This phone also reaches EDL with vol-up+vol-down+power,
#   which is the way back even if both boot slots are bad.
#
#   The bootloader does fall back on its own after repeated failures, but
#   that is not a plan: it spends boot attempts and lands on whatever the
#   other slot holds.
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-op8p"
PRODUCT=instantnoodlep

die() { echo "flash-op8p: $*" >&2; exit 1; }
say() { echo "flash-op8p: $*" >&2; }

MODE="${1:-}"
[[ -n "$MODE" ]] || die "用法: $0 --boot|--test [--img FILE]"
shift

IMG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --img) IMG="$2"; shift ;;
    *) die "不认识的参数: $1" ;;
  esac
  shift
done

command -v fastboot >/dev/null || die "没有 fastboot"

# Pick the image: an explicit --img, else the gzip packing (the one that
# matches what ROCKNIX and alioth have both proven), else v2.
if [[ -z "$IMG" ]]; then
  for c in boot-op8p-gzip.img boot-op8p-v2.img; do
    [[ -f "${IMG_DIR}/${c}" ]] && IMG="${IMG_DIR}/${c}" && break
  done
fi
[[ -n "$IMG" && -f "$IMG" ]] || die "没有镜像（先跑 ./make-op8p.sh）"
IMG="$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")"

say "镜像 $IMG ($(stat -f %z "$IMG" 2>/dev/null || stat -c %s "$IMG") 字节)"

# --- talk to the phone -----------------------------------------------------

# getvar in both shapes this and other Qualcomm bootloaders print:
#   "name: value"  and  "(bootloader) name:value".
getvar() {
  local name="$1" out val
  out="$(fastboot getvar "$name" 2>&1)" || die "fastboot getvar $name 失败: $out"
  val="$(printf '%s\n' "$out" | sed -n "s/^(bootloader) *${name}: *//p" | head -n1)"
  [[ -n "$val" ]] || val="$(printf '%s\n' "$out" | sed -n "s/^${name}: *//p" | head -n1)"
  printf '%s' "$val"
}

# This tree's scripts are not the only ones in this repo, and an sm8250 boot
# image flashed into a different phone's boot partition is a day of
# someone's life. Check identity before anything else.
#
# `getvar product` does NOT work for that on this phone, and this was
# measured rather than assumed (2026-10-25): OnePlus' fastboot answers
#
#   product: kona            <- the SoC, not the model
#   variant: SM8 UFS
#   version-baseband:        <- empty
#
# and `getvar all` contains no model string at all -- no "oneplus", no
# "instantnoodle", no "IN2020". Every SM8250 device from any vendor would
# pass a product check here, so it would be a guard that cannot fire.
#
# What is actually distinctive is the partition geometry, which comes from
# the GPT and is per-device. These three sizes are this phone's, read from
# its own fastboot on 2026-10-25:
#
#   boot_a  0x6000000  (100,663,296)
#   dtbo_a  0x1800000  ( 25,165,824)
#   param   0x 100000  (  1,048,576)
#
# A wrong phone fails all three (an sm8650 handheld has different boot
# sizes and no `abl_a` at all, which the second check below rules out).
soc="$(getvar product)"
case "$soc" in
  kona|*sm8250*|*SM8250*) ;;
  *) die "SoC 不是 SM8250/kona（getvar product = '$soc'）—— 这不是本移植的目标" ;;
esac

expect_size() {   # expect_size <partition> <hex>
  local p="$1" want="$2" got
  got="$(getvar "partition-size:$p")"
  [[ -n "$got" ]] || die "读不到 partition-size:$p —— 这不是一台 $PRODUCT"
  # Accept both "0x6000000" and "100663296".
  if [[ "$got" == 0x* ]]; then
    [[ "$((got))" == "$((want))" ]] || die "$p 大小是 $got（$((got))），期望 $want —— 这不是 $PRODUCT"
  else
    [[ "$got" == "$want" ]] || die "$p 大小是 $got，期望 $want —— 这不是 $PRODUCT"
  fi
}

expect_size boot_a 0x6000000
expect_size dtbo_a 0x1800000

# `abl_a` existing at all is the OnePlus layout; most handhelds have no such
# partition, and writing boot_* into one of those would be a different
# brick. This also confirms the A/B scheme the slot logic below depends on.
[[ -n "$(getvar partition-size:abl_a)" ]] \
  || die "没有 abl_a 分区 —— 这不是 OnePlus 机型"

say "设备 ${soc}（分区几何匹配 ${PRODUCT}）"

active="$(getvar current-slot)"
[[ "$active" == a || "$active" == b ]] || die "读不到 current-slot（得到 '$active'）"
if [[ "$active" == a ]]; then inactive=b; else inactive=a; fi
say "活动槽 $active，本次可写的槽 $inactive"

if [[ "$MODE" == --boot ]]; then
  say "fastboot boot（零写入）"
  fastboot boot "$IMG" || die "fastboot boot 失败"
  say "已发送。ABL 的 OKAY 在跳转之前就回了，所以这不代表镜像可用。"
  exit 0
fi

[[ "$MODE" == --test ]] || die "用法: $0 --boot|--test"

# Writing the slot the phone is running from would replace the only system
# that currently boots. Refuse, and say what to do instead.
[[ "$inactive" != "$active" ]] || die "内部错误：可写槽 == 活动槽"

# dtbo: ERASE, do not flash.
#
# This is the one rule that took nine failed boots to find, and alioth had
# already recorded it (docs/alioth.md, "Xiaomi ABL 的实际行为"):
#
#     Dtbo hdr magic mismatch 0, with D7B7AB1E
#     -> Best match DTB tags ...
#     -> boot succeeded
#
# An erased dtbo partition reads back all zeroes, so the magic is 0. The
# ABL treats "magic 0" differently from "valid table with no entries": it
# skips the whole overlay path and uses the DTB appended to the kernel
# instead. Measured on this phone on 2026-10-25, the alternatives are all
# dead ends:
#
#   stock 11-overlay partition  -> board-id mismatch, No match found
#   valid table, 0 entries      -> Error: Board Dtbo blob not found
#   valid table, 1 stub entry   -> identity OK, ufdt apply overlay failed
#   valid table, stock overlay  -> identity OK, ufdt apply overlay failed
#
# The last two fail because a Qualcomm overlay (target = <0xffffffff>,
# resolved through __fixup__) cannot be applied to a mainline DTB -- the
# node paths do not exist. Erasing sidesteps the merge entirely.
#
# The partition is erased per slot: dtbo_${inactive} only. The active
# slot's dtbo is left alone, so `--set-active=${active}` still boots
# Android. Both were backed up before the first flash (~/op8p-backup/).
cat <<EOF

即将执行（只动这些，别的一概不碰）：
  fastboot flash boot_${inactive}   <img>
  fastboot erase dtbo_${inactive}   （擦除，不是刷空表）

不会碰：abl_a/b、super、vbmeta_a/b、userdata、boot_${active}、dtbo_${active}
恢复：按住 音量下+电源 进 fastboot，再 fastboot --set-active=${active}
      进不去 fastboot 时：音量上+下+电源 进 EDL 9008

EOF

# The confirmation must come from a terminal. `echo YES | ./flash-op8p.sh`
# must not be able to do this unattended.
if [[ ! -t 0 ]]; then
  die "确认必须来自 TTY（检测到非交互 stdin）—— 请直接运行本脚本"
fi
read -r -p "输入 YES 继续: " ans
[[ "$ans" == YES ]] || die "已取消"

say "=> fastboot flash boot_${inactive}"
fastboot flash "boot_${inactive}" "$IMG" || die "flash boot 失败"

say "=> fastboot erase dtbo_${inactive}"
fastboot erase "dtbo_${inactive}" || die "erase dtbo 失败"

say "完成。启动方法：fastboot --set-active=${inactive} && fastboot reboot"
say "回退：./flash-op8p.sh 只写 ${inactive} 槽；改回 ${active} 槽即回到 Android"
