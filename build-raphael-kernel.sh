#!/usr/bin/env bash
# 构建 raphael（SM8150）的内核。
#
# 与 build-alioth-kernel.sh 的三处差别，都是结构性的，不是风格：
#
#  1. **不校验 ROCKNIX 检出**。raphael 的内核来自它自己的树（kernel-sm8150/soc.env
#     的 KSRC_URL，按 commit 固定），板级文件、config、DTS 全在那棵树里，
#     没有一样来自 ROCKNIX。kernel-common/build.sh 在 OWN_KERNEL_TREE=1 时也
#     不再要求它 —— 要求一个构建根本不读的树，只会让人以为它很重要。
#  2. **仍然要 aarch64 静态 busybox**，理由和 alioth 一样：build-gcc15.sh 只检查
#     "statically linked"，不检查架构，x86_64 的静态 busybox 能过检查却产出一个
#     设备执行不了的 initramfs，表现是黑屏且调试 shell 起不来 —— 而调试 shell
#     是阶段 1 唯一的观测手段。
#  3. **容器运行时仍然要确认守护进程连得上**。`command -v docker` 成功但
#     `docker info` 失败时，错误会发生在深得多的地方，且信息与真正的原因无关。
#
# 产物：work/kernel-raphael/output/current/{boot/Image, dtbs/, modules/}。
# 下一个脚本 make-steamos-raphael.sh 用 Image + dtbs/sm8150-xiaomi-raphael.dtb
# 打 boot.img。
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export MOUNT="${MOUNT:-$(dirname "$PORT_ROOT")}"
export WORK="${WORK:-$PORT_ROOT/work/kernel-raphael}"
export BUSYBOX="${BUSYBOX:-$PORT_ROOT/work/busybox-aarch64-static}"

if [[ -z "${DOCKER:-}" ]]; then
  if command -v podman >/dev/null; then DOCKER=podman
  elif command -v docker >/dev/null; then DOCKER=docker
  else DOCKER=podman; fi
fi
export DOCKER

die() { echo "build-raphael-kernel: $*" >&2; exit 1; }

[[ -x "$BUSYBOX" ]] || die "没有 busybox: $BUSYBOX
  要一个 aarch64 的静态 busybox（它进 initramfs）。取法见 docs/alioth.md 的「前置依赖」，
  和 alioth 用的是同一个，放到 work/busybox-aarch64-static。"

bb_desc=$(file -b "$BUSYBOX")
case "$bb_desc" in
  *"ARM aarch64"*) ;;
  *) die "busybox 不是 aarch64：$bb_desc" ;;
esac
case "$bb_desc" in
  *"statically linked"*) ;;
  *) die "busybox 不是静态链接：$bb_desc" ;;
esac

for p in "$PORT_ROOT" "$WORK"; do
  [[ "$p" == "$MOUNT"/* ]] || die "$p 不在 MOUNT=$MOUNT 之下（build-gcc15.sh 只挂 MOUNT）"
done

command -v "$DOCKER" >/dev/null || die "没有容器运行时 '$DOCKER'"
mkdir -p "$WORK"
SUDO_DOCKER=0
if ! "$DOCKER" info >/dev/null 2>&1; then
  if [[ "$DOCKER" == docker ]] && sudo -n docker info >/dev/null 2>&1; then
    # 上游 exec 的是带引号的 "$DOCKER"，所以 DOCKER='sudo docker' 会被当成一个
    # 叫 "sudo docker" 的二进制去找。放一个 shim 在 PATH 最前面的做法原样保留。
    shim="$WORK/.shim"
    mkdir -p "$shim"
    printf '#!/bin/sh\nexec sudo -n docker "$@"\n' > "$shim/docker"
    chmod +x "$shim/docker"
    export PATH="$shim:$PATH"
    SUDO_DOCKER=1
  else
    die "'$DOCKER info' 失败 —— 守护进程没启动，或当前用户不在 docker 组"
  fi
fi

echo "build-raphael-kernel: MOUNT=$MOUNT"
echo "build-raphael-kernel: WORK=$WORK"
echo "build-raphael-kernel: BUSYBOX=$BUSYBOX ($bb_desc)"
echo "build-raphael-kernel: DOCKER=$DOCKER$([[ $SUDO_DOCKER == 1 ]] && echo ' (经 sudo shim)')"

# rootful docker 下容器内的 root 就是宿主 root，产物会归 root，之后普通用户
# 跑 fdtget / mkbootimg / git add 全会失败。无论成败都把 WORK 交回来。
status=0
bash "$PORT_ROOT/external-and-mods/kernel-common/build-gcc15.sh" sm8150 "$@" || status=$?
if [[ $SUDO_DOCKER == 1 ]]; then
  sudo -n chown -R "$(id -u):$(id -g)" "$WORK" || echo "build-raphael-kernel: 警告 —— chown $WORK 失败" >&2
fi
exit $status
