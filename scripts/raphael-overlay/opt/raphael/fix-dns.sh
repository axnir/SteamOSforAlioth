#!/bin/sh
# 修「能 ping 通 IP、但所有域名都卡死」。
#
# 2026-11-08 复现：开机 wlan0/5G 都正常（5180 MHz，192.168.31.220），
# 但 curl https://store.steampowered.com/ 12 秒超时返回 000，
# `ping www.qq.com` 直接挂住不返回，`ping 223.5.5.5` 12ms 正常。
# 也就是**路由和链路没问题，是域名解析这一层卡死**。
#
# /etc/resolv.conf 当时是 → /run/systemd/resolve/stub-resolv.conf，nameserver 127.0.0.53。
# 参考仓库对这件事有明确警告（porting-checklist §12.1）：
#   systemd-resolved 默认不开，NetworkManager 自己写 /etc/resolv.conf；
#   如果 resolv.conf 是指向 resolved stub 的软链、而 NM 又不是 systemd-resolved 模式，
#   两边谁都不给上游 → 127.0.0.53 收下查询但转不出去 → 客户端永久等待。
#
# 本脚本做三件事，全部幂等：
#   1) 打印现场（resolved 状态、上游、resolv.conf 真实指向、NM 的 dns 模式）
#   2) 把 DNS 钉死在连接上：ipv4.dns + ignore-auto-dns（不依赖 DHCP 给的 DNS）
#   3) 让 resolved 有上游：/etc/systemd/resolved.conf.d/50-raphael.conf 写 DNS/FallbackDNS，
#      并确认 NetworkManager 是 dns=systemd-resolved；如果是别的模式，就让 NM 自己写
#      /etc/resolv.conf（把软链换成实体文件，避免它写不进去）
#
# 用法：sh /opt/raphael/fix-dns.sh [连接名...]
#       不带参数就作用于所有 wifi 连接。
# 回退：nmcli connection modify <名字> ipv4.dns "" ipv4.ignore-auto-dns no
set -u

RESOLVED_CONF=/etc/systemd/resolved.conf.d/50-raphael.conf
NM_CONF=/etc/NetworkManager/conf.d/10-raphael-dns.conf
DNS1=${DNS1:-223.5.5.5}
DNS2=${DNS2:-119.29.29.29}

say() { echo "[dns] $*"; }

# ---------- 1) 现场 ----------
say "===== 现场 ====="
say "resolv.conf: $(readlink -f /etc/resolv.conf 2>/dev/null)"
say "resolved active: $(systemctl is-active systemd-resolved 2>/dev/null)"
say "NM dns 模式: $(grep -rhs '^dns=' /etc/NetworkManager/ /run/NetworkManager/ 2>/dev/null | tr '\n' ' ')"
say "--- 上游（resolved 视角）---"
timeout 5 resolvectl status 2>/dev/null | grep -iE "DNS Servers|Current DNS|DNS Domain|Link [0-9]" | head -n 12
say "--- 解析对比（关键判据）---"
say "直连 223.5.5.5 解析 www.qq.com:"
timeout 5 nslookup www.qq.com "$DNS1" 2>&1 | tail -n 4
say "走系统解析（resolved stub）:"
timeout 5 getent hosts www.qq.com 2>&1 | head -n 2 || say "  (超时或失败 —— 这就是卡死点)"

# ---------- 2) 连接上钉死 DNS ----------
if [ $# -gt 0 ]; then
  CONNS="$*"
else
  CONNS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
          awk -F: '$2 ~ /wireless/ {print $1}' | tr '\n' ' ')
fi
say "===== 作用于连接: ${CONNS:-<无>} ====="
for c in $CONNS; do
  nmcli connection modify "$c" \
    ipv4.dns "$DNS1 $DNS2" \
    ipv4.ignore-auto-dns yes 2>/dev/null &&
    say "  $c: ipv4.dns=$DNS1,$DNS2 ignore-auto-dns=yes"
done

# ---------- 3) 给 resolved 上游 + 对齐 NM 模式 ----------
if [ "$(systemctl is-active systemd-resolved 2>/dev/null)" = active ]; then
  mkdir -p "$(dirname "$RESOLVED_CONF")"
  cat >"$RESOLVED_CONF" <<EOF
# raphael：resolved 必须自己有上游，否则 127.0.0.53 收下查询转不出去，
# 所有域名解析都会「卡住」而不是「失败」（2026-11-08 踩过）。
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=1.1.1.1 8.8.8.8
# 不要因为链路暂时没 DNS 就把上游清空
Cache=yes
EOF
  say "写入 $RESOLVED_CONF"

  mkdir -p "$(dirname "$NM_CONF")"
  if ! grep -rqs '^dns=systemd-resolved' /etc/NetworkManager/ /run/NetworkManager/ 2>/dev/null; then
    cat >"$NM_CONF" <<EOF
# 让 NetworkManager 把每条连接的 DNS 推给 systemd-resolved。
# 否则 NM 走 dns=default 会试图自己写 /etc/resolv.conf，
# 而那份是个指向 resolved stub 的软链 —— 两边都不生效（见 fix-dns.sh 头部）。
[main]
dns=systemd-resolved
EOF
    say "写入 $NM_CONF（NM 之前不是 systemd-resolved 模式）"
  fi

  systemctl restart systemd-resolved 2>/dev/null
  systemctl reload-or-restart NetworkManager 2>/dev/null
  sleep 3
else
  # resolved 没跑：把 resolv.conf 换成实体文件，让 NM 直接写。
  if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    printf 'nameserver %s\nnameserver %s\n' "$DNS1" "$DNS2" >/etc/resolv.conf
    say "resolved 未运行，/etc/resolv.conf 已改为实体文件"
  fi
  systemctl reload-or-restart NetworkManager 2>/dev/null
  sleep 2
fi

# 连接需要重激活才会带上新 DNS
for c in $CONNS; do
  nmcli connection up "$c" >/dev/null 2>&1 && say "  $c reactivated"
done
sleep 3

# ---------- 验收 ----------
say "===== 验收 ====="
say "resolv.conf: $(readlink -f /etc/resolv.conf 2>/dev/null)"
timeout 5 getent hosts www.qq.com 2>&1 | head -n 2 || say "  解析仍失败"
timeout 8 curl -s -o /dev/null -w "http  baidu %{http_code} %{time_total}s\n" --max-time 6 http://www.baidu.com/ 2>&1
timeout 12 curl -s -o /dev/null -w "https store %{http_code} %{time_total}s\n" --max-time 10 https://store.steampowered.com/ 2>&1
say "完。仍不通就把上面全部输出贴回来。"
