# op8p 硬件清单与 mainline 状态（对标 alioth-hardware.md）

原始数据来自设备自身 sysfs / devicetree / getevent，采集于原厂 Android
（2026-10-25），完整转储见 [hardware-inventory.txt](hardware-inventory.txt)。
**「mainline 状态」一列区分两种来源**：标「已实测」的是 SteamOS 下真机验证过
的（截至 2026-11-22，验收记录在 [README.md](README.md) §28）；其余是已知
情况，不是实测。

## 整机

| 项 | 值 |
|---|---|
| 机型 | OnePlus 8 Pro（`instantnoodlep` / IN2020，`project_name=19811`） |
| SoC | Snapdragon 865（kona，`dt_msm_id=0000016400020001`、`board_id=0000000800000000`） |
| 存储 | UFS，`userdata=/dev/block/sda23`，A/B 槽（boot_a=sde11 / boot_b=sde35） |
| 电池 | 设计容量 **3991 mAh**，`voltage_max_design=4.42 V`（注意：不是 DTS 的 4.35V，也不同于 alioth 的 4.45V） |
| 无线充电 | 有（`wlchg_rx`，alioth 没有） |
| 快充 | Dash/Warp（`dash_fastchg @ 8-0026`，最多 2.25 A / 5 V） |

## 显示与输入

| 器件 | 型号 / 位置 | mainline 状态 |
|---|---|---|
| 面板 | Samsung **ANA6706**，DSC 命令模式，四组时序（1080×2376@60/120、1440×3168@60/120） | **已实测可用** —— gamescope `--prefer-output DSI-1` 上屏，Steam 登录页显示（2026-11-22） |
| Pixelworks Iris | 独立显示协处理器，i2c bus 6（`pxlw,iris-chip-enable`） | **未驱动** —— 不带它面板也能亮；画质增强类功能放弃 |
| 背光 | `bl_ctrl_dcs`，max 2047，默认 360 | 已实测可用 |
| 触摸 | Samsung **S6SY761**，i2c4 @0x48，1439×3168，`event3` | 驱动在（sec-s6sy761），**SteamOS 下未验证** |
| 电源键 / 音量键 | `qpnp_pon`（event0）、`gpio-keys`（event2） | 已实测可用（阶段 1） |
| 屏下指纹 | Goodix `gf_input`（event6） | 无计划（SteamOS 无解锁场景） |
| 距离传感器 | STM VL53L1 真实 ToF（event7） | 无计划 |
| 振动马达 | `qti-haptics`（event1）+ **aw8697** 驱动 | 驱动已写（`regen-op8p-aw8697-patch.sh`），**未进内核构建** |

## 音频（本移植最大的工作量）

| 器件 | 值 | mainline 状态 |
|---|---|---|
| codec | WCD938x + bolero（rx/tx/va macro） | 固件缺：`adsp.mbn`/`cdsp.mbn` 未提取，remoteproc offline，`error -22` ×2 |
| 扬声器功放 | NXP **TFA98xx ×2**（`tfa98xx_right@34` / `left@35`） | **不是 CS35L41，不走 Tertiary TDM，不走 WSA SoundWire**（`wsa-max-devs=0`，WSA881x 不存在）——照搬 alioth 的音频路径会失败 |
| 耳机 jack | Headset/Button Jack 已枚举 | 未验证 |
| USB-C 音频 | fsa4480 typec-mux（节点待核） | 未验证 |

## 充电与电量

| 器件 | 值 | mainline 状态 |
|---|---|---|
| 电量计 | TI **BQ27541**（i2c16 @0x55，外部电量计，非标准固件：SOC 报 0.01% 单位、温度直接报 0.1 °C、FCC 未学习时 0xFFFF、**TS 引脚板上未接** → Temperature() 恒 52.1 °C 垃圾值） | **已实测**：capacity/电压/电流寄存器与内核逐字节吻合（2026-11-22 i2c 转储）；温度源已切换为内部传感器（0036 + `ti,ts-pin-unused`，内部结温 36.9 °C 正常）；电池表面温度的正解是 PM8150B `batt_therm`（原厂行为，未接） |
| 充电主控 | bq2597x + chgpump + smb1390（`qcom_pm8150b_charger` 内核驱动缺） | **未通** —— 只能放电不能充电 |
| 无线充电 | `wlchg_rx @ 7-003b` | 无计划 |

## GPU / 固件

| 项 | 值 | mainline 状态 |
|---|---|---|
| GPU | Adreno **650**（kgsl-3d0） | **已实测可用**：zap 四件套（本机 OEM CA 签名，`.b01` sha `2cccbd69…`）从 initramfs 加载，Vulkan 到 gamescope，`-22` 归零 |
| 关键教训 | TrustZone **拒收 linux-firmware 通用签名**的 PAS 镜像（`Test User` 链），必须用 `vendor_a` 里本机签名那份 | 见 README §27.3、`docs/alioth.md:1643` |
| adsp / cdsp / slpi | `vendor/firmware_mnt/image/` 下有完整分段（adsp.b00–b18、cdsp.*、slpi.*），需 pil-squasher 合成 | 未提取 —— 待办 #1 |

## 无线

| 器件 | 值 | mainline 状态 |
|---|---|---|
| WiFi/BT | QCA6390（PCI `17cb:1101`，与 alioth 同款） | **WiFi 已实测连网**：`wlan0` connected `Xiaomi_0A83_5G`（**5G 频段**，alioth 未做到）；开机自连未验。蓝牙 `hci0 UP`、有 MAC，配对未验 |
| board-2.bin | 需 ath11k-bdencoder 从本机 `bdwlan.e01..eNN` 合成 | 已做（probe 干净，`fw_version 0x10121492`） |
| NFC | nq-nci @0x28 | 无计划 |

## USB

| 项 | 值 | mainline 状态 |
|---|---|---|
| 控制器 | `ssusb@a600000`（dwc3），**dr_mode=drd，super-speed** —— USB 3.0，alioth 是 USB2-only | 串口 gadget（ttyGS0/GS1）已实测；**host 模式未验** |
| 第二控制器 | `ssusb@a800000`（DP alt mode） | 无计划 |

## 内存留白（DT reserved-memory 实测）

| 区 | 地址 / 大小 | 备注 |
|---|---|---|
| cont_splash | `0x9c000000` / 0x2300000 | simpledrm framebuffer |
| ramoops | `0xA9800000` / **0x400000**（alioth 的 4 倍） | pstore 未验（alioth 上结论是地址有但用不了） |
| pil_adsp | `0x8fe00000` / 0x2500000 | remoteproc 加载区 |
