#!/usr/bin/env bash
# Build the OnePlus 8 Pro (instantnoodlep) kernel **inside** the container.
#
# Host entry point: scripts/op8p-build-docker.sh. Paths here are the
# container's: the repository is at /repo (bind mount), and everything the
# build writes lives in /work (a docker volume, so it survives between runs
# and stays off the host filesystem).
#
# The real build entry point is still external-and-mods/kernel-common/build.sh;
# this file is machine glue only. Its predecessor is work/wslc-op8p-build.sh
# (Windows + wslc, kept for that box). What changed for this one:
#
#  1. **Architecture.** colima on an Apple-silicon host is aarch64, and the
#     fedora:43 image is pulled as arm64 — so this is a *native* aarch64
#     build and build.sh must not be given CROSS_COMPILE (it would then look
#     for aarch64-linux-gnu-gcc that has no reason to exist). On an x86_64
#     host the cross toolchain branch is still there.
#  2. **Package list is per-architecture.** Fedora's aarch64 repos do not
#     carry gcc-aarch64-linux-gnu — the same-named package only exists for
#     the architectures it cross-compiles *from*.
#  3. **The source is still copied out of /repo** before patching. Not
#     because of drvfs anymore (macOS bind mounts are virtiofs, cheap enough)
#     but because build.sh applies ~200 patches in place, and a source tree
#     that is also a git checkout invites `git status` noise and accidental
#     commits of patched kernel code. Only output/ is copied back.
#  4. **CRLF stripping stays.** The tree is clean LF right now, so it is a
#     no-op; it is kept because the failure it prevents (`#!/bin/sh\r`,
#     patches that match nothing) produces error messages very far from the
#     cause, and this repo has been moved between Windows and macOS once
#     already (docs/op8p/MIGRATION.md).
#  5. **Fixed mirror, bounded dnf.** A sick mirror hangs dnf rather than
#     failing it, so every install has a timeout and retries.
#
# Usage (normally via the host script):
#   docker run --rm --dns 223.5.5.5 \
#     -v /path/to/SteamOSforAlioth:/repo -v op8p-build-work:/work \
#     fedora:43 bash /repo/scripts/op8p-build-container.sh
#
# The first run downloads linux-7.2.8.tar.xz (~140 MB), extra-firmware,
# wireless-regdb and a handful of linux-firmware files into /work/.../cache;
# later runs reuse them. Everything the build needs from the host tree:
#   work/rocknix-20261001/   sparse checkout of ROCKNIX@20261001 (with .git,
#                            build.sh verifies the pinned revision)
set -euo pipefail

REPO=/repo
WORK="${WORK:-/work/kernel-sm8250}"
REPO_WORK=/repo/work/kernel-sm8250
SRC=/work/src
ROCKNIX="$REPO/work/rocknix-20261001"

HOST_ARCH="$(uname -m)"
echo "== 环境 =="
echo "   容器架构 $HOST_ARCH，内核 $(uname -r)"
echo "   产物目录 $WORK，仓库 $REPO"

echo "== 前置检查 =="
[[ -d "$REPO/external-and-mods/kernel-sm8250" ]] \
  || { echo "   !! /repo 不像这个仓库（缺 external-and-mods/kernel-sm8250）" >&2; exit 1; }
[[ -d "$ROCKNIX/.git" ]] \
  || { echo "   !! 缺 work/rocknix-20261001 的 git 元数据；build.sh 校验不了固定版本" >&2; exit 1; }
# 这里只查目录是否存在：git 是下面 dnf 装的，每个 --rm 容器都是全新的，
# 在装好之前调 git 会得到 "command not found"（第一版就把它印成了 "ROCKNIX ?"）。
# 版本号在装完 git 之后打。

echo "== DNS =="
echo 'nameserver 223.5.5.5' > /etc/resolv.conf
timeout 10 getent hosts mirrors.tuna.tsinghua.edu.cn >/dev/null \
  || echo "   !! 解析不了清华源，下面的 dnf 会失败" >&2

echo "== 依赖 =="
rm -f /etc/yum.repos.d/*.repo
cat > /etc/yum.repos.d/fedora-build.repo <<'EOF'
[fedora]
name=Fedora $releasever - $basearch
baseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/$releasever/Everything/$basearch/os/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[updates]
name=Fedora $releasever - $basearch - Updates
baseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora/updates/$releasever/Everything/$basearch/
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF

# Base set: identical for both architectures. pahole (dwarves) is needed for
# BTF, elfutils-libelf-devel provides gelf.h (build.sh checks for it).
PKGS="file gcc binutils make bc bison flex python3 curl tar xz gzip zstd cpio
  kmod patch perl rsync openssl-devel elfutils-libelf-devel dwarves
  diffutils findutils hostname which git"
CROSS=0
if [[ "$HOST_ARCH" != aarch64 ]]; then
  # Cross-compiling from x86_64: the aarch64 toolchain packages exist there.
  PKGS="$PKGS gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"
  CROSS=1
fi

ok=0
for try in 1 2 3 4; do
  # shellcheck disable=SC2086
  if timeout 600 dnf -q -y --disablerepo='*' --enablerepo=fedora,updates \
       --setopt=timeout=20 --setopt=retries=2 --setopt=install_weak_deps=False \
       install $PKGS; then ok=1; break; fi
  echo "   dnf 第 $try 次失败/超时，重试" >&2
  rm -rf /var/cache/dnf/* 2>/dev/null || true
done
[[ "$ok" == 1 ]] || { echo "依赖装不上，放弃" >&2; exit 1; }

# build.sh 内部还有几处 git 调用（rev-parse 校验固定版本），让 git 认这棵树：
# bind mount 的属主不是 root，不声明 safe.directory 时 git 以
# "dubious ownership" 拒绝，而 build.sh 会把拒绝读成
# "ROCKNIX checkout does not match pinned 20261001"（一句非常误导的错误）。
git config --global --add safe.directory "$REPO"
git config --global --add safe.directory "$ROCKNIX"
echo "   ROCKNIX $(git -C "$ROCKNIX" describe --tags 2>/dev/null \
  || git -C "$ROCKNIX" rev-parse --short HEAD 2>/dev/null || echo '?')"

if [[ "$CROSS" == 1 ]]; then
  command -v aarch64-linux-gnu-gcc >/dev/null || { echo "交叉编译器没装上" >&2; exit 1; }
  echo "   交叉编译：aarch64-linux-gnu-gcc $(aarch64-linux-gnu-gcc -dumpversion)"
else
  # Native: build.sh only needs a working gcc; do not hand it CROSS_COMPILE.
  echo "   原生编译：gcc $(gcc -dumpversion) ($HOST_ARCH)"
fi

echo "== aarch64 静态 busybox =="
# It never runs during the build — it is copied into the initramfs as a file
# (build.sh: cp /bin/busybox $WORK/initramfs/root/bin/busybox). build.sh does
# insist that it is statically linked.
mkdir -p /work
if [[ ! -x /work/busybox-aarch64-static ]]; then
  mkdir -p /tmp/bb && cd /tmp/bb
  curl -fsLO --retry 3 https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/busybox-static-1.37.0-r20.apk
  tar -xzf busybox-static-1.37.0-r20.apk 2>/dev/null
  cp bin/busybox.static /work/busybox-aarch64-static
  chmod +x /work/busybox-aarch64-static
fi
desc="$(file -b /work/busybox-aarch64-static)"
echo "   $desc"
case "$desc" in
  *"ARM aarch64"*) ;;
  *) echo "busybox 不是 aarch64" >&2; exit 1 ;;
esac
case "$desc" in
  *"statically linked"*) ;;
  *) echo "busybox 不是静态链接" >&2; exit 1 ;;
esac
install -m0755 /work/busybox-aarch64-static /bin/busybox

echo "== 拷源码并去掉 CRLF =="
rm -rf "$SRC"
mkdir -p "$SRC"
cp -a "$REPO/external-and-mods" "$SRC/"
find "$SRC" -type f \( -name '*.sh' -o -name '*.patch' -o -name '*.config' \
     -o -name 'soc.env' -o -name '*.dts' -o -name '*.dtsi' -o -name '*.append' \) \
     -exec sed -i 's/\r$//' {} +
# 无扩展名的可执行文件（initramfs/init 等）同样是 Linux 直接执行的。
for f in "$SRC"/external-and-mods/kernel-common/initramfs/init \
         "$SRC"/external-and-mods/kernel-common/initramfs/bootdebug \
         "$SRC"/external-and-mods/kernel-common/initramfs/konkr-update-recover; do
  [[ -f "$f" ]] && sed -i 's/\r$//' "$f"
done
echo "   $(find "$SRC" -name '*.patch' | wc -l) 个补丁、$(find "$SRC" -name '*.dts' | wc -l) 个 dts 已转换"

echo "== 缓存 =="
mkdir -p "$WORK/cache"
# build.sh 的 fetch() 见到同名非空文件就不再下。宿主机上 work/cache 里已经有的
# 整目录搬进来（历史原因：GitHub archive 会在大文件 70% 处被 HTTP/2 CANCEL）。
if [[ -d "$REPO/work/cache" ]]; then
  cp -a "$REPO/work/cache/." "$WORK/cache/" 2>/dev/null || true
fi
echo "   已有：$(ls "$WORK/cache" 2>/dev/null | tr '\n' ' ')"

echo "== 构建 =="
cd "$SRC"
env_args=(ARCH=arm64 "WORK=$WORK" "ROCKNIX_DIR=$ROCKNIX" "JOBS=$(nproc)")
if [[ "$CROSS" == 1 ]]; then
  env_args+=("CROSS_COMPILE=aarch64-linux-gnu-")
fi
env "${env_args[@]}" bash external-and-mods/kernel-common/build.sh sm8250

echo "== 产物带回来 =="
mkdir -p "$REPO_WORK"
rm -rf "$REPO_WORK/output"
# cp -a keeps output/current as the symlink build.sh creates (ln -sfn), so
# assert-op8p-stage2.sh finds the products instead of an empty directory.
cp -a "$WORK/output" "$REPO_WORK/output"
du -sh "$REPO_WORK/output"
ls -l "$REPO_WORK/output/current/boot/" 2>/dev/null || true
