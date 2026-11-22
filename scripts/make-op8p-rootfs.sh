#!/usr/bin/env bash
# Build work/steamos-op8p/userdata.img: an ext4 tree of SteamOS that grows to
# the whole userdata partition on first boot.
#
# Split from make-op8p.sh because this needs e2fsprogs and a few hundred MB
# of scratch: it runs inside the build container, the same way the kernel
# does. make-op8p.sh --install is the entry point.
#
# What it does NOT do, on purpose:
#   * no loop mount. This container has no CAP_SYS_ADMIN, so the image is
#     populated with `mke2fs -d`, which walks the tree without mounting it.
#     It keeps uid/gid/mode/symlinks/hardlinks but **not xattr**, so
#     security.capability is lost -- setcap programs (ping, some gamescope
#     helpers) will start without their caps. Fix later with a first-boot
#     unit that re-applies the few that matter.
#   * no bootloader work. The kernel is already on boot_a; this image only
#     becomes / because the cmdline says root=PARTLABEL=userdata.
#
# Usage (inside the container):
#   scripts/make-op8p-rootfs.sh [--size-mib N] [--skip-copy]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${STEAMOS_WORK:-${ROOT}/work}"
SRC="${STEAMOS_SRC_ROOTFS:-${WORK}/rootfs}"
R="${STEAMOS_ROOTFS:-${WORK}/rootfs-op8p}"
KOUT="${KERNEL_OUT:-${WORK}/kernel-sm8250/output/current}"
OUT="${WORK}/steamos-op8p"
IMG="${OUT}/userdata.img"

SIZE_MIB=0
SKIP_COPY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size-mib) SIZE_MIB="$2"; shift ;;
    --skip-copy) SKIP_COPY=1 ;;
    *) echo "make-op8p-rootfs: 不认识的参数 $1" >&2; exit 1 ;;
  esac
  shift
done

die() { echo "make-op8p-rootfs: $*" >&2; exit 1; }
say() { echo "make-op8p-rootfs: $*" >&2; }

for c in rsync mkfs.ext4 e2fsck uuidgen du; do
  command -v "$c" >/dev/null || die "缺少 $c"
done

# 1. copy the shared SteamOS tree. The source is never modified.
if [[ $SKIP_COPY == 0 ]]; then
  [[ -x "${SRC}/usr/bin/bash" ]] || die "没有源 rootfs ${SRC} —— 先跑 scripts/fetch-steamos-rootfs.sh"
  say "复制 rootfs ${SRC} → ${R}"
  mkdir -p "$R"
  rsync -aHAX --numeric-ids --delete --exclude=/proc --exclude=/sys \
        --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/var/tmp \
        "${SRC}/" "${R}/"
else
  [[ -x "${R}/usr/bin/bash" ]] || die "--skip-copy 但 ${R} 里没有 rootfs"
fi

# 2. overlays. steamos-overlay is device-independent (inputplumber, sdl2,
#    wireplumber); op8p-overlay is ours and may not exist yet.
for o in steamos-overlay op8p-overlay; do
  [[ -d "${ROOT}/${o}" ]] || continue
  say "overlay ${o}"
  rsync -aHAX --numeric-ids "${ROOT}/${o}/" "${R}/"
done

# systemd 的 wants 链接：工作区在 Windows 上，建不了 symlink（overlay 里
# 那个链接是空的），所以在容器里补。串口 getty 是这台机器唯一的无依赖
# 调试口 —— 屏幕和网络都还没验证的时候，必须能登进去。
mkdir -p "${R}/usr/lib/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
  "${R}/usr/lib/systemd/system/multi-user.target.wants/serial-getty@ttyGS0.service"
# 首启扩根：同样的理由在容器里建链接（overlay 在 Windows 上建不出 symlink）。
mkdir -p "${R}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/op8p-firstboot.service \
  "${R}/etc/systemd/system/sysinit.target.wants/op8p-firstboot.service"
chmod 755 "${R}/usr/lib/steamos-arm/op8p-firstboot"

# DSP 固件：机内签名的那三份（adsp/cdsp/slpi）不可再分发，镜像里一份都不放，
# 由 op8p-dsp-firmware 在开机时从 modem_a 现取 —— 和 Nura、alioth 一个思路。
# squash 脚本只有一份，宿主和设备共用 scripts/ 里那个。
cp "${ROOT}/scripts/squash-qcom-mdt.py" \
  "${R}/usr/lib/steamos-arm/squash-qcom-mdt.py"
chmod 755 "${R}/usr/lib/steamos-arm/op8p-dsp-firmware"
mkdir -p "${R}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/op8p-dsp-firmware.service \
  "${R}/etc/systemd/system/multi-user.target.wants/op8p-dsp-firmware.service"

# 首启解压 Steam 客户端：镜像自带 /usr/lib/steam/steam.tar.zst，但没有任何
# 东西去解它。不解的话 steam.service 的 ExecStartPre（往 ~/.local/share/Steam
# 拷 RUNSTEAM.sh）直接失败，gamescope 没有可合成的客户端，屏幕停在 fbcon 的黑帧。
mkdir -p "${R}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/op8p-steam-client.service \
  "${R}/etc/systemd/system/sysinit.target.wants/op8p-steam-client.service"
chmod 755 "${R}/usr/lib/steamos-arm/op8p-steam-client"

# SteamOS 的 /home 是独立分区（/dev/disk/by-partsets/shared/home），这里的
# userdata 没有那个 partset。不屏蔽的话 home.mount 永远起不来，pam_systemd
# 每次登录都卡到 90 秒超时（"Failed to create session: Connection timed out"），
# 图形会话根本拉不起来。/home 本来就在根分区上，屏蔽即可。
mkdir -p "${R}/etc/systemd/system"
ln -sf /dev/null "${R}/etc/systemd/system/home.mount"

# 没有 VR 硬件，steamvr.service 在 RUNSTEAM.sh 建好 ~/.steam/sdkarm64 之前就
# dlopen steamclient.so，注定失败。只 mask 不行：Wants= 指向 masked unit 会让
# steam.service 以 "result 'dependency'" 失败。真正的修复在
# op8p-overlay/etc/systemd/user/steam.service.d/99-no-steamvr.conf（清空
# Wants=/After=），mask 只是防止别的东西把它拉起来。
mkdir -p "${R}/etc/systemd/user"
ln -sf /dev/null "${R}/etc/systemd/user/steamvr.service"

# NetworkManager 只加载 600 的连接配置，别的权限它直接忽略（不报错）。
NM="${R}/etc/NetworkManager/system-connections/usb0.nmconnection"
[[ -f "$NM" ]] && chmod 600 "$NM"

# 3. kernel modules and firmware. Both are =m/=y mixtures: without the
#    modules the phone boots to a shell with no display server, no audio.
[[ -d "${KOUT}/modules/7.2.8-sm8250-steamos" ]] || die "没有已编译的模块（先构建内核）"
say "模块 → /lib/modules"
mkdir -p "${R}/lib/modules"
rsync -aHAX --numeric-ids --delete \
      "${KOUT}/modules/7.2.8-sm8250-steamos/" \
      "${R}/lib/modules/7.2.8-sm8250-steamos/"

if [[ -d "${KOUT}/firmware" ]]; then
  say "固件 → /lib/firmware"
  mkdir -p "${R}/lib/firmware"
  rsync -aHAX --numeric-ids "${KOUT}/firmware/" "${R}/lib/firmware/"
fi

# 4. fstab. root itself comes from the cmdline, but fstab gives root the
#    growfs flag: the image only holds the content plus slack, and the
#    first boot expands the filesystem to the whole 112 GiB partition.
#    Not a mount unit -- systemd-fsck@root needs an fstab entry to exist.
ROOT_UUID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
say "root UUID ${ROOT_UUID}"
cat >"${R}/etc/fstab" <<EOF
# SteamOS ARM (sm8250, OnePlus 8 Pro)：userdata 上的一个 ext4 就是 /
# 首启靠 x-systemd.growfs 长到整个分区；fsck 用 UUID 找设备。
UUID=${ROOT_UUID}  /  ext4  defaults,noatime,commit=30,x-systemd.growfs  0 1
EOF

# SteamOS 的 /etc 是 overlayfs（lower 在只读的 /usr，upper 在
# /var/lib/overlays/etc）。upper 里如果本来就有一份 fstab，它会盖住我们刚
# 写的那份，首启就找不到根 —— alioth 的镜像两处都写，这里照做。
mkdir -p "${R}/var/lib/overlays/etc/upper"
cp -a "${R}/etc/fstab" "${R}/var/lib/overlays/etc/upper/fstab"

# 每台机器要有自己的 D-Bus / 网络身份：不清空的话所有刷了这份镜像的机器
# 是同一个 machine-id。alioth 的镜像也做这一步。
: >"${R}/etc/machine-id"
[[ -f "${R}/var/lib/overlays/etc/upper/machine-id" ]] \
  && : >"${R}/var/lib/overlays/etc/upper/machine-id"

# 首启哨兵：op8p-firstboot.service 见不到它就什么都不做。放在镜像里而不是
# 首启时创建 —— 中断（掉电、SIGKILL）必须落在「哨兵还在」，下次开机重来。
mkdir -p "${R}/var/lib"
touch "${R}/var/lib/op8p-firstboot-pending"

# 5. the image. 尺寸照 11-07 raphael 那次成功的配方：内容约 9.5 GiB，固定
#    12 GiB（余量约 2.7 GiB）。mkfs.ext4 -d 在灌数据阶段还要写 journal 和
#    目录块，余量给足就没有"跑到 98% 报 No space left"这种收尾失败。
used_mib="$(du -sm "${R}" | cut -f1)"
if [[ $SIZE_MIB == 0 ]]; then
  SIZE_MIB=12288
  # 内容涨到 3/4 以上时警告：那时候 12 GiB 的余量已经不够，别再硬灌。
  if (( used_mib > 9216 )); then
    say "警告：内容 ${used_mib} MiB，已超过 12 GiB 镜像的 3/4，请用 --size-mib 调大"
  fi
fi
say "内容 ${used_mib} MiB，镜像 ${SIZE_MIB} MiB"
mkdir -p "$OUT"
rm -f "$IMG"
truncate -s "${SIZE_MIB}M" "$IMG"

# -d populates without mounting. -b 4096 显式给（raphael 那次也是显式给的）。
# -m 1 keeps 1% for root. The label is what the initramfs and the recovery
# instructions both refer to.
mkfs.ext4 -q -F -L steamos -U "$ROOT_UUID" -b 4096 -m 1 -d "$R" "$IMG"
e2fsck -f -y "$IMG" >/dev/null 2>&1 || true

say "写出 ${IMG}"
ls -l "$IMG"
say "用户数据分区会被整个覆盖：Android 的 /data 就此消失（super 与 abl 不动）"
