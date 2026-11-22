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

---

## 22. 面板驱动已换成上游那份（2026-11-21）

**§21.6 里"唯一的真相是 `drivers/panel-oneplus-ana6706.c`"这句话已经作废。**
那个文件删了，`patches/0029` 现在是另一个驱动。

原因和过程见 [`display-findings.md`](display-findings.md) 第五轮、
[`reference-nura-port.md`](reference-nura-port.md)：

- 手写那版四轮之后，面板自报 `power_mode 0x9c`（sleep_out/booster/display_on
  全置位）、`err_count 0`、`vsync` 在涨、`underrun 0`，屏幕全黑；
- darknagel 的 instantnoodlep/Nura 移植在同一块屏上用 mainline 跑出了
  1440×3168@120，驱动 480 行、有 upstream binding；
- 换掉之后，如果还黑，问题就不在面板寄存器序列，而在内核/DPU/ABL ——
  这本身就是一条结论。

现在的文件：

```
external-and-mods/kernel-sm8250/drivers/panel-samsung-ams678uw01.c   ← 唯一真相
external-and-mods/kernel-sm8250/bindings/samsung,ams678uw01.yaml
external-and-mods/kernel-sm8250/patches/0029-drm-panel-add-the-samsung-ams678uw01-panel.patch
scripts/regen-op8p-panel-patch.sh    从上面两个文件生成补丁
scripts/assert-op8p-panel.sh         39 条断言，守显示路径不被改坏
```

`patches/0030`（slice_per_pkt）随旧驱动一起删了：那份能亮的实现里没有它，
`qcom,mdss-dsc-slice-per-pkt` 这个属性现在在 DTS 里也没有了 —— 留着就是一个
没人读的死属性。

下次上机按 `display-findings.md` 第五轮末尾那四条判据看。

---

## 23. 真机点亮，以及音频/电源/振动/闪光灯的搬运（2026-11-21）

### 23.1 1440×3168@120 点亮了

换成 darknagel 那份驱动后第一次上机就出图。判据全部来自真机，不是推断：

| 判据 | 实测值 |
|---|---|
| 面板驱动 probe | `panel-samsung-ams678uw01 ae94000.dsi.0: using mode 1440x3168@120` |
| 帧缓冲 | `/proc/fb` = `0 msmdrmfb`，`virtual_size` = `1440,3168`，32 bpp |
| connector | `card0-DSI-1` status=`connected`，enabled |
| 背光 | `ae94000.dsi.0` 2047/2047（满） |
| 编码器 | vsync 15954 → 16049，**underrun 0** |
| 画面 | 往 `/dev/fb0` 写 4 MB 随机数 → 屏幕出现噪点；填纯白 → 整屏均匀白，无条纹、无花屏、无偏色 |

**`DSI PLL(0) lock failed, status=0x00000000` 是假警报**，早就在
`driver-work-assessment.md` 里定过性：`dsi_7nm_pll_save_state()` 在 probe 时
只读状态、PLL 本就未启用。不要再被这一行带去查 PHY。`0077`/`0078` 不需要。

一个还没解释的细节：`encoder-0/status` 报 `mode: INTF_MODE_CMD`，而驱动给的是
`MIPI_DSI_MODE_VIDEO_BURST`。功能上没问题，但要么这是 DPU 侧对 DSI video 的
既有命名，要么模式真被切成了 cmd —— 下次可以用 `intf_cfg` 核对。

### 23.2 触摸也通了

`s6sy761` 在 i2c13 的 0x48，抓 `/dev/input/event2` 拿到 7 个 `EV_ABS`：
`TRACKING_ID=0`、`POSITION_X=783`、`POSITION_Y=1378`、`TOUCH_MAJOR=11`、
`PRESSURE=43`，中断计数 4 → 11。驱动、上电、中断、evdev 四层全通，不需要补丁。

两个别被带偏的点：

- `s6sy761: the axis have not been set` 是驱动自己的检查顺序 bug（在
  `input_mt_init_slots()` 之前查 `ABS_X`），参考移植的 kernel `0069` 就是修这个，
  与功能无关。
- 触摸节点里没有 `reset-gpios` 不要紧：mainline s6sy761 不支持这个属性，它的
  上电是 regulator + I2C 读 `BOOT_STATUS` 确认进入 application 模式。

### 23.3 音频：DTS 与驱动都搬进来了，但还听不到

参考移植 `0005` 的 448 行 DTS 已合入（`work/op8p-dts/merge-audio.sh`，
git 忽略）：wcd938x（SoundWire）、tert MI2S pinctrl（`mi2s2_*`）、
`tfa9874@34/@35`（i2c15，reset gpio91/99）、`&sound` 的五组前端 dai-link、
rxmaco/txmacro/vamacro/swr1/swr2。

**拓扑判断修正**：不是"WCD938x 模拟输出"，是 **tertiary MI2S**；顶部扬声器
兼听筒（参考的 pmaports 补丁原话 "the top speaker is the earpiece"）。
`qcom,wsa-max-devs = 0` 的旧说法作废。

驱动：mainline 7.2.8 只有 `tfa989x.c`（TFA1：9890/9895/9897）和 `tfa9879.c`，
都不认 **TFA9874**。用的是 `howtocuddle/xiaomi_raphael` 的 `tfa9872.c`
（317 行，compatible 含 `nxp,tfa9874`，DSP bypass、不需要厂商 container 固件、
没有硬件音量控制），与参考移植同源。落成 `drivers/tfa987x.c` +
`patches/0030` + `scripts/regen-op8p-tfa987x-patch.sh`。

config：ROCKNIX 的 `linux.aarch64.conf` 已经给了 QDSP6/SM8250 machine/
WCD938X/SoundWire（全 `=m`），缺的是 LPASS RX/TX/VA macro 与 TFA987X，
已补进 `kernel-sm8250/steamos.config`。

**现在仍然不会响**，原因不是配置：设备停在 initramfs，ADSP 固件在 rootfs 的
`/lib/firmware`，而 `SND_SOC_QDSP6` 那一串是 `=m`，没有 rootfs 就没有 modprobe。
出声要等 userdata 装好。

### 23.4 电源 / 振动 / 闪光灯：两个能工作，两个缺驱动

| 项 | 状态 | 说明 |
|---|---|---|
| 电量计 bq27541（i2c16 0x55） | 可用 | DTS 节点本来就有，只差 `CONFIG_BATTERY_BQ27XXX(_I2C)`，现已打开 |
| 闪光灯 PM8150L 两通道 | 可用 | `leds-qcom-flash` 在树里，厂商值 1500 mA / 1280 ms |
| 充电器 PM8150B | 只有节点 | **`qcom_pm8150b_charger.c` 不在 mainline 7.2.8** |
| 振动 AW8697 | 只有节点 | 树里只有 `aw86927`，另一代芯片 |

两个缺口的共同点：参考移植的补丁**都是对驱动本体的修改**，驱动没随仓库提供
（充电 8 个补丁 0068–0085/0165–0166，振动只有 DTS 0074）。节点已按厂商
overlay 原样写好，驱动补进来即用。

### 23.5 四个静默失败的坑

1. **0029 的 Makefile hunk 只能在干净 7.2.8 上打。** 本项目自己的 0017
   （ams667xx01）在同一个位置插过一行，真实构建树里锚点的上一行已是
   `AMS667XX01`，patch 直接 FAILED。改成只用插入点之后的三行上下文。
   "离线验证通过"是因为那次只单独打了 0029。
2. **参考 DTS 的 `usb-dai-link` 引用 `&q6usbdai`，7.2.8 的 `sm8250.dtsi`
   没有这个标签**，dtc 直接 abort。已删，USB-C 音频与 DP 一起做时再加。
3. **`drivers/leds/flash/Kconfig` 整个包在 `if LEDS_CLASS_FLASH` 里。**
   只写 `CONFIG_LEDS_QCOM_FLASH=y` 时这个符号在 Kconfig 里不存在，`.config`
   里连 `# ... is not set` 都没有，build.sh 也不打 WARN。必须两个一起开。
4. **GNU `stat -f` 不是格式化。** `stat -f %m` 打印一段文件系统信息并退出 0，
   `||` 后备永不触发，`SOURCE_DATE_EPOCH` 变成多行散文，`mkbootimg` 用
   `int()` 解析直接抛异常。三处改成 `-c` 优先。

### 23.6 当前产物

```
work/kernel-sm8250/output/current/boot/Image                 35,883,520 B
work/kernel-sm8250/output/current/dtbs/...instantnoodlep.dtb   135,980 B
work/steamos-op8p/boot-op8p-gzip.img                         15,167,488 B
```

断言：`assert-op8p-panel.sh`（39 条）、`assert-op8p-audio.sh`（40 条）、
`assert-op8p-power.sh`（22 条）、`assert-op8p-flash.sh`，全部通过。

刷 `boot_a`（非活动槽）后可以直接验证三件不需要 rootfs 的事：屏幕回归、
`/sys/class/power_supply/bms` 的电压容量、`/sys/class/leds/white:flash` 手电。

### 23.7 上机时用到的两条操作

**回到 Android 不必按键**：Linux 里 `poweroff -f` 与 sysrq `o` 都不生效
（USB 一直挂着），正确做法是写 `misc`（`/dev/sda3`）：

```
dd if=/dev/zero of=/dev/sda3 bs=512 count=1 conv=notrunc
printf "boot-fastboot" | dd of=/dev/sda3 bs=1 seek=0 conv=notrunc
sync; reboot -f
```

**ABL 认 `boot-fastboot`，不认 `bootonce-bootloader`**（后者是 AOSP 老名字，
试过一次，重启后照样进 Linux）。进 fastboot 后
`fastboot --set-active=<原槽>` 即可回 Android。

### 23.8 下一步

1. ~~写 `--install`~~ 已实现（见 §24）。装完之后音频/传感器/摄像头才有验证基础。
2. 补 `qcom_pm8150b_charger.c`（约 2000 行 + 8 个修正）与 `aw8697.c`。
3. 音频 UCM：参考移植的 pmaports 补丁是 Alpine 包定义，SteamOS 侧要重写成
   wireplumber 配置。

---

## 24. `--install`：把 SteamOS 装进 userdata（2026-11-21）

### 24.1 两条命令

```
./make-op8p.sh --install     → work/steamos-op8p/userdata.img
./flash-op8p.sh --install    → fastboot flash userdata（确认词 ERASE）
```

`make-op8p.sh --install` 只是入口，真正干活的是
`scripts/make-op8p-rootfs.sh`，它在**容器里**跑：这台 Windows 没有
`mkfs.ext4`，也没有 `unsquashfs`，而 Valve 的 rootfs 是个 RAUC bundle，
需要用 `unsquashfs` 解出 caibx、再按 casync chunk 从远端重组。容器里
`dnf` 装齐依赖（注意 repodata 缓存会坏，脚本先清 `/var/cache/libdnf5`）。

### 24.2 两个刻意的限制

**不用 loop mount。** 这个容器没有 `CAP_SYS_ADMIN`，`mount` 一律失败。所以
镜像是用 `mke2fs -d <目录>` 直接灌进去的。它保留 uid/gid、权限、符号链接、
硬链接，但**不保留 xattr** —— 也就是说 `security.capability` 会丢，
`ping` 之类靠 setcap 拿权限的程序起来没有 caps。以后用一个首启 unit 把
少数几个重新 `setcap` 一遍。

**镜像只有内容 + 1 GiB 余量。** 首启靠 `/etc/fstab` 里的
`x-systemd.growfs` 长到整个 userdata（100 多 GB），所以写进分区的文件
看起来只有几个 GB。fstab 用 UUID 找设备（`systemd-fsck@root` 需要一个
fstab 条目才存在）。

### 24.3 装了什么

| 内容 | 说明 |
|---|---|
| Valve 的 aarch64 rootfs | 与 alioth 同源（`work/steamos-20261002.6232440`） |
| `steamos-overlay` | 设备无关：inputplumber、sdl2、wireplumber 通用配置 |
| `op8p-overlay` | 设备特定：串口 getty、usb0 网络（见下） |
| `/lib/modules/7.2.8-sm8250-steamos` | 内核模块（`=m` 的那一半） |
| `/lib/firmware` | 固件（ADSP/CDSP/GPU/WiFi/BT） |

`op8p-overlay` 现在只有两件事，都是"没有它就进不去"的：

- **串口 getty**：`serial-getty@ttyGS0` 的 wants 链接 + `--autologin root`
  的 drop-in。ttyGS0 是 USB gadget 的 console，插数据线就能登，不依赖
  网络也不依赖屏幕。链接必须在容器里建 —— Windows 工作区建不了 symlink。
- **usb0 静态地址**：`172.16.42.1/24`（`usb0.nmconnection`，权限必须 600，
  NetworkManager 对别的权限是静默忽略）。与 initramfs 的 usb_shell 同网段，
  宿主机那边的 `172.16.42.2` 不用改。

### 24.4 与 Android 的关系

`--install` 只写 userdata，不碰 `super`、`abl`、两个槽的 `boot`/`dtbo`，
也不参与槽位逻辑（userdata 没有 A/B）。所以：

- Linux 起不来：`fastboot --set-active=<Linux 槽以外的槽>` 就回 Android
- 但 Android 的 `/data` 已经变成 SteamOS 的 `/`，里面的数据回不来

---

## 25. Steam 图形会话跑起来（2026-11-21 深夜）

目标只是「屏幕上出现 Steam UI」。实际卡了一整晚，因为**九个独立故障串在一条链上**，
每修好一个才露出下一个。按暴露顺序记下来，下次从任意一条直接跳。

### 25.1 启动链

```
sddm (autologin steamos)
  └─ gamescope-session.service          Type=notify, TimeoutStartSec=45
       └─ /usr/lib/steamos/gamescope-session     算参数，exec gamescope
            └─ gamescope --backend drm --prefer-output DSI-1
                 └─ /usr/lib/steamos/gamescope-onready     发 READY、拉 steam.service
                      └─ steam.service → /usr/share/deckard/RUNSTEAM.sh
                           └─ steamrtarm64/steam
```

判据（别数进程，看这三条）：

| 判据 | 期望 |
|---|---|
| `pgrep -a steamwebhelper` | 8 个 |
| `steam_output.log` 里的 `[Gamescope WSI] Created swapchain` | 有 |
| `/tmp/.X11-unix/X0` | 存在 |

### 25.2 九个故障（按暴露顺序）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `sddm-helper exited with 126` | shebang 变成 `#!/bin/bash\r` | 脚本去 CR（见 25.3） |
| 2 | `pam_systemd: Failed to create session: Connection timed out`，登录卡 90 秒 | `home.mount` 依赖 `/dev/disk/by-partsets/shared/home`，userdata 没有那个 partset | `ln -sf /dev/null /etc/systemd/system/home.mount` |
| 3 | 整个图形会话不跑 | `/usr/lib/steamos/panel-modes` CRLF → python3 退出 127，`set -e` 一路带走 | 去 CR |
| 4 | gamescope 起来了但没有子进程 | `gamescope-onready` CRLF，`exec` 直接失败 | 去 CR（`/usr/lib/steamos/*` 全量 18 个文件） |
| 5 | 日志停在 `pipewire: stream state changed: connecting`，46 秒一轮重启 | ADSP 固件缺失 → 没有声卡 → pipewire 有 socket 无 sink → gamescope 的音频流建立连接永不返回 | `PIPEWIRE_RUNTIME_DIR=/run/gamescope-nopipewire`（**指向不存在的目录**），让连接立即失败 |
| 6 | gamescope 起不来，Vulkan 无设备 | `a650_zap.mdt` 缺（msm 编进内核，1.3 秒就 probe；root 3.6 秒才挂载） | 本机签名的 zap 四件套塞进 initramfs |
| 7 | `steam.service` 起不来，屏幕纯黑 | 镜像自带 `steam.tar.zst`，但**没有任何东西解它** | 首启 `op8p-steam-client.service` |
| 8 | `Job steam.service/start failed with result 'dependency'` | mask 掉 `steamvr.service` 后 `Wants=` 无法满足 | drop-in 里把 `Wants=`/`After=` 置空 |
| 9 | 45 秒被杀，无限重启 | `systemctl --user` 每次要几十秒才应答，而 READY 在脚本末尾才发 | READY 提到最前 + 三处 `--no-block` + 超时 45 秒 |

第 5 条的反证值得单独记：把 `XDG_RUNTIME_DIR` 指到一个**没有 pipewire socket**
的目录，gamescope 打印 `pw_context_connect failed` /
`Warning: failed to setup PipeWire, screen capture won't be available` 之后
照常 spawn 子进程。也就是说它只在「连得上但连不通」时死等，这是绕过方案的依据。

### 25.3 CRLF 是这台机器的系统性风险

`core.autocrlf=true`，加上一批**没有 `.sh` 后缀**的脚本（`gamescope-session`、
`gamescope-onready`、`steamos-select-branch`、`panel-modes`），每次 checkout 都可能
把 shebang 变成 `#!/bin/bash\r`。`.gitattributes` 现在对 `steamos-overlay/**` 和
`op8p-overlay/**` 全树 `eol=lf`。

已经实测过的两种死法：

- bash：`/bin/bash^M: bad interpreter`，sddm-helper 退出 126
- python：`python3\r: not found`，退出 127

### 25.4 落地位置（重建镜像即生效，不需要再手工改设备）

| 改动 | 落在哪 |
|---|---|
| `PIPEWIRE_RUNTIME_DIR` 绕过 | `steamos-overlay/usr/lib/steamos/gamescope-session` |
| READY 提前 + 三处 `--no-block` | `steamos-overlay/usr/lib/steamos/gamescope-onready` |
| `TimeoutStartSec=45` | `steamos-overlay/usr/lib/systemd/user/gamescope-session.service` |
| 去掉 steamvr 依赖 | `op8p-overlay/etc/systemd/user/steam.service.d/99-no-steamvr.conf` |
| 首启解压 Steam 客户端 | `op8p-overlay/usr/lib/steamos-arm/op8p-steam-client` + 同名 `.service` |
| `home.mount` / `steamvr.service` mask | `scripts/make-op8p-rootfs.sh`（Windows 建不了 symlink，在容器里建） |
| 全树 LF | `.gitattributes` |

### 25.5 还没通的

- **音频**：`adsp.mbn` / `cdsp.mbn` / `slpi.mbn` 三个都不在，`/proc/asound/cards`
  为空，三个 remoteproc 全 `offline`。可照 GPU zap 的做法，从 `super` 的
  `vendor_a` 里取。
- **振动**：驱动已写（`aw8697.c` + 0031 补丁），但没进这次的内核构建。
- **充电**：`qcom_pm8150b_charger.c` 仍缺，只有 bq27541 电量计。
- **电量计数值失真**：`capacity=3947`、`TEMP=-2082`、`HEALTH=Dead`，寄存器读到了
  但没做单位换算与校准。
- **WiFi 未连**：硬件全通（见 25.6），只差 SSID 与口令。
- **蓝牙**：`hci0 UP RUNNING`、有 MAC、`errors:0`，扫描与配对未验证。

### 25.6 WiFi 是 rfkill 软阻塞，不是驱动问题

`wlan0` 一直 `DOWN`，但 ath11k 的 probe 是干净的（`qca6390 hw2.0`、
`fw_version 0x10121492`、`Generated MAC_ADDR`）。真正的开关是：

```
phy0: Wireless LAN   Soft blocked: yes
```

`rfkill unblock wlan` 之后立刻扫到 9 个 AP。状态保存在
`/var/lib/systemd/rfkill/platform-1c00000.pcie-pci-0000:01:00.0:wlan`，
已写回 `0`；`NetworkManager.state` 里 `WirelessEnabled=true`。
**下次开机会不会自动恢复 unblocked，还没验证过。**

---

## 26. 阶段 2：温控、电量计、DSP 固件（2026-11-21 深夜）

阶段 1（电源键 / 音量键 / 游戏态调度 / 温度看门狗）是热部署，本轮这三项要动
内核，所以放在一起构建、一次刷 `boot_a`。

### 26.1 温控：两个 cluster 温区原来完全不参与降温

真机实测（`/sys/class/thermal/thermal_zone*/`）：

| 温区 | 温度 | 绑定的 cooling device |
| --- | --- | --- |
| cpu0-thermal … cpu3-thermal | 44 °C | 6 |
| cpu4-top … cpu7-bottom | 43 °C | 12 |
| gpu-top / gpu-bottom | 42 °C | 3 |
| **cluster0-thermal (zone5)** | 44 °C | **0** |
| **cluster1-thermal (zone6)** | 44 °C | **0** |
| aoss / wlan / video / mem / npu … | 42-43 °C | 0 |

`sm8250.dtsi` 给 cluster0/cluster1 只写了 `type = "hot"` 的 90 °C trip，既没有
passive trip 也没有 cooling-maps —— hot 只上报、不降频。CPU 温区虽然绑了
cooling device，但被动降频阈值是 **90 °C / 95 °C**，而这台机器跑 Steam 时
稳定在 80-90 °C，等于永远踩不到线。

改法（`dts/sm8250-oneplus-instantnoodlep.dts` 末尾）：

- 12 个 CPU 温区的一档 90 → **84**，二档 95 → **88**
- GPU 的 85 → **82**（上下两个温区）
- cluster0 补一档 84 °C 的 passive trip，绑 cpu0-3；cluster1 同样，绑 cpu4-7
- critical 110 °C 一个都没动 —— 那是最后关机线

两层结构：用户态 `op8p-thermal-guard` 按 78/84/88 进、72/79/84 退压
`scaling_max_freq`（阶段 1 已上线），内核这层是它没跑起来时的兜底。两者写
同一个文件，谁最后写谁生效，所以内核这层只负责"不至于完全不降"。

### 26.2 电量计：这块 gauge 有四处不符合 datasheet

DTS 里 compatible 写的是 `ti,bq27541`，但直读芯片命令寄存器得到
`DeviceType() = 0x0421`（BQ27742-G1）。寄存器表本身和 bq27541 一致，问题是
**同一组寄存器里的数值语义不同**：

| 属性 | 上游解析 | 实测原始值 | 真值 |
| --- | --- | --- | --- |
| `capacity` | SOC 0-100 % | 寄存器 0x2C = **0x0EDF = 3807** | 38.07 %（0.01 % 单位） |
| `temp` | 0.1 K，减 2731 | 0x06 = 0x0108 = 264 | 26.4 °C（0.1 °C 单位） |
| `charge_full` | FCC × 1000 µAh | 0x12 = **0xFFFE** | 未学习，用设计容量 4455 mAh |
| `health` | FLAGS 的 SOCF 位 | 0x0A = **0x0F3B**（FC 与 SOCF 同时置位） | 正常 |

判定依据不是猜的：`temp = 264` 减 2731 得 −246.7 °C；同时电压 3692 mV、
放电 2142 mA 与 38 % 自洽（86 % 对应 OCV 4.05 V，与实测对不上）。SOC 与
NAC 的 3823 mAh 那条线是矛盾的，真正可信的是 SOC 与电压。

补丁 `patches/0032-power-supply-bq27xxx-tolerate-off-spec-soc-temp-units.patch`
（6 个 hunk）全部采用**越界才修正**的写法，正常 gauge 走原路径：

1. `read_soc`：>100 且 ≤10000 时按 0.01 % 换算；>10000 返回 `-ENODATA`
2. `read_temperature`：减 2731 后低于 −100 °C 判定为 0.1 °C，直接用
3. `read_fcc`：≥0xFFFE×1000 视为未学习，回落到 `read_dcap`
4. `read_health`：SOCF 位置位但容量 >5 % 时不再报 `DEAD`
5. `capacity_level`：FC 与 SOCF 同时置位时（自相矛盾）改按 capacity 分档
6. `current_and_status`：放电中（curr < 0）不再被 FC 位盖成 `FULL`

### 26.3 DSP 固件：路径是 `postmarketos/`，不是 `qcom/sm8250/`

dmesg 说得很清楚：

```
Direct firmware load for postmarketos/adsp.mbn failed with error -2
```

镜像里放的是 `qcom/sm8250/adsp.mbn`（soc.env 的 FW_BUILTIN 带上来的），而
DTS 的 `firmware-name` 指 `postmarketos/`。补上路径后固件能加载（
`Booting fw image postmarketos/adsp.mbn, size 17166524`），但接着报

```
qcom_q6v5_pas 17300000.remoteproc: error -22 setting up firmware
```

`-22` 是 `-EINVAL`。alioth 的记录（`docs/alioth.md` §阶段 2）说这类
`qcom_scm_pas_init_image` 的 EINVAL 是 TrustZone 拒收通用签名镜像，必须用
机内签名的那份。这里已经照做 —— 从本机 `modem_a` 的
`image/adsp.mdt` + `adsp.b00..b18` 用 `scripts/squash-qcom-mdt.py` 拼成
17,166,524 字节的 `adsp.mbn`，**仍然 −22**。所以 op8p 这条不是（或不只是）
签名问题，待查。硬件排除了两件事：modem 分区里有 adsp/cdsp/slpi 三套完整
mdt，且 a650_zap 用的是 linux-firmware 版（与设备上 sha256 相同）却能正常
初始化 GPU —— 说明 TZ 并不一概拒收通用签名。

落地方式与固件分发：**机内签名的固件不进镜像**。新增
`op8p-overlay/usr/lib/steamos-arm/op8p-dsp-firmware` +
`op8p-dsp-firmware.service`，开机时从 `modem_a` 现取、squash、再重绑
`qcom_q6v5_pas`。与 Nura 的 "first boot copies the DSP firmware from your own
partitions" 同一个思路。

### 26.4 构建与断言

```
./work/wslc-op8p-build.sh            5 分 53 秒（wslc + fedora:43）
work/kernel-sm8250/output/current/
  boot/Image                          35,887,616 B
  dtbs/…instantnoodlep.dtb               136,412 B（+432，温控节点）
work/steamos-op8p/boot-op8p-gzip.img    15,265,792 B
scripts/assert-op8p-stage2.sh           21 通过 / 0 失败
```

### 26.5 下一次要做的验证

1. `fastboot flash boot_a` + `erase dtbo_a` + `set-active=a` 后确认能起来
2. `thermal_zone5/cdev*` 从 0 变成 4、`trip_point_0_temp` 读到 84000
3. 电量计在 `/sys/class/power_supply/bq27541-0/`（**不是 `bms/`**，2026-11-21
   实测就是这个名字）：`capacity` 在 30-50 之间、`temp` 在 200 左右（0.1 °C）、
   `health` 不再是 Dead
4. adsp 的 −22：换 7.2.8 侧 `qcom_scm` 的 debug 或对比 Nura 的 DTS/固件流程




---

## 27. 刷 b 槽之前：打包链上两个静默故障和一条被推翻的结论（2026-11-21 深夜）

### 27.1 `make-op8p.sh` 报 `boot/Image` 不存在 —— 其实是 python 变了

现象：`Image` 明明在（35,887,616 B），打包却抛

```
FileNotFoundError: '/d/Developer/Repo/SteamOSforAlioth/work/kernel-sm8250/
                    output/7.2.8-sm8250-steamos/boot/Image'
```

原因不在内核产物，在**解释器**：这台机器上 `python3` 现在解析到
WorkBuddy 自带的原生 Windows 版（`C:/Users/moeka/.workbuddy/binaries/
python\versions\3.13.12\python3.exe`）。win32 python 不认 MSYS 的
`/d/Developer/...`，会把它当成「当前盘符下的 /d/...」，于是把一个好文件
报成不存在。之前能跑通是因为当时的 PATH 里排在前面的是一份能读 MSYS 路径
的解释器。

修法（`make-op8p.sh`）：新增 `python3w()`，把所有以 `/` 开头的参数先过
`cygpath -w`；没有 `cygpath` 的环境（Linux）原样透传。三处 `python3`
（`stage_payload`、`mkbootimg-v0.py`、`mkbootimg-v2.py`）都改用它。

顺带修掉一个**静默失败**：`stage_payload` 的最后一句是 `echo "$payload"`，
所以 python 挂了函数照样返回 0，`set -e` 不触发，后面 `cat` 一个不存在的
`Image.gz` 才报错，日志看起来像「DTB 打包出错」。现在改成
`|| return 1` + 调用处 `|| die`。

### 27.2 GPU ramdisk 的 96 KB 必须验内容，不能看大小的近似

`gpu-fw-ramdisk.cpio.gz` 新旧两版都是 94,994 B（6 个文件、两个搜索路径、
页对齐），光看大小分辨不出里面装的是谁的 zap。验法：解出 cpio 后按 newc
头部（`filesize` 在偏移 54、`namesize` 在 94、名字从 110 开始，均 4 字节
对齐）取出数据段算 sha256。当前产物：

```
qcom/a650_zap.mdt          size=13964  sha256=0624d84e…  ← linux-firmware 那份
updates/qcom/a650_zap.mdt  size=13964  sha256=0624d84e…
```

顺带把 ramdisk 脚本里 `dnf install` 的输出从 `>/dev/null 2>&1` 改成只吞
stdout：容器里 dnf 抖一下会让整个脚本静默 exit 1，外层只看到「没产出」。

### 27.3 【结论作废，2026-11-22 更正】方向推反了：TZ 要的是本机签名

本节原先写的「TZ 接受 linux-firmware 那条链、拒收 vendor_a」是**反的**。
真正的事实，三处独立记录早就写死：

- `docs/alioth.md:1643`（10-24）：**TrustZone 拒收通用签名的 PAS 镜像**，
  `a650_zap.mbn` / `adsp.mbn` 用 linux-firmware 那份都报
  `error -22 initializing firmware`（`qcom_scm_pas_init_image` 返 -EINVAL）；
  必须用机内签名那份，两份连大小都一样（zap 都是 13,964 B），只有签名不同。
- `§25` 第 6 条：21:00 能进 Steam 登录页的修法就是「**本机签名的 zap
  四件套塞进 initramfs**」。
- 提交 `f3ef29c` 的 `scripts/make-op8p-gpu-ramdisk.sh`：用的正是
  `work/op8p-firmware/a650_zap.mdt + .b00/.b01/.b02`。

被拒的是 **linux-firmware / `California / SecTools / Test User`** 那条链，
被接受的是本机 `vendor_a` 的 **`OEM CA / Technologies / US`** 那条。

**事故经过**：按这节的错误推论，两个生成脚本里的 zap 从「本机签名四件套」
换成了「linux-firmware 的 `.mbn` 改名 `.mdt`」（sha `0624d84e…`）。结果 GPU
zap shader 被 TZ 拒收（`error -22` 累计 302 次）、gamescope 拿不到 Vulkan、
sddm 反复 `Removing display / Adding new display`，屏幕回到纯黑 —— 把
`f3ef29c` 已经跑通的图形会话弄坏了。

修法已固化：两个脚本都改回四件套，合成脚本加 `b01` 的 sha256 防呆断言
（`2cccbd69…`）。校验产物：`.mdt` 6860 B / `d059d0d2…`，
`.b01` 6712 B / `2cccbd69…`。

**顺带纠正另一条误判**：Linux 的 `populate_rootfs()` 是内置 initramfs 与
外部 initrd **叠加**解包，不是「有 initrd 就跳过内置」。当时那个 `~ #`
救援 shell 的真因是 ABL 给了 `androidboot.startupmode=dc_charger`，
不是 ramdisk 缺 `/init`。

逐段比对本身没错，错的只是「谁被接受」：

| 段 | 用途 | 长度 | 结果 |
|---|---|---|---|
| b00 | hash table | 0x94 | 相同 `ec9b9d5a…` |
| b01 | 签名段（X.509 证书链） | 0x1a38 | **不同** `2cccbd69…`（本机，可用） vs `efaaffe6…`（通用，被拒） |
| b02 | 代码段 | 0x68c | 相同 `a415e545…` |

`scripts/squash-qcom-mdt.py` 的拼装逐字节正确，它只拼不签。所以 adsp 也
照 `§25.5` 从 `modem_a` 取**本机签名**那份即可，不需要另找别的签名。

### 27.4 刷 b 槽的操作序列

`misc`（`/dev/sda3`）写引导标记进 fastboot —— 2026-11-21 实测仍然有效：

```
dd if=/dev/zero of=/dev/sda3 bs=512 count=1 conv=notrunc
printf "boot-fastboot" | dd of=/dev/sda3 bs=1 seek=0 conv=notrunc
sync; reboot -f
```

进 fastboot 后核对的几何（本次实读）：`current-slot: a`、`boot_a`/`boot_b`
都是 `0x6000000`（100,663,296）、`dtbo_a` `0x1800000`、`abl_a` 存在、
`product` 这次答的是 `OnePlus8Pro`（§24 记的 `kona` 是旧 ABL 的答案，两种
都要接受）。写 `boot_b` + `erase dtbo_b` 由 `./flash-op8p.sh --test` 做，
脚本要求 TTY 输入 `YES`。

闲聊级别的一条：设备上 `/lib/firmware/postmarketos/` 只有 `adsp.mbn` 和
`cdsp.mbn`，没有 `slpi.mbn` —— 正好印证删掉 `ConditionPathExists=!…/adsp.mbn`
那条判断是对的（否则三个里缺一个整个 unit 就被跳过）。

---

## 28. 验收：Steam 登录页上屏（2026-11-22 00:24）

**屏幕上显示 Steam 登录页**（用户确认）。阶段 2 的温控、电量计也都在位。
本轮用的镜像是 `work/steamos-op8p/boot-op8p-gzip.img`（15,937,536 B，
前 4096 B 指纹 `4ed3126d…`，`ramdisk_size=767975`），已刷 `boot_a` +
`erase dtbo_a` + `--set-active=a`，`boot_b` 仍是坏实验镜像（勿切）。

### 28.1 真机快照（COM4 实测，00:24）

| 判据 | 实测 | 结论 |
|---|---|---|
| `pgrep -c steamwebhelper` | 8 | Steam UI 进程组完整 |
| gamescope 主进程 | PID 1723，`--backend drm --prefer-output DSI-1` | DRM 后端在跑 |
| gamescope 子进程 | `gamescopereaper`×2 + `mangoapp` | READY 链路活 |
| `dmesg` 里 `error -22` 计数 | **2**（回归时是 302） | 剩余 2 条 = `adsp.mbn`/`cdsp.mbn` 音频 DSP，与 §25.5 待办一致，不是 GPU |
| 电量计 | `bq27541-0`：`capacity=37`、`health=Good` | 阶段 2 保住 |
| 温控 | `thermal_zone5` 42.6 °C，3 个 cdev | 阶段 2 保住 |
| WiFi | `wlan0: wifi: connected: Xiaomi_0A83_5G` | **已连网，且是 5G 频段** |

### 28.2 5G 连上了 —— 这一点比 alioth 强

alioth（ath11k qca6390）当时 5G 认证阶段一直 `CONN_FAILED`，只能用 2.4G。
这台 OP8P 是同款 `qca6390 hw2.0`，`nmcli` 实测直接连上了 `Xiaomi_0A83_5G`。
可能的差异：OP8P 这边没做 `calibration-variant` 之类的额外要求、且 rfkill
状态早已写回 unblocked。**别把"能连"当成已验证**：信号强度、吞吐、断线重连
还没测。

### 28.3 观测工具注记：COM4 是救援 shell，不是真系统 shell

这轮实测发现 COM4（ttyGS1）的 shell 没有 PATH，`ls`/`grep`/`pgrep` 全
`not found`，且 `/proc/1/root/usr/bin/<动态链接二进制>` 直接执行报
`not found`（ELF 解释器路径按当前救援根解析，找不到 loader）。正确用法：

```
B=/dbg/bin/busybox          # 静态链接，永远可用
$B chroot /proc/1/root /usr/bin/pgrep -c steamwebhelper
$B dmesg | $B grep -c -e -22
$B chroot /proc/1/root /usr/bin/nmcli -t -f DEVICE,STATE,CONNECTION device status
```

`op8p-sh.ps1` 本身不用改，改的是喂给它的命令。

---

## 29. 待完善清单（对照 `docs/alioth.md`）

alioth 走完的路里，每一项在 OP8P 上的状态。排序按「阻塞日常使用的程度」。
alioth 对应章节给的是 `docs/alioth.md` 的行号锚点，修 OP8P 时**先读那边**，
不要现场试错——这是 11-21 深夜那轮回归的直接教训。

| # | 项 | OP8P 现状 | alioth 已趟过的路 |
|---|---|---|---|
| 1 | **音频** | `adsp.mbn`/`cdsp.mbn` 缺（剩 2 条 `-22`），无声卡，pipewire 被绕过（§25.2 #5 的 `PIPEWIRE_RUNTIME_DIR` 空目录法） | §1857 扬声器通路四缺陷、§1965 后端是 Tertiary TDM 不是 MI2S；OP8P 是 TFA987x（补丁脚本 `regen-op8p-tfa987x-patch.sh` 已备） |
| 2 | **充电** | ~~`qcom_pm8150b_charger.c` 缺~~ **2026-11-22 修复**：驱动一直在（ROCKNIX 0004/0011），真因是 `&pm8150b_typec` 未启用导致 charger 注册永远 defer；启用 typec/vbus + Nura 修复链后 `pm8150b-charger`/`tcpm-source-psy` 已注册（见 §30）。**插电验收未做** | §2591 2A→3A 与缺位的 JEITA |
| 3 | **电量计校准** | `capacity`/`health` 已好，`temp`/电压单位换算未验 | alioth 阶段 2 验收清单 |
| 4 | **触摸** | 驱动在（S6SY761）+ Nura 0069/0081 补强已编入（0037/0038，含休眠唤醒修复），真机未验 | §731/§790：诊断收口→被原厂实测推翻的两轮教训 |
| 5 | **蓝牙** | `hci0 UP RUNNING`、有 MAC，扫描/配对/音频未验 | §1421 WiFi 与蓝牙阻塞点是一行配置 |
| 6 | **GPU 占用率** | 未查；msm debugfs 缺文件 + MangoHud 写死 `dri/0` 两个坑大概率原样复现 | §2055、§2269 |
| 7 | **USB-C host** | 未验（有线手柄） | §927、§1238 真机通过的那条线 |
| 8 | **ramoops/pstore** | 未验；alioth 上结论是地址有但用不了 | §864 |
| 9 | **双槽冗余** | `boot_b` 是坏实验镜像，要刷 a 槽镜像过去 | §1781 设备自己写 boot 槽 |
| 10 | **WiFi 持久化** | 已连 5G；开机自连、`rfkill` 状态回写未验 | §25.6 |
| 11 | **游戏验证** | 未装游戏；Proton/box64、帧率未测 | §2478 升频速度瓶颈、"绑大核"是负优化；`docs/custom-games.md` |
| 12 | **振动** | ~~未进内核构建~~ **已完成**：驱动（0031）+ DTS（i2c11 @0x5a）+ CONFIG 全就绪，已编入；手电筒（pm8150l_flash 双 LED）同批完成——都待真机验证 | alioth 无对应（它没有这颗） |
| 13 | **Steam 账号** | 登录页已显示，账号登录本身未完成 | alioth 阶段 2 验收 |

优先级最高三项**按实施难度从低到高**：

1. **触摸（#4）** —— 驱动已在内核里（S6SY761，原厂 Android 下 `event3` 正常），
   SteamOS 下只差真机验证，成本最低，先做；
2. **充电（#2）** —— `qcom_pm8150b_charger.c` 缺，要移植内核驱动，
   有 alioth 的充电经验（§2591）可参照，是常规驱动工作量；
3. **音频（#1）** —— 本移植最大的工作量（§4），且分两段：
   固件提取（`adsp`/`cdsp` 四件套，照 GPU zap 的成熟做法，难度低、可先行）
   和扬声器通路（TFA98xx 接进机器驱动，难度最高）。

**注意**：难度序 ≠ 影响序。"没有音频/充电就不能当日常机用"的事实不变，
只是实施顺序上先易后难、每一步都有可验收的产出。另：9（双槽冗余）只要
一条 fastboot 命令，建议下次刷机时顺手做掉。

### 29.1 像 alioth 那样沉淀的配套文档

alioth 那边的文档结构是三件套：`alioth.md`（结论）+ `alioth-journal.md`
（过程）+ `alioth-hardware.md`（硬件清单与 mainline 状态）。OP8P 这边对应：

| alioth | op8p | 说明 |
|---|---|---|
| `docs/alioth.md` | `docs/op8p/README.md` | 本文件，结论性内容 |
| `docs/alioth-journal.md` | `docs/op8p/journal.md` | 过程记录（新建，见 §28.1 同目录） |
| `docs/alioth-hardware.md` | `docs/op8p/hardware.md` | 硬件清单 + mainline 状态（新建；原始 sysfs 转储在 `hardware-inventory.txt`） |
| `docs/custom-games.md` | （待建） | 装游戏、Proton 验证之后再写 |

---

## 30. 充电：驱动一直在，缺的是一行 `status = "okay"`（2026-11-22）

### 30.1 三个连续的误判

| 之前的结论 | 实际 |
|---|---|
| "`qcom_pm8150b_charger.c` 缺" | ROCKNIX 20261001 的 `devices/SM8250/patches/linux/0004-pm8150b.patch`（charger/fg DTS 节点 + ADC 通道）和 `0011-qcom-pm8150b-charger.patch`（驱动本体 + qcom_fg.c + Kconfig/Makefile）**一直随构建进内核**，`CONFIG_CHARGER_QCOM_SMB5=y` 也在 ROCKNIX 设备配置里 |
| "驱动缺所以没充电" | 真机 dmesg：`deferred probe pending: qcom-pm8150b-charger: failed to register power supply` —— 驱动在 probe，只是注册不出来 |
| 注册不出来的原因 | 板级 DTS `power-supplies = <&pm8150b_typec>`，而 `pm8150b_typec` 从未 `status = "okay"` → typec 的 power_supply 永远不注册 → `devm_power_supply_register` 拿着这个 fwnode 永远 defer |

结论：**一行 `&pm8150b_typec { status = "okay" }` + connector 图，充电器就上线。**
Nura 仓库（`reference-nura-port.md`）在这轮的价值：它的 `docs/patches.md`
明确标注 charging works，还带着 8 条针对这台机器的充电修复，且它的
`docs/patches.md` 给出了内核基座 tag（`sm8250-7.2.0_git20261010`）。

### 30.2 顺带发现的两份驱动差异（都看内容，别看大小）

- pmOS soc 树基座（964 行）的浮压公式是**带 bug 的旧版**
  （`(v−3487500)/7500+1`，4.35V 电池会被写成 4.76V——Nura 0068 修的就是它）；
  ROCKNIX 的拷贝（950 行）**已经带正确公式** `(v−3600000)/10000`。
- pmOS 树的 `include/linux/power_supply.h` 多一个
  `POWER_SUPPLY_PROP_CHARGING_ENABLED`（mainline 没有）——Nura 修复链的
  驱动用到它，pristine 7.2.8 编不过。→ 我们的 `0035` 补丁补上（只加枚举，
  不加 sysfs 名，与 pmOS 一致）。

### 30.3 落地（全部可复现）

| 文件 | 内容 |
|---|---|
| `patches/0033-power-supply-pm8150b-apply-nura-fix-chain.patch` | 驱动整体重写：pmOS 基座 + Nura 0068/0073/0082/0083/0084/0085/0165/0166（1739 行）。0166 = 按外部电量计（`qcom,fuel-gauge` → 我们的 bq27541）的厂商充电策略，修"充到 88% 就停" |
| `patches/0034-arm64-dts-qcom-pm8150b-add-the-charger-source-change.patch` | Nura 0086 原样：charger 节点补 `usbin-src-change` 中断 |
| `patches/0035-power-supply-add-POWER_SUPPLY_PROP_CHARGING_ENABLED.patch` | power_supply.h 补枚举 |
| 板级 DTS | 启用 `&pm8150b_typec`（vdd-pdphy=l2a_3p1、usb-c-connector、PDO 5V/3A dual、port@0 ↔ `usb_1_dwc3_hs_out`）+ `&pm8150b_vbus`（0.5–3A）；`#include <dt-bindings/usb/pd.h>` |
| 刻意不动 | `&usb_1_dwc3` 保持 `dr_mode="peripheral"`（Nura 是 otg + usb-role-switch）——串口 gadget/NCM 调试依赖固定外设模式，角色切换留给 USB-C host 验证 |

坑：`work/ref-instantnoodlep` 的补丁是 CRLF（Windows clone），`git apply`
全 FAIL，`tr -d '\r'` 后逐条干净；手写 power_supply.h hunk 出 fuzz 2，
用 diff 工具重新生成后干净。

### 30.4 刷入与真机验证（2026-11-22 01:05，b 槽）

用户选择刷 b 槽并切换（misc 写 `boot-fastboot` → `flash boot_b` +
`erase dtbo_b` + `--set-active=b`）。b 槽头指纹核验一致；
**a 槽保留 00:24 验收的可用镜像 = 真退路**，双槽冗余顺手完成。

真机实测：

```
/sys/class/power_supply/: bq27541-0, pm8150b-charger, tcpm-source-psy-...typec@1500
qcom-pm8150b-charger: float voltage 3980000 uV
qcom-pm8150b-charger: charging policy uses bq27541-0   ← 0166 的厂商策略认到电量计
qcom-pm8150b-charger: battery temperature zone -2 -> 6
```

`deferred probe pending` 消失。图形无回归（8 个 steamwebhelper，`-22` 仍
只剩音频 DSP 的 2 条）。

**还没做**：插电验收（`status` 仍是 Discharging，因为没插电源）。插充电器后
要看：`status→Charging`、`current_now` 方向、float 电压随策略走
（3.98 V 是低温区初值，应走到 4.35 V 档）、充满/回充行为。

### 30.5 对照 Nura README 的状态表（2026-11-22）

Nura 的自述：除快充/无线充电/回声消除外日常功能全部打通。OP8P SteamOS 侧
逐项对照（工作目标不同——我们跑 Game Mode，它跑手机 UI——但硬件维度可比）：

| 部件 | Nura | 我们 |
|---|---|---|
| 显示 1440×3168@120 | ✓ | ✓（同款面板驱动，AMS678UW01，§28 验收） |
| 触摸 s6sy761 | ✓（含休眠唤醒重初始化，补丁 0069/0081） | 驱动在，**真机未验** |
| GPU A650 | ✓ | ✓（Vulkan → gamescope，§28） |
| 声音 | ✓（PipeWire 已调好） | ✗ **adsp/cdsp 固件未提取，无声卡**；TFA987x 功放补丁脚本已备（待办 #1） |
| WiFi | ✓ | ✓ **已连 5G**（§28.2） |
| 蓝牙 | ✓ | 驱动 UP、配对未验 |
| USB | ✓ 网络共享 + DP 外接显示器 | 串口 gadget/NCM ✓；host 模式未验；**DP 外接未做**（dwc3 还固定 peripheral） |
| 调制解调器 | ✓ VoLTE/短信/数据/GPS | ✗ **完全未做**（modem 固件/服务在 `work/ref-instantnoodlep/modem/` 有现成方案） |
| NFC | ✓ 读标签 | ✗ 未做（驱动已绑定） |
| 摄像头 ×5 | ✓ 全走 CAMSS+libcamera | ✗ 未做（Nura 补丁 0010–0014 现成可搬） |
| 传感器 | ✓ 加速度/光线/接近/指南针 | ✗ 未做（Nura 0006–0008/0046/0061 现成） |
| 指纹 | ✓ goodix + fprintd | ✗ 未做（`ref-instantnoodlep/fingerprint/` 现成） |
| 视频编解码 Venus | ✓ H.264/HEVC/VP9 硬解硬编 | 未验（固件未确认在位） |
| **充电** | ✓ 5V/2A + bq27411 电量计 | **链路通，被 gauge 温度挡住**（见 30.6） |
| 震动 AW8697 | ✓ | 驱动+DTS 补丁脚本备好，**未进内核构建** |
| 手电筒 | ✓ | 未做（PM8150L flash 通道） |
| 电源/音量键 | ✓ | ✓（阶段 1） |

### 30.6 充电卡点：可能是 gauge 型号认错（2026-11-22 01:20）

充电链路已全通（charger/TCPM 注册、0166 策略跑起来），但策略读到 gauge
温度 **恒 52 °C**（其余 27 个温度区 38–42 °C，47 分钟不变）→ `ZONE_TOO_HOT`
→ 按 ≥50 °C 禁充，float 落到 3.98 V fallback。电流寄存器同样恒 −2142 mA
（物理不成立：这个速率 40 分钟耗光，但 SOC 47 分钟没动）。电压/SOC 正常。

**关键线索**：Nura README 明说他们充电用 **bq27411**，我们 DTS 绑
`ti,bq27541`。两颗芯片 DeviceType **都是 0x0421**（TI 二义性），寄存器表
完全不同（bq27411: Temp@0x02 / Volt@0x04 / SOC@0x1c；bq27541: Temp@0x06 /
Volt@0x08 / SOC@0x2c）。`hardware-inventory.txt` 早就警告 hw_version 15
批次器件可能与首批不同。矛盾点：若真为 bq27411，按 bq27541 表读 0x08
应命中 NAC（~1477 mAh）而非 3.8 V 电压——所以不能只凭症状下定论。

**裁决方法**：i2c 原始寄存器转储（0x02/0x04/0x06/0x08/0x1c/0x2c），
对照两张表各自的自洽性。若确认 bq27411 → 改 DTS compatible → 温度/电流/
SOC 全部原生正常 → 充电自然解锁，0032 的 0.01 % SOC 换算可能可删。

### 30.7 裁决：TS 引脚悬空，bq27411 假设排除（2026-11-22 01:35）

i2c 原始寄存器转储（`i2cget -f -y 16 0x55`；内核驱动占用地址，必须 `-f`
强制访问）拿到了决定性证据：

| 寄存器 | 原始值 | 与内核读数 |
|---|---|---|
| 0x08 电压 | 0x0ED2 = 3794 mV | ✅ 逐字节吻合 |
| 0x14 电流 | 0xF7A2 = −2142 mA | ✅ 吻合（值卡死是 gauge 自身） |
| 0x2c SOC | 0x0E99 = 3737 → 37% | ✅ 吻合（0032 的 0.01% 换算正确） |
| 0x3c DCAP | 4455 mAh | ✅ 合理（设计容量 4410） |
| 0x06 Temperature() | 521 → **52.1 °C 恒定** | ✅ 吻合（0032：固件直接报 0.1 °C） |
| 0x28 InternalTemperature() | 3704→3692→3690 → **37.0 °C 且漂移** | gauge 结温，活的 |

四张表全自洽 → **芯片就是 bq27541**，bq27411 假设（30.6 的猜想）排除——
bq27411 寄存器表下电压/SOC 读出 4294 mV/100%，完全不自洽。

**真根因（TI SLUS861 手册 + E2E 佐证）**：Pack Config 的 `TEMPS` 位默认 =1
→ `Temperature()` 读 **TS 引脚热敏电阻**；这块板（hw_version 15）根本没接
那颗 NTC——原厂的电池温度走 PM8150B 的 `batt_therm`（Android 清单里的
`bms/temp`）。悬空引脚 → 恒 52.1 °C → 0166 策略 ZONE_TOO_HOT 禁充。
`InternalTemperature()`（0x28）不受 TEMPS 位影响，实测 37.0 °C 且随温度
漂移，与整机 38–42 °C 一致。

先例：sdm845-mainline issue #36——一加 6/6T 同样按生产批次换 gauge
（bq27411 ↔ bq27541），错绑的症状就是荒谬温度。0032 处理过的 SOC 0.01%
单位、FCC 0xFFFF 哨兵、温度 0.1 °C 直报，全部是同一颗非标固件的表现。

**修复（0036，已验证干跑、重建中）**：

- `patches/0036-power-supply-bq27xxx-internal-temp-when-ts-unpopulated.patch`
  —— 新 DT 属性 `ti,ts-pin-unused`：置位后 `Temperature()` 改读 0x28
  内部温度，同固件直接报 0.1 °C，无开尔文换算。三处改动：header 加
  `bool use_internal_temp`、i2c probe 读属性、read_temperature 分支。
- 板级 DTS：`smart_battery` 节点置位 `ti,ts-pin-unused`。
- alioth 的 DTS 不用 bq27xxx，共享内核不受影响。

预期：策略温度源 36.9 °C → ZONE_NORMAL → 2 A / 4.435 V 充电解锁。
后续正解（可选）：接 PM8150B `batt_therm`（NTC 查表），与原厂完全一致。

观察工具注记：i2cget/i2cdump 在 SteamOS rootfs 里**有**（/usr/bin/），
救援 shell 里跑要 `busybox chroot /proc/1/root`。

---

## 31. 可搬运清单：Nura 217 个补丁的分层盘点（2026-11-22）

`work/ref-instantnoodlep/kernel-patches/`（217 个）+ 7 个用户态目录逐个过了一遍，
按"对 SteamOS 游戏机形态的价值"分层。搬运铁律不变：先读对应补丁和 alioth/Nura
的验证记录，再动手；内核补丁直接 `git am`/`patch`，DTS 改动进我们的
`external-and-mods/kernel-sm8250/dts/`。

### 31.1 高价值（游戏机直接受益）

| 部件 | Nura 补丁 | 我们的现状 | 成本 |
|---|---|---|---|
| 触摸健壮性 | 0069 多点校验、0081 休眠唤醒重初始化 | 驱动在、真机未验 | 低 |
| 震动 AW8697 | 0074（DTS 节点） | 驱动已进内核（我们 0031），只差 DTS + CONFIG | 低 |
| Venus 硬解硬编 | 0223–0229（MMCX vote、vcodec0_core 调频、VP9 修复、解码顺序/延迟） | 未验，固件未确认 | 低-中 |
| USB host / 角色切换 | 0096/0099 外部 VBUS 时序、0094/0097/0098 TCPM PR swap | dwc3 固定 peripheral | 中 |
| USB-C DP 外接 | 0088–0093（fsa4480 四 lane、QMP PHY）、0138–0150（DP HDR/音频） | 未做 | 中-大 |
| 音频收尾 | 0036 TFA987x 控件、0055–0057 USB-C 耳机/mbhc、0059 rx macro | 等声卡先通 | 低 |
| 手电筒 | 0104 双闪光灯合一 LED | 未做 | 低 |

### 31.2 中价值

- **指纹**：0219–0222（Goodix SPI 驱动 + binding + DTS）+ `fingerprint/`
  （libfprint-goodixoplus、PAM、overlay）。依赖 QSEECOM TEE 驱动组
  0174–0218（约 40 个补丁），搬运量大。
- **传感器**：0006–0008（OnePlus sensor devinfo，SLPI 通信前提）+
  `sensors/`（setup-sensors.sh、slpi-guard）+ `iio-sensor-proxy-patches/`。
- **面板/DPU 补强**：0070 背光 defer、0115 PPS 失败断电、0146/0147/0161–0163
  cmd mode 清理与 DSC 配对——我们跑 video 模式暂不咬人。

### 31.3 低价值（SteamOS 暂不需要，均现成）

- **摄像头 ×5**：0010–0014、0033–0041（CAMSS C-PHY）、0042–0044
  （IMX689/IMX586/GC5035）、0048–0054/0063/0066/0067（VCM/OIS）、
  0114/0154/0155/0168–0170 + `libcamera-patches/`。
- **modem/通话（WIP）**：0116–0137（SDX55 MHI + q6voice）+ `modem/`
  （ModemManager 规则、sdx55 通话音频/GNSS 脚本）、0164/0171–0173（PCIe wake）。
- **NFC**：0032 + neard 用户态。
- **用户态媒体栈**：`ffmpeg-patches/`、`qcom-va-driver-patches/`、
  `hexagonrpc-patches/`。

### 31.4 已搬运的（避免重复盘点）

| Nura | 我们 |
|---|---|
| 0001–0003（AMS678UW01 面板） | 0029 + DTS（§7，2026-11-21） |
| 0068/0073/0082–0085/0165/0166（充电修复链） | 0033（§30.3） |
| 0086（charger 中断） | 0034 |
| ——（无对应，我们自己发现） | 0032/0035/0036（bq27541 非标固件三补丁） |
| ——（ROCKNIX 自带） | TFA9872/9874（0030）、AW8697 驱动（0031）、bq27xxx（0032） |

### 30.8 最终裁决修正：这颗芯片是 bq27411，0032/0036 的补偿全部作废（2026-11-22 10:56）

刷入 fg-primary 镜像并交叉验证后，30.7 的结论要再修正一次：

**芯片身份**：bq27541 假设作废。两条铁证：
1. **DeviceType = 0x0421 = bq27411 家族**（bq27541-G1 报 0x0541——
   sdm845-mainline 给 OnePlus 6/6T 的修复补丁把这两个型号的判别和踩坑
   写得明明白白，同款错误）；一加按生产批次在这个位置换过 gauge，
   Nura README 写 bq27411 是对的。
2. **fg 交叉验证**：bq27541 寄存器表读出的"电压"（3.79 V）与独立 fg
   实测（4.19 V）差 400 mV。30.7 说"四张表自洽"——那不是自洽，是
   驱动和转储出自同一张错误的表。

0032/0036 的全部补偿（SOC 0.01% 换算、温度 0.1 °C 直报、内部温度切换）
都是在给读错寄存器打补丁，等效于用错的地图解释错的风景。**教训升级**：
寄存器读数"自洽"不能当芯片身份证据；身份判据 = DeviceType + 独立第三方
交叉验证。

**当前配置（已刷 b 槽验证全绿）**：
- `battery` psy（qcom_fg，PMIC FG Gen4）= 唯一电池源：
  90% / 4.19 V / 521 mA / 24 °C，实时
- 充电策略 `qcom,fuel-gauge` → fg，`zone -2 -> 4`（正常档）
- aw8697 `GPIO_ACTIVE_LOW` 修复后 probe 成功
- `&smart_battery`（bq27541 compatible）`status = "disabled"`

**后续可选项**：DTS compatible 改 `ti,bq27411` 重新启用这颗芯片作
第二意见（mainline bq27411 支持完整，0032/0036 可删）；fg 是主源，
不急。

### 30.9 独立求证：同刻七寄存器交叉验证（2026-11-22 11:00，应用户要求）

不采信任何一方的口头判断，设计同刻对照实验：i2c 直读芯片的两套候选寄存器表，
同一时刻与 fg（独立第二方、原厂正牌数据源）的实时读数对比。
fg 基准：**capacity=89 / voltage=4237 mV / current=−76 mA / temp=24.0 °C**。

| 寄存器 | 原始值 | bq27411 表解释 | bq27541 表解释 | fg 基准 | 判决 |
|---|---|---|---|---|---|
| 0x04 vs 0x08（电压） | 4229 / 3526 | **4229 mV** | 3526 mV | 4237 mV | 27411（Δ8 vs Δ711 mV） |
| 0x1c vs 0x2c（SOC） | 93 / 3716 | **93%** | 37.16% | 89% | 27411（Δ4 vs Δ52） |
| 0x10 vs 0x14（电流） | 45 / −2142 | **平均 45 mA** | 瞬时 −2142 mA（昨至今恒死值） | −76 mA | 27411（量级吻合 vs 恒死） |
| 0x0c+0x0e（RC/FCC） | 3431 / 3704 | **92.6%** 自洽容量三角 | 无此解释 | 89% | 27411 ✅ |
| 0x02 vs 0x06（温度） | 3084 / 392 | 0x02 漂移中（30.8 °C 结温） | 0x06 恒死 521 | 24.0 °C（测量点不同，不判分） | — |
| 0x3c（DCAP） | 4455 | 两表同址（4455 ≈ 设计 4410） | 同左 | — | 不构成判据，正确排除 |

**bq27411 表在每一个可判别寄存器上同时命中；bq27541 表全军覆没。**
第二次独立 dump（隔 9 小时、两次开机）重复同一模式，可复现。

方法论修正（对自己之前错误的记录）：
1. 30.7 的"四表自洽 = bq27541"论证无效——驱动和转储出自同一张错误的表，
   自洽是循环论证。正确的对照物是独立第三方（fg）。
2. 前会话记录的 DeviceType 0x0421 与本结论一致（bq27411），但本次用
   用户态 i2ctransfer 复读 DeviceType 未成功（裸读指针行为问题，读回的
   是温度寄存器漂移值）——身份结论最终建立在七寄存器同刻交叉验证上，
   DeviceType 仅作旁证。
3. 昨夜 0032（"SOC 报 0.01% 单位"）与 0036（温度源切换）的本质：
   给"读错寄存器"打补丁。fg 启用后二者皆多余；bq27541 节点已停用。
4. 若将来要启用这颗芯片当第二意见：DTS compatible 改 `ti,bq27411`，
   mainline bq27411 支持完整，无需任何补偿补丁。

### 30.10 bq27411 正确绑定上线：双电量计互相印证（2026-11-22 11:30）

DTS compatible 改 `ti,bq27411`、删 `ti,ts-pin-unused`、恢复启用后刷 b 槽：

| 项 | bq27411-0 | fg（battery，主源） |
|---|---|---|
| 容量 | 94% | 90% |
| 电压 | 4221 mV | 4194 mV |
| 电流 | −365 mA（活值） | +571 mA（活值） |
| 温度 | 36.3 °C | 24.0 °C |

SOC/电压高度一致（Δ4%/Δ27mV）；电流方向与数值有差异——测量点不同
（bq sense 电阻 vs PMIC IBAT）+ 符号约定不同，不影响使用。

dmesg 记录了驱动的 data flash 写入（pmOS 同款 `bq27xxx_dt_to_nvm` 行为）：
`update design-capacity to 4410`、`update design-energy to 17060`、
`cfgupdate 0, retries 10` —— **这块从出厂起未被配置的 gauge，第一次
被正确配置**（此前 0032 时代的"bq27541 绑定"下 flash 更新不支持）。

充电策略 `qcom,fuel-gauge` 仍指 fg（不受影响）。系统现在有两个电池
psy：`battery`（fg，主）与 `bq27411-0`（第二意见）。0032/0036 补丁
保留在树里（对 bq27411 无副作用：SOC≤100 不触发换算、温度走标准
开尔文换算、FCC 哨兵逻辑未触发），后续可择机删除。

**挂起**：aw8697 FF 链路 RC=0（EVIOCSFF 修复 = struct ff_effect 48 字节）
但用户未感觉到震动——play_effect 路径待查（挂到音频/触感阶段）。
ffplay 工具沉淀在 `work/fftool-src/`。

---

## 32. 音频开工：adsp 固件调查与排除清单（2026-11-22）

### 32.1 顺手修复：时区

SteamOS 默认时区是 `America/Los_Angeles`，用户看到的时间差 16 小时。
`timedatectl set-timezone Asia/Shanghai` 修掉；NTP 同步（systemd）本来就
在跑，开机自动对时。**此后所有 op8p 交付出厂配置都应直接写
`Asia/Shanghai`**（记入 make-op8p-rootfs 待办）。

### 32.2 启动链现状（dmesg 事实）

内核按 DTB `firmware-name` 请求 `/lib/firmware/postmarketos/{adsp,cdsp,slpi}.mbn`。
已试过的三种来源与结果：

| 来源 | 结果 |
|---|---|
| 通用签名（ROCKNIX linux-firmware 20260916，镜像出厂） | `-22 setting up firmware` |
| modem_a 机内 .mdt/.bNN 现拼（squash-qcom-mdt.py） | adsp `-22 initializing`（TZ 验签拒）；**cdsp 验签过了但 `auth_and_reset` -22**；slpi 未单独测 |
| AYN Thor adsp（不同 OEM 签名） | `-22 initializing` |

### 32.3 Nura 的真实做法（读完 firmware/ 全部脚本后的复盘）

- 镜像"console only, no proprietary OnePlus files"：**不内置任何机内固件**；
- `dsp-firmware.sh` 首启只从 modem 槽取 **slpi/venus/cdsp**（pil-squasher 现拼，
  放 `/lib/firmware/updates/postmarketos/` 覆盖打包版）；
- **adsp 不在这个脚本里**——pmOS 体系里它来自 `firmware-oneplus-instantnoodlep`
  提取包，安装时从用户自己手机的分区提取（我们缺的就是这一步的正确姿势）；
- 脚本靠 cmdline 的 `androidboot.slot_suffix` 决定取 modem_a 还是 modem_b
  ——**我们的 cmdline 没有这个标记**，之前"取 modem_a"是拍脑袋，没有依据。

### 32.4 已排除（不再走）

| 途径 | 结论 |
|---|---|
| super 动态分区（vendor_a EROFS） | **没有 adsp.mbn**。513 MB vendor 镜像已拉到主机（WiFi 流式 ~11 MB/s，47 s）并用 erofs-utils 解包验证：`firmware/` 目录结构与预期一致但无 adsp |
| OnePlus OTA（oneplus-ota-fetch.json） | 只含指纹 TA（gfp96xx）+ 传感器配置，无 adsp |
| AYN Thor / 通用签名固件 | TZ 拒签 |
| modem_a 的 adsp | 不是本机 bootloader 配套版本（拒签 + cdsp auth 失败，Nura 注释明说打包固件可能与本机共享内存布局不兼容） |

### 32.5 待决（三个候选，等用户拍板）

1. **modem_b 对比**（1 条只读命令）：挂 modem_b、sha256 对比 adsp/cdsp。
   当前活动槽是 b——原厂配套固件可能在 modem_b，正好解释拒签；
2. **用户提供 OxygenOS 完整 OTA 或原厂分区备份**，从配套版本提取；
3. **转 Venus**：venus.mbn 已确认在 modem_a，Nura 标注 works，无 TZ 签名敏感。

### 32.6 工具沉淀（work/fftool-src/）

- `ffplay.c` / `ffplay`：免 libc aarch64 FF 触发器（2.2 KB，raw syscall）。
  注意 `struct ff_effect` 在新内核为 **48 字节**（EVIOCSFF=0x40304580）；
- `receiver.py`：主机端 HTTP POST 流式接收（WiFi 快传，实测 ~11 MB/s）；
- `scan2.py`：super 分区 ext4/EROFS/f2fs 魔数扫描器；
- `lpinfo.py` / `findname.py`：LP metadata 解析 / 文件名扫描（本轮弃用，
  留档）。串口 base64 推送流程见 memory 2026-11-22。

---

### 32.7 真机复核（2026-11-22 18:30）：**cdsp 已经 up 了**，adsp 仍 -22

用刚做好的串口工具第一次上机复核，dmesg 给出的现状和 §32.2 的表不一样：

```
[    7.585] remoteproc remoteproc2: Booting fw image postmarketos/adsp.mbn, size 15523964
[    7.595] remoteproc remoteproc1: remote processor cdsp is now up      ← §32.2 说它 -22
[    7.631] qcom_q6v5_pas ...: error -22 initializing firmware postmarketos/adsp.mbn
[   19.942] platform sound: deferred probe pending: snd-sm8250: MultiMedia1: error getting cpu dai name
[   19.942] platform 3210000.soundwire: deferred probe pending: ... supplier 3200000.rxmacro not ready
```

三件事要分开说：

1. **cdsp 通了**。§32.2 里"cdsp 验签过但 `auth_and_reset -22`"是那次用的那份
   文件；现在设备上这份 3,868,436 字节的 `cdsp.mbn` 能起来。所以 §32.5 的
   三选一里，"DSP 侧还有几块能起"要按这份重新算。
2. **adsp 仍是唯一缺的**：文件在（15,523,964 字节）、被 boot 尝试、`-22 initializing`
   —— 与 §32.2 的判断一致，TZ 拒。
3. **声卡还是没起**，而且原因链比"缺 adsp"多一环：`snd-sm8250` 报
   `MultiMedia1: error getting cpu dai name`，SoundWire 的两条 macro 都
   `supplier ... not ready` —— LPASS 的 RX/TX macro 依赖 ADSP 起来，所以这是
   adsp 的下游，不是独立的第二个故障。

还有一个**部署状态**的坑：`/lib/firmware/postmarketos/` 里那三件
（`adsp.mbn` 11:45、`cdsp.mbn`/`slpi.mbn` 11:37）是**手工推上去的**，
`op8p-dsp-firmware.service` 在设备上 `not-found` —— 因为设备里的 rootfs 是
11-21 17:56 生成的，而服务是 11-22 才随 0682fe9 入库、还没进过镜像。
**下次刷 rootfs 会把这套手工固件丢掉**，除非先把服务装进去。



### 32.8 又一来源被排除：GitHub 上的整机固件仓库（2026-11-22 19:00）

`pangwalla/oneplus-instantnoodlep-firmware`（2023-03 更新，含
`adsp/ cdsp/ modem/ gpu/ ipa/ slpi/ venus/ wlan/`）里的 `adsp/` 是**分段**
（`adsp.b00..b18` + `adsp.mdt`），与 `modem` 分区同构，但是**另一代**：
b02/b04/b06/b07 的大小都不同。

拼接后 15,921,292 字节，与 `modem` 版**完全同构**：

| 检查项 | GitHub 2023 版 | AYN Thor 版 |
|---|---|---|
| phnum | 20 | 20 |
| ph[1]（metadata，`PT_NULL`）头 | `0c000000 06000000 …` | 同 |
| 段间空隙 | 全 0 | 全 0 |
| 末段 | off = 文件尾、size = 0 | 同 |
| max(off+size) − 文件长度 | 3,956 | 3,972（同一种布局） |

真机：`error -22 setting up firmware`（TZ 在 `pas_init_image` 就拒），与
`modem_a`/`modem_b` 完全相同。

四个来源的完整证据：

| 来源 | 时间 | 大小 | TZ 结果 |
|---|---|---|---|
| `modem_a` 现拼 | 2021-12 | 17,166,524 | 拒（`setting up`） |
| `modem_b` 现拼 | 2021-12 | 17,166,524 | 拒（`setting up`） |
| GitHub pangwalla | 2023-03 | 15,921,292 | 拒（`setting up`） |
| **AYN Thor**（完整 mbn） | — | 15,523,964 | **过**，卡 `auth_and_reset`（`initializing`） |

**结论**：不是版本新旧（2023 的也被拒），不是 ELF 结构（两份同构），只与
"是不是由 OnePlus 的分段拼出来的"相关。最可能的解释是 OnePlus 用**加密
PIL**（TZ 用设备密钥解密），而拼接产物没有那个标记；AYN 发布的是未加密的
完整 mbn，所以它能过验签、却因为配置不匹配倒在下一步。

于是 **§32.5 的候选全部关闭**：OOS 全量包、LineageOS 的 vendor、GitHub 的
整机固件，三者给的都是同一类分段。再找更多 OnePlus 固件没有意义。

剩下的只有两条路：接受音频阻塞，或者反过来攻 AYN 那份的 `auth_and_reset -22`
（它是唯一过了 TZ 的，值得单独查 DDR/内存布局与 metadata）。

### 32.9 大文件怎么传：WiFi，不是串口（同轮顺带确认）

这段经验对以后所有"往设备里放文件"都适用：

- 设备连上 WiFi 后有 `192.168.5.21/24`，与主机 `192.168.5.7` 同一网段；
- 主机 `python3 -m http.server 8000 --bind 192.168.5.7`，设备
  `curl -o <目标> http://192.168.5.7:8000/<文件>` —— 15.9 MB **几秒**，md5 一致；
- 串口传大文件是死路，原因不是带宽而是**行规程**：getty 登录后的 tty 是
  canonical 模式，base64 数据不含换行，超过 4 KB 的行缓冲直接被丢弃。表现是
  "传了 21 秒、文件是 0 字节、没有任何报错"。`stty raw` 能绕过行缓冲，但
  管道与标记的时序仍然脆（一次实测把 shell 卡死，只能从另一个口
  `systemctl restart serial-getty@ttyGS1` 救回来）；
- **串口只做命令**，几 KB 的文件用 `--push`（base64 分块）足够。

顺带修正两个此前记错的口身份（两个都是**完整系统 shell**，不是只有 initramfs）：

| 节点 | 实际 | 说明 |
|---|---|---|
| `/dev/cu.usbmodem101` | ttyGS0 + getty → bash（`[root@frame ~]#`） | 内核 console 的 dmesg 也混在这里，命令输出要挑着看 |
| `/dev/cu.usbmodem103` | ttyGS1 | 开机时是 initramfs 救援 shell（`/dbg/bin/busybox chroot /proc/1/root`）；`serial-getty@ttyGS1` 重启之后也是完整系统 shell |

## 33. 震动的 reset 极性：ACTIVE_HIGH 把芯片按在复位里（2026-11-22）

驱动在树里（0031）、DTS 节点齐全、`CONFIG_INPUT_AW8697=y`，probe 却失败，
i2c11 上 `i2cdetect` 连 0x5a 都没有 —— 整条总线 NACK，看起来像"芯片没焊好"
或"供电没起来"。

判据链（不靠猜）：

1. `debugfs` 读 gpio72：**物理低**；
2. 读 `drivers/aw8697.c` 的 `aw8697_hw_reset()`：`:569` 写逻辑 1（拉复位），
   `:571` 写逻辑 0（释放），而 `devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH)`
   的初值也是逻辑 1。也就是说**复位序列结束时引脚停在逻辑 0**；
3. 在 `GPIO_ACTIVE_HIGH` 的语义下，逻辑 0 = 物理低 = **RSTN 有效** ——
   驱动以为自己在"释放复位"，实际把芯片一直摁在复位里。

改 `GPIO_ACTIVE_LOW` 后 probe 成功（`input2` 注册，`/dev/input/event*` 出现）。

留档两点：

- Nura 的 0074 用的是 `ACTIVE_HIGH`，而且它自己标注"未设备验证"。这是
  "参考移植里没验过的部分不能当前提"的又一例，和 §30.7 的 bq27541 同型。
- 手感：**2026-11-22 19:28 已通**。但根因不在驱动，而在我们自己的测试工具 ——
  `struct ff_effect` / `input_event` 的字段偏移写错（§33.1）。驱动从头到尾都是
  好的：波形上传进 RAM、`play_mode=RAM`、`GO` 置位、`GLBSTATE` 进播放态，
  只是拿到 `level=0`（偏移错、读到 padding）就直接 return 了。

### 33.1 为什么 `EVIOCSFF` 返回 0、dmesg 干净、马达却不动

症状：触发后 `RC=0`、驱动无任何日志、`dmesg` 干净、用户毫无感觉。
复位、供电、波形上传、`probe` 全都正常 —— 所以"哪里都对，就是不震"。

踩坑过程（两次判断都是错的，记下来免得再犯）：

1. 先用 `grep -n "ram_init" | head -12` 看驱动，结论是"`aw8697_ram_init()`
   从没被调用、RAM 里没有波形"。**错**：`head` 把后面的调用行截掉了，`probe`
   里一直都有 `ram_init` + `f0_calibrate`（第 647/651 行），补丁里也有。
2. 然后发现 `ffplay.c` 的 `input_event.type` 写在偏移 8（实际 16），改成 16 ——
   时间对了、`RC=0`，以为好了。**又错**：同一版里把 `ff_effect` 的
   `strong_magnitude` 挪到了 24（照着"应该是 24"推的），而它在这套内核头上
   在 **16**。写进 24 就落进 padding，驱动读到 `level=0`，与初值相同 →
   `play_effect` 第一行就 `return 0`（不播放、不报错）。

真正定位它靠的是**不猜，量两个东西**：

- `regmap` 的 debugfs（不影响驱动、不用 unbind）：播放瞬间读
  `04`(SYSCTRL) `05`(GO) `46`(GLBSTATE) `39`(DATDBG)。修好后是
  `SYSCTRL=0x42`（play_mode=RAM、已退出 standby）、`GO=0x01`、
  `GLBSTATE=0x07`（播放中）、`DATDBG=0x80`（满量程）。修之前 `DATDBG=0x01` ——
  那一格就是"level 只有 1"的直接证据，比任何日志都硬。
- `offsetof`：容器里 `gcc + <linux/input.h>` 直接打印，aarch64 实测——
  `sizeof(ff_effect)=48`，但 `replay.length@10`、`delay@12`、`strong@16`、
  `weak@18`（`trigger` 只占 4 字节，`envelope` 在 union 里）；
  `sizeof(input_event)=24`，`type@16 code@18 value@20`。

工具已固化进仓库：**`scripts/op8p-ff-trigger.c`**（免 libc，`gcc -O2 -nostdlib
-static` 直接用容器的原生 aarch64 gcc 编）。满量程 `0xFFFF` 只用于测试，
日常强度由应用通过 FF 决定。

这条和 §30.7（bq27541 寄存器表）、§33（reset 极性）是同一类：
**"返回 0"、'寄存器都写成功了'、'状态机对了'，都不等于"东西真的动了"**。


## 34. 换机后的地基：三处静默故障与 docker 构建入口（2026-11-22）

换机（`MIGRATION.md`）之后在 macOS 上重新验证，先撞上的不是设备问题，是
**仓库和构建链的三处静默故障**：它们都不报错，只是让"验证"变成假的。

### 34.1 三个静默故障

| 现象 | 真因 | 判据 |
|---|---|---|
| `git status` 110 个文件全脏，18033 增 / 18033 删 | 工作树被转成 CRLF，索引是 LF | `git diff --ignore-cr-at-eol` 为空 + 逐文件增删等量 = 纯行尾；`git checkout -- .` 复原 |
| `assert-op8p-stage2.sh` 无任何输出、退出码 1 | `output/current` 是**被展开成空目录的符号链接**（Windows 拷贝把 `ln -sfn` 摊平了）+ `find dtbs` 返回 1 + `set -e` | 三条路径分开：目录不存在 / 缺 dtbs / 缺 config 都显式 SKIP 并说明 |
| `assert-op8p-power.sh` 三条 FAIL | 期望值停在修复前：`ti,bq27541`、`fuel-gauge = <&smart_battery>`、`reset ACTIVE_HIGH` | 按 §30.8–30.10 与 §33 的实测结论对齐 |

行尾那条最危险的不是文档，是这三处**会原样进镜像**：
`external-and-mods/kernel-common/initramfs/init`（shebang 带 `\r` → 内核
exec 失败 = 起不来）、`alioth-overlay/usr/lib/steamos-arm/alioth-*`（126 退出，
memory 里已记两次）、`scripts/assert-*.py` 与 `mkbootimg-v2.py`。

两个断言脚本的修改都做了**负向测试**：把值改回旧写法，断言必须报红（分别
报 2 / 2 / 1 / 3 条），恢复后全绿。这一步不能省 —— 一个恒绿的断言比没有
断言更糟。stage2 另外加了一条真检查："反编译产出的 dtb，确认里面真的有
`awinic,aw8697`"（需要 `dtc`；没有就 SKIP 并说明，不假装通过）。

`output/current` 修复：`rmdir current && ln -s 7.2.8-sm8250-steamos current`。

### 34.2 构建入口：`scripts/op8p-build-docker.sh`

`work/wslc-op8p-build.sh` 驱动的是 Windows 容器 CLI（`/c/Program Files/WSL/wslc`），
在 macOS 上不存在。新增三个文件，与它并存（Windows 那台继续用旧的）：

| 文件 | 作用 |
|---|---|
| `scripts/op8p-build-docker.sh` | 宿主入口：挂 `/repo`（bind）+ `/work`（docker volume），跑容器 |
| `scripts/op8p-build-container.sh` | 容器内：装依赖、取 busybox、去 CRLF、调 `build.sh sm8250`、把 `output/` 带回来 |
| `scripts/op8p-build.Dockerfile` | 工具链镜像 `op8p-build:43`，把 330 个包烧进层里 |

四个关键决策，每个都因为踩过：

1. **aarch64 不传 `CROSS_COMPILE`。** colima 是 aarch64 VM，镜像也是 arm64
   原生，`build.sh` 自己就在 `uname -m == aarch64` 时走原生分支；硬塞
   `CROSS_COMPILE` 会去找一个不该存在的 `aarch64-linux-gnu-gcc`。
2. **包列表按架构分支。** Fedora 的 aarch64 仓库没有 `gcc-aarch64-linux-gnu`
   —— 这个名字只在"从哪些架构交叉出去"的仓库里存在。
3. **`/work` 用 volume，不用 bind。** 内核树是几十万文件 + 140 MB 缓存，
   放 virtiofs 上元数据开销比编译本身还贵，也免得 `git status` 被副产品弄脏。
4. **`safe.directory`。** bind mount 属主不是 root，git 判 "dubious ownership"
   拒绝操作，而 `build.sh` 会把拒绝读成
   `ROCKNIX checkout does not match pinned 20261001`（一句非常误导的错误）。

实测（MacBook，colima aarch64）：

| 场景 | 耗时 |
|---|---|
| 首次全量（含 linux-7.2.8.tar.xz 140 MB、extra-firmware、11 个 linux-firmware 文件） | 7 分 19 秒 |
| 增量，直接用 `fedora:43`（每次重装 330 包） | 1 分 42 秒 |
| 增量，用工具链镜像 `op8p-build:43` | **29 秒** |

镜像只影响速度不影响正确性：容器内脚本仍会 `dnf install` 一遍（幂等），
镜像过期时包会被补齐。`--bare` 参数强制不用镜像，用来验证脚本自身能独立跑。

### 34.3 新产物**不等于**已验收的那份（别把"编出来了"当"没变"）

这次重编的 Image 与 §28 验收那份：

| | 旧（11:26，刷在 a 槽 / 曾用于验收） | 新（本轮） |
|---|---|---|
| `Image` 大小 | 35,887,616 | 35,887,616（一模一样） |
| `Image` sha256 前 12 | `98d157c6bcc2` | `3857076c0753`（首编）/ `0ef5e5c317bf`（增量） |
| 编译器 | `aarch64-linux-gnu-gcc` **15.2.1**（Red Hat Cross） | `gcc` **15.3.1**（Red Hat，原生） |
| binutils AS/LD | 2.45.0 | 2.45.1 |

`config` 的非注释行只差 **9 行**，全是编译器身份（`CC_VERSION_TEXT`、
`GCC_VERSION`、`AS_VERSION`、`LD_VERSION`、`CC_CAN_LINK`），**配置契约一致**；
二进制差异来自 gcc 15.2.1 → 15.3.1。

两个结论都写下来：

1. **Image 每次构建 sha 都不同，即使源码和配置一字未改** —— 内核会嵌入构建
   时间戳（`UPD include/generated/compile.h`、`init/version-timestamp.o`）。
   所以**不要用 sha 判断"源码有没有变"**；要判断看 `config` 和 `build.sh`
   的 patch digest（它自己会打 `source already patched`）。
2. **配置等价 ≠ 二进制等价，要上机就得重新验收。** 旧的已验收产物留在
   `work/kernel-sm8250/output-1126-accepted/`（git-ignored），新产物在
   `output/7.2.8-sm8250-steamos/`，两者不要混着说。

### 34.4 三件补上了（同日下午）

上午这轮结束时还留着三处缺口，当天补完。三件的共同点：都是"不绿也不会
报错"的地方 —— 断言不跑、`--install` 直接 die、串口工具不存在，三者都只
表现为"这一步没法做"，而不是"做错了"。

**① 刷机门禁：`scripts/assert-op8p-boot-image.sh`（新）**

其余 `assert-op8p-*.sh` 查的都是**源码**（DTS、config、flash 脚本）。可刷机时
真正写进分区的是一个几十分钟前打出来的 `.img`，源码后来改没改、改完有没有
重新打包，它们全看不见。这个脚本查那一个镜像：

| 组 | 查什么 | 对应的真机症状 |
|---|---|---|
| 头部 | magic、`header_version`、`page_size=4096`、四个载入地址、`second_size=0`、装得进 `boot_a` | Load Error / 弹回 fastboot，ABL 不会说原因 |
| cmdline | `root=PARTLABEL=userdata`、`rootwait`、`console=ttyGS0`+`tty0`、`loglevel=7`、`steamos.usbshell=1`、无 `quiet`/`loglevel=0` | 面板黑时唯一的观测手段被关掉 |
| **ramdisk** | 存在、gzip、cpio 里有 `updates/qcom/a650_zap.mdt` 等四件 + `init` | **缺了就是全黑**：GPU 拿不到 zap → Vulkan 失败 → gamescope 不 modeset（§28） |
| 设备树 | gzip 流之后恰好 1 个 DTB、没有多余字节、含 `awinic,aw8697`/`ti,bq27411`/`samsung,s6sy761`、**与当前产物逐字节相同** | 分辨率/触摸/电量计悄悄退回上一版 |

`flash-op8p.sh` 在碰设备（第一次 `fastboot getvar`）**之前**跑它，加上
`assert-op8p-flash.sh` 自己的规则；`make-op8p.sh` 打完立刻跑同一个脚本。
`OP8P_SKIP_ASSERT=1` 是唯一的绕过方式，且必须显式设置。

负向测试（不做这一步就等于不知道断言是不是恒绿）：

| 动手脚 | 结果 |
|---|---|
| `page_size` 4096 → 2048 | 7 条 FAIL |
| `ramdisk_size` 置 0 | 1 条 FAIL（就是黑屏那条） |
| 截掉尾部 DTB 60 KB | 1 条 FAIL |
| cmdline 注入 `quiet` | 7 条 FAIL |

`assert-op8p-flash.sh` 里另加了 5 条"门禁自己也要被断言"：flash 必须调用这两个
脚本、必须把 `$IMG` 传进去（否则 `--img` 指向任何文件都绕过检查）、跳过只能
靠显式环境变量、`make-op8p.sh` 打包后也要验。

**② `--install` / `--verify` 走容器：`scripts/op8p-rootfs-docker.sh`（新）**

原来只认"Linux 工具在 PATH"或 Windows 的 `wslc`，macOS 上直接 die。现在复
用内核构建的同一个镜像 `op8p-build:43`（Dockerfile 里加了 e2fsprogs /
squashfs-tools / btrfs-progs / util-linux）：`mkfs.ext4 -d`、`unsquashfs`、
`e2fsck`、`btrfs restore` 一个镜像全有 —— 两个镜像意味着"编译用的 gcc"和
"打包用的 mkfs"会在不同时间漂移。

- `--verify` 已实测（12.9 GB 的 `userdata.img`）：7 组全 ok，
  "userdata.img 可以刷"；
- `--install` **未实测**：要解包 10 GB 的 Valve rootfs 再生成 12.9 GB 镜像。
  代码路径与 `--verify` 同一条（同一个镜像、同一套挂载），但没跑过就是没跑过；
- 与 Windows 那条路的唯一差异：不用 `/scratch` 中转。那边是 DrvFs 不保留
  Unix 权限位，这边 virtiofs 保留。

**③ 串口：`scripts/op8p-sh.py`（新，真机已验证）**

Windows 上是 COM3/COM4；macOS 上同一根线枚举成 `/dev/cu.usbmodem*`，
**设备节点名不带端口号**，所以没法靠命名区分两个口 —— `--list` 列出来，再拿
`uname -a` 试。只用 python3 标准库（termios + select），不引入 pyserial。

2026-11-22 18:20 上机实测，两个口的身份：

| 节点 | 是 | 特征 |
|---|---|---|
| `/dev/cu.usbmodem101` | ttyGS0 内核 console | 输出混着 dmesg；命令也能执行但没 PATH |
| `/dev/cu.usbmodem103` | ttyGS1 救援 shell | 根是 **initramfs**（有 `/newroot`、`/dbg`，没有 `/usr`），`PATH=[/bin]`，`uname`/`cat` 都没有 |

所以系统命令要走 §28.3 那条老路：
`/dbg/bin/busybox chroot /proc/1/root /usr/bin/<命令>`。

**两个 bug 都是"只在真实时序下才出现"**，pty 假设备只能抓到第一个：

1. 设备会把命令回显一遍，回显行里就带完成标记 —— 只做子串匹配时"设备根本
   没回"会被读成"成功、输出为空"（pty 上复现：超时用例返回 0 和一行空）。
2. **更隐蔽的那个**：改成"标记独占一行"之后，break 条件写的还是
   `END + "\n"` 这个子串 —— 而回显行 `echo STARTS; cmd; echo ENDE` 自己就
   带着 `END` 和换行，于是循环**第一次读到回显就 break**，那时 start 行还没
   到，于是被判成超时。真机上稳定复现，而 **raw 模式反而一切正常**（raw 不
   检查标记，一直读到超时，所以看得到输出）—— 这个不对称是最误导人的地方。
   最终做法：起止双标记，**两端都必须是独占行**才认。

真机验证过的四类：短命令、长命令（两条 `chroot` 拼接）、多行输出、超时
（退出码 1 且 stderr 说明原因）。另外顺手确认了 §32.7 那件事。

### 34.5 顺带确认的两件事

- `make-op8p.sh --gzip` 打出来的新镜像 15,937,536 字节（旧 15,941,632），
  差 4096 = `Image` 大小变化引起的页对齐差异；DTB 与产物**逐字节相同**
  （dtb 编译可复现，只有 `Image` 含时间戳）。
- 旧的 11:26 验收镜像已备份：`work/steamos-op8p/boot-op8p-gzip.img.1126-accepted`。

### 34.6 蓝牙：控制器、固件、扫描都正常（2026-11-22 19:35）

一开始 `Powered: no`，`bluetoothctl power on` 之后 `Powered: yes`。固件链完整：

```
hci0: QCA Downloading qca/htbtfw20.tlv
hci0: QCA Downloading qca/htnv20.bin
hci0: Generated BD_ADDR: 00:03:7f:31:34:27
hci0: QCA setup on UART is completed
```

地址是驱动**生成**的（不是芯片 OTP 里的），但 `systemctl restart bluetooth` 后仍是
同一个 —— 生成算法是确定性的，所以配对记录不会每次失效。这点和 raphael 不同
（那边需要 `/etc/raphael-bdaddr` 手工钉住）。扫描 15 秒发现多台设备。

**未验证**：配对/连接/音频。注意 **音频（A2DP）要过 ALSA**，而声卡至今没起来
（§32.7），所以蓝牙耳机现在连上也听不到；**蓝牙手柄不受影响**（走 evdev）。

### 34.7 Steam 登录卡在 CM：`'Try another CM'`（2026-11-22 20:15，**未解决**）

现象：扫码认证通过 → 屏幕显示 logging in → 几秒后回到未登录界面。

`connection_log.txt` 的原话：

```
[20:05:33] ConnectionCompleted() (205.196.6.133:443, WebSocket)
[20:05:41] [Connected, 0, 11] ScheduledAttemptReconnect() not reconnecting due to already having an hConnection
[20:06:40] RecvMsgClientLogOnResponse() : 'Try another CM' / 'Failure', ignored since we're not waiting for a logon response
```

所以认证（扫码）是成功的，卡在**用 token 登录 CM** 这一步，而且 CM 是**主动拒绝**
（`Try another CM`），不是网络断开。

已排除：

| 怀疑 | 依据 |
|---|---|
| 时间错导致 TLS 全挂 | `date` 正确（CST 2026-11-22），`client-update.steamstatic.com` 返回 304 |
| DNS | CM 域名解析到真实 IP（`cmp1-hkg1` → 103.28.54.100） |
| CM 不可达 | hkg1 / sea1 / jnb1 等多个 CM 都 `ConnectionCompleted` |
| 出口 IP 被 CM 拒 | **同一 WiFi 下 Mac 上的 Steam 正常，用户不需要加速器** |

试过并**已回滚**的方案：把 58 个 `(cmp|ext)*.steamserver.net` 写进 hosts 指向
127.0.0.1，配一个用户态转发器（经 Mac 的 Clash SOCKS5 连 `cm0`，实测 27017/
27018/27019/27020/443 全部 `rep=0`）。失败原因：**Steam 的 CM 域名有上百个且
动态变化** —— 抓了 58 个，它下一次连的 `ext2-jnb1` 不在名单里，转发器一个连接都
没接到。半成品留着会让 Steam 连到不通的地址，所以 hosts 和转发器都已复原。

下一步（没做，下次接着查）：

1. 读 `console_log.txt`（这次被中断，没读到）；
2. 用 steamcmd / 另一台机器同账号验证，把"客户端问题"和"账号问题"分开；
3. **主要怀疑：ARM64 SteamOS 客户端**。这台跑的是
   `steam_client_steamdeck_stable_linuxarm64`（Steam Frame 的固件），而 raphael
   上也是卡在同一个位置（memory 2026-11-08 "二维码空是 CM 握手失败"）。两台
   完全不同的硬件、同一个症状，指向客户端而不是设备。

### 34.8 这一轮结束时的状态（2026-11-22 20:20）

| 功能 | 状态 |
|---|---|
| 显示 / GPU / 触摸 / 按键 / 手电筒 / 温控 | 通 |
| 振动 | **通**（§33.1，修的是测试工具的结构偏移） |
| WiFi（含 5G）+ 开机自连配置 | 通 |
| 蓝牙控制器 / 固件 / 扫描 | 通（配对与音频未验） |
| 充电（双电量计） | 通 |
| 音频 | **阻塞**：adsp 被 TZ 拒，四个来源全部试过（§32.3–§32.8） |
| Steam 登录 | **阻塞**：CM 返回 `Try another CM`（§34.7） |
| 摄像头 / 指纹 / 传感器 / NFC / GPS / USB-C host | 无驱动或未验（§34 盘点） |

设备侧没有留下任何临时改动：hosts 已复原（`/etc/hosts.bak.op8p` 也还在）、
CM 转发器已停、`/tmp` 下的测试文件已删。
