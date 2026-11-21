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

# 5. the image. Content plus slack; never smaller than 2 GiB even for an
#    empty tree, because ext4 needs room for its own metadata.
used_mib="$(du -sm "${R}" | cut -f1)"
if [[ $SIZE_MIB == 0 ]]; then
  SIZE_MIB=$(( used_mib + 1024 ))
  (( SIZE_MIB < 3072 )) && SIZE_MIB=3072
fi
say "内容 ${used_mib} MiB，镜像 ${SIZE_MIB} MiB"
mkdir -p "$OUT"
rm -f "$IMG"
truncate -s "${SIZE_MIB}M" "$IMG"

# -d populates without mounting. -m 1 keeps 1% for root. The label is what
# the initramfs and the recovery instructions both refer to.
mkfs.ext4 -q -F -L steamos -U "$ROOT_UUID" -m 1 -d "$R" "$IMG"
e2fsck -f -y "$IMG" >/dev/null 2>&1 || true

say "写出 ${IMG}"
ls -l "$IMG"
say "用户数据分区会被整个覆盖：Android 的 /data 就此消失（super 与 abl 不动）"
