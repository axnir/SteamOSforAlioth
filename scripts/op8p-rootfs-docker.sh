#!/usr/bin/env bash
# 在容器里做 rootfs（`make-op8p.sh --install`）或校验它（`--verify`），
# 供 macOS / 任何没有裸 e2fsprogs 的宿主使用。
#
# 为什么要单独一个入口：这两件事需要 mkfs.ext4 -d / unsquashfs / e2fsck，
# 而 make-op8p.sh 原来只认两种环境 —— 本机有这些工具（Linux），或者有
# Windows 的 wslc 容器 CLI。换到 macOS 之后两者都不成立，于是 --install 和
# --verify 会直接 die。容器本来就有（内核构建天天在跑），复用同一个镜像。
#
# 与 wslc 那条路的差异，只有一处：不用 /scratch 中转。Windows 的 DrvFs 不
# 保留 Unix 权限位（restore 出来的 bash 会变 -rw-r--r--，装进镜像后系统
# 起不来），所以那边必须整棵树放进容器自己的文件系统；macOS 的 virtiofs
# 保留权限位，直接在 /repo/work 里做就不会出那个问题。
#
# 用法:
#   scripts/op8p-rootfs-docker.sh --install   # 造 work/steamos-op8p/userdata.img
#   scripts/op8p-rootfs-docker.sh --verify    # 只读校验现有 img
#
# 镜像与卷与内核构建共用（op8p-build:43 / op8p-build-work）：同一个 Fedora 43
# 里既有 gcc 也有 mkfs.ext4，少一份要维护的工具链。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:---install}"
IMAGE="${IMAGE:-op8p-build:43}"
VOLUME="${VOLUME:-op8p-build-work}"
DOCKERFILE="${DOCKERFILE:-$ROOT/scripts/op8p-build.Dockerfile}"
OUT="$ROOT/work/steamos-op8p"

case "$mode" in
  --install)
    # fetch 是幂等的：rootfs.img 与 .ok 标记都在就不重下。解包那一步需要
    # btrfs restore（容器没有 CAP_SYS_ADMIN，loop 挂载必失败），所以它也在
    # 容器里跑，而不是在宿主上先解一半。
    container_cmd=(bash -c 'set -e
      bash /repo/scripts/fetch-steamos-rootfs.sh
      exec bash /repo/scripts/make-op8p-rootfs.sh')
    ;;
  --verify)  container_cmd=(bash /repo/scripts/verify-op8p-userdata.sh) ;;
  *) echo "用法: $0 --install|--verify" >&2; exit 2 ;;
esac

if ! docker info >/dev/null 2>&1; then
  cat >&2 <<'EOF'
   !! docker 不可用。macOS 上通常是 colima 没起：
        colima start
        docker context use colima
EOF
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== 构建工具链镜像 $IMAGE（内含 e2fsprogs / squashfs-tools） =="
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$ROOT" || {
    echo "   !! 镜像构建失败。也可以 IMAGE=fedora:43 让它每次临时 dnf 装（慢）" >&2
    exit 1
  }
fi
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

if [[ "$mode" == --verify ]]; then
  [[ -s "$OUT/userdata.img" ]] \
    || { echo "没有 $OUT/userdata.img —— 先跑 ./make-op8p.sh --install" >&2; exit 1; }
fi

echo "== $mode（容器内） =="
docker run --rm --dns 223.5.5.5 -w /repo \
  -v "$ROOT:/repo" -v "$VOLUME:/work" \
  "$IMAGE" "${container_cmd[@]}"
