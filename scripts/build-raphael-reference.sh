#!/usr/bin/env bash
# 按参考仓库 archlinux-xiaomi-raphael 的引导链重做 raphael 的两个产物：
#   cache    FAT32 引导镜像：EFI/BOOT/BOOTAA64.EFI + linux.efi + initramfs + dtbs + loader/entries
#   userdata 可写 ext4 rootfs：Valve rootfs 内容 + raphael payload（模块/固件/调试服务）
#
# 引导链: U-Boot(boot) -> bootefi bootmgr -> FAT 上的 \EFI\BOOT\BOOTAA64.EFI
#         -> systemd-boot 读 loader/entries/steamos.conf -> linux.efi (EFI stub)
#         -> initramfs 解析 root=UUID=... 挂载 -> switch_root /sbin/init
#
# 不用 python，不用 loop 挂载（wslc 容器没有 CAP_SYS_ADMIN）。
set -euo pipefail

W=/work
REPO=/repo/SteamOSforAlioth
IMG=$W/steamos-20261002.6232440/rootfs.img
TREE=$W/valve-tree
PAY=$W/raphael-payload
KOUT=$W/kernel-raphael/output/7.3.0-raphael-steamos
STAGE=$W/bootstage
ROOT_UUID=ee8d3593-59b1-480e-a3b6-4fefb17ee7d8

echo "===== 0/7 依赖 ====="
cat > /etc/yum.repos.d/fedora-wslc.repo <<EOF
[fedora]
baseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/\$releasever/Everything/\$basearch/os/
enabled=1
gpgcheck=0
EOF
timeout 300 dnf -q -y --disablerepo='*' --enablerepo=fedora \
  install btrfs-progs e2fsprogs mtools cpio gzip android-tools >/dev/null 2>&1
for c in btrfs mkfs.ext4 mcopy mdir cpio img2simg; do command -v "$c" >/dev/null || { echo "缺 $c"; exit 1; }; done
echo OK

echo "===== 1/7 抽出 Valve rootfs（离线，不挂载）====="
rm -rf "$TREE"; mkdir -p "$TREE"
btrfs restore -i -m -S -x "$IMG" "$TREE" 2>/dev/null || true
[ -e "$TREE/usr/bin/bash" ] || { echo "抽取失败：没有 /usr/bin/bash"; exit 1; }
echo "   $(du -sh "$TREE" | cut -f1) / $(find "$TREE" -type f | wc -l) 文件"
SB=$(find "$TREE/usr/lib/systemd/boot/efi" -name 'systemd-bootaa64.efi' -o -name 'systemd-bootaarch64.efi' 2>/dev/null | head -1)
[ -n "$SB" ] || { echo "Valve rootfs 里没有 systemd-bootaa64.efi"; find "$TREE/usr/lib/systemd" -name '*boot*efi' | head; exit 1; }
echo "   systemd-boot: $SB"

echo "===== 2/7 极简 initramfs ====="
IR=$W/ir-stage
rm -rf "$IR"; mkdir -p "$IR/bin" "$IR/lib/modules" "$IR/proc" "$IR/sys" "$IR/dev" "$IR/newroot" "$IR/mnt"
cp "$W/busybox-aarch64-static" "$IR/bin/busybox"
chmod 755 "$IR/bin/busybox"
for m in phy-qcom-qmp-ufs qcom_ice ufs-qcom; do
  f=$(find "$KOUT/modules" -name "$m.ko*" | head -1)
  [ -n "$f" ] && cp "$f" "$IR/lib/modules/" || { echo "缺模块 $m"; exit 1; }
done

# GPU 固件必须进 initramfs：msm DRM 在 0.96s probe，那一刻只有 initramfs 可见，
# 放在 rootfs 的 /usr/lib/firmware 来不及（实测 Direct firmware load ... -2）。
# zap-shader 的路径由 DTB 写死为 qcom/sm8150/Xiaomi/raphael/a640_zap.mbn，
# 所以要同时放 qcom/ 下和那个子目录里，.mdt/.bNN 是 qcom_mdt_load() 要的分段。
mkdir -p "$IR/lib/firmware/qcom/sm8150/Xiaomi/raphael"
FWSRC="$REPO/work/raphael-fw/vendor-firmware"
for f in a630_sqe.fw a640_gmu.bin; do
  [ -f "$FWSRC/$f" ] && cp "$FWSRC/$f" "$IR/lib/firmware/qcom/" ||
    echo "警告: 缺机内固件 $f（GPU 可能降级）"
done
for f in a640_zap.mbn a640_zap.mdt a640_zap.b00 a640_zap.b01 a640_zap.b02; do
  if [ -f "$PAY/usr/lib/firmware/qcom/$f" ]; then
    cp "$PAY/usr/lib/firmware/qcom/$f" "$IR/lib/firmware/qcom/"
    cp "$PAY/usr/lib/firmware/qcom/$f" "$IR/lib/firmware/qcom/sm8150/Xiaomi/raphael/"
  fi
done
cat > "$IR/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts

# UFS 是模块，先按依赖顺序装上，否则根本看不到 userdata
for m in /lib/modules/*; do
  [ -f "$m" ] || continue
  insmod "$m" 2>/dev/null && echo "insmod ${m##*/}"
done

CMDLINE="$(cat /proc/cmdline)"
ROOTARG=""; FSTYPE=""; FLAGS=""
for a in $CMDLINE; do
  case "$a" in
    root=*) ROOTARG="${a#root=}" ;;
    rootfstype=*) FSTYPE="${a#rootfstype=}" ;;
    rootflags=*) FLAGS="${a#rootflags=}" ;;
  esac
done
[ -n "$ROOTARG" ] || { echo "NO root= in cmdline"; exec /bin/busybox sh; }

resolve() {
  case "$1" in
    /dev/*) echo "$1" ;;
    UUID=*) /bin/busybox findfs "UUID=${1#UUID=}" 2>/dev/null ;;
    LABEL=*) /bin/busybox findfs "LABEL=${1#LABEL=}" 2>/dev/null ;;
    PARTUUID=*) /bin/busybox findfs "PARTUUID=${1#PARTUUID=}" 2>/dev/null ;;
    *) echo "$1" ;;
  esac
}
DEV=""; i=0
while [ $i -lt 40 ]; do
  DEV="$(resolve "$ROOTARG" | head -1)"
  [ -b "$DEV" ] && break
  /bin/busybox sleep 0.25; i=$((i+1))
done
echo "root device: $DEV"
[ -b "$DEV" ] || { echo "根设备没出现"; exec /bin/busybox sh; }
OPTS="rw"
[ -n "$FLAGS" ] && OPTS="$OPTS,$FLAGS"
# 两种布局都支持:
#   a) userdata 本身就是裸 ext4（走 cache 分区上的 ESP 引导）
#   b) userdata 里是嵌套 GPT，p2 从 LBA 67584 开始（U-Boot blkmap 0 方案）
# 先直接挂，失败就用 losetup 偏移挂 p2。
mount -t "${FSTYPE:-ext4}" -o "$OPTS" "$DEV" /newroot 2>/dev/null || {
  echo "裸 ext4 挂载失败，尝试嵌套 GPT 的 p2 (offset 276824064)"
  /bin/busybox losetup -o 276824064 /dev/loop0 "$DEV" 2>/dev/null || \
    /bin/busybox losetup -o 276824064 /dev/loop1 "$DEV" 2>/dev/null
  for L in /dev/loop0 /dev/loop1; do
    [ -b "$L" ] && mount -t "${FSTYPE:-ext4}" -o "$OPTS" "$L" /newroot 2>/dev/null && break
  done
}
[ -x /newroot/sbin/init ] || [ -x /newroot/usr/lib/systemd/systemd ] || { echo "挂载后仍没有 init"; exec /bin/busybox sh; }
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
mount --move /dev /newroot/dev
exec /bin/busybox switch_root /newroot /sbin/init
INIT
chmod 755 "$IR/init"
(cd "$IR" && find . | cpio -o -H newc --owner=0:0 2>/dev/null) > "$W/initramfs-raphael.cpio"
gzip -9 -n -c "$W/initramfs-raphael.cpio" > "$W/initramfs-raphael.img"
echo "   $(du -h "$W/initramfs-raphael.img" | cut -f1)"

echo "===== 3/7 cache 分区引导镜像 ====="
rm -rf "$STAGE"; mkdir -p "$STAGE/EFI/BOOT" "$STAGE/loader/entries" "$STAGE/dtbs/qcom"
cp "$SB" "$STAGE/EFI/BOOT/BOOTAA64.EFI"
cp "$KOUT/boot/Image" "$STAGE/linux.efi"
cp "$W/initramfs-raphael.img" "$STAGE/initramfs"
cp "$KOUT/dtbs/sm8150-xiaomi-raphael.dtb" "$STAGE/dtbs/qcom/"
cat > "$STAGE/loader/loader.conf" <<'EOF'
default steamos.conf
timeout 3
editor yes
console-mode keep
EOF
cat > "$STAGE/loader/entries/steamos.conf" <<EOF
title  SteamOS on raphael
linux  /linux.efi
initrd /initramfs
devicetree /dtbs/qcom/sm8150-xiaomi-raphael.dtb
options root=/dev/sda31 rootfstype=ext4 rw rootwait console=tty0 loglevel=7 ignore_loglevel
EOF
cat > "$STAGE/loader/entries/steamos-direct.conf" <<EOF
title  SteamOS on raphael - no initramfs (recovery)
linux  /linux.efi
devicetree /dtbs/qcom/sm8150-xiaomi-raphael.dtb
options root=/dev/sda31 rootfstype=ext4 rw rootwait console=tty0 loglevel=7
EOF
cp "$REPO/work/boot-fat.img" "$W/boot-cache.img"
# mtools 原地改写 FAT32（无需 root / loop）
mcopy -i "$W/boot-cache.img" -s "$STAGE/EFI" :: 2>/dev/null || { mmd -i "$W/boot-cache.img" ::EFI ::EFI/BOOT; mcopy -i "$W/boot-cache.img" -s "$STAGE/EFI" ::; }
mmd -i "$W/boot-cache.img" ::loader ::loader/entries ::dtbs ::dtbs/qcom 2>/dev/null || true
mcopy -i "$W/boot-cache.img" -o "$STAGE/loader/entries/steamos.conf" "$STAGE/loader/entries/steamos-direct.conf" ::loader/entries/
mcopy -i "$W/boot-cache.img" -o "$STAGE/loader/loader.conf" ::loader/
mcopy -i "$W/boot-cache.img" -o "$STAGE/linux.efi" "$STAGE/initramfs" ::
mcopy -i "$W/boot-cache.img" -o "$STAGE/dtbs/qcom/sm8150-xiaomi-raphael.dtb" ::dtbs/qcom/
echo "   FAT 内容:"; mdir -i "$W/boot-cache.img" ::/ | head -14
mkdir -p "$REPO/work/steamos-raphael"
cp "$W/boot-cache.img" "$REPO/work/steamos-raphael/boot-cache.img"

echo "===== 4/7 合并 payload 到 Valve rootfs 树 ====="
cp -a "$PAY"/. "$TREE"/
mkdir -p "$TREE/usr/lib/modules"
cp -a "$KOUT/modules/7.3.0-raphael-steamos" "$TREE/usr/lib/modules/"

# 4.5/7 raphael 系统配置（可复现，全部在 git 里，不依赖 work/ 里的手工产物）。
# 关键：gadget 的 enable 链接必须落在 sysinit.target.wants —— multi-user.target
# 会被 dev-zram0.device 之类的 job 拖住，挂在那边的服务永远不会执行，系统起来
# 之后电脑上就一个串口都看不到。
if [ -d "$REPO/scripts/raphael-overlay" ]; then
  # git 在 Windows 上会把这些文件 checkout 成 CRLF；unit 里的 CR 会让 systemd
  # 解析失败，gadget.sh 的 shebang 带 CR 更是直接起不来。逐文件去 CR。
  OV="$REPO/scripts/raphael-overlay"
  (cd "$OV" && find . -type f | while read -r rel; do
     mkdir -p "$TREE/$(dirname "$rel")"
     tr -d '\r' < "$OV/$rel" > "$TREE/$rel"
   done)
  chmod 755 "$TREE/opt/raphael/gadget.sh" 2>/dev/null || true
  chmod 755 "$TREE/opt/raphael/qcom-setup.sh" 2>/dev/null || true
  mkdir -p "$TREE/etc/systemd/system/sysinit.target.wants"
  ln -sf /etc/systemd/system/raphael-usb-gadget.service \
    "$TREE/etc/systemd/system/sysinit.target.wants/raphael-usb-gadget.service"

  # Qualcomm 用户态三件套（qrtr-ns / rmtfs / tqftpserv）+ 启动 modem。
  # 没有它们 modem 每 40s 崩一次、ath10k 的 QMI WLFW 永远等不到，WiFi 起不来。
  # 二进制来自 Debian arm64 包（scripts/fetch-raphael-qcom-tools.sh 下到
  # work/qcom-tools/stage），这里只负责摆位、给执行位、建 enable 链接。
  if [ -d "$REPO/work/qcom-tools/stage" ]; then
    mkdir -p "$TREE/opt/raphael/qcom"
    cp -a "$REPO/work/qcom-tools/stage/." "$TREE/opt/raphael/qcom/"
    chmod 755 "$TREE/opt/raphael/qcom/bin/"* 2>/dev/null || true
    mkdir -p "$TREE/usr/lib"
    cp -f "$TREE/opt/raphael/qcom/lib/libqrtr.so.1" "$TREE/usr/lib/" 2>/dev/null || true
    mkdir -p "$TREE/etc/systemd/system/multi-user.target.wants"
    for u in raphael-qrtr-ns raphael-rmtfs raphael-tqftpserv raphael-modem raphael-usb-net; do
      [ -f "$TREE/usr/lib/systemd/system/$u.service" ] &&
        ln -sf "/etc/systemd/system/$u.service" \
          "$TREE/etc/systemd/system/multi-user.target.wants/$u.service"
    done
    echo "   qcom tools: $(ls "$TREE/opt/raphael/qcom/bin" | tr '\n' ' ')"
  else
    echo "   提示: work/qcom-tools/stage 不存在，WiFi 依赖的三个守护进程不会装"
  fi

  # 首次开机扩根（照 alioth-firstboot）。哨兵必须由镜像带进来 ——
  # 脚本只删不建，没有它 resize2fs 永远不会跑，Steam 会撞上一个 12 GiB 的根。
  chmod 755 "$TREE/usr/lib/steamos-arm/raphael-firstboot" 2>/dev/null || true
  mkdir -p "$TREE/var/lib"
  touch "$TREE/var/lib/raphael-firstboot-pending"
  ln -sf /etc/systemd/system/raphael-firstboot.service \
    "$TREE/etc/systemd/system/sysinit.target.wants/raphael-firstboot.service"
  echo "   overlay: $(find "$REPO/scripts/raphael-overlay" -type f | wc -l) 个文件"
fi

# Valve 的 /usr/lib/systemd/system/{efi,esp,home}.mount 是静态 unit，不读 fstab，
# 而且 generator 目录的优先级高于 /etc 里的 mask —— 光改 fstab 或 systemctl mask
# 都压不住。直接从树里删掉，才能让 graphical.target 不被 device job 拖死。
rm -f "$TREE/usr/lib/systemd/system/efi.mount" \
      "$TREE/usr/lib/systemd/system/esp.mount" \
      "$TREE/usr/lib/systemd/system/home.mount"

# 同样的 GPU 固件在 rootfs 里也放一份（systemd 起来后重新 probe / 用户态查询用）。
FWDIR="$TREE/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael"
mkdir -p "$FWDIR"
cp -a "$TREE/usr/lib/firmware/qcom"/a640_zap.* "$FWDIR/" 2>/dev/null || true
for f in a630_sqe.fw a640_gmu.bin; do
  [ -f "$FWSRC/$f" ] && cp "$FWSRC/$f" "$TREE/usr/lib/firmware/qcom/"
done

# --- 机内签名固件：ADSP / modem / SLPI / IPA --------------------------------
# DTB 把 remoteproc 的 firmware-name 写死成 qcom/<soc>/<vendor>/<model>/xxx.mbn，
# 少一级目录就是 request_firmware -2（GPU zap 和 ADSP 都这么踩过：文件其实在
# qcom/adsp.mbn，内核却去 qcom/sm8150/Xiaomi/raphael/ 找）。
#
# ADSP 是音频的前置：它不起来，q6asm-dai 不注册，声卡就卡在
#   sound: deferred probe pending: msm-snd-sm8150: MultiMedia1: error getting cpu dai name
# 把 adsp.mbn 放到正确路径后，ADSP 自动起来、声卡注册成
#   card 0: sm8150 - Xiaomi Redmi K20 Pro（真机实测，2026-11-08）。
#
# modem.mbn 是 WiFi 的前置（ath10k_snoc 通过 QMI WLFW 找 modem 的 wlan 服务）；
# SLPI 管传感器、IPA 管移动数据，都按同一套布局装。
SQUASH="$REPO/scripts/squash-raphael-mdt.py"
squash_into() { # $1=源目录 $2=分段名 $3=目标名
  local src="$PAY_FW/$1" out="$FWDIR/$3"
  [ -f "$src.mdt" ] || return 0
  [ -f "$out" ] && return 0
  python3 "$SQUASH" "$src.mdt" "$out" >/dev/null 2>&1 &&
    echo "   $(basename "$out") $(( $(stat -c%s "$out") / 1048576 )) MiB" ||
    echo "   警告: 拼装 $3 失败"
}
PAY_FW="$REPO/work/raphael-fw"
[ -f "$PAY/usr/lib/firmware/qcom/adsp.mbn" ] && cp "$PAY/usr/lib/firmware/qcom/adsp.mbn" "$FWDIR/"
squash_into modem-image/modem   x modem.mbn
squash_into modem-image/slpi_rp x slpi_rp.mbn
squash_into vendor-firmware/ipa_fws x ipa_fws.mbn
# ADSP/SLPI 运行时要的校准注册文件，和镜像放一起（内核按 firmware-name 的目录解析）
for j in adspr.jsn adspua.jsn slpir.jsn slpius.jsn; do
  [ -f "$PAY_FW/modem-image/$j" ] && cp "$PAY_FW/modem-image/$j" "$FWDIR/"
done

# --- 无线固件（linux-firmware，可再分发）-----------------------------------
# WCN3990 的 BT 走 qca/，WiFi 走 ath10k/WCN3990/hw1.0/。这两个不在机内分区里
# （Android 是让 modem 通过 tqftpserv 从 vendor 分区取的），所以用通用版本。
# 由 scripts/fetch-raphael-firmware-ext.sh 下到 work/fw-ext/。
if [ -d "$REPO/work/fw-ext" ]; then
  cp -a "$REPO/work/fw-ext/." "$TREE/usr/lib/firmware/"
  # 必须删掉 Android 那份 26 KB 的 board.bin：它是单板 legacy 格式，没有 5G 的
  # 分信道功率/校准表，ath10k 一旦回落到它，2.4G 能连、5G 认证帧发出去没回应
  # （2026-11-08 实测：改名回 board-2.bin 后 5180 MHz 立刻可连）。
  # 固件加载器是 board-2.bin 优先、找不到匹配才退 board.bin，留着就是定时炸弹。
  rm -f "$TREE/usr/lib/firmware/ath10k/WCN3990/hw1.0/board.bin"
  echo "   无线固件: $(find "$REPO/work/fw-ext" -type f | wc -l) 个"
else
  echo "   警告: work/fw-ext 不存在，蓝牙/WiFi 固件不会装（跑 fetch-raphael-firmware-ext.sh）"
fi
# /boot 挂 cache（与参考仓库同一条），nofail 避免挂不上拖进 emergency
mkdir -p "$TREE/boot"
grep -q 'PARTLABEL=cache' "$TREE/etc/fstab" 2>/dev/null || \
  echo 'PARTLABEL=cache /boot vfat umask=0077,nofail,noatime,x-systemd.device-timeout=10 0 0' >> "$TREE/etc/fstab"

# ===== 4.6/7 去 VR 化（照 alioth，2026-11-07 在 raphael 真机跑通 Game Mode）=====
# Frame 是 VR 头显：gamescope 默认 --backend openvr --vr-session-manager，
# SteamVR 不在就立刻退，sddm 无限重登 → 全程黑屏。详见 apply-raphael-devr.sh。
# 脚本自身也会被 git checkout 成 CRLF，先去 CR；RAPHAEL_REPO 让它仍找得到
# 仓库里的 steamos-overlay/（脚本被放到容器卷里执行）。
tr -d '\r' < "$REPO/scripts/apply-raphael-devr.sh" > "$W/apply-raphael-devr.lf.sh"
RAPHAEL_REPO="$REPO" bash "$W/apply-raphael-devr.lf.sh" "$TREE"
echo "   $(du -sh "$TREE" | cut -f1)"

echo "===== 5/7 mkfs.ext4 -d（可写根，固定 UUID）====="
truncate -s 12G "$W/rootfs-ext4.img"
mkfs.ext4 -q -F -L steamos -U "$ROOT_UUID" -b 4096 -d "$TREE" "$W/rootfs-ext4.img"
echo "   $(du -h "$W/rootfs-ext4.img" | cut -f1)"

echo "===== 6/7 img2simg ====="
img2simg "$W/rootfs-ext4.img" "$W/rootfs-ext4-sparse.img" 4096
ls -lh "$W/rootfs-ext4-sparse.img"

echo "===== 7/7 拷回 Windows ====="
cp "$W/rootfs-ext4-sparse.img" "$REPO/work/steamos-raphael/rootfs-ext4-sparse.img"
sha256sum "$W/boot-cache.img" "$REPO/work/steamos-raphael/boot-cache.img" | cut -c1-72
echo ALL-DONE
