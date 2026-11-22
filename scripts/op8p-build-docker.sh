#!/usr/bin/env bash
# Build the OnePlus 8 Pro kernel on macOS (or any Linux with docker).
#
# Host entry point. The work happens in scripts/op8p-build-container.sh, which
# runs inside fedora:43; this script only arranges the container:
#
#   /repo   the repository, bind-mounted (read-only would be wrong: the build
#           copies output/ back here)
#   /work   a docker **volume**, not a bind mount. The build writes a kernel
#           tree (hundreds of thousands of files) plus a 140 MB tarball cache;
#           putting that on virtiofs costs more in metadata than the compile
#           costs in CPU, and it also keeps `git status` clean. The volume
#           persists between runs, so the second build is incremental.
#
# Replaces work/wslc-op8p-build.sh, which drives the Windows container CLI
# (`/c/Program Files/WSL/wslc`). That one still works on that box; this one is
# for colima/docker on the Mac. Differences that matter:
#   * the Mac is arm64, so this is a native aarch64 build (no CROSS_COMPILE);
#   * --dns is passed because containers here get a resolver that cannot see
#     the dnf mirror otherwise.
#
# Usage:
#   scripts/op8p-build-docker.sh              # build (incremental)
#   scripts/op8p-build-docker.sh --clean      # drop the /work volume first
#   scripts/op8p-build-docker.sh --shell      # interactive shell in the same
#                                             # container layout, for poking
#                                             # at a failed build
#   scripts/op8p-build-docker.sh --bare       # skip the toolchain image and
#                                             # run in plain fedora:43 (checks
#                                             # that the container script is
#                                             # self-sufficient)
#
# Needs: docker reachable (`docker info`). On this Mac colima provides it
# (`colima start`; `docker context use colima`). The first run builds a
# toolchain image (scripts/op8p-build.Dockerfile, ~1.5 GB) so later runs only
# relink; if that build fails it falls back to pulling fedora:43 and letting
# the container install its own dependencies. Nothing is written outside the
# repository except the docker volume and that image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-op8p-build:43}"
FALLBACK_IMAGE="${FALLBACK_IMAGE:-fedora:43}"
DOCKERFILE="${DOCKERFILE:-$ROOT/scripts/op8p-build.Dockerfile}"
VOLUME="${VOLUME:-op8p-build-work}"
LOG="${LOG:-$ROOT/work/op8p-build.log}"

mode=build
case "${1:-}" in
  --clean) mode=clean ;;
  --shell) mode=shell ;;
  --bare) mode=bare ;;   # 不用工具链镜像，直接在 fedora:43 里跑（验证脚本自身）
  "") ;;
  *) echo "未知参数: $1（可用 --clean / --shell / --bare）" >&2; exit 2 ;;
esac

echo "== 宿主环境 =="
echo "   仓库 $ROOT"
echo "   宿主 $(uname -s)/$(uname -m)"
if ! docker info >/dev/null 2>&1; then
  cat >&2 <<'EOF'
   !! docker 不可用。macOS 上通常是 colima 没起：
        colima start          # 首次会建 VM
        docker context use colima
      或者装了 Docker Desktop 就打开它。
EOF
  exit 1
fi
echo "   docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

if [[ "$mode" == bare ]]; then
  IMAGE="$FALLBACK_IMAGE"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [[ "$mode" == bare ]]; then
    echo "== 拉取镜像 $IMAGE =="
    docker pull "$IMAGE"
  else
    echo "== 构建工具链镜像 $IMAGE（一次，约 1.5 GB；之后增量构建只剩重链） =="
    if ! docker build -t "$IMAGE" -f "$DOCKERFILE" "$ROOT"; then
      echo "   !! 镜像构建失败，退回 $FALLBACK_IMAGE（容器内会自己装依赖，只是慢）" >&2
      IMAGE="$FALLBACK_IMAGE"
      docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"
    fi
  fi
fi
# 架构必须和目标一致才叫"原生"：arm64 宿主配 arm64 镜像，否则就是仿真编译。
img_arch="$(docker image inspect "$IMAGE" --format '{{.Architecture}}')"
host_arch="$(uname -m)"
case "$host_arch:$img_arch" in
  arm64:arm64|aarch64:arm64|x86_64:amd64) echo "   镜像架构 $img_arch（原生）" ;;
  *) echo "   !! 镜像架构 $img_arch 与宿主 $host_arch 不一致，会走仿真，非常慢" >&2 ;;
esac

if [[ "$mode" == clean ]]; then
  echo "== 删除构建卷 $VOLUME（源码树与下载缓存都会没，下次全量编译） =="
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
fi
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null
echo "   构建卷 $VOLUME"

common=(--rm --dns 223.5.5.5 -w /repo
        -v "$ROOT:/repo" -v "$VOLUME:/work")

if [[ "$mode" == shell ]]; then
  echo "== 交互 shell（/repo 与 /work 已挂好；构建脚本在 /repo/scripts/） =="
  exec docker run -it "${common[@]}" "$IMAGE" bash
fi

mkdir -p "$(dirname "$LOG")"
echo "== 开始构建，日志同时写入 $LOG =="
echo "   （首次会下载 linux-7.2.8.tar.xz 约 140 MB，然后编译 20–40 分钟）"
set -o pipefail
docker run "${common[@]}" "$IMAGE" bash /repo/scripts/op8p-build-container.sh 2>&1 | tee "$LOG"
