#!/bin/sh
# 把 MultiMedia1 这个前端 DAI 接到物理后端上。
#
# 为什么需要：DTS 里 FE 的 dai-link 只有 cpu 一端（q6asmdai），FE→BE 的连接是
# 运行时靠 ASoC 的 mixer 开关建立的，平时由 UCM 的 EnableSequence 做。这台机器
# 没有 sm8150/raphael 的 UCM（上游 alsa-ucm-conf 只到 sm8250），所以没人做这件事，
# 内核就直接拒绝播放：
#
#   MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1,
#                possibly missing ALSA mixer-based routing or UCM profile
#
# 症状是「声卡在、PCM 在、一播放就 Invalid argument」，PipeWire 那边则是只有
# Dummy Output（ACP 找不到 UCM profile，一个节点都不建）。
#
# DTS 里 MultiMedia1 的播放后端只有两条（`sm8150-xiaomi-raphael.dts` §sound）：
#   SLIM Playback    → q6afedai SLIMBUS_0_RX      → wcd9340（耳机 / 听筒）
#   TFA9874 Playback → q6afedai QUATERNARY_MI2S_RX → tfa9874（外放）
#
# 两条同时开会互相打架（hw_params 失败），所以这里明确二选一：默认外放。
# 插耳机要切到 SLIM 那条时，跑 `sh /opt/raphael/audio-route.sh headphone`。
#
# 控件名要用 `name='...'` 形式：`amixer sset '<名字>' 1` 在 busybox 下会被
# 传成两个参数，amixer 回 `Invalid command!`（实测）。
set -u
CARD=${CARD:-0}
MODE=${1:-speaker}

ctl() {
  # $1 = 控件名，$2 = on/off
  #
  # 重试是必须的，不只是保险。2026-11-08 真机：服务在 22:10:08 启动，cget 已经
  # 能查到控件（说明声卡注册完了），但 cset 失败 —— 那个时间窗里 PipeWire /
  # WirePlumber 正在初始化，声卡的控制接口被占着，返回 EBUSY。同样的命令手工
  # 跑一次就成功。所以等「控件存在」不够，要等到「写得进去」。
  local n=0
  while [ "$n" -lt 20 ]; do
    if amixer -c "$CARD" cset "name='$1'" "$2" >/dev/null 2>&1; then
      echo "[audio] $1 = $2"
      return 0
    fi
    sleep 0.5
    n=$(( n + 1 ))
  done
  echo "[audio] failed after 10s: $1 (card $CARD busy or missing)"
  return 1
}

# 开机时 sound.target 变 active 只代表「有一张声卡注册了」，mixer 控件是
# msm-snd-sm8150 的 probe 后半段才挂出来的，两者之间有几百毫秒到几秒的窗口。
# 手工跑的时候声卡早就绪，所以看不出这个问题；做成 service 就会踩上。
# 这里等到控件真的能写为止（最多 30 s），而不是一次性试完就算。
wait_ctl() { # wait_ctl <控件名> [超时秒]
  local n=0 max=$(( ${2:-30} * 2 ))
  while [ "$n" -lt "$max" ]; do
    if amixer -c "$CARD" cget "name='$1'" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    n=$(( n + 1 ))
  done
  echo "[audio] 等不到控件：$1（超时 ${2:-30}s）"
  return 1
}

wait_ctl 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 30 || true

case "$MODE" in
  speaker)
    ctl 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 0
    ctl 'QUAT_MI2S_RX Audio Mixer MultiMedia1' 1
    ;;
  headphone)
    ctl 'QUAT_MI2S_RX Audio Mixer MultiMedia1' 0
    ctl 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 1
    ;;
  off)
    ctl 'QUAT_MI2S_RX Audio Mixer MultiMedia1' 0
    ctl 'SLIMBUS_0_RX Audio Mixer MultiMedia1' 0
    ;;
  *)
    echo "用法: $0 [speaker|headphone|off]" >&2
    exit 2
    ;;
esac

exit 0
