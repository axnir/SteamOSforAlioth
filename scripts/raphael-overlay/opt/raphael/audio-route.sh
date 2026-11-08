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
  if amixer -c "$CARD" cset "name='$1'" "$2" >/dev/null 2>&1; then
    echo "[audio] $1 = $2"
  else
    echo "[audio] 失败：$1（控件不存在，或声卡还没注册）"
  fi
}

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
