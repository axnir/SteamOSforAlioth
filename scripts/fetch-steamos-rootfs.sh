#!/usr/bin/env bash
# 取回 Valve Frame 的官方 aarch64 rootfs 并解包成一棵目录树。
#
# 为什么是新文件而不是复用 make-steamos-sm8650.sh：那个脚本里的
# ensure_official_rootfs() 做的正是这件事，但它嵌在一个继续往下造 SD 卡
# 三分区镜像（p1 BOOT / p2 root / p3 home）的流程里，没有「取完就停」的
# 开关，而 alioth 走的是手机模型 —— 单个 ext4 刷进 userdata。把那个函数
# 抽出来会改动上游文件、扩大每次 merge 的冲突面（spec §4）。
#
# 四步，与上游同一条流水线、同一组 URL：
#   1. curl 取 RAUC bundle（.raucb，其实是个 squashfs）
#   2. unsquashfs 解出 rootfs.img.caibx 与 manifest.raucm
#   3. scripts/extract_rootfs.py 按 caibx 从 casync chunk store 重组 rootfs.img
#      （sha256 取自 manifest，由该脚本校验）
#   4. loop 挂载后 rsync 成目录树（-aHAX --numeric-ids，保 xattr 与属主）
#
# 每一步都幂等：bundle 在就不重下，rootfs.img 有 .ok 标记就不重组，
# 目标树里有 usr/bin/bash 就直接返回。重跑这个脚本不会重新下载几 GB。
#
# 用法: scripts/fetch-steamos-rootfs.sh [输出目录]
#   默认输出 ${STEAMOS_ROOTFS:-${STEAMOS_WORK:-<repo>/work}/rootfs}
# 版本由 STEAMOS_BUILD / STEAMOS_VERSION 覆盖（默认与上游一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
WORKDIR="${STEAMOS_WORK:-${ROOT}/work}"
R="${1:-${STEAMOS_ROOTFS:-${WORKDIR}/rootfs}}"

# 与 make-steamos-sm8650.sh 同一组默认值；versions.env 若存在则优先。
[[ -f "${ROOT}/versions.env" ]] && source "${ROOT}/versions.env"
STEAMOS_BUILD="${STEAMOS_BUILD:-20261002.6232440}"
STEAMOS_BUNDLE="deckard-${STEAMOS_BUILD}-${STEAMOS_VERSION:-0.5.3}"
STEAMOS_URL="https://steamdeck-images.steamos.cloud/vr/${STEAMOS_BUILD}"

log() { echo "fetch-steamos-rootfs: $*" >&2; }
die() { echo "fetch-steamos-rootfs: $*" >&2; exit 1; }

for c in curl unsquashfs rsync python3; do
  command -v "$c" >/dev/null || die "缺少 $c"
done

if [[ -x "${R}/usr/bin/bash" ]]; then
  log "rootfs 已解包在 ${R}，不做任何事"
  exit 0
fi

dl="${WORKDIR}/steamos-${STEAMOS_BUILD}"
img="${dl}/rootfs.img"
mkdir -p "${dl}"

if [[ ! -s "${dl}/bundle/rootfs.img.caibx" ]]; then
  log "取 RAUC bundle ${STEAMOS_BUNDLE}"
  curl -fL --retry 3 -o "${dl}/${STEAMOS_BUNDLE}.raucb" \
    "${STEAMOS_URL}/${STEAMOS_BUNDLE}.raucb"
  rm -rf "${dl}/bundle"
  unsquashfs -q -d "${dl}/bundle" "${dl}/${STEAMOS_BUNDLE}.raucb"
fi

sha="$(sed -n '/^\[image.rootfs\]/,/^\[/{s/^sha256=//p}' "${dl}/bundle/manifest.raucm")"
[[ -n "$sha" ]] || die "manifest.raucm 里没有 [image.rootfs] 的 sha256"

if [[ ! -s "${img}" || ! -f "${img}.ok" ]]; then
  log "按 casync chunk 重组 rootfs.img（sha256 ${sha}）"
  python3 "${SCRIPTS}/extract_rootfs.py" \
    --caibx "${dl}/bundle/rootfs.img.caibx" --output "${img}" \
    --store "${STEAMOS_URL}/${STEAMOS_BUNDLE}.castr" \
    --store "https://steamdeck-images.steamos.cloud/vr/chunks.castr" \
    --expected-sha256 "${sha}"
  touch "${img}.ok"
fi

log "解包 rootfs.img → ${R}"
mnt="${WORKDIR}/.rootfs-ro"
mkdir -p "${mnt}" "${R}"
# 已挂着就先卸，否则重跑会 rsync 出一棵空树。
mountpoint -q "${mnt}" && sudo umount "${mnt}" 2>/dev/null || true

# 优先走挂载 + rsync：它保留 xattr、属主、稀疏文件和硬链接，是唯一"完整"
# 的方式。但构建容器没有 CAP_SYS_ADMIN，mount 一定失败（lo 设备都没有），
# 所以在那种环境里退到 debugfs 的 rdump —— 它逐文件复制，保 mode/属主/
# 时间戳，**不保 xattr**，10 GiB 的树要跑十几分钟，但不需要任何特权。
if mount -o loop,ro "${img}" "${mnt}" 2>/dev/null; then
  trap 'sudo umount "${mnt}" 2>/dev/null || umount "${mnt}" 2>/dev/null || true' EXIT
  rsync -aHAX --filter="-x btrfs.*" --numeric-ids "${mnt}/" "${R}/"
  umount "${mnt}" 2>/dev/null || sudo umount "${mnt}"
  trap - EXIT
else
  # 不能挂载时按文件系统类型分派。Valve 这份 rootfs.img 是 **btrfs**
  # （debugfs 会直接报 "contains a btrfs file system"），所以主路径是
  # btrfs restore —— 它不需要任何特权，也不需要 loop 设备。
  fstype="$(blkid -o value -s TYPE "${img}" 2>/dev/null || true)"
  [[ -n "$fstype" ]] || fstype="$(file -b "${img}" 2>/dev/null | grep -io 'btrfs\|ext[234]' | head -1)"
  log "不能 loop 挂载（容器无 CAP_SYS_ADMIN），文件系统是 ${fstype:-unknown}，走离线恢复"
  rm -rf "${R}"
  mkdir -p "${R}"
  case "$fstype" in
    btrfs)
      command -v btrfs >/dev/null || die "没有 btrfs 工具 —— 装 btrfs-progs"
      # -m 是必须的：没有它 restore 只写内容，属主和权限全部落成默认值
      # （/usr/bin/bash 变成 644），树看起来完整但系统起不来。这是走了
      # 一整轮弯路才发现的 —— 表现是"restore rc=0、18 万个文件、bash 存在
      # 但没有 x 位"。
      LOGD="${SCRATCH:-/tmp}/btrfs-restore.log"
      btrfs restore -v -m "${img}" "${R}" >"$LOGD" 2>&1 || true
      errs="$(grep -c '^ERROR' "$LOGD" 2>/dev/null || true)"
      log "btrfs restore 报错 ${errs:-0} 条"
      if [[ ! -x "${R}/usr/bin/bash" ]]; then
        tail -8 "$LOGD" >&2
        die "restore 没有产出 /usr/bin/bash（完整日志在容器内 $LOGD）"
      fi
      # 已知且无害的一条：/usr/lib/xorg/modules 是符号链接，restore 会
      # 报 "mkdir ... Not a directory" 然后跳过它下面的内容。
      if grep -q 'Not a directory' "$LOGD" 2>/dev/null; then
        log "注意：xorg/modules 是 symlink，restore 跳过了它（SteamOS 图形不依赖这条路径）"
      fi
      ;;
    ext4|ext3|ext2|"")
      command -v debugfs >/dev/null || die "没有 debugfs —— e2fsprogs 没装成"
      if ! debugfs -R "rdump / ${R}" "${img}" >"${WORKDIR}/debugfs-rdump.log" 2>&1; then
        tail -5 "${WORKDIR}/debugfs-rdump.log" >&2
        die "debugfs rdump 失败（完整日志 ${WORKDIR}/debugfs-rdump.log）"
      fi
      ;;
    *)
      die "不认识的 rootfs 文件系统：${fstype}"
      ;;
  esac
fi

[[ -x "${R}/usr/bin/bash" ]] || die "解包后的 rootfs 里没有 /usr/bin/bash"
log "完成: ${R}"
