#!/usr/bin/env bash
# 把 alioth 已真机验收的「去 VR 化」层装进一棵 raphael rootfs 目录树。
#
# 照 scripts/apply-alioth-devr.sh，四处 raphael 适配：
#  - 所有文件逐行去 CR：git 在 Windows 会把 steamos-overlay checkout 成 CRLF，
#    shebang 变成 /bin/sh\r，sddm-helper 以 126 退出、会话脚本一次都跑不起来
#    （2026-11-07 实测）。build-raphael-reference.sh 的 overlay 合并也去 CR。
#  - gamescope-session 的 zink GL 判断加 qcom,sm8150。
#  - 不装 sm8550-fixpad（raphael 没有 rsinput sticks；脚本有 -x 判断，不装即跳过）。
#  - 不写 /etc overlayfs 的 upper 镜像：raphael 根是普通可写 ext4，直接写就生效。
#
# mask 清单刻意不动 raphael-usb-gadget.service / raphael-debug-shell.service：
# COM3 的 root shell 和 USB NCM 是这台手机唯一的观测通道。
#
# 用法: scripts/apply-raphael-devr.sh <rootfs-dir>
set -euo pipefail

ROOT="${RAPHAEL_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOVL="${ROOT}/steamos-overlay"
R="${1:-}"

log() { echo "apply-raphael-devr: $*" >&2; }
die() { echo "apply-raphael-devr: $*" >&2; exit 1; }

[[ -n "$R" ]] || die "用法: $0 <rootfs-dir>"
[[ -d "$R" ]] || die "rootfs 目录不存在: $R"
[[ -d "$SOVL" ]] || die "找不到 $SOVL"

STOCK="$R/var/lib/steamos-arm-stock"
mkdir -p "$STOCK"

backup() { # $1=目标（只在第一次运行时留 Frame 原件）
  local src="$1" dst="$STOCK/${1#"$R/"}"
  [[ -f "$src" ]] || return 0
  [[ -e "$dst" ]] && return 0
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

files=(
  usr/lib/steamos/gamescope-session
  usr/lib/steamos/gamescope-onready
  usr/lib/steamos/panel-modes
  usr/bin/start-gamescope-session
  usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf
  usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf
  usr/lib/systemd/user/steam.service.d/61-gamescope-env-wait.conf
  usr/lib/systemd/user/steamos-manager-session-cleanup.service.d/10-steamos-arm-timeout.conf
)
for f in "${files[@]}"; do
  [[ -f "$SOVL/$f" ]] || die "缺 $SOVL/$f"
done

log "装入 ${#files[@]} 个去 VR 化文件（逐文件去 CR）→ $R"
for f in "${files[@]}"; do
  mkdir -p "$(dirname "$R/$f")"
  backup "$R/$f"
  tr -d '\r' < "$SOVL/$f" > "$R/$f"
  chmod "$(stat -c %a "$SOVL/$f")" "$R/$f"
done

# raphael 的 GPU 也需要 zink-on-Turnip，否则 Xwayland 没有 GLX。
sed -i 's/-e "qcom,sm8250"/-e "qcom,sm8250" -e "qcom,sm8150"/' \
  "$R/usr/lib/steamos/gamescope-session"
grep -q 'qcom,sm8150' "$R/usr/lib/steamos/gamescope-session" || die "sm8150 补丁没打上"

chmod 755 \
  "$R/usr/lib/steamos/gamescope-session" \
  "$R/usr/lib/steamos/gamescope-onready" \
  "$R/usr/lib/steamos/panel-modes" \
  "$R/usr/bin/start-gamescope-session"

# Frame 的 gamescope-session.service 写着 PartOf=steamvr.service；下面的
# /etc drop-in（raphael-overlay 提供）会把它清掉，否则 mask steamvr.* 会
# 让整个用户会话立刻 Exit the Session。
mask_user=(
  steamvr.service steamvr-logs.service steamvr-proxmicmute.service
  steamvr-v4l2cam.service steamvr-nested-desktop.service
)
mask_sys=(
  steamvr-program-ble.service steamvr-v4l2loopback.service
  steamvr-set-kernel-thread-priorities.service
  deckard-audio-setup.service deckard-fan-control.service
  deckard-fpga.service deckard-led-control.service
  deckard-typec-logger.service deckard-charger.service
  deckard-power-monitor.service deckard-fpga-resume.service
  deckard-boot-images.service set-wifi-mac-address.service
  steamos-boot.service systemd-repart.service
  adbd.service adbd-post.service
)
mkdir -p "$R/etc/systemd/user" "$R/etc/systemd/system"
for u in "${mask_user[@]}"; do ln -sfn /dev/null "$R/etc/systemd/user/$u"; done
for u in "${mask_sys[@]}"; do ln -sfn /dev/null "$R/etc/systemd/system/$u"; done
log "已 mask ${#mask_user[@]} 个用户态 + ${#mask_sys[@]} 个系统态 unit"

# 断言：shebang 绝不能带 CR，这是 126 的根因。
for f in usr/bin/start-gamescope-session usr/lib/steamos/gamescope-session; do
  if head -1 "$R/$f" | grep -q $'\r'; then die "$f 的 shebang 仍有 CR"; fi
done
log "完成"
