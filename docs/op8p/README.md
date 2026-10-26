# OnePlus 8 Pro (instantnoodlep) 移植基线

这份文档是 `alioth` 移植的**姊妹篇**，不是它的复制品。

采集于 2026-10-25，来源是设备自身的 sysfs / devicetree（root，Magisk），
不是从上游 DTS 或 pmaports 推断的。原始清单见
[`hardware-inventory.txt`](hardware-inventory.txt)。

> **凡是本文与上游 `sm8250-oneplus-instantnoodlep.dts` 冲突的地方，以本文为准。**
> 上游那份 DTS 有多处明显错误（触摸 IC 写成了 Samsung S6SY761 之外的型号、
> 电池参数不对、`&gpu` 被 `disabled`），实测数据推翻了它。

---

## 0. 结论先行：这个移植为什么比预想的容易，又比预想的难

**容易的部分**：SoC 是同一个 SM8250，`qcom,msm-id = 356 / 0x20001`，
`qcom,board-id = <8 0>`。ROCKNIX 的 SM8250 基线、`kernel-common/`、
`build-*` 脚本、断言框架、`steamos-overlay/` 全部原样可用。

**难的部分**（按风险降序，与前一份分析相比**有重大修正**）：

| 项 | 前一份分析的判断 | 实测后的判断 | 变化 |
|---|---|---|---|
| 触摸 | "DTS 写 s6sy761 是错的，OnePlus 用 Goodix" | **错的是我。DTS 是对的** —— 就是 Samsung S6SY761 | ⬇ 风险大幅降低 |
| 显示 | "上游没有面板驱动，要大写" | **面板型号确定了：ANA6706，4 组时序全部拿到**；Iris 有硬件旁路信号（`abyp_ready`），主显示直连面板 | ⬇ 风险降低 |
| 音频 | "功放是 CS35L41，照搬 alioth 补丁" | **完全不是。是 TFA98xx（I2C），不走 TDM / SoundWire** | ⬆ 风险**上升** |
| 充电 | "可能是 BQ259xx，要重做" | BQ25970 + BQ27541 + Dash 快充，链路比 alioth 复杂，**但有 BQ27541 mainline 驱动** | ↔ 持平 |
| EDL 救砖 | "比 alioth 容易" | 确认：`adb reboot edl` 可用，bootloader 已解锁 | ⬇ 风险降低 |

---

## 1. 设备身份（实测）

```
codename        instantnoodlep      project_name  19811
hw_version      15                  rf_version    11
platform        SM8250 (id 356)     sku           3
bootloader      **unlocked**        vbmeta        orange
当前槽位        _b
当前系统        OxygenOS 11 (RP1A.201005.001, 2022-02-14)
kernel          4.19.110-perf+      PAGESIZE      4096  ← FEX 硬性前提成立
qcom,board-id   <8 0>  (be32 00000008 00000000)
qcom,msm-id     <356 0x20001>
```

`PAGESIZE=4096` 是本项目成立的前提（FEX 绝对要求 4K 页）。这一条成立，
**项目继续**。

`board-id <8 0>` 在 ROCKNIX 的 11 个 SM8250 DTB 里唯一吗？需要确认——但无论
唯一与否，阶段 1 都只打包本机这一个 DTB，所以不影响。

---

## 2. 显示：ANA6706 + Pixelworks Iris

### 2.1 面板本体

```
cmdline:  msm_drm.dsi_display0=qcom,mdss_dsi_samsung_ana6706_dsc_cmd
name:     samsung ana6706 dsc cmd mode panel
type:     dsi_cmd_mode / burst_mode / DSC
reset:    tlmm 75      te: tlmm 66
```

四组时序（**这是移植的核心数据，全部实测**）：

| idx | 分辨率 | fps | hfp | hbp | hpw | vfp | vbp | vpw | DSC slice |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 1080×2376 | 60 | 64 | 48 | 8 | 1100 | 1100 | 188 | 540×72 @8bpp |
| 1 | 1080×2376 | **120** | 64 | 48 | 8 | 2 | 8 | 2 | 540×72 @8bpp |
| 2 | 1440×3168 | **120** | 88 | 56 | 8 | 8 | 8 | 8 | 720×96 @8bpp |
| 3 | 1440×3168 | 60 | 80 | 80 | 8 | 180 | 180 | 12 | 720×16 @10bpp |

**默认应该用 idx 1（1080×2376@120）**：它是 4K 页 + 120 Hz 的组合，和
`dumpsys display` 报告的实际逻辑尺寸 `1080x2376` 一致，也最适合 gamescope
横屏合成。idx 2/3 是 FHD+ 原生，帧率压力更大，留作可选。

> **注意 idx 0 的 vfp/vbp = 1100/1100**：这不是笔误，是 ANA6706 在 60 Hz
> 下的长 blanking。移植时不要"顺手归一化"成小值——那会改掉实际刷新率。

### 2.2 Pixelworks Iris（**新增的风险项**）

`pxlw,iris-chip-enable` 存在，`pixelworks-i2c` 驱动已绑定在 `i2c@994000`
的 `6-0022` 和 `6-0026` 上。这是一颗**外挂显示协处理器**，负责 MEMC / 插帧 /
色彩处理。

mainline 上**没有 Pixelworks Iris 驱动**，也基本不可能有（闭源固件 + 专有
协议）。

**但有明确的旁路证据**，实测三条：

1. pinctrl 里有 **`iris_abyp_ready_active` / `iris_abyp_ready_suspend`**
   （abyp = *bypass*）——这是硬件旁路握手信号，说明设计上就允许 Iris 不参与。
2. `pxlw,dsi-display-primary-active` 的内容是字符串
   `"qcom,mdss_dsi_samsung_ana6706_dsc_cmd"` —— **主显示直接指向 ANA6706
   面板节点本身**，不经过 Iris 的显示节点。
3. `pxlw,iris-chip-enable` 与 `pxlw,soft-iris-enable` 都是**空属性**
   （DT 里 boolean = true），即两者同时存在——下游驱动在 `soft-iris` 分支下
   走软件路径。

**处置建议**：走 `soft-iris` 旁路，面板由 MDSS 直接驱动，Iris 保持上电但不
参与数据处理。需要保留的只是：
- `iris_vdd18` 供电（否则面板供电链可能不完整）
- `iris_reset` 的释放时序
- `iris_abyp_ready` 的拉高（旁路握手）

具体 GPIO 编号需要在 TLMM 节点里逐个 pin group 反查（本机实测未展开，因为
这是 P3 面板驱动任务的一部分，而不是 P2 的前置条件）。

> **残余风险**：`soft-iris` 路径本身可能仍需要向 Iris 写入一段初始化序列才能
> 真正旁路。这条要等面板驱动能做到"点屏"才能验证，不能提前断言。如果真需
> 要，可以从下游 `pixelworks-i2c` 驱动的初始化表反推——但那是一个闭源微码
> 协议，工作量不可低估。

### 2.3 前向移植方法

参考 alioth 的 patch 0017（`panel-samsung-ams667xx01.c`）的移植注释，它的
三条 API 变更说明对任何 6.19 → 7.2 的面板驱动都成立：

- `drm_panel_init()` 已在 7.2 移除 → `devm_drm_panel_alloc()` 既分配又初始化；
- `.get_orientation` + `of_drm_get_panel_orientation()` 是新加的（Qualcomm
  下游从不读 DT 的 `rotation`）；
- `dsi->dsc_slice_per_pkt` 只存在于 pmOS fork，mainline msm DSI host 只支持
  `slice_per_pkt = 1`。

**旋转**：Qualcomm 下游的旋转约定与 mainline `DRM_MODE_PANEL_ORIENTATION_*`
差 180°。alioth 上 DT 写 `<270>` 实际要 `<90>`。OnePlus 8 Pro 的面板物理
竖装（1080 宽 × 2376 高），大概率也是 `<90>`，但**必须在真机上看控制台方向
确认**——这个值离机无法确定。

---

## 3. 触摸：Samsung S6SY761（我上一轮判断错了）

```
compatible   sec-s6sy761      chip-name  SY79x
i2c          4-0048 (i2c@a94000)
tx-rx        17 × 38
coords       1439 × 3168
irq-gpio     tlmm 39, flags 0x2008 (EDGE_FALLING | ONESHOT)
reset-gpio   tlmm 38
vdd_2v8      0x2de600 = 3009024 µV
```

**好消息**：mainline 有 `CONFIG_TOUCHSCREEN_S6SY761`（pmOS config 里 `=m`），
驱动现成。上游 `sm8250-oneplus-instantnoodlep.dts` 里的触控节点是对的，
不需要重写驱动。

需要做的只是：
1. 把 `=m` 改成 `=y`（阶段 1 无 rootfs，`=m` 等于不存在）；
2. 核对 `vdd` / `avdd` 供电 regulator 在 mainline DTS 里是否存在；
3. 触摸的 **libinput 校准矩阵**照 alioth 的思路重推（同为物理竖装 + gamescope
   横屏）：`LIBINPUT_CALIBRATION_MATRIX="0 1 0 -1 0 1"` 大概率直接可用。

> 上一轮我说"OnePlus 用 Goodix、DTS 是错的"，依据是 OnePlus 8 系列整线
> 传闻。**这个是错的**，实测 `sec-s6sy761` 就在 `4-0048` 上正常工作，
> `getevent` 能看到 `touchpanel` 设备上报 1439×3168。
> 这正是 AGENTS.md 那条规则的实例：**先在真机上验前提，再改代码**。

---

## 4. 音频：这是本移植最大的工作量

### 4.1 实测拓扑

```
声卡    kona-mtp-snd-card
codec   wcd938x_codec (WCD9385) + bolero (rx/tx/va/wsa macro)
功放    nxp,tfa98xx × 2   @ i2c@884000
          tfa98xx_right@34   reset tlmm 91
          tfa98xx_left@35    reset tlmm 99
WSA     qcom,wsa-max-devs = 0   ← WSA881x 完全不存在
aux-dev qcom,wsa-aux-dev-prefix = "SpkrLeft" / "SpkrRight"
```

### 4.2 为什么 alioth 的三个音频补丁**不能**直接用了

alioth 的补丁解决的是 **TDM 后端**问题：
- 0025：给 MI2S codec 位时钟
- 0026：把 `qcom,tdm-invert-sync` / `tdm-data-delay` 送到 ADSP
- 0027：machine driver 支持 TDM 后端

OnePlus 8 Pro 的 TFA98xx **根本不在 TDM 上**。它是 I2C 控制的 I/V 感应功放，
音频数据走 **WCD938x 的模拟输出**（`SpkrLeft` / `SpkrRight` aux dev 前缀
指向的就是它们）。

所以：
- 0026 / 0027 **对本机无用**（它们修的是 TDM 路径）；
- 0025 部分有用（WCD938x 也需要位时钟，但走的是 MI2S 而非 TDM）。

### 4.3 真正要做的

1. **TFA98xx 驱动**：mainline 里没有。NXP 自己在 `linux` 上有过 out-of-tree
   patch（`tfa98xx.c`），需要从 NXP 开源补丁或下游内核移植。
   这是一个**中等规模的新驱动**（~2500 行），带 `rw` / `calibra` /
   `selfcheck` / `temperature` sysfs 接口。
2. **`&sound` 节点**：照 alioth 的形状写，但 `qcom,audio-routing` 要按
   TFA98xx + WCD938x 的实际控件名重推。
3. **UCM profile**：声卡名 `kona-mtp-snd-card`，所以入口是
   `conf.d/sm8250/kona-mtp-snd-card.conf`。
4. **增益安全线**：OnePlus 8 Pro 无听筒、双扬声器对称，比 alioth 的
   RCV/LCV 非对称结构简单。但 TFA98xx 有硬件限幅（`selfcheck` 会读故障位），
   这比 alioth 的"信号链完全无保护"要好——**先读故障寄存器再推增益**。

> **如果不能接受 TFA98xx 驱动的成本**，可以退一步：只做耳机/蓝牙/USB-C
> 音频，扬声器留空。但那样这台机器就不是掌机了。

### 4.4 阶段 1 的简化

阶段 1 只需要 `dmesg` 里看到 `wcd938x` 和 `tfa98xx` 绑定成功，不需要出声。
所以 **`=m` 的音频驱动在阶段 2 才必须变成 `=y`**。

---

## 5. 充电与电量

```
电量计   bq27541-battery @ 8-0055   (TI BQ27541，mainline 有 BATTERY_BQ27XXX)
充电器   bq2597x-charger @ 7-0066 / chgpump-charger @ 7-0019
         dash_fastchg @ 8-0026 / smb1390_slave @ 0x18
```

**本机实测值**：

```
voltage_max_design   = 4420000 µV   (4.42 V)
charge_full_design   = 3991000 µAh  (3991 mAh)
```

对比：
- alioth 是 `4.45 V / 4520 mAh`
- 上游 `sm8250-oneplus-instantnoodlep.dts` 写的是 `4.35 V / 4410 mAh`

**当前 DTS 采用上游的 4.35 V / 4410 mAh（2026-10-25 按要求改回）。**
差异认为是电池批次不同（本机 hw_version=15、sku=3）造成的，不是抄错。

阶段 1 不含充电驱动，这个值此时不影响启动；等阶段 2 接充电时，
先读 `/sys/class/power_supply/bms/voltage_max_design` 再定，
**不要在充电驱动起来之前就按哪个值去写。**

`alioth-charge-guard` 的温度降额看门狗**逻辑可原样复用**，只需重标定
温度曲线（实测待机 23.5 °C 是正常室温，与 alioth 的 38 °C 边充边玩不是
同一个工况）。

---

## 6. USB

```
ssusb@a600000 -> dwc3@a600000
dr_mode          = drd
maximum-speed    = super-speed     ← USB 3.0，alioth 只有 USB 2.0
cmdline: androidboot.usbcontroller=a600000.dwc3
typec port0: data_role "host [device]"  power_role "source [sink]"
第二个口: ssusb@a800000 (DP alt mode)
```

**这是比 alioth 强的地方**，但也有代价：USB 3.0 的 Type-C 方向需要
`typec mux`（SBU/SuperSpeed 切换），而 pmOS wiki 明确记录了 sm8250 DTS 缺
mux endpoint 导致"插反只跑 USB 2.0"的问题。

USB-C host 模式（接有线手柄）要看 `vdd-vbus-supply` 是否接上——alioth
的教训是 `pm8150b.dtsi` 的 typec 节点不带给它，驱动拿到 dummy regulator，
**没有任何东西能打开 VBUS**。OnePlus 8 Pro 要单独验这一条。

---

## 7. 固件：三份都要从本机取

| 固件 | 来源 | 处理方式 |
|---|---|---|
| `a650_zap.mbn` | `/vendor/firmware/a650_zap.{mdt,b00,b01,b02}` | **`pil-squasher`** 合成 |
| `adsp.mbn` | `/vendor/firmware_mnt/image/adsp.{mdt,b00..b18}` | **`pil-squasher`** 合成 |
| `board-2.bin` | `/vendor/firmware_mnt/image/qca6390/bdwlan.e*` (+ `Data.msc`) | **`ath11k-bdencoder`** 合成 |

`a650_gmu.bin` / `a650_sqe.fw` 可以直接拷（不走 PAS，不需要签名）。

> **绝对不能用 `linux-firmware` 里的同名 zap/adsp**。alioth 的实测：两边
> 连字节数都一样，只有签名不同，TrustZone 拒收，表现为黑屏 + 无声。
> 这台机器的 `ro.boot.secboot=enabled`，同样会拒。

**目标路径**（要注意 pmaports 把 gpu 装到 `qcom/`，adsp 装到
`postmarketos/`，两套命名不统一）：

```
/lib/firmware/qcom/a650_zap.mbn
/lib/firmware/qcom/a650_gmu.bin
/lib/firmware/qcom/a650_sqe.fw
/lib/firmware/qcom/sm8250/adsp.mbn        ← 或 postmarketos/adsp.mbn，跟 DTS 对齐
/lib/firmware/ath11k/QCA6390/hw2.0/{amss.bin,m3.bin,board-2.bin}
/lib/firmware/qca/htbtfw20.tlv / htnv20.bin   ← 蓝牙，待确认具体文件名
```

---

## 8. Boot image 与刷机

上游 `deviceinfo` 给的是 **header v2**：

```
pagesize        4096
base            0x00000000
kernel_offset   0x00008000
ramdisk_offset  0x01000000
tags_offset     0x00000100
dtb_offset      0x01f00000
second_offset   0x00000000
header_version  2
```

`kernel/ramdisk/tags/page_size` 这几项和 alioth 完全相同，**只有
`dtb_offset` 和 `header_version` 不同**。

这意味着 `mkbootimg-v0.py` 需要扩展（或换用 `mkbootimg` v2 模式）：
- 加 `--header-version 2` 与 `--dtb-offset`；
- DTB 作为独立的 `dtb` 段，而不是像 alioth 那样直接 `cat` 到 gzip 流后面。

**建议**：先试 alioth 那种"gzip(Image) ++ DTB 追加"的方式（它对 Qualcomm
ABL 普遍有效），失败再切 v2 的独立 dtb 段。两种都便宜。

### 分区与硬规则

| 分区 | 处置 | 理由 |
|---|---|---|
| `abl_a` / `abl_b` | **绝不写** | bootloader，坏了只能 EDL |
| `super` | **绝不写**（若沿用 alioth 的 userdata 方案） | Android 系统分区，保住才能刷回 |
| `vbmeta_a/b` | 不碰 | 已 `orange`，解锁态放行 |
| `dtbo_a/b` | 阶段 1 `erase` | 厂商 overlay 会与 mainline DTS 冲突 |
| `boot_a`（非活动槽） | `--test` 写 | 活动槽是 `_b`，所以先写 `boot_a` |
| `userdata` | 仅 `--install`，需 `ERASE` | 不可逆 |

> **一个和 alioth 的差异**：alioth 的活动槽是 `b`，项目规定"只写 a"。
> 这台机器当前也是 `_b`，**巧合地一致**，所以 `flash-alioth.sh` 的槽位逻辑
> 可以直接沿用。但脚本里的 `getvar product` 必须改成 `instantnoodlep`。

### EDL 退路（比 alioth 好）

```
adb reboot edl                    # 或 音量上+下+电源
```
bootloader 已解锁、`secboot=enabled` 但 `verifiedbootstate=orange`，
EDL 9008 可达。**这意味着即使写坏了 abl，也有比 alioth 便宜的救砖路径**——
但依然不要冒险，规则照旧。

---

## 9. 建议的落地顺序

| 阶段 | 内容 | 交付物 | 判据 |
|---|---|---|---|
| **P0** | 本文档 + 硬件清单 | `docs/op8p/` | done |
| **P1** | 环境：`soc.env` 加 DTB 名，`steamos.config` 加面板/触摸 `=y`，基线编译通过 | `make op8p-kernel` | `boot/KERNEL` 产出 |
| **P2** | 设备树：`sm8250-oneplus-instantnoodlep.dts` 从上游继承 + 按本文修正（`&gpu` 打开、电池 4.42V、面板节点、触摸供电） | DTS 文件 + `assert-op8p-dtb.py` | dtb 断言通过 |
| **P3** | 面板驱动 `panel-samsung-ana6706.c` | patch + 驱动 | 面板点亮、控制台可读 |
| **P4** | 首次真机启动（`--test` 写 `boot_a`） | `boot-debug.img` | 到 initramfs shell / USB ACM |
| **P5** | 固件三件套 | `extract-op8p-firmware.sh` | TZ 接受 zap、ADSP 上线 |
| **P6** | 触摸 `=y` + udev 校准 | overlay | 触摸位置正确 |
| **P7** | TFA98xx 驱动 + UCM | 驱动 + overlay | 出声、故障位为 0 |
| **P8** | Rootfs + Game Mode | `make-op8p.sh --install` | 横屏 Game Mode |

**P4 之前不要碰 P7**。理由和 alioth 一样：黑屏会掩盖每一个后续问题。

---

## 10. 我在这轮里判断错的地方（留档）

1. **"OnePlus 8 Pro 用 Goodix 触摸，DTS 的 s6sy761 是错的"** —— 错。
   实测 `sec-s6sy761` 就在 `4-0048`。
2. **"面板要自己从零写，上游只有 simple-framebuffer"** —— 部分对（上游确实
   没有面板节点），但我低估了可获得的信息量：完整 4 组时序、
   DSC 参数、reset/TE GPIO 都能从运行中的 DT 直接读出来，不需要从下游内核
   反推。
3. **"功放是 CS35L41，照搬 alioth 补丁"** —— 错。是 TFA98xx，音频架构完全不同。

这三条都指向同一个教训，和 `AGENTS.md` 写的一致：
**在真机上读数据，比在仓库和 wiki 里推理可靠得多。**

---

## 11. P1 实施记录（2026-10-25，已编译通过）

### 11.1 一个被实测推翻的推断

我在 §9 的 P1 里写"`soc.env` 加一行 DTB 名即可"。**这是错的**，
第一次编译就失败：

```
make[3]: *** No rule to make target
  'arch/arm64/boot/dts/qcom/sm8250-oneplus-instantnoodlep.dtb'.
  Stop.
```

原因是 ROCKNIX 的 `qcom/Makefile` 第 471 行**已经注册了**
`sm8250-oneplus-instantnoodlep.dtb`，但 `arch/arm64/boot/dts/qcom/` 里
**没有这个 DTS 文件**。ROCKNIX 只留了 Makefile 的挂位，设备树要由
设备包提供——alioth 的 DTS 就是这么来的（`kernel-sm8250/dts/` 下的文件
被 `build.sh` 复制进内核树）。

**正确的做法**是把 DTS 放进 `external-and-mods/kernel-sm8250/dts/`，
`soc.env` 的 `DTBS` 也要加名字（两步都要，缺一不可）。

### 11.2 DTS 的来源与修正

从 `sm8250-mainline/linux`（GitLab, `sm8250/v6.13`）取
`sm8250-oneplus-instantnoodlep.dts`，920 行，依赖的 5 个 dtsi
（sm8250/pm8150/pm8150b/pm8150l/pm8009）在 7.2.8 里全部存在。

改了**一处**：

| 项 | 上游值 | 改成 | 依据 |
|---|---|---|---|
| `&gpu` | `status = "disabled"` | `"okay"` | `kgsl-3d0` 在本机绑定中；不开就没有 Turnip |

电池参数**保持上游**（`4.35 V / 4410 mAh`）。本机实测是
`4.42 V / 3991 mAh`，差异按电池批次处理，等阶段 2 接充电驱动时再定。

### 11.3 内核配置

`steamos.config` 末尾追加了 OnePlus 段。**核心只有一条**：

```
CONFIG_TOUCHSCREEN_S6SY761=y
```

ROCKNIX 默认 `# ... is not set`。改成 `=y` 而不是 `=m`，理由和 alioth
一致：阶段 1 没有 rootfs、没有 modprobe。

**不需要** `CONFIG_SPI_QCOM_GENI`——那是 alioth 的 FT8756 挂在 SPI 上
才要的；S6SY761 在 I2C（`i2c@a94000`）上。这两条在共享的 config 里都
留着，对彼此无害。

音频段**故意留空**：mainline 没有 `SND_SOC_TFA98XX` 这个符号，写了只会
产生 `WARN ... not applied` 的噪音，并让人误以为驱动已就绪。

### 11.4 构建结果（在本机 macOS + Colima 上实测）

| 项 | 值 |
|---|---|
| 宿主 | macOS 27 / Apple M2 (arm64) + Colima vz, 8 CPU / 8 GiB |
| 容器 | fedora:43，**原生 aarch64，不交叉编译** |
| 内核 | `7.2.8-sm8250-steamos` |
| `boot/KERNEL` | 16,652,288 B |
| `boot/Image` | 35,883,520 B |
| DTB 总数 | 12（11 个原有 + `sm8250-oneplus-instantnoodlep.dtb`，127,555 B） |
| 配置断言 | `ARM64_4K_PAGES=y` `PREEMPT=y` `LRU_GEN=y` `S6SY761=y` ✓ |
| 编译告警 | 0 |

DTB 内容核对：

```
$ fdtget -t s dtb / model
OnePlus 8 Pro (instantnoodlep)
$ fdtget -t x dtb / qcom,board-id
8 0 0 0
$ fdtget -t i dtb /battery voltage-max-design-microvolt
4350000
$ fdtget -t s dtb /soc@0/gpu status
okay
```

### 11.5 构建环境的一个坑（macOS 特有）

`build-kernel.sh` 默认把 `WORK` 放在仓库目录下，而 macOS 上这个仓库
通过 **virtiofs** 挂进容器。virtiofs 上 `tar -x` 会把符号链接解成
`----------` 权限的空文件（内核树里有 62 个，如
`scripts/dtc/include-prefixes/arm -> ../../../arch/arm/boot/dts`），
构建随后在 `arm64/boot/dts` 阶段失败，报错离原因很远。

**解法**：把构建目录放在 Docker **named volume** 里（原生 ext4/overlayfs），
产物最后同步回 `work/`。实测在 volume 上解压 152 MiB 内核源码只需 4.5 秒、
零坏文件。

这不是项目的问题，是 macOS 宿主特有的，Linux 宿主上不会遇到。

### 11.6 P1 完成定义

```
[x] soc.env 的 DTBS 加 sm8250-oneplus-instantnoodlep
[x] dts/ 下放入并修正 DTS（GPU / 电池）
[x] steamos.config 加 CONFIG_TOUCHSCREEN_S6SY761=y
[x] 基线编译通过，零告警
[x] DTB 身份与实测一致（board-id 8 0 / msm-id 164 20001 / model）
[ ] boot image 打包（make-*-op8p.sh）—— P2
```

**下一个动作是 P2**：写 `make-op8p.sh`（header v2 + `dtb_offset=0x01f00000`），
产出可刷的 `boot-debug.img`。这一步之后才需要动真机。

---

## 12. P2 实施记录：boot image 打包（2026-10-25）

### 12.1 三个工具，两种打包

| 工具 | header | DTB 位置 | 用于 |
|---|---|---|---|
| `mkbootimg-v0.py`（原有） | v0 | 无 dtb 段，调用方 `cat` 到 kernel 后面 | alioth（小米 ABL） |
| `mkbootimg-v2.py`（**新增**） | v2 | 独立 `dtb` 段 + `dtb_addr` | pmaports 对这台机器的 recipe |
| `make-op8p.sh`（**新增**） | 两者皆可 | — | 统一入口 |

`make-op8p.sh` 默认 `--gzip`（v0），`--v2` 切换。**默认选 gzip 不是偷懒**，
理由见 12.3。

### 12.2 v2 header 的一个坑

AOSP `boot_img_hdr_v2` 里 `recovery_dtbo_offset` 和 `dtb_addr` 是
**uint64**，不是 uint32：

```c
struct boot_img_hdr_v1 : public boot_img_hdr_v0 {   // +16
    uint32_t recovery_dtbo_size;
    uint64_t recovery_dtbo_offset;
    uint32_t header_size;
} __attribute__((packed));
struct boot_img_hdr_v2 : public boot_img_hdr_v1 {   // +12
    uint32_t dtb_size;
    uint64_t dtb_addr;
} __attribute__((packed));
```

→ v0=1632, v1=1648, **v2=1660**。写成 u32 会让 `header_size` 错位，
bootloader 从 header 中间开始读 kernel，症状是黑屏且没有任何报错。
`mkbootimg-v2.py` 里三个尺寸都有 `assert`。

### 12.3 EFI_ZBOOT 与 "THE IMPOSTOR"：一次差点改错的判断

`CONFIG_EFI_ZBOOT=y` 时 `make Image` 产出的**不是**裸 arm64 Image，而是
PE/COFF 包装：开头 `MZ`，0x40 处是 PE 头（machine `0xaa64`），两个段
（`.text` @0x10000 / 24.6 MiB，`.data`）。

我第一版按"arm64 header 在 0x38，正文从 0x40 开始"来切，gzip 了
`d[0x40:]` —— 这等于 **gzip 了 PE 头**。第二版"修正"成抽取 `.text` 段
（30,081,024 字节，首指令 `3f2303d5`），看着更对，**其实更错**：剖出来的
载荷连 arm64 header 都没有。

**实测证据（决定性）**：把 ROCKNIX 自己产出的 `KERNEL` 的 kernel 段
解压，得到的是 **35,883,520 字节、开头 `MZ`、0x38 处 `ARM\x64`** 的文件
——和我们的 `Image` **逐字节相同**。也就是说 ROCKNIX 就是原样 gzip 整个
EFI zboot 包装。而 ROCKNIX 的 ABL 路径正是 pmaports 验证过的那条。

→ 结论：**原样 gzip 整个 `Image`**。`make-op8p.sh` 的 `stage_payload()`
只做一件事：断言 `d[0x38:0x3C] == b"ARM\x64"`（防止将来工具链变了却静默
产出坏镜像），然后 gzip。

```
ours  decompressed 35883520  first4 4d5a40fa  [0x38] ARMd   == ROCKNIX: True
```

这个坑要说清楚，因为两轮都"看起来更合理"，只有拿参考产物对比才定得下来。

### 12.4 打包结果

| | gzip (v0) | v2 |
|---|---|---|
| 文件 | `boot-op8p-gzip.img` | `boot-op8p-v2.img` |
| 大小 | 15,134,720 B | 15,138,820 B |
| header | v0, page 4096 | v2, header_size 1660 |
| kernel 段 | 14,998,534 B gzip | 14,998,534 B gzip |
| DTB | `cat` 在 gzip 后，127,555 B | 独立段，`dtb_addr=0x1f00000` |
| 载入地址 | `0x8000 / 0x1000000 / 0x100` | 同左 |

cmdline（默认**不静音**，理由见下）：

```
video=efifb:off usbcore.interrupt_interval_override=045e:028e:2
mem_sleep_default=s2idle fw_devlink.sync_state=timeout
console=ttyGS0 console=tty0 loglevel=7
rw rootwait root=PARTLABEL=userdata rootfstype=ext4 errors=remount-ro
steamos.usbshell=1 steamos.root=PARTLABEL=userdata
steamos.bootlabel=steamos-arm-no-boot-partition
panic=120 initcall_blacklist=simpledrm_platform_driver_init
```

与 alioth 的 `make-steamos-alioth.sh` 有一处**故意的不同**：alioth 默认
`CMDLINE_QUIET=1`，这里默认 `0`。理由：alioth 那条镜头的**同时**是发布
镜像；而这里目前只会产出**阶段 1 调试镜像**，没有 rootfs、没有 Game Mode，
第一次刷机唯一的意义就是在面板和 ACM 上读内核说了什么，而
`quiet loglevel=0` 恰好把那个静音掉。等这台机器真能进 Steam 再用
`--quiet`。

### 12.5 flash-op8p.sh 与 12 个变异测试

规则（全部接线进代码，不是只写在注释里）：

```
不写 abl_a/abl_b      不写 super      不写 vbmeta*
--test 只写 inactive 槽，且运行时从设备读槽位
--boot 零写入，并明确说明 OKAY 不代表镜像可用
确认必须来自 TTY      声明 set-active 与 EDL 9008 两条退路
```

`scripts/assert-op8p-flash.sh` 用**剔除注释/heredoc/say/echo 之后**的代码
来检查（和 alioth 的 `assert-alioth-flash.sh` 同一思路：`echo "=> fastboot
flash ..."` 和真命令必须分得清）。

12 个故意违规的变异体全部被抓住：

```
✓ flash abl_a            ✓ erase super          ✓ flash 活动槽(同行)
✓ flash 活动槽(新行)     ✓ 写死 boot_b          ✓ -w
✓ erase userdata         ✓ vbmeta               ✓ 去掉 TTY 守卫
✓ 硬编码 prod            ✓ 硬编码 active        ✓ 自动放行确认
```

其中"flash 活动槽(同行)"和"写死 boot_b"第一轮**没抓到**，原因是 BSD
`grep -E` 不接受 `\{\}` 转义（macOS 上报 `invalid repetition count`），
以及整行过滤会把同一行里的第二个 flash 一起滤掉。改成按**每个 boot_ 目标
逐个比对**才抓住。这条也解释了为什么断言必须用变异体验一遍：它在"没有
变异"时会全绿。

### 12.6 P2 完成定义

```
[x] mkbootimg-v2.py（header v2 + dtb 段，尺寸有 assert）
[x] make-op8p.sh（--gzip 默认 / --v2 / --quiet，可复现）
[x] payload 与 ROCKNIX 逐字节一致（决定性对照）
[x] flash-op8p.sh（两条模式，TTY 确认，只写 inactive 槽）
[x] scripts/assert-op8p-flash.sh + 12 个变异体全部通过
[ ] 真机首次启动 —— 需要人在设备旁边
```

**下一个动作是 P4（真机首次启动）**，它不可自动化：需要把手机插上、
进 fastboot、人工输入 `YES`，然后看面板和 `ttyACM0` 上打印什么。
P3（面板驱动）本可以在刷机**之前**做，但更值得先用 simpledrm 把内核
跑起来——因为一旦确认内核能起，后面每次改面板驱动都只需要
`./make-op8p.sh && ./flash-op8p.sh --test`，而不是从黑屏开始猜。

---

## 13. P4 实测：第一次真机启动 —— **失败，但失败得很干净**

2026-10-25，第一次把内核刷进真机。

### 13.1 做了什么

```
./flash-op8p.sh --test        # 写 boot_a（活动槽是 _b）
fastboot --set-active=a
fastboot reboot
```

写入成功：

```
Sending 'boot_a' (14784 KB)   OKAY [0.347s]
Writing 'boot_a'              OKAY [0.070s]
```

### 13.2 结果：设备回到 fastboot，内核没有跑起来

```
current-slot        a
slot-successful:a   no      ← 之前是 yes
slot-unbootable:a   no
```

**`fastboot devices` 能看到设备，`adb` 看不到，`/dev/tty.usbmodem*` 没有出现。**
也就是说：内核没有执行到 USB gadget 初始化（那是在 initramfs 早期）。

另外做了一次**零写入**的 `fastboot boot`，结果一样：

```
Sending 'boot.img' (14784 KB)  OKAY [0.351s]
Booting                        OKAY [0.082s]
```

然后 USB 描述符**完全没有变化**，10 秒内一直是 fastboot。

这与 alioth 的记录一致，`flash-op8p.sh` 的注释里也写了：
**ABL 的 `OKAY` 在跳转之前就返回了，它不证明镜像能启动。**

### 13.3 恢复（成功）

```
fastboot --set-active=b && fastboot reboot
```

**14 秒后 Android 正常回来了。** 恢复路径验证通过，这是本次最重要的收获。

### 13.4 为什么失败：三个候选，还没排除

| # | 假设 | 判据 | 怎么测 |
|---|---|---|---|
| **A** | **packing 不对**：OnePlus ABL 不接受 gzip+追加 DTB 的 v0 镜像 | 镜像一个字节都没执行 | 改试 header v2（`mkbootimg-v2.py` 已经写好了） |
| **B** | **镜像太大**：15 MB 超过 ABL 对 boot_a 的加载限制 | 同上 | 换 v2 会小一点点，或先做一个极小的测试内核 |
| **C** | **内核早期就崩了，且没有日志通道** | 同上 | **加 `console=ttyMSM0`**，用 UART 看 |

**最可能是 A 或 B**，因为现象是"完全没有反应"而不是"跑了一下再死"。

如果是 C，通常会看到：
- 背光闪一下
- 或者 fastboot 后过几秒才回到 fastboot

但我们是**立刻**留在 fastboot，所以更像 bootloader 层就拒绝了。

### 13.5 一个重要发现：没有早期日志通道

原厂 Android 的 cmdline 里有 **`androidboot.console=ttyMSM0`**，
而我们的镜像 cmdline 里**没有**。

```
我们的:  console=ttyGS0 console=tty0 loglevel=7 ...
原厂:    androidboot.console=ttyMSM0
```

`ttyGS0` 是 USB gadget 的 ACM —— 它要等内核跑到 initramfs 才存在。
`tty0` 是 simpledrm 帧缓冲 —— 也要等 DRM 起来。

**在这一切之前，唯一能看见内核说话的地方是 `ttyMSM0`（串口）。**

这条要加。但注意：OnePlus 8 Pro 的 UART 是走 USB-C 的 SBU 引脚（需要
特定线缆）还是走主板焊盘，目前不知道。如果拿不到串口，
**就得靠在多次失败之间做差分**，而不是靠日志。

### 13.6 下一步的验证顺序（成本从低到高）

1. **试 header v2**（0 成本，工具已就绪）
   ```
   ./make-op8p.sh --v2
   ./flash-op8p.sh --test
   ```
2. **加 `console=ttyMSM0`**，尝试拿串口日志
3. **做一个"最小内核"**：只带极简 initramfs、关掉所有非必要驱动，
   把大小压到 5 MB 以内，排除"太大"这个假设
4. 如果都不行，去查 pmaports 对这台机器**实际用的是什么 packing**
   （`deviceinfo_header_version="2"` 和 `dtb_offset=0x01f00000` 是强提示）

### 13.7 这次失败的价值

- **恢复路径被真实验证过**：刷坏 → `--set-active=b` → 14 秒回 Android
- **`flash-op8p.sh` 的行为被真实验证过**：只写 `boot_a`，不碰别的
- **排除掉了"设备处于某种异常状态"这个可能性**：Android 刷完就正常起
- **确认了 `fastboot boot` 在这台机器上不提供信息**

### 13.8 一个必须记下的教训

`getvar product` 在这台机器上返回 **`kona`**（SoC 名），
`getvar all` 里**没有任何机型字符串**（没有 oneplus、没有 instantnoodle、没有 IN2020）。

我原来的 `flash-op8p.sh` 用 `product == instantnoodlep` 做设备校验 ——
**这个检查永远不会触发**，等于没有。任何 SM8250 设备都能通过。

已经改成用**分区几何**校验：

```
boot_a = 0x6000000 (100,663,296)
dtbo_a = 0x1800000 ( 25,165,824)
abl_a  存在（OnePlus A/B 布局，掌机没有）
```

这是本次刷机前抓到的，比事后发现好。

---

## 14. 查清 pmOS 实际怎么打包（结论：差异是 header v2 + 独立 dtb 段）

来源不是猜测。`boot-deploy` 是 postmarketOS 真正生成 boot.img 的工具，
我读了它的 `boot-deploy-functions.sh`（`generate_bootimg()`，约 690–905 行）。

### 14.1 pmOS 的实际命令

```sh
mkbootimg \
  --header_version 2 \
  --kernel       vmlinuz \
  --ramdisk      initramfs                       # mkinitfs 产物，几 MB
  --base         0x00000000 \
  --kernel_offset  0x00008000 \
  --ramdisk_offset 0x01000000 \
  --tags_offset    0x00000100 \
  --second_offset  0x00000000 \
  --pagesize     4096 \
  --dtb_offset   0x01f00000 \
  --dtb          sm8250-oneplus-instantnoodlep.dtb \
  --cmdline      "<cmdline>" \
  -o boot.img
```

`--dtb` 和 `--dtb_offset` 是 `_header_v2` 变量，只在
`deviceinfo_header_version == "2"` 时加上。

### 14.2 `vmlinuz` 到底是什么

这是最关键的一条。`linux-postmarketos-qcom-sm8250/APKBUILD` 的 `package()`：

```sh
if [ -e "$builddir/arch/$_carch/boot/vmlinuz.efi" ]; then
    install -Dm644 .../vmlinuz.efi  "$pkgdir/boot/linux.efi"   # EFI 用的
    install -Dm644 .../vmlinuz      "$pkgdir/boot/vmlinuz"     # boot.img 用的
else
    install -Dm644 .../Image.gz     "$pkgdir/boot/vmlinuz"
fi
```

注释写得很清楚：

> `vmlinuz.efi` — **ZBOOT EFI decompressor for EFI booting**
> `vmlinuz` — **Old GZIP'd kernel image for boot.img compatibility**

也就是说 pmOS 同时产出两个：

| 文件 | 内容 | 用途 |
|---|---|---|
| `linux.efi` | EFI zboot PE（`MZ...`） | systemd-boot / EFI 启动 |
| **`vmlinuz`** | **真正的 gzip 内核（`Image.gz`）** | **塞进 boot.img** |

**`vmlinuz` 不是 `vmlinuz.efi`，也不是把 `vmlinuz.efi` 再 gzip 一遍。**

### 14.3 我们做的三处不同

| # | pmOS | 我们（P4 刷的那个） | 影响 |
|---|---|---|---|
| **1** | header **v2** | header **v0** | ABL 可能只认 v2 |
| **2** | DTB 在**独立 `dtb` 段**（`--dtb`） | DTB **追加在 gzip 流后面** | ABL 可能只从 dtb 段读 |
| **3** | kernel = **真 `Image.gz`**（gzip 流，~15 MB 解压后 30 MB） | kernel = **`gzip(整个 EFI PE)`** | ⚠️ **见下** |
| 4 | ramdisk = **真 initramfs（几 MB）** | ramdisk = **5 字节 `"dummy"`** | v2 规范要求 ramdisk ≠ 0，可能被拒 |

### 14.4 第 3 条的初步判断（**后被 14.5b 推翻**）

`gzip(EFI PE)` 和 pmOS 的 `vmlinuz` 都在 gzip 流里，但**解压出来的东西不同**：

```
pmOS vmlinuz 解压 → 裸 arm64 Image（0x38 处 ARM\x64，从 0x40 开始是指令）
我们 解压       → "MZ" 开头的 EFI PE 文件（0x40 是 PE 头）
```

OnePlus ABL 在解压之后会**跳转到解压结果的开头**。如果它跳到一个 PE 头，
执行的就是 PE 头字节 —— **立刻崩溃或停在某个异常**。

这与我们观察到的现象完全吻合：**完全没有反应**。

我在 P2 时写过一段注释，说 "ROCKNIX 就是原样 gzip 整个 EFI 包装，所以我们也这样做"。
那句是对的（ROCKNIX 确实这样），**但 ROCKNIX 的 ABL 会处理 zboot 包装，
OnePlus 的不一定**。我把一个验证过的做法从一个 bootloader 搬到了另一个。

### 14.5 怎么拿到真正的 `vmlinuz`

我们的内核树只产出了 `Image`（EFI PE），没有 `Image.gz`/`vmlinuz`。
因为 `CONFIG_EFI_ZBOOT=y` 时 `make Image` 直接给 PE，而 `Image.gz` 目标
在别的配置下才生成。

三个办法：

1. **从 EFI PE 里抽出裸 Image**（我 P3 时试过，抽出了 `.text` 段，
   但那段没有 arm64 头，不对）
2. **重新构建时关掉 `CONFIG_EFI_ZBOOT`** —— 这会让 `make Image` 产出
   裸 Image，`make Image.gz` 产出真 gzip。这是最干净的。
3. **用 `objcopy` 从 PE 里取**：PE 的 `.text` 段 + 手工补 arm64 头

**办法 2 最正确**：pmOS 的 config 里 `CONFIG_EFI_ZBOOT=y`（我查过），
但它是**同时**产出 `linux.efi` 和 `vmlinuz` 的，说明那个内核树能产出两者。
ROCKNIX 的 config 也是 `EFI_ZBOOT=y`，而它能产出可用的 boot image（给它的 ABL 用）。

所以正确做法可能是：**在构建时额外跑一次 `make Image.gz`**，
而不是关掉 EFI_ZBOOT。

### 14.5b 更正：第 3 条**不是**根因（2026-10-25 复查）

我写完 14.1–14.5 之后核实了一遍，**14.5 的「第 3 条最严重」是错的**。

事实核查：

```
我们的 Image 头部:
  code0    = 4d5a40fa (MZ)      <- EFI stub
  text_off = 0x0
  img_size = 0x2300000
  magic    = "ARM\x64"  ✓
  pe_off   = 0x40
```

这是**标准的 arm64 Image with EFI stub**，不是「被搞坏的文件」。
`MZ` 开头是 `CONFIG_EFI_STUB=y` 的正常结果，arm64 的 Image 一直长这样。

而且 **ROCKNIX 的 KERNEL 解压出来是完全相同的 35,883,520 字节、
MZ 开头、0x38 是 ARM\x64、pe_off 0x40**。

**所以 gzip 整个 Image 这个做法本身没有错。** 我 P2 时的判断是对的，
P3 时「改成抽 .text」才是错的，现在又差点推翻成第三次错。

`CONFIG_EFI_ZBOOT=y` 也确实存在（我一度读漏），但关掉它重新编译后
`Image` 仍然是 MZ 开头、大小不变 —— 因为 MZ 来自 EFI_STUB，不是 ZBOOT。

**这一点必须写下来。同一个问题上我反复横跳了三次，
每次都有"看起来更合理"的理由。** 可靠的判据只有一个：
**和 ROCKNIX 的实际产物逐字节对比**（已做，完全相同）。

### 14.6 重新聚焦：真正的差异只剩两处

既然 kernel 内容相同，那么和 pmOS 的差异就只剩：

| # | pmOS | 我们 | 可能性 |
|---|---|---|---|
| **1** | header **v2** | header **v0** | ⬆ 高 |
| **2** | DTB 独立 `dtb` 段 | DTB 追加在 gzip 后 | ⬆ 高 |
| 3 | ramdisk 真 initramfs | 5 字节 dummy | 中 |

（kernel 内容：**相同**，已排除）

**这就是为什么下一步应该刷 header v2**：它同时覆盖了 1 和 2 两个差异，
是当前唯一有明确证据支持的改动。

### 14.7 修正后的行动方案

按优先级：

1. **让构建产出 `Image.gz`**（真 gzip 内核）—— 这是根因
2. **打包改用 header v2 + `--dtb` 独立段**（`mkbootimg-v2.py` 已就绪）
3. **ramdisk 给真 initramfs 或至少非 dummy**（先观察，若不必要则跳过）
4. 再刷

第 1 步是关键。第 2 步顺手做（成本为零）。

---

## 15. P4 第二次实测（header v2）：**拿到 ABL 日志，根因确定**

### 15.1 结果

v2 镜像（header v2 + 独立 dtb 段）刷入 `boot_a` 后：

```
t=1..5s  设备从 USB 上完全消失
t=6s     以 fastboot 身份重新出现
```

**与 v0 不同的细节**：v0 是立刻留在 fastboot，v2 是消失 5 秒才回来。
这 5 秒就是 ABL 在尝试。

### 15.2 ABL 日志给出了完整答案

`/dev/block/by-name/abl_log`（`sde67`）里存着 bootloader 自己的日志。
槽 a 那次启动完整记录：

```
Booting from slot (_a)
Load Image boot_a total time: 101 ms
avb_slot_verify.c:245: ERROR: boot_a: Hash of data does not match digest in descriptor.
Load Image dtbo_a total time: 27 ms
VB2: Authenticate complete! boot state is: orange
Decompressing kernel image total time: 336 ms        ← 解压成功了
soc PfId= 0x0 Soc= 0x0 Fid= 0x0 DVId= 0x0 ...
No match found for Soc Dtb type
Error: Appended Soc Device Tree blob not found       ← 真正的原因
Launching fastboot
```

**ABL 成功解压了内核。** 所以：

- ❌ 不是 header 版本问题（v0 和 v2 都解压成功）
- ❌ 不是镜像大小问题
- ❌ 不是 kernel 格式问题
- ✅ **是 DTB 匹配失败**

### 15.3 为什么匹配失败：board-id 写错了

ABL 打印的匹配键是 `Soc=0x0 Fid=0x0`，它在找 **`board-id 0 0`**。

对照原厂 `boot_b.img` 的 dtb 段（1,566,663 字节，含 **3 个** DTB）：

| DTB | qcom,msm-id | qcom,board-id | model |
|---|---|---|---|
| #0 | `164 20001` | **`0 0`** | kona v2.1 SoC |
| #1 | `164 20000` | **`0 0`** | kona v2 SoC |
| #2 | `164 10000` | **`0 0`** | kona v1 SoC |

**原厂三个 DTB 的 board-id 全是 `0 0`**，靠 msm-id 区分 SoC 版本（v1/v2/v2.1）。

而我们用的 DTS 写的是：

```dts
qcom,msm-id = <0x164 0x10000>, <0x164 0x20001>;
qcom,board-id = <0x08 0x00>, <0x00 0x00>;   ← 第一个是 <8 0>
```

上游 sm8250-mainline 那份 DTS 把 `<8 0>` 写在前面。ABL 用 `board-id 0 0`
去匹配，第一个就对不上 —— 而且**它似乎不尝试第二个**，直接报错。

### 15.4 另一个发现：DTB 必须「追加」还是「独立段」

日志里 `Error: Appended Soc Device Tree blob not found` 这句话里的
"Appended" 值得注意。

但原厂用的是**独立 dtb 段**（header v2），而且能正常启动。
所以 ABL 的 "Appended" 只是它内部的措辞，不代表必须追加。

**真正的差异是 board-id，不是存放位置。**

### 15.5 下一步（一字之改）

只改一处：**把 `qcom,board-id = <8 0>` 去掉，只保留 `<0 0>`**。

```dts
-	qcom,board-id = <0x08 0x00>, <0x00 0x00>;
+	qcom,board-id = <0x00 0x00>;
```

保留两个 msm-id（`0x10000` 和 `0x20001`）覆盖 v1/v2.1。
或者更稳的做法：**照原厂，放三个 DTB**（v1 / v2 / v2.1 三个变体）。
但本机实测 `platform_id=356`、`hw_version=15`，对应 `20001`，
所以一个 `msm-id 164 20001` + `board-id 0 0` 应该就够。

### 15.6 这次最值得记的方法

**`abl_log` 分区里存着 bootloader 的完整日志。**

前面我一直在猜（header 版本、镜像大小、kernel 格式、ramdisk 大小），
猜了四轮。而答案就写在设备自己的分区里，一条 `strings` 就能读出来。

这与 `AGENTS.md` 那条规则完全一致：**「两个猜测都猜不中就打印数据」**。
我猜了四个才想起去找日志。

**下次刷机前就该先备好读 `abl_log` 的方法**，而不是失败后再找。

---

## 16. P4 第三次实测：board-id 不是全部原因

改 `board-id = <0 0>` 后刷入，**同样的错误**：

```
Load Image boot_a total time: 101 ms
Decompressing kernel image total time: 336 ms
No match found for Soc Dtb type
Error: Appended Soc Device Tree blob not found
```

### 16.1 但日志里有一组决定性的对照

**失败时（我们的镜像）：**
```
soc PfId= 0x0 Soc= 0x0 Fid= 0x0 DVId= 0x0 DMa= 0x0 DMi= 0x0 PS= 0x0 MV= 0x0 pr= 0 hw= 0
```

**成功时（原厂 boot_b）：**
```
soc   PfId= 0x164 Soc= 0x20001 Fid= 0x0 DVId= 0x0 ... MV= 0x50033000
board PfId= 0 Soc= 0 Fid= 0 DVId= 8 DMa= 0 DMi= 0 PS= 0 MV= 0x30003006 pr= 19811 hw= 15
Apply Overlay total time: 429 ms
```

**ABL 从我们的镜像里读到的 SoC 值是全 0。**
它根本没解析到我们 header 里那个 dtb 段的 `msm-id`。

### 16.2 原厂的启动是「两级 DTB + overlay」

日志里的顺序揭示了这个 ABL 的真实流程：

```
1. 读 SoC DTB        -> soc PfId=0x164 Soc=0x20001      (msm-id 匹配)
2. 读 board DTB      -> board ... pr=19811 hw=15        (board-id / prj hw)
3. Apply Overlay     -> 429 ms                          (把 dtbo 合并)
```

第 1 步失败，后面全不执行，直接 `Launching fastboot`。

原厂 `boot_b.img` 的 dtb 段里有 **3 个 DTB**（v1/v2/v2.1），每个 500 KB 左右，
那是**完整的 Qualcomm SoC DTB**（包含所有 QUP/i2c 控制器、时钟、电源域定义），
不是 mainline 那种精简 DTS。

我们的 DTB 只有 128 KB，是 mainline 的 `sm8250.dtsi` + 设备节点，
**结构上不是 ABL 期待的那种「SoC DTB」**。

### 16.3 所以真正的问题是什么

`Error: Appended Soc Device Tree blob not found` 这句话的字面意思是：
**在 kernel 后面追加的那块区域里没找到 SoC DTB。**

原厂的 3 个 DTB 放在 **header v2 的 dtb 段**里，而且能工作。
但注意：原厂那个 dtb 段里的 DTB **本身就是完整的 Qualcomm SoC DTB 格式**
（`model = "Qualcomm Technologies, Inc. kona v2.1 SoC"`），
mainline DTS 的 `model` 是 `"OnePlus 8 Pro (instantnoodlep)"`。

ABL 可能在 dtb 段里**按 model 字符串或固定结构**找 SoC DTB，找不到就报这个错。

### 16.4 三条可能的出路

| # | 做法 | 代价 | 把握 |
|---|---|---|---|
| **A** | 在 dtb 段里**同时放原厂的 SoC DTB + 我们的 DTB** | 简单：把原厂 3 个 DTB 拷进我们的镜像，再追加 mainline DTB | 中 |
| **B** | 用 **dtbo 分区**承载，`dtbo_idx` 指向它 | 需要构造 dtbo 镜像 | 中 |
| **C** | 让 kernel **自己带 DTB**（`CONFIG_ARM64_APPENDED_DTB` 或 zboot 内置） | 需要重编，且 ABL 可能仍然要求外部 DTB | 低 |

**A 最值得先试**：把原厂的 3 个 SoC DTB 原样放进 dtb 段，
让 ABL 的两级匹配都通过；然后 mainline 内核实际用的是**追加在 kernel 后面
或 zboot 里**的那份。

但这里有个矛盾：ABL 报的是 "Appended ... not found"，
说明它**期望 DTB 追加在 kernel 后面**，而不是 dtb 段。

### 16.5 下一步该做的：读 ABL 的代码而不是继续猜

我已经猜了五次（header v0/v2、镜像大小、kernel 格式、ramdisk、board-id）。
这条路的成本已经超过收益。

**正确做法**：从 `abl_a` 分区里反汇编，找
`"Appended Soc Device Tree blob not found"` 这个字符串的引用，
看它在什么条件下触发、期望的 DTB 在哪个偏移。

`abl_a` 是 8 MiB 的 ELF，里面有完整字符串表。这条路能一次问到底。

### 16.6 另一个更简单的检验

在做反汇编之前，有一个便宜得多的实验：

**把原厂的 3 个 SoC DTB 原样拷出来，先单独刷一个"只有原厂 DTB + 我们的 kernel"
的镜像**。如果它能过 SoC DTB 匹配，再谈下一步。

这能直接区分「ABL 要求 Qualcomm 格式的 SoC DTB」和「ABL 只是读不到」。

---

## 17. **P4 成功：内核起来了**（2026-10-25）

### 17.1 突破点：`erase dtbo`，不是 `flash dtbo`

`flash-op8p.sh --test` 现在的动作是：

```
fastboot flash boot_a  boot-op8p-gzip.img     # header v0，DTB 追加在 gzip 后
fastboot erase dtbo_a                          # 擦除，不是刷空表
fastboot --set-active=a && fastboot reboot
```

启动后 **11 秒**，主机侧看到：

```
"USB Product Name" = "SteamOS ARM debug shell"
/dev/cu.usbmodem1101
/dev/cu.usbmodem1103
```

**两个 ACM 串口都枚举出来了**，说明：

- ABL 加载并解压了内核
- 内核跑过了 head.S / C 启动
- `initramfs/init` 里的 `usb_shell` 执行了：configfs gadget 建好、acm.usb0 + acm.usb1 + ncm.usb0 绑定、UDC 注册成功
- `console=ttyGS0` 生效（两个 ACM 之一就是它）

这是阶段 1 的第一个硬指标，**通过了**。

### 17.2 为什么是 erase，而不是别的

`docs/alioth.md` 里早就记着这条，作者在小米 ABL 上验证过：

> `Dtbo hdr magic mismatch 0, with D7B7AB1E` → `Best match DTB tags ...`
> → 启动成功
>
> **`erase dtbo_<槽>` 有效且被容忍**（magic 0 = 已擦除）。bootloader
> 跳过 overlay，直接用追加在内核后面的 DTB。

关键区别是 **magic 为 0**（分区全零）与**合法表但零 entry**：

| dtbo 分区状态 | ABL 行为 |
|---|---|
| 原厂 11 overlay | 走 overlay 流程 → board-id 对不上 → `No match found` |
| **erase（全 0，magic=0）** | **跳过 overlay，直接用追加的 DTB** ✓ |
| 合法 table，0 entry | `Error: Board Dtbo blob not found` |
| 合法 table，1 桩 | 身份匹配 ✓，但 `ufdt apply overlay failed` |
| 合法 table，原厂 ovl5 | 身份匹配 ✓，但 `ufdt apply overlay failed` |

最后两行失败的原因是结构性的：Qualcomm overlay 用
`target = <0xffffffff>` + `__fixup__` 解析路径，而那套路径只存在于
Qualcomm 的 DTS 里，mainline 的 `sm8250.dtsi` 没有对应节点。
**erase 直接绕开了整个合并步骤。**

### 17.3 我在这件事上绕的弯路（十个阶段）

| # | 组合 | ABL 日志 | 我的错误判断 |
|---|---|---|---|
| 1 | v0 + 追加DTB + 原厂dtbo | `No match found for Soc Dtb type` | 以为要改 header |
| 2 | v2 + 独立段 + 原厂dtbo | 同上 | 以为 pmOS 能跑所以我们也行 |
| 3 | 改 board-id `0 0` | 同上 | **抄错了方向** |
| 4 | 裸 DTB 桩 | `Dtbo hdr magic mismatch` | 没查 dtbo 格式规范 |
| 5 | table + 桩 | `ufdt failed` | 以为格式对了就行 |
| 6 | 桩 + 空 fragment | `ufdt failed` | 以为 fragment 是关键 |
| 7 | 桩 + 原厂匹配键 | 身份 ✓，`ufdt failed` | 以为身份是关键 |
| 8 | table + 原厂 ovl5 | 同上 | 以为 overlay 内容是关键 |
| 9 | 空 table（0 entry） | `Board Dtbo blob not found` | 以为"空"等于"没有" |
| **10** | **erase dtbo** | **启动成功** | — |

**第 9 步和第 10 步只差一个词，但语义完全不同**：ABL 区分
"magic 0 → 没有 dtbo" 和 "magic 存在 → 有 dtbo 但内容空"。

### 17.4 真正的教训

`AGENTS.md` 里写的移植步骤如下，其中**没有一条**提到 dtbo：

```
1. 确认 4K 页
2. 设备树
3. Boot image 格式   ← 我在这里花掉了全部十次
4. 日志通道
...
```

而 `docs/alioth.md` 的 "Xiaomi ABL 的实际行为" 一节里，
**erase dtbo 就写在第一张表的第二行**。

我在 P2 写 `flash-op8p.sh` 时，把 alioth 的 `erase dtbo` 规则删掉了，
理由是「OnePlus 不需要」——**那个理由是编的，没有任何证据**。
删掉一条已知规则，比留下它需要更强的证据，而我当时没有。

### 17.5 现在的状态

```
✓ 内核启动
✓ USB gadget（ACM x2 + NCM）
✓ 阶段 1 的日志通道建立
? 面板      —— DTS 里 panel status = "disabled"，预计黑屏
? 触摸      —— S6SY761 已 =y，需要看 dmesg
? Wi-Fi/BT  —— ath11k 需要本机固件
? GPU       —— 需要 a650_zap.mbn（本机签名）
```

### 17.6 下一步

1. **配好主机侧的 NCM 地址**，用 `nc 172.16.42.1 23` 进 shell 看 dmesg
   （需要 `sudo ifconfig en8 172.16.42.2/24 up`；`en8` 的 MAC 是
   `02:00:00:00:00:00`，就是 NCM gadget）
2. 从 dmesg 里读：面板 probe 情况、触摸、UFS、USB、ramoops
3. 再决定面板驱动（patch 0029 已就绪，只差 DTS 里把 status 打开）

---

## 18. 显示链调试（2026-10-26 凌晨）：从全黑到"先花后黑"

P4 成功后内核在跑，但屏幕是黑的。这一节记录从"全黑"推到最后两个
具体缺陷的过程，以及每个缺陷是怎么被证伪或确认的。

### 18.1 起点：整条链都没有日志

```
msm-mdss ae00000.display-subsystem: deferred probe timeout
msm-mdss ...: probe with driver msm-mdss failed with error -110
```

`/sys/class/drm/` 里只有 `version`，`/dev/dri/` 是空的。
`-110` 是 `-ETIMEDOUT`，12.27 秒（deferred probe 窗口）之后才报。

### 18.2 缺陷一：`&dispcc` 是 `disabled`

上游 `sm8250-oneplus-instantnoodlep.dts` 里：

```dts
&dispcc {
       status = "disabled";
};
```

和 `&gpu` 一样，是 sm8250-mainline 为了先跑通其他外设而关掉的。

**怎么找到的**：在运行中的内核上直接读设备树：

```
~ # cat /proc/device-tree/soc@0/clock-controller@af00000/status
disabled
```

`af00000` 就是 dispcc。改成 `okay` 之后，MDSS 立刻不再超时，
`card0`、`card0-DSI-1`、`renderD128` 全部出现。

**这条值得记住**：`/proc/device-tree/.../status` 能直接告诉你某个
device tree 节点到底有没有启用，比读 dmesg 猜快得多。

### 18.3 缺陷二：暴露了 1440 宽的模式

改完 dispcc 后：

```
DSI: pic_width 1440 has to be multiple of slice 540
```

面板是 DSC，`ana6706_dsc_cfg` 里 `slice_width = 540`，只能整除 1080。
驱动却把厂商 DT 的四组时序全暴露了，其中 timing@2/@3 是 1440×3168。

DRM 选了 1440 那个模式，msm 直接拒绝。

**修法**：只暴露 1080×2376 的两个模式（timing@0/@1）。1440 需要
`slice_width = 720` 和另一套 DSC 参数，那是运行时切换时序的活，
不属于当前范围。

### 18.4 缺陷三（最关键）：`MIPI_DSI_MODE_VIDEO_BURST` 用错了

到这里 `card0`、`DSI-1`（`enabled`）、`1080x2376` 全都有了，但屏幕还是黑。

写了一个 `drmtest`（见 18.6）强制 `drmModeSetCrtc`，**返回成功**，
屏幕依然全黑。这排除了"没有 compositor 所以没人推帧"这个解释。

**决定性的方法：在面板驱动里加一行 `dev_info`。**

```c
dev_info(&dsi->dev, "init sequence start\n");
```

改动前的完整 dmesg 里，与面板相关的只有两行：
`supply avdd not found` 和 `bound ae94000.dsi`。
**`init sequence start` 一次都没有出现过** ——
面板的 DCS 初始化序列从未执行过。

原因在 `mode_flags`：

```c
/* 错的 */
dsi->mode_flags = MIPI_DSI_MODE_VIDEO_BURST | MIPI_DSI_MODE_LPM |
                  MIPI_DSI_MODE_NO_EOT_PACKET;

/* 对的 */
dsi->mode_flags = MIPI_DSI_MODE_LPM | MIPI_DSI_MODE_NO_EOT_PACKET;
```

这个错误的来源是照抄厂商 DT：

```
qcom,mdss-dsi-traffic-mode = "burst_mode"
```

我把 Qualcomm 的 "burst" 直接翻译成了 `MIPI_DSI_MODE_VIDEO_BURST`。
两者不是一回事：

| | 含义 |
|---|---|
| Qualcomm `burst_mode` | 主机把一帧怎么打包到 DSI 链路上 |
| MIPI `MIPI_DSI_MODE_VIDEO_BURST` | **面板处于 video mode** |

我们的面板是 `dsi_cmd_mode`（命令模式）。设了 VIDEO 位，msm 走 video
路径，`drm_panel_prepare` / `enable` 就永远不会被调用 —— 面板一次都
没被初始化过。

改完之后：

```
[1.250485] panel-oneplus-ana6706 ae94000.dsi.0: init sequence start
```

**这是整晚最有价值的一行日志。**

### 18.5 当前状态：先花后黑

初始化序列跑起来了，`drmtest` 的 `SETCRTC` 也成功，屏幕上出现的是
**先花一下、然后黑**。

与之前"纯黑、毫无反应"的区别是实质性的：面板现在**收到了东西**，
只是内容或时序不对。

已经排除和待查的：

| 项 | 状态 |
|---|---|
| DSI 链路 | ✅ `dsi_isr` 以 ~10 Hz 持续触发 |
| 面板初始化序列 | ✅ 执行了（有日志） |
| `SETCRTC` 提交 | ✅ 返回 0 |
| 背光 | ✅ `actual_brightness` 1023/2047，`bl_power` 0 |
| fb0 状态 | 曾被 console blank 设成 `4`（POWERDOWN），已改回 `0` |
| **DSI PLL** | ❌ `lock failed, status=0x00000000`，**待查** |
| **DSC 参数** | ⚠️ 只验证过 `slice_width` 能整除，未验证 PPS 是否正确 |

**"先花后黑"最可能的两个原因**（下一个会话从这里开始）：

1. **DSI PLL 没锁**。`status=0x00000000` 是寄存器全零，不是"未锁定"
   的位模式，说明 PLL 根本没有被时钟驱动。没有 PLL 就没有稳定的
   DSI 时钟，画面会先出垃圾再消失。
2. **DSC PPS 不匹配**。`ana6706_dsc_cfg` 里的 `bits_per_pixel`、
   `slice_height`、`rc_*` 等 20 多个参数只填了 6 个，其余是零。
   DSC 压缩参数错的话，解压出来就是噪声。

### 18.6 新增工具：`drmtest`

`external-and-mods/kernel-common/initramfs/drmtest.c`

在没有 compositor 的 initramfs 里强制 `drmModeSetCrtc` 提交一帧纯色，
用来区分"硬件坏了"和"没人驱动"。

编译（结果不进 git，`build.sh` 检测到才打进 initramfs）：

```bash
docker run --rm -v "$PWD/external-and-mods/kernel-common/initramfs:/src:ro" \
  -v "$PWD/work:/out" fedora:43 bash -c \
  'dnf -q -y install gcc glibc-static && \
   gcc -static -Os -s -o /out/drmtest /src/drmtest.c'
cp work/drmtest external-and-mods/kernel-common/initramfs/
```

用法：`drmtest`（白色）或 `drmtest 0xff 0 0`（红色）。

它只依赖 `drm.h` / `drm_mode.h` 和 raw ioctl，不需要 libdrm，所以能
静态编译成一个可执行文件。

### 18.7 这一节里失败过的路径（都记下来）

为了让下一个会话不要重走：

| 试过 | 结果 | 结论 |
|---|---|---|
| 只改 `&dispcc` | MDSS 起来，但仍黑 | 必要不充分 |
| 保留 1440 模式 | `pic_width 1440 has to be multiple of slice 540` | 必须去掉 |
| `clk_ignore_unused pd_ignore_unused` | PLL 仍然 `status=0` | 不是时钟被关的问题 |
| `echo 0 > /sys/class/graphics/fb0/blank` | 无变化 | blank 不是主因（虽然它确实是 4） |
| 往 `/dev/tty0` 写、往 `/dev/fb0` 写 | 无变化 | fbcon 不触发 modeset |
| `drmtest` 用 `MIPI_DSI_MODE_VIDEO_BURST` | `SETCRTC` 成功但全黑 | **初始化序列被跳过** |
| 去掉 VIDEO 位 | `init sequence start` 出现，先花后黑 | **前进了一大步** |

### 18.8 顺带修掉的：Wi-Fi GPIO 属性名

```
qca6390-pmu: deferred probe pending:
pwrseq-qcom_wcn: Failed to get the WLAN enable GPIO
```

`pwrseq-qcom-wcn.c` 里要的是：

```c
devm_gpiod_get_optional(dev, "wlan-enable", ...);
```

所以属性名必须是 **`wlan-enable-gpios`**。上游 sm8250-mainline 写的是
`wlan-en-gpios`（Qualcomm 下游的叫法），驱动从来读不到。
旁边的 `bt-enable-gpios` 已经是对的，只有 wlan 这条漏了。

（改完还没验证 —— 需要单独一次启动看 dmesg。）

### 18.9 下一步（按优先级）

1. **查 DSI PLL 为什么不锁**。`status=0x00000000` 需要看 PLL 的
   `pll_base` 是否被正确映射、`gdsc`（power domain）是否打开。
   `CONFIG_PM_GENPD_DEBUG` 没开，先打开它再读
   `/sys/kernel/debug/pm_genpd/pm_genpd_summary`。
2. **补全 DSC 参数**。从面板的 PPS 反推（厂商 DT 的
   `qcom,mdss-dsc-*`），把 `drm_dsc_config` 里其余字段填满。
3. 验证 Wi-Fi GPIO 修复。

---

## 19. 显示链调试（续）：从"纯黑"到"花屏"再到定位到 DCS 时序

第 18 节停在"先花后黑"。这一节是之后几小时的进展，**结论比第 18 节强得多**，
也推翻了第 18 节里的两个判断。

### 19.1 先纠正第 18 节里的两个错误判断

#### 错误一：以为 `mipi_dsi_dcs_read()` 返回 1 是失败

日志是 `readback: power_mode r=1 0x0c`。我以为 `r=1` 是错误码，
于是断定"DSI 读通道不通"。

**实际上 `mipi_dsi_dcs_read()` 返回的是读到的字节数。** `r=1` 表示
**成功读到 1 个字节**。这个误读让整条排查方向偏了很久。

教训：**API 的返回值语义必须查源码确认，不能按名字猜。**

#### 错误二：以为 DSC 参数缺失是根因

我以为 `drm_dsc_config` 那 39 个字段只填了 6 个会出问题。
查 `drivers/gpu/drm/msm/dsi/dsi_host.c` 才发现：

```c
/* dsi_populate_dsc_params()，由 dsi_host mode_set 调用 */
drm_dsc_set_const_params(dsc);
drm_dsc_set_rc_buf_thresh(dsc);
drm_dsc_setup_rc_params(dsc, DRM_DSC_1_1_PRE_SCR);
dsc->initial_scale_value = drm_dsc_initial_scale_value(dsc);
return drm_dsc_compute_rc_parameters(dsc);
```

**msm 在 mode_set 时会自动补全所有字段。** 只填几何参数本来就是对的。

### 19.2 真正的进展：把面板的 PPS 解码出来

面板的 PPS 在 init sequence 的 `0x9e` 命令里，88 字节。
按 `drm_dsc_pps_payload_pack()` 的实际布局逐字段解开：

| 字段 | 值 | | 字段 | 值 |
|---|---|---|---|---|
| `dsc_version` | 1.1 | | `initial_offset` | 6144 |
| `line_buf_depth` | 9 | | `final_offset` | **4336** |
| `bits_per_component` | 8 | | `flatness_min_qp` | **3** |
| `bits_per_pixel` | 8.0 | | `flatness_max_qp` | **12** |
| `pic_width` × `pic_height` | 1080 × 2376 | | `rc_model_size` | **8192** |
| `slice_width` × `slice_height` | 540 × 72 | | `rc_edge_factor` | 6 |
| `slice_chunk_size` | 540 | | `rc_quant_incr_limit0/1` | 11 / 11 |
| `initial_xmit_delay` | 512 | | `rc_buf_thresh` | 14,28,42,56,70,84,98,105,112,119,121,123,125,126 |
| `initial_dec_delay` | 594 | | `rc_tgt_offset` | 0x0b |
| `initial_scale_value` | 32 | | `rc_range_parameters` | 15 组 |
| `scale_increment_interval` | 1595 | | | |
| `scale_decrement_interval` | 7 | | | |
| `first_line_bpg_offset` | 15 | | | |
| `nfl_bpg_offset` | 433 | | | |
| `slice_bpg_offset` | 362 | | | |

**这一步的关键是布局**：PPS 是字节序列，不是 bit-packed 三元组。
我一开始按 3 字节一组解码，全错；后来漏掉 `pps26_reserved` 这个
1 字节字段，导致后面全部偏移。**最终靠读内核结构定义逐字段对出来。**

### 19.3 codex 补的 DSC 参数：一半对，一半错

对比如下（左：面板 PPS 真值，右：codex 填的）：

| 字段 | PPS | codex | |
|---|---|---|---|
| `line_buf_depth` | 9 | 9 | ✅ |
| `pic_width/height` | 1080/2376 | 同 | ✅ |
| `slice_width/height` | 540/72 | 同 | ✅ |
| `slice_chunk_size` | 540 | 540 | ✅ |
| `initial_xmit_delay` | 512 | 512 | ✅ |
| `initial_dec_delay` | 594 | 594 | ✅ |
| `initial_scale_value` | 32 | 32 | ✅ |
| `scale_increment_interval` | 1595 | 1595 | ✅ |
| `scale_decrement_interval` | 7 | 7 | ✅ |
| `nfl_bpg_offset` | 433 | 433 | ✅ |
| `slice_bpg_offset` | 362 | 362 | ✅ |
| `initial_offset` | 6144 | 6144 | ✅ |
| `rc_quant_incr_limit1` | 11 | 11 | ✅ |
| `rc_buf_thresh` | 14 项 | 同 | ✅ |
| **`final_offset`** | **4336** | 4096 | ❌ |
| **`flatness_min_qp`** | **3** | 16 | ❌ |
| **`flatness_max_qp`** | **12** | 16 | ❌ |
| **`rc_model_size`** | **8192** | 780 | ❌ 差 10 倍 |
| **`rc_quant_incr_limit0`** | **11** | 6 | ❌ |

另外 `rc_edge_factor` 和 `rc_tgt_offset_*` 填了也没用：
`drm_dsc_pps_payload_pack()` 会**用常量覆盖**它们
（`DSC_RC_EDGE_FACTOR_CONST` / `DSC_RC_TGT_OFFSET_*_CONST`）。

**已经在代码里按真值修正，并在注释里说明了为什么这几个字段不能乱填。**

### 19.4 最重要的一条：`0x11` 没有让面板退出睡眠

写了一个可逆性探针（`ana6706_init_sequence()` 末尾）：

```c
a = 读 power_mode            /* 序列刚跑完 */
发 0x10 (enter_sleep), 120 ms
b = 读 power_mode
发 0x11 (exit_sleep), 120 ms
发 0x29 (display_on), 20 ms
c = 读 power_mode
```

实测结果：

```
probe: get_power_mode a=1/0x0c b=1/0x0c c=1/0x9c err_count=1/0x00
```

按 MIPI DCS 的 `get_power_mode` 位定义：

| 位 | 含义 | a=0x0c | c=0x9c |
|---|---|---|---|
| bit7 | booster voltage | 0 | **1** |
| bit4 | sleep out | **0** | **1** |
| bit3 | booster on | 1 | 1 |
| bit2 | display on | 1 | 1 |
| bit1:0 | display mode | 0 | 0 |

**`a` 的 `sleep_out = 0`，说明整个初始化序列跑完之后，面板仍然在睡眠状态。**

而 `c` 的 `sleep_out = 1`、`booster voltage = 1`，这才是真正醒着的状态。

**所以：序列里的 `0x11` 没生效，但探针里单独发的 `0x11` + `0x29` 生效了。**

### 19.5 三个可能的解释

| # | 解释 | 怎么区分 |
|---|---|---|
| **A** | 序列里 `0x11` 后的 11 ms 延迟不够（探针用了 120 ms） | 已把序列改成 120 ms |
| **B** | `0x11` 本身不唤醒，是末尾的 `0x29` 唤醒的 | 下一次探针会把 `0x11` 和 `0x29` 分开读 |
| **C** | 序列中间某条私有命令（`0xf0`/`0xb0` 那类）打断了 sleep-out | 需要逐条二分 |

**这三点是下一轮要一次性分开的**，探针已经改好（等 0x11 后读一次 → d，
发 0x29 后再读一次 → c）。

### 19.6 一个重要的观察：花屏说明写通道是好的

期间有一版镜像屏幕**出现了花屏**。这是整个调试过程里最有信息量的现象：

- 花屏 = **面板收到了画面数据**
- 因此 DSI 写通道、面板唤醒、DPU 输出都是通的
- 问题在**画面内容**（DSC 参数或时序），不在链路

而且它和第 18 节的"先花后黑"一致：**这台机器的面板并非完全不响应，
而是数据不对。**

### 19.7 期间踩的坑：驱动注册被截断

有一版编译后 `/sys/class/drm/` 里只有 `version`，面板驱动不 probe。
编译日志里：

```
warning: 'ana6706_probe' defined but not used
warning: 'ana6706_of_match' defined but not used
```

原因：我用脚本从补丁里提取驱动源码再重新 diff，提取逻辑在文件末尾截断了，
**`module_mipi_dsi_driver(ana6706_driver)` 那一行丢了**。

驱动编进去了但没有注册，所以不会 probe。

**教训**：补丁里嵌整个源文件（`@@ -0,0 +1,N @@`）这种形式，
任何脚本处理都必须校验 `N` 与实际 `+` 行数一致。
现在每次生成补丁后都要跑这个检查。

### 19.8 当前代码状态（已编译，未刷写）

`patches/0029` 现在包含：

| 内容 | 状态 |
|---|---|
| 完整 DCS 初始化序列（668 字节转录） | ✅ |
| `MIPI_DSI_MODE_VIDEO_BURST` 已去掉（命令模式） | ✅ |
| `avdd` 供电器已去掉（硬件没有） | ✅ |
| sleep-out 延迟 11 ms → **120 ms** | ✅ 待验证 |
| DSC 参数按真实 PPS 修正 5 个字段 | ✅ 待验证 |
| 可逆性探针（分开读 0x11 和 0x29） | ✅ 待验证 |
| 驱动注册（`module_mipi_dsi_driver`） | ✅ 已修复 |

**下一次刷机应当一次回答 19.5 里的三个问题，并验证 DSC 修正是否消除花屏。**

### 19.9 下一轮的正确做法

1. 刷入当前镜像，读 `probe: power_mode a=.. b=.. d=.. c=..`
2. 按 `d` 和 `c` 的值判断是 A / B / C 哪种
3. 如果 `c=0x9c` 且屏幕**不再花屏**，说明 DSC 参数修对了 —— 那很可能就亮了
4. 如果还花屏，问题在时序（porch / 帧率），查 `ana6706_modes[]` 的 clock 计算

### 19.10 本轮代码已编译完成（未刷写）

```
Image        36,473,344 B
boot-op8p-gzip.img  15,413,248 B
DTB          127,987 B
编译告警      0
```

驱动内容校验（在内核树里直接确认，不是看补丁）：

```
module_mipi_dsi_driver   1   ← 注册在
rc_model_size = 8192     1   ← DSC 已按真实 PPS 修正
120000 (sleep-out delay) 2   ← 序列 + 探针各一处
after 0x11 (probe 分离)  1   ← 探针已分开读 0x11 和 0x29
```

**下次刷入后要读的一行：**

```
probe: power_mode a=.. b=.. d=.. c=.. err_count=..
```

- `a` 是序列跑完时的状态。如果 `a = 0x9c`，说明 120 ms 的修改就解决了问题。
- 如果 `a` 仍是 `0x0c` 但 `d = 0x9c`，说明 `0x11` 单独就能唤醒，
  序列里别的东西把它又打回去了 —— 那时要二分序列。
- 如果 `d` 仍是 `0x0c` 而 `c = 0x9c`，说明是 `0x29`（display on）
  在唤醒它，那 `0x11` 的延迟就不是问题，序列结构要调整。

### 19.11 一个值得记下的构建坑

有一次编译在 `net/wireless/util.o` 失败：

```
fixdep: error opening file: net/wireless/.util.o.d: No such file or directory
```

这不是代码问题，是**上一次构建被中途取消留下的半成品目录**。
`rm -rf` 掉 `linux-7.2.8` 再编译即可。

另一次失败是 Fedora 镜像的 metalink SSL 错误（`Curl error (35)`），
重试一次就好。**两者都不该被误读成代码回归。**

### 19.12 更正：探针结果被误读了两次

写之前几节时，我对同一组数据下过两个互相矛盾的结论。这里把正确的读法记下来。

**探针原始输出：**

```
probe: get_power_mode a=1/0x0c b=1/0x0c c=1/0x9c err_count=1/0x00
```

序列是：读 a → `0x10` enter_sleep,120ms → 读 b → `0x11` exit_sleep,120ms →
`0x29` display_on,20ms → 读 c。

**第一次误读**："`0x11` 没生效，所以面板还在睡。"
**第二次误读**："a 和 b 都是旧值，只有 c 是真的。"

两次都错在同一个地方：**把 `power_mode` 当成一个可靠的、实时的状态脚**。

事实是：如果一条写被面板忽略，它读回来仍然是**旧值**；如果写生效了，
读回来是**新值**。所以：
- `a == b` 既可能是"面板忽略了 enter_sleep"，也可能是"enter_sleep 生效但值恰好没变"；
- 单看三四个点，**无法区分"写被丢弃"和"写生效但没有可观察的变化"**。

**从这组数据能确定下来的只有一件事：`c = 0x9c` 与 `a/b = 0x0c` 不同。
也就是说，在某个时刻、发了某组命令之后，面板的状态确实变了。** 这足以
排除"整个 DSI 写通道是死的"，但不足以定位到具体哪条命令。

**所以本节 19.5 列的那三个候选（A：11ms 不够 / B：0x11 不唤醒而是 0x29 /
C：序列中间被打断）到这一轮结束时仍然是三个**，没有收敛。

### 19.13 这一轮实际改了什么（都比上一轮更保守）

| 改动 | 理由 |
|---|---|
| sleep-out 延迟 **120ms 改回 11ms** | 120ms 是我按"规范最坏值"推的。但 `panel-samsung-sofef00.c` 和 **`panel-samsung-ams667xx01.c`（alioth 靠它点亮的那份）** 都用 10ms，厂商 DT 也是 11ms。**只有我一个用 120ms，没有任何证据支持。** |
| 探针**去掉** enter_sleep/exit_sleep/display_on 三次扰动 | 那三次写本身就会改变面板状态，等于在测量过程中动被测对象。改为**只读一次** `power_mode` + `err_count`，不干扰 init 路径。 |
| `BIT(n)` 改成字面量 `0x10`/`0x08`/`0x04` | 避免依赖 `linux/bits.h` 是否被间接包含。 |

**这一轮没有引入新的假设，只是把上一轮凭推测做的两处改动收回去。**

### 19.14 下一轮该怎么定位（不要再用 power_mode 猜）

`power_mode` 读回来的值无法区分"写被丢弃"和"写生效无变化"。要区分，
需要一个**有明确、可观测副作用**的命令：

| 手段 | 为什么能区分 |
|---|---|
| **`0x51` 亮度**：写 0 / 写 0x7ff，各读一次 `0x52`（get brightness） | 亮度是可读回的、不由硬件自决的值。写什么读什么 = 写通了；读回不变 = 写被丢弃。 |
| **`0x0B` address mode**：写 0x00，读 0x0B | 同上，纯寄存器值，无副作用。 |
| **`0x0C` pixel format** 写已知值再读回 | 同上。 |

**这三个都比 `power_mode` 更适合做探针**，因为它们读回的是"我写进去的值"，
而不是"硬件自己决定的状态"。下一轮应该改成写-读-比对，而不是读-猜。

### 19.15 编译状态（已编译，未刷写）

```
补丁 0029     733 行（行数校验：声明 733 = 实际 733）
编译          0 error / 0 warning
```

---

## 20. 参考厂商开源内核：找到缺失的一步（2026-10-26 上午）

前一轮结束时仍卡在"面板能通信、能唤醒，但花屏"。
用户提供了 OnePlus 的官方内核仓库：

```
https://github.com/OnePlusOSS/android_kernel_oneplus_sm8250
branch: oneplus/sm8250_t_13.0.0_op8
```

**这一次终于有可对照的实现，不用再猜了。**

### 20.1 厂商内核里面板代码在哪

这个分支是 GKI 结构，`drivers/gpu/drm/msm/` 下**没有 panel 目录**，
面板逻辑在 legacy fbdev 路径里：

```
drivers/video/fbdev/msm/mdss_dsi_panel.c      3071 行
drivers/video/fbdev/msm/mdss_panel.c          PPS 打包在这里
include/uapi/drm/msm_drm_iris.h               ← Iris 的 ioctl 定义
```

`msm_drm_iris.h` 的存在证实了 Iris 是一个由 userspace 通过 DRM ioctl
驱动的协处理器，**不在内核的 DSI 路径里** —— 这一点对 8.3 的风险评估
是个好消息。

### 20.2 `mdss_dsi_panel_on()` 的真实流程

```c
static int mdss_dsi_panel_on(struct mdss_panel_data *pdata)
{
    /* 1. 发送 on_cmds —— 就是那 668 字节初始化序列 */
    if (on_cmds->cmd_cnt)
        mdss_dsi_panel_cmds_send(ctrl, on_cmds, CMD_REQ_COMMIT);

    /* 2. 如果用了 DSC，再单独发一次 PPS */
    if (pinfo->compression_mode == COMPRESSION_DSC)
        mdss_dsi_panel_dsc_pps_send(ctrl, pinfo);
    ...
}
```

**关键：第 2 步是独立的。**

### 20.3 `mdss_dsi_panel_dsc_pps_send()` 发的是什么

```c
void mdss_dsi_panel_dsc_pps_send(struct mdss_dsi_ctrl_pdata *ctrl,
                                 struct mdss_panel_info *pinfo)
{
    cmd.dchdr.dlen  = mdss_panel_dsc_prepare_pps_buf(&pinfo->dsc, ctrl->pps_buf, 0);
    cmd.dchdr.dtype = DTYPE_PPS;          /* 0x0a */
    cmd.dchdr.last  = 1;
    cmd.dchdr.wait  = 10;
    ...
    pcmds.link_state = DSI_LP_MODE;
    mdss_dsi_panel_cmds_send(ctrl, &pcmds, CMD_REQ_COMMIT);
}
```

`DTYPE_PPS = 0x0a`（见 `mdss_dsi_cmd.h`），**这是 MIPI 标准 DSI 数据类型，
不是 DCS 命令。**

而初始化序列里那条 `0x9e` 用的是 `DTYPE_DCS_LWRITE = 0x39`：

```
pkt21: dtype=0x39  payload=9e 11 00 00 89 30 80 09 ...
                  ^^ 89 字节 PPS
```

**两者是不同的包：**

| | dtype | 含义 |
|---|---|---|
| 序列里的 `0x9e` | `0x39` DCS 长写 | Qualcomm 私有的 PPS 写入命令 |
| `dsc_pps_send()` | **`0x0a` DTYPE_PPS** | MIPI 标准 PPS 长包 |

**厂商两个都发，我们只发了第一个。**

### 20.4 还缺一个：`mipi_dsi_compression_mode(true)`

mainline 里没有 `DTYPE_PPS` 的发送逻辑：

```
$ grep -rn "MIPI_DSI_PPS\|DTYPE_PPS" drivers/gpu/drm/msm/dsi/*.c
(无输出)
```

`drm_dsc_config` 在 mainline 里只喂给 **DPU 编码器**（`dsi_populate_dsc_params`）。
**面板侧的 PPS 必须由面板驱动自己发**，而 `compression_mode` 也必须自己开。

这一点在 alioth 的面板驱动里有现成的正确写法
（`panel-samsung-ams667xx01.c`，**它是 mainline 上真的能点亮的那块**）：

```c
drm_dsc_pps_payload_pack(&pps, ctx->desc->dsc);
ret = mipi_dsi_picture_parameter_set(ctx->dsi, &pps);   /* 发 DTYPE_PPS */
if (ret < 0) { dev_err(...); return ret; }

ret = mipi_dsi_compression_mode(ctx->dsi, true);        /* 开压缩模式 */
if (ret < 0) { dev_err(...); return ret; }

msleep(28);
```

### 20.5 为什么这解释了"花屏"

```
DPU 侧：已经在按 DSC 压缩输出（dsc_cfg 齐全）
面板侧：收到了压缩数据，但没被告知"这是压缩的"
结果  ：解出一堆噪声 —— 花屏
```

`compression_mode` 没开，面板就不知道要解压。**这是花屏最直接的物理解释**，
比前几轮猜的时序、DSC 参数都更贴合现象。

### 20.6 本次改动

`ana6706_enable()` 里，init sequence 之后补上：

```c
drm_dsc_pps_payload_pack(&pps, &ana6706_dsc_cfg);
ret = mipi_dsi_picture_parameter_set(dsi, &pps);
ret = mipi_dsi_compression_mode(dsi, true);
msleep(28);
```

同时把 `ana6706_dsc_cfg` 的定义移到 `enable()` 之前（原来在文件后半部分），
并加上 `#include <drm/display/drm_dsc_helper.h>`。

### 20.7 这一轮的教训：该早点看厂商内核

**前四轮我一直在 mainline、pmOS、ROCKNIX 里找答案，唯独没看厂商自己开源的实现。**

事实是：
- pmOS 没有这台机器的面板驱动（第 19.9 节之前已确认）
- mainline 没有这台面板
- **但 OnePlus 自己开源了完整的面板驱动和初始化序列**

厂商内核确实不能直接用（它是 4.19 downstream，和 mainline 的 DRM API 完全不同），
但**它定义了硬件的正确行为**。`mdss_dsi_panel_on()` 那 10 行，把
"面板 ON 需要做哪几件事"讲得一清二楚。

**应该在第一次卡住时就去读它。**

---

## 21. 参考 LineageOS 内核：找到 `.clock` 算错了（2026-10-26）

第 20 节补上 PPS 和压缩模式后，屏幕仍然是黑的。用户又提供了一个仓库：

```
https://github.com/LineageOS/android_kernel_oneplus_sm8250
branch: lineage-24.0
```

**这里有这块面板的完整 DTS，而且是 Chromium/LineageOS 长期维护、真机跑通的版本：**

```
arch/arm64/boot/dts/vendor/oplus/instantnoodlep/
    dsi-panel-oplus19811-samsung-1440-3168-dsc-cmd.dtsi     2183 行
```

`oplus19811` 就是本机的 `project_name=19811`。

### 21.1 四组时序的官方值

| # | 分辨率 | fps | `qcom,mdss-dsi-panel-clockrate` |
|---|---|---|---|
| 0 | 1080×2376 | 60 | **825,600,000** |
| 1 | 1080×2376 | 120 | **825,600,000** |
| 2 | 1440×3168 | 120 | **1,452,000,000** |
| 3 | 1440×3168 | 60 | **825,600,000** |

porch 参数与我们转录的完全一致（`hfp=64 hbp=48 vfp=2 vbp=8` 等），
**DSC 参数也一致**（`slice 540×72`、`slice-per-pkt 2`、`bpc 8`、`bpp 8`、
`block-prediction-enable`）。

**所以初始化序列和 DSC 配置都是对的。差别在时钟。**

### 21.2 致命的错误：`drm_display_mode.clock` 算错了

我们的驱动里（原始版本）：

```c
{ /* timing@1 */
    .clock = 155835,   /* (1080+64+48+8) * (2376+2+8+2) * 120 / 1000 */
```

**注释里的算式和值对不上。** 那个表达式算出来是：

```
1200 * 2388 * 120 = 343,872,000 Hz = 343,872 kHz
```

**而写的是 155835 —— 差了 2.2 倍。**

### 21.3 为什么这个错是致命的，而且完全静默

mainline 的 msm 驱动直接拿这个值当像素时钟：

```c
/* drivers/gpu/drm/msm/dsi/dsi_host.c */
pclk_rate = mode->clock * 1000u;          /* → 155,835,000 Hz */
if (dsc)
    pclk_rate = dsi_adjust_pclk_for_compression(...);
```

**PLL 会按 155.8 MHz 去配，而面板需要 343.9 MHz。**

- 驱动不会报错：写 PLL 寄存器成功了
- 面板不会报错：`err_count` 仍然是 0
- 屏幕不亮：时钟不对，数据根本送不出去

**这解释了为什么所有软件层指标都正常、屏幕却是黑的。**

### 21.4 修正

四组模式全部按 `htotal × vtotal × fps / 1000` 重算：

| # | htotal | vtotal | old `clock` | **new `clock`** |
|---|---|---|---|---|
| 0 | 1200 | 4764 | 195578 | **343008** |
| 1 | 1200 | 2388 | 155835 | **343872** |
| 2 | 1592 | 3192 | 206942 | **609799** |
| 3 | 1608 | 3540 | 106154 | **341539** |

对应 LineageOS 的 `panel-clockrate`（DSI 位时钟）：
`343872 kHz × 4 lanes / 24 bpp` 再经 DSC 压缩调整，量级对得上 825.6 MHz。

### 21.5 这一轮真正该记住的

**`.clock` 这类"自己算出来"的常数，必须把算式写进注释，并且让注释和值
可以互相验证。**

我写了算式，也写了值，但没人（包括我自己）去核对两者是否一致。
四组模式里有四组都是错的，而且错得没有规律 —— 不是统一的换算错误，
是每次心算时的笔误。

**一个便宜的防护**：在驱动里加 `BUILD_BUG_ON` 或运行期 `dev_warn`，
校验 `clock == htotal * vtotal * drm_mode_vrefresh(mode) / 1000`。
下一轮会加上。

### 21.6 基线整理（同时做的）

驱动源码从补丁里**抽出来独立成文件**：

```
external-and-mods/kernel-sm8250/drivers/panel-oneplus-ana6706.c   ← 唯一的真相
external-and-mods/kernel-sm8250/patches/0029-...patch              ← 由脚本生成
```

新增 `scripts/regen-op8p-panel-patch.sh`，从 `.c` 生成补丁，并**强制校验**：

1. `@@ -0,0 +1,N @@` 的 N 等于实际 `+` 行数
2. 文件以 `MODULE_LICENSE("GPL");` 结尾
3. 大括号平衡
4. `module_mipi_dsi_driver` / `mipi_dsi_picture_parameter_set` /
   `mipi_dsi_compression_mode` / `ana6706_init_sequence` 四个符号都在

**原因是这个补丁被"提取-编辑-重新 diff"的循环截断过三次**，
每次都是静默的（只表现为一个 `-Wunused-function` 警告），其中一次
丢了 `module_mipi_dsi_driver()` 导致驱动编译通过但从不 probe。

从现在起**不再手工编辑补丁**。
