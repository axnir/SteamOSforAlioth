#!/bin/sh
# 把无线管制域钉成 CN —— 5GHz 连不上的正解。
#
# 为什么必须做：SteamOS 的 rootfs 里没有可信的 regulatory.db（vendor 内核开了
# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB，上游 wireless-regdb 的签名它不认），
# cfg80211 于是落在 world 域：5GHz 信道几乎全是 "no IR"，扫描能看见 SSID、
# 认证阶段直接被内核拒掉（NetworkManager 报 CONN_FAILED / TEMP_DISABLED）。
#
# 参考仓库 Winter21c/archlinux-xiaomi-raphael 的做法是把
# cfg80211.ieee80211_regdom=<国家> 写进引导项（config/build.conf 的 WIFI_COUNTRY），
# 我们这里做同样的事，落在 ESP 的 loader entry 上 —— 那条路已经验证过
# （DTB 就是外部加载的，改 ESP 不需要刷机，见 docs/raphael.md §24.2）。
#
# 用法：
#   /opt/raphael/set-regdom.sh          # 默认 CN，补 ESP + 立刻生效
#   /opt/raphael/set-regdom.sh US       # 换国家码
#   /opt/raphael/set-regdom.sh CN /dev/sda29
# 幂等：已经写过的 entry 不会再追加，备份只在第一次做（*.conf.bak）。
set -u

COUNTRY="${1:-CN}"
ESP="${2:-/dev/sda29}"
MNT=/mnt/_esp

patched=0
skipped=0

patch_dir() {
  d="$1"
  for f in "$d"/loader/entries/*.conf; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if grep -q "cfg80211\.ieee80211_regdom=" "$f"; then
      echo "  = $name 已有 regdom，跳过"
      skipped=$((skipped + 1))
      continue
    fi
    [ -f "$f.bak" ] || cp "$f" "$f.bak"
    if grep -q "^options" "$f"; then
      sed -i "s|^\(options.*\)$|\1 cfg80211.ieee80211_regdom=$COUNTRY|" "$f"
    else
      printf 'options cfg80211.ieee80211_regdom=%s\n' "$COUNTRY" >>"$f"
    fi
    echo "  + $name 追加 cfg80211.ieee80211_regdom=$COUNTRY"
    patched=$((patched + 1))
  done
}

# 1) ESP：优先复用已挂载的 /efi，否则用 512 字节扇区的 loop 挂
if findmnt -no SOURCE /efi >/dev/null 2>&1 && [ -d /efi/loader/entries ]; then
  echo "ESP 已挂在 /efi，就地修改"
  patch_dir /efi
else
  mkdir -p "$MNT"
  LOOP=$(losetup -b 512 -f --show "$ESP" 2>/dev/null) || {
    echo "losetup $ESP 失败" >&2
    exit 1
  }
  if ! mount "$LOOP" "$MNT" 2>/dev/null; then
    echo "mount $LOOP 失败（$ESP 不是 ESP？）" >&2
    losetup -d "$LOOP"
    exit 1
  fi
  echo "临时挂载 $ESP -> $MNT"
  patch_dir "$MNT"
  sync
  umount "$MNT"
  losetup -d "$LOOP"
fi

# 2) 立刻生效（这次开机不用重启就能重试 5G）
if command -v iw >/dev/null 2>&1; then
  iw reg set "$COUNTRY" 2>/dev/null && echo "iw reg set $COUNTRY: ok" || echo "iw reg set $COUNTRY: 失败（没有 wiphy？）"
  iw reg get 2>/dev/null | head -n 8
fi

echo "patched=$patched skipped=$skipped"
# 注意：引导项只在下次开机进 systemd-boot 时读取，所以 5G 的完整验证需要一次 reboot。
exit 0
