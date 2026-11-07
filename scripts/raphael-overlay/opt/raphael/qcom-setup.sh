#!/bin/sh
# Qualcomm 侧的启动准备：QRTR 名字服务、EFS（rmtfs）、TFTP（tqftpserv），
# 然后把 modem 拉起来 —— modem 起来后它的 wlan 子系统才会注册 QMI WLFW，
# ath10k_snoc 才可能握手成功。
#
# 为什么挂在 raphael-usb-gadget.service 里而不是自己的 unit：那几个
# multi-user.target.wants 的 unit 在 Valve 的 rootfs 上开机时会被 systemd
# 跳过（ConditionResult=no，journal 里一条记录都没有），而这支 gadget 服务
# 在 sysinit 阶段稳定运行，用它当钩子最省事。
set -u
Q=/opt/raphael/qcom/bin
LOG=/var/log/raphael-qcom.log
: >"$LOG" 2>/dev/null || LOG=/dev/null

echo "[qcom] start $(date)" >>"$LOG"

# usb0 的链路本地地址：Windows 侧 NCM 网卡拿的是 169.254.x/16，手机进同一段
# 才能互相连（推文件、跑代理）。必须在 gadget 绑好 UDC 之后加，所以放在这儿。
ip addr add 169.254.240.121/16 dev usb0 2>/dev/null
ip link set usb0 up 2>/dev/null

# tqftpserv 把 modem 的请求映射到 /readonly/firmware/image（Android 里是 vendor 分区）
mkdir -p /readonly/firmware /readwrite
ln -sfn /lib/firmware/qcom/sm8150/Xiaomi/raphael /readonly/firmware/image

for p in qrtr-ns rmtfs tqftpserv; do
  if ! pidof "$p" >/dev/null 2>&1; then
    case "$p" in
      qrtr-ns)    setsid "$Q/qrtr-ns" -f        >>"$LOG" 2>&1 & ;;
      rmtfs)      setsid "$Q/rmtfs"             >>"$LOG" 2>&1 & ;;
      tqftpserv)  setsid "$Q/tqftpserv"         >>"$LOG" 2>&1 & ;;
    esac
    echo "[qcom] started $p" >>"$LOG"
  fi
done

sleep 2
# modem：只有 rmtfs/tqftpserv 就位后再启动才不会 0.4 秒一次 fatal error
if [ "$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)" != running ]; then
  echo start >/sys/class/remoteproc/remoteproc1/state 2>/dev/null &&
    echo "[qcom] modem start requested" >>"$LOG"
fi

exit 0
