#!/usr/bin/env bash
# Flash a raphael boot image, or hand it to the bootloader without writing.
#
# 和 flash-alioth.sh 最大的区别是**没有第二条命**。alioth 是 A/B，写坏 a 槽
# 还有 b 槽的 Android 兜底；这台是 A-only（`fastboot getvar all` 里一个 slot
# 变量都没有），`boot` 只有一个。所以：
#
#   * 写之前必须先有备份：work/raphael-facts/stock-boot.img，且 sha256 对得上
#     （docs/raphael.md §2.3）。没有就直接拒绝，不给"我知道我在干什么"的开关
#     —— 那个开关在半夜会被人加上的。
#   * 本脚本只碰 `boot`。`abl`/`xbl`/`tz` 这一串碰了就是 9008；`dtbo` 是
#     面板和触摸的 overlay，清掉会不会黑屏没验证过；`vbmeta` 不需要；`super`
#     要留着让 Android 能装回来；`userdata` 是唯一不可逆的一个，`--install`
#     还没实现，所以这个脚本今天写不到它。
#   * 没有任何"标记槽位成功"的动作，因为这台机器没有槽位。
#
# 两个模式：
#
#   --ramboot   把镜像交给 bootloader 直接启动，**不写任何分区**。
#               2026-11-07 实测：**这台机器的 ABL 整体不支持 RAM 启动** ——
#               连原厂 boot.img 都回 `Failed to load/authenticate boot image:
#               Load Error`。所以这个模式在这里没有用；留着是因为它不写东西，
#               换一台机或者哪天 ABL 放开，它仍然是最便宜的试法。
#
#   --test      写 `boot` 再重启。回退一条命令：
#                 fastboot flash boot work/raphael-facts/stock-boot.img
#               五次失败都是这么回来的，40 秒。
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-raphael"
FACTS="${PORT_ROOT}/work/raphael-facts"

# 这两份是这个手机自己的分区备份，sha256 是 dd + adb pull 之后两边对过的。
# 写成常量是为了让"备份还在不在"这个问题有一个可执行的答案，而不是靠记得。
EXPECT_BOOT_SHA=b794c34b2d868cc81e694ecd01d732a4c286ef8bc6ecf541548e0fe38ed048ce
EXPECT_DTBO_SHA=f921ddda9bc38bb4582287c0e2d6aafb5fc3b132680ab53774bdd9ae9fc6f540

die() { echo "flash-raphael: $*" >&2; exit 1; }

MODE="${1:-}"
case "$MODE" in
  --ramboot|--test) ;;
  --install)
    die "--install 还没实现（见 make-steamos-raphael.sh 里的理由）。今天这个脚本只写 boot"
    ;;
  *) die "用法: $0 --ramboot | --test" ;;
esac

IMAGE="${IMG_DIR}/boot-debug.img"
[[ -s "$IMAGE" ]] || die "没有 $IMAGE —— 先跑 ./make-steamos-raphael.sh --kernel-only"

# 1. 备份必须在，而且要是那份备份。
[[ -s "${FACTS}/stock-boot.img" ]] \
  || die "没有回退物 ${FACTS}/stock-boot.img。
    这台机器没有 A/B 槽，boot 写坏就只剩 fastboot。备份怎么取见 docs/raphael.md §2.3。
    从运行中的 Android + root 侧 dd 出来，或者用官方线刷包里的 boot.img。"
echo "${EXPECT_BOOT_SHA}  ${FACTS}/stock-boot.img" | sha256sum -c --quiet \
  || die "${FACTS}/stock-boot.img 的 sha256 不是预期的那份 —— 别用它当回退物"

# 2. 镜像本身要过 SHA256SUMS（make-steamos-raphael.sh 写的）。
[[ -f "${IMG_DIR}/SHA256SUMS" ]] || die "没有 ${IMG_DIR}/SHA256SUMS"
(cd "$IMG_DIR" && sha256sum -c --quiet SHA256SUMS) || die "boot-debug.img 和 SHA256SUMS 对不上"

# 3. fastboot 和手机。
command -v fastboot >/dev/null || die "没有 fastboot"
[[ -n "$(fastboot devices 2>/dev/null)" ]] || die "fastboot 看不到设备（手机要在 fastboot 模式：adb reboot bootloader）"

# 4. bootloader 得是解锁的。锁着的时候 flash 会失败得很难懂（有些版本甚至
#    先擦后写），所以在这里先问一句。
unlocked="$(fastboot getvar unlocked 2>&1 | sed -n 's/.*unlocked:[[:space:]]*//p' | tr -d '\r' | head -1)"
[[ "$unlocked" == "yes" ]] || die "bootloader 没解锁（unlocked=${unlocked:-未知}）"

# 5. 这台机器**不应该**有槽位。有的话说明我认错了机型，或者有人给它刷过
#    别的东西，两种情况都不该继续。
slots="$(fastboot getvar current-slot 2>&1 | grep -c 'current-slot:' || true)"
[[ "$slots" == 0 ]] || die "这台设备汇报了 current-slot —— 它不是 A-only 的 raphael，停下"

echo "镜像:   $IMAGE"
echo "         sha256 $(sha256sum "$IMAGE" | cut -d' ' -f1)"
echo "回退物: ${FACTS}/stock-boot.img"
echo "         fastboot flash boot ${FACTS}/stock-boot.img"

if [[ "$MODE" == --ramboot ]]; then
  cat <<'EOF'

--ramboot：只交给 bootloader 启动，不写任何分区。
  起来 → DTB 被认了，内核跑到了 initramfs，阶段 1 过了。
  起不来 → 长按电源重启，手机什么都没变。
EOF
  read -r -p "继续？输入 RAMBOOT 确认: " ans
  [[ "$ans" == RAMBOOT ]] || die "已取消"
  fastboot boot "$IMAGE"
  exit 0
fi

cat <<'EOF'

--test：写 `boot`，清空 `dtbo`，然后重启。
  动两个分区：boot（我们的镜像）和 dtbo（清空）。

  为什么要清 dtbo：里面那些 overlay 是给厂商设备树的，ABL 会把它们叠到 boot 镜像
  里的 DTB 上；我们的 DTB 是 mainline 板级文件，overlay 要改的节点不存在，叠加失败，
  ABL 就不启动（表现是刷写 OKAY、重启 6 秒回 fastboot）。实测清掉之后同一个镜像
  就被接受了。

  想回 Android 且屏幕调校正常，两个都要回来：
    fastboot flash boot work/raphael-facts/stock-boot.img
    fastboot flash dtbo work/raphael-facts/stock-dtbo.img
EOF
read -r -p "继续？输入 BOOT 确认: " ans
[[ "$ans" == BOOT ]] || die "已取消"

# dtbo 的备份也要在，而且要是那份 —— 它是"回得去"的另一半。
echo "${EXPECT_DTBO_SHA}  ${FACTS}/stock-dtbo.img" | sha256sum -c --quiet \
  || die "${FACTS}/stock-dtbo.img 的 sha256 不是预期的那份 —— 别在没备份的 dtbo 上动手"

echo "=> fastboot erase dtbo"
fastboot erase dtbo
echo "=> fastboot flash boot"
fastboot flash boot "$IMAGE"
echo "=> fastboot reboot"
fastboot reboot
echo
echo "回退：fastboot flash boot ${FACTS}/stock-boot.img && fastboot flash dtbo ${FACTS}/stock-dtbo.img"
