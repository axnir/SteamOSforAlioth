#!/bin/sh
# Qualcomm 侧的启动准备：QRTR 名字服务、EFS（rmtfs）、TFTP（tqftpserv），
# 然后把 modem 拉起来 —— modem 起来后它的 wlan 子系统才会注册 QMI WLFW，
# ath10k_snoc 才可能握手成功。
#
# 为什么挂在 raphael-usb-gadget.service 的 ExecStart 末尾（gadget.sh）而不是
# 自己的 unit：那几个 multi-user.target.wants 的 unit 在 Valve 的 rootfs 上开机时
# 会被 systemd 跳过（ConditionResult=no，journal 里一条记录都没有），而 gadget
# 在 sysinit 阶段稳定运行。**但 gadget 太早**，见下面第 1 步的等待。
set -u
Q=/opt/raphael/qcom/bin
LOG=/var/log/raphael-qcom.log
: >"$LOG" 2>/dev/null || LOG=/dev/null

log() { echo "[qcom] $*" >>"$LOG"; }

log "start $(date)"

# usb0 的链路本地地址：Windows 侧 NCM 网卡拿的是 169.254.x/16，手机进同一段
# 才能互相连（推文件、跑代理）。必须在 gadget 绑好 UDC 之后加，所以放在这儿。
ip addr add 169.254.240.121/16 dev usb0 2>/dev/null
ip link set usb0 up 2>/dev/null

# 1) 等 rmtfs 要用的共享内存字符设备。
#
# 这是 2026-11-08 那次「开机后一个 WiFi 都搜不到」的根因：gadget 在 sysinit 就跑，
# 那时 /dev/qcom_rmtfs_mem1 还没被 rmtfs_mem 建出来，rmtfs 于是退化成
# `falling back to /dev/mem access`——EFS 读不到，modem 的 wlan PD 起不来，
# QMI WLFW 一直不注册，ath10k_snoc 永远停在 "using dummy regulator"，
# wlan0 根本不存在。手工晚几分钟重跑同一份脚本反而一次就通，就是因为这个时序。
#
# 最多等 120s；真等不到也继续往下走（留个记录，比卡死不启动强）。
i=0
while [ ! -e /dev/qcom_rmtfs_mem1 ] && [ "$i" -lt 240 ]; do
  sleep 0.5
  i=$((i + 1))
done
if [ -e /dev/qcom_rmtfs_mem1 ]; then
  log "qcom_rmtfs_mem1 就绪（等了 $((i / 2))s）"
else
  log "警告：等了 120s 仍没有 /dev/qcom_rmtfs_mem1，rmtfs 会退化成 /dev/mem"
fi

# tqftpserv 把 modem 的请求映射到 /readonly/firmware/image（Android 里是 vendor 分区）
mkdir -p /readonly/firmware /readwrite
ln -sfn /lib/firmware/qcom/sm8150/Xiaomi/raphael /readonly/firmware/image

start_stack() {
  for p in qrtr-ns rmtfs tqftpserv; do
    if ! pidof "$p" >/dev/null 2>&1; then
      case "$p" in
        qrtr-ns)    setsid "$Q/qrtr-ns" -f        >>"$LOG" 2>&1 & ;;
        rmtfs)      setsid "$Q/rmtfs"             >>"$LOG" 2>&1 & ;;
        tqftpserv)  setsid "$Q/tqftpserv"         >>"$LOG" 2>&1 & ;;
      esac
      log "started $p"
    fi
  done
}

start_modem() {
  if [ "$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)" != running ]; then
    echo start >/sys/class/remoteproc/remoteproc1/state 2>/dev/null &&
      log "modem start requested"
  fi
}

start_stack
sleep 2
# modem：只有 rmtfs/tqftpserv 就位后再启动才不会 0.4 秒一次 fatal error
start_modem

# 2) 兜底：如果 60s 内 wlan0 还是没出现，把用户态那三件套重来一遍。
# 实测「晚一点重跑」就能让 WLFW 重新注册（ath10k 的 QMI 等待是幂等的），
# 这比重启整台机器快得多。
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 120 ]; do
  sleep 0.5
  i=$((i + 1))
done
if [ -e /sys/class/net/wlan0 ]; then
  log "wlan0 就绪（$((i / 2))s）"
else
  log "wlan0 60s 未出现，重启 qcom 用户态再试一次"
  for p in qrtr-ns rmtfs tqftpserv; do
    pid=$(pidof "$p" 2>/dev/null) && [ -n "$pid" ] && kill $pid 2>/dev/null
  done
  sleep 2
  start_stack
  sleep 2
  start_modem
  i=0
  while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 180 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  if [ -e /sys/class/net/wlan0 ]; then
    log "重试后 wlan0 就绪（$((i / 2))s）"
  else
    log "重试后仍没有 wlan0 —— 跑 /opt/raphael/wifi-diag.sh 取证"
  fi
fi

exit 0
