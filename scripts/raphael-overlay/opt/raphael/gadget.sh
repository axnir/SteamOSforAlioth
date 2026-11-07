#!/opt/raphael/bin/busybox sh
# 开机把 USB gadget 立起来：两个 ACM 串口（ttyGS0/GS1）+ 可选 NCM 网卡。
# 这台手机没有物理 UART，COM3/COM4 是唯一能进系统的线。
# raphael-debug-shell.service 在 ttyGS0 上等这个脚本执行完。
BB=/opt/raphael/bin/busybox
CFG=/sys/kernel/config/usb_gadget/steamos

$BB mount -t configfs none /sys/kernel/config 2>/dev/null
[ -d /sys/kernel/config/usb_gadget ] || { echo "gadget: configfs 不可用"; exit 1; }
[ -d "$CFG" ] && { echo "gadget: 已经起来了"; exit 0; }

# 等 UDC（dwc3 编进内核，一般已在；晚一点也不能放弃）
i=0
while [ $i -lt 40 ]; do
  [ -n "$($BB ls /sys/class/udc 2>/dev/null)" ] && break
  $BB sleep 0.25
  i=$((i+1))
done
UDC=$($BB ls /sys/class/udc 2>/dev/null | $BB head -n 1)
[ -n "$UDC" ] || { echo "gadget: 没有 UDC"; exit 1; }

$BB mkdir -p "$CFG/strings/0x409" "$CFG/configs/c.1/strings/0x409" \
  "$CFG/functions/acm.usb0" "$CFG/functions/acm.usb1" || exit 1
echo 0x1d6b > "$CFG/idVendor"
echo 0x0104 > "$CFG/idProduct"
echo "SteamOS ARM" > "$CFG/strings/0x409/manufacturer"
echo "SteamOS ARM debug shell" > "$CFG/strings/0x409/product"
echo "steamos-arm-debug" > "$CFG/strings/0x409/serialnumber"
echo "debug" > "$CFG/configs/c.1/strings/0x409/configuration"
ln -s "$CFG/functions/acm.usb0" "$CFG/configs/c.1/acm.usb0"
ln -s "$CFG/functions/acm.usb1" "$CFG/configs/c.1/acm.usb1"

# NCM 只是第二条通道（USB 网），建不起来也不能拖累串口
if $BB mkdir -p "$CFG/functions/ncm.usb0" 2>/dev/null; then
  echo "02:16:42:00:00:01" > "$CFG/functions/ncm.usb0/dev_addr" 2>/dev/null
  echo "02:16:42:00:00:02" > "$CFG/functions/ncm.usb0/host_addr" 2>/dev/null
  ln -s "$CFG/functions/ncm.usb0" "$CFG/configs/c.1/ncm.usb0"
fi

echo "$UDC" > "$CFG/UDC" || { echo "gadget: UDC bind 失败 ($UDC)"; exit 1; }
$BB sleep 1
if [ -d /sys/class/net/usb0 ]; then
  $BB ip link set usb0 up 2>/dev/null
  $BB ip addr add 172.16.42.1/24 dev usb0 2>/dev/null
fi
echo "gadget: up on $UDC, ttyGS0/ttyGS1 ready"
