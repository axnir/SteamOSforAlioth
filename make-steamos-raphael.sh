#!/usr/bin/env bash
# Build the boot image for raphael (Xiaomi Redmi K20 Pro / Mi 9T Pro).
#
# 阶段 1 只有一个模式：--kernel-only。产出 work/steamos-raphael/boot-debug.img，
# 里面是内核 + 单个 raphael DTB + 编进 Image 的 initramfs（soc.env 的
# EMBED_INITRAMFS=1）。没有 rootfs，没有 GPU 和 WiFi 的固件 —— 这两样都来自
# 手机自己、不可再分发（见 kernel-sm8150/soc.env），阶段 1 也不需要它们：
# 判据只有两条，出画面和进 USB shell。
#
# 打包参数不是抄来的，是从这台机器**原厂 boot.img 的头部**读出来的
# （docs/raphael.md §2.2）：
#
#   page_size 4096   kernel_addr 0x00008000
#   tags_addr 0x00000100   ramdisk_addr 0x00000000
#
# 和 alioth 那套只差 ramdisk 地址（alioth 用 0x01000000）。这里的每一个值
# 都来自一份这台机器真的从它启动过的镜像，改之前先想清楚凭什么。
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCOMMON="${PORT_ROOT}/external-and-mods/kernel-common"
SOC_DIR="${PORT_ROOT}/external-and-mods/kernel-sm8150"
DTB=sm8150-xiaomi-raphael

KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-raphael/output/current}" 2>/dev/null || true)"
OUT="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-raphael"

die() { echo "make-steamos-raphael: $*" >&2; exit 1; }

MODE="${1:-}"
case "$MODE" in
  --kernel-only) ;;
  --install)
    # 不是"还没写"，是"还差一整块"：把 SteamOS rootfs 装进 userdata 需要
    #   1) 机内签名固件（a640 zap / adsp / modem / WCN3998 board file），
    #      要从这台手机自己的分区里取，脚本还没写；
    #   2) 一份 raphael 的 overlay（UCM、模块加载顺序、电源键）；
    #   3) 一份已确认能启动的 boot.img —— 也就是阶段 1 的产物。
    # 在阶段 1 还没过一次真机之前做这三件事，等于把三个未知叠在一起调。
    die "--install 还没实现。先走 --kernel-only 把阶段 1 点亮（docs/raphael.md §7）"
    ;;
  *) die "用法: $0 --kernel-only" ;;
esac

# 原厂 boot.img 的头部，见文件头。
PAGESIZE=4096
KERNEL_ADDR=0x00008000
RAMDISK_ADDR=0x00000000
TAGS_ADDR=0x00000100
SECOND_ADDR=0x00000000
# 原厂头部的 os_version。显式写死而不是按日期算：这个字段可能被 ABL 比较，
# 而"今天是哪一天"不是能对表的东西。
OS_VERSION=0x16000155
# 原厂 Image 头里的 text_offset。我们的内核编出来是 0（7.x 可重定位内核的默认），
# 原厂是 0x80000。ABL 很可能拿它算加载位置 —— 0 会让内核落在 kernel_addr 本身。
TEXT_OFFSET=0x80000

img="${KOUT}/boot/Image"
dtb="${KOUT}/dtbs/${DTB}.dtb"
[[ -n "$KOUT" && -d "$KOUT" ]] || die "没有内核输出目录（KERNEL_OUT=${KERNEL_OUT:-默认}）"
[[ -s "$img" ]] || die "没有 $img —— kernel-sm8150/soc.env 里需要 KEEP_IMAGE=1"
[[ -s "$dtb" ]] || die "没有 $dtb —— soc.env 的 DTBS 里要有 $DTB"

mkdir -p "$OUT"

# ABL 拿到的东西：v1 头部 + 小米的"未压缩内核"封装。
#
# 原厂 boot.img 的内核段不是 gzip，也不是裸 Image，而是：
#     "UNCOMPRESSED_IMG" + u32(DTB 在 Image 内的偏移) + Image + DTB
# （每个字段都在原厂镜像里对上过：段内 +20 是 Image，+20+u32 处是 d00dfeed）
#
# 所以这里没有 gzip 那一步 —— 第一次刷写用的就是 gzip，`flash boot` 成功但设备
# 6 秒回到 fastboot、无内核日志，加载期被拒。alioth 的 ABL 收 gzip，这台不收。
#
# 只放 raphael 一个 DTB。补丁 0001 给这棵树补了 qcom,msm-id / qcom,board-id
# —— 没有它们，ABL 眼里这份镜像根本不是候选。
pack_boot() {   # pack_boot <输出文件名>

# cmdline 里的每一条都不是默认值：
#
# steamos.usbshell=1   拉起 USB gadget shell（ACM 串口 + 172.16.42.1:23）。
#                      这台机器没有能从外面接的调试串口，这是阶段 1 唯一
#                      能看的通道，所以必须显式打开。
# steamos.root=        不用 root=：小米 ABL 会在我们给的参数后面再追加它自己
#                      的一串 Android 参数，init 取最后见到的 root=，
#                      steamos.root= 永远赢（initramfs/init）。
# panic=120            这个 config 里 PANIC_TIMEOUT 是 0，panic 之后永远挂着。
#                      挂着的内核写不了 pstore，长按电源才重启又恰好把 DRAM
#                      丢了 —— 记录还没读就没了。给个非零值，让它温重启。
# steamos.bootlabel=   指一个这里不存在的 GPT 名字。默认值会让 initramfs 去找
#                      一个叫 ROCKNIX 的分区并往里面写启动日志；这台机器没有
#                      那个分区，但"禁止写入"是硬约束，把它从巧合变成保证。
# loglevel=7           CMDLINE_QUIET=0 时用 7 而不是 4：阶段 1 没有 journal，
#                      控制台和 pstore 就是唯一的记录，loglevel=4 会把
#                      USB 枚举和驱动 probe（都是 KERN_INFO）全丢掉。
cmdline="$(
  CMDLINE_QUIET=0 \
  KERNEL_CMDLINE_EXTRA="panic=120 steamos.usbshell=1 steamos.root=PARTLABEL=userdata steamos.bootlabel=steamos-arm-no-boot-partition" \
  bash -c "source '${SOC_DIR}/soc.env'; source '${KCOMMON}/cmdline.sh'; build_cmdline PARTLABEL=userdata"
)"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$img")}"

python3 "${KCOMMON}/mkbootimg-v1.py" \
  --image "$img" \
  --dtb "$dtb" \
  --image-text-offset "$TEXT_OFFSET" \
  --cmdline "$cmdline" \
  --pagesize "$PAGESIZE" \
  --kernel-addr "$KERNEL_ADDR" \
  --ramdisk-addr "$RAMDISK_ADDR" \
  --tags-addr "$TAGS_ADDR" \
  --second-addr "$SECOND_ADDR" \
  --os-version "$OS_VERSION" \
  --out "${OUT}/$1"
echo "cmdline: $cmdline"
}

sums() { (cd "$OUT" && sha256sum ./*.img >SHA256SUMS); }

pack_boot boot-debug.img
sums

echo
echo "kernel:  $(basename "$KOUT") ($(readlink -f "$KOUT"))"
ls -l "${OUT}/boot-debug.img"
echo
cat <<'EOF'
下一步：

  ./flash-raphael.sh --test      # 写 boot 分区；回退物在 work/raphael-facts/

（--ramboot 在这台机器上没用：ABL 连原厂镜像都拒绝 RAM 启动，见 flash-raphael.sh）

两个模式都只碰 boot。dtbo 不写：那边是面板/触摸的 overlay，清掉会不会黑屏没验证过。
EOF
