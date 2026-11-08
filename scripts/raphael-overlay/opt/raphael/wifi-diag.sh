#!/bin/sh
# 5G 连不上时一次收齐证据，别再来回猜。
#
# 判据链（顺序即因果）：
#   1. regdom         —— 是不是 world 域 / 5180 有没有 NO_IR
#   2. 板级文件       —— ath10k 到底吃的是哪一份 board 文件
#   3. 固件与 MAC     —— firmware ver / crc32 / invalid MAC
#   4. 扫描结果       —— 能不能看见 5G 的 SSID、信道号对不对
#   5. 认证阶段       —— CONN_FAILED 之前最后一条内核消息
#
# 用法：sh /opt/raphael/wifi-diag.sh > /tmp/wifi.txt   然后把 /tmp/wifi.txt 取回
set -u

FW=/lib/firmware/ath10k/WCN3990/hw1.0
SSID_5G="${1:-Xiaomi_0A83_5G}"

echo "===== 1. regdom ====="
iw reg get 2>&1
echo
echo "-- 5180/5200/5745 的可用性（Client 视角）--"
for f in 5180 5200 5745; do
  if command -v iw >/dev/null 2>&1 && [ -d /sys/class/ieee80211 ]; then
    phy=$(basename "$(ls -d /sys/class/ieee80211/* | head -n 1)")
    iw phy "$phy" info 2>/dev/null | grep -n "MHz \[$f\]" | head -n 2
  fi
done

echo
echo "===== 2. 板级文件 ====="
ls -l "$FW" 2>&1
for f in "$FW"/board.bin "$FW"/board-2.bin "$FW"/board-2.bin.zst; do
  [ -f "$f" ] && { printf '%s  ' "$f"; sha256sum "$f" | cut -d' ' -f1; }
done
echo "-- dmesg 里选了哪份 board 文件 --"
dmesg 2>/dev/null | grep -i "board\|bdf\|otp" | tail -n 12

echo
echo "===== 3. 固件与 MAC ====="
dmesg 2>/dev/null | grep -i "ath10k" | tail -n 25
echo "-- wlan0 --"
ip -br link show wlan0 2>&1
cat /sys/class/net/wlan0/address 2>/dev/null

echo
echo "===== 4. 扫描 ====="
nmcli -f SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list 2>&1 | head -n 25
echo "-- 只看目标 SSID --"
nmcli -f SSID,CHAN,FREQ,SIGNAL device wifi list 2>&1 | grep -i "$SSID_5G"
iw dev wlan0 scan 2>/dev/null | grep -A1 "SSID: $SSID_5G" | head -n 6

echo
echo "===== 5. 认证阶段 ====="
dmesg 2>/dev/null | grep -iE "SME|authenticate|deauth|CTRL-EVENT|valid frequency" | tail -n 25
echo "-- NM 侧 --"
nmcli -f GENERAL.STATE,GENERAL.REASON device show wlan0 2>&1

echo
echo "===== 6. 现役连接 ====="
nmcli -f NAME,DEVICE,STATE connection show 2>&1 | head -n 10
cat /etc/NetworkManager/conf.d/wifi-powersave.conf 2>&1
iw dev wlan0 get power_save 2>&1
