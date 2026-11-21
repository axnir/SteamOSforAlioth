# 参考实现：darknagel 的 OnePlus 8 Pro / Nura 移植（同面板、已点亮）

上游：<https://github.com/darknagel/oneplus-instantnoodlep-nura-unofficial>
本地副本：`work/ref-instantnoodlep/`（`work/` 已 gitignore，需要时重新 clone）

写这份文档的原因只有一个：**这是我们第一次拿到同一块面板、同一条 mainline 路径、
且真机能亮 1440×3168@120 的现成实现。** 前面 §19–§21 的所有推断，现在都可以
拿它当对照组，而不是继续猜。

---

## 1. 它是什么，不是什么

| | 内容 |
|---|---|
| 系统 | Nura（原 postmarketOS）/ Alpine + Phosh 或 Plasma Mobile |
| 内核 | `linux-postmarketos-qcom-sm8250`，即 **mainline + 217 个补丁**，不是 4.19 downstream |
| 显示 | **自己写的 `panel-samsung-ams678uw01` 驱动 + 自己写的 DTS 节点**，不是 simpledrm |
| 自述状态 | Display 1440×3168 @ 120 Hz works，kmscube ~119.4 fps |
| 许可 | 每个补丁随上游项目；驱动是 GPL-2.0（文件名/结构可整份取用，保留作者与来源） |

对照 §18.5 我们拆过的那三个「声称已验证显示」的包：那些全是
`dispcc disabled / dsi disabled / 没有 panel 节点 / 靠 simpledrm`。
**这个不是。** 它的 DTS 把 `dispcc`、`mdss_dsi0`、`mdss_dsi0_phy` 全开，
面板节点是完整的 `panel@0`。

### 同一块屏的证据

| 来源 | 标识 |
|---|---|
| 他们的 README / `docs/panel-log.md` | Android 报 `oppo19811_samsung_1440_3168_dsc_cmd` |
| 我们的 `docs/op8p/README.md` §21 | 厂商 DTS 文件名 `dsi-panel-oplus19811-samsung-1440-3168-dsc-cmd.dtsi`，本机 `project_name=19811` |

`oppo19811` / `oplus19811` 是同一台机器的工程名。AMS678UW01 是模组型号，
ANA6706 是 Qualcomm DT 里的面板节点名 —— 同一块屏的两个编号。

---

## 2. 他们的实现（事实，全部来自 `kernel-patches/0002`、`0003`）

### 2.1 驱动形态

一个标准 mainline `drm_panel`，`drm_mipi_dsi_driver` 注册，
`devm_drm_panel_alloc()` + `devm_mipi_dsi_attach()`，
`prepare/unprepare/get_modes` 三个 ops。**485 行，比我们的 953 行短一半**，
因为初始化序列是 `linux-mdss-dsi-panel-driver-generator` 直接从厂商 DT 生成的，
没有逐条手抄 + 二分探针那套东西。

### 2.2 模式标志：视频模式

```c
dsi->mode_flags = MIPI_DSI_MODE_VIDEO_BURST |
                  MIPI_DSI_MODE_NO_EOT_PACKET |
                  MIPI_DSI_CLOCK_NON_CONTINUOUS;
```

`on()` 里临时 `|= MIPI_DSI_MODE_LPM` 让 DCS 走 LP，`off()` 里清掉。
**注意：`CLOCK_NON_CONTINUOUS` 我们有，他们没有 —— 反过来，我们没有，他们有。**
见 §3。

这直接印证了 §19 末尾那条一直没上机验证的判断：**这块屏在 mainline 上要按
video burst 跑，而不是按「命令模式面板」的字面意思跑。**

### 2.3 DSC：几何 + 面板自带 PPS，两份都发

```c
ctx->dsc.dsc_version_major = 1; ctx->dsc.dsc_version_minor = 1;
ctx->dsc.slice_width  = desc->slice_width;
ctx->dsc.slice_height = desc->slice_height;
ctx->dsc.slice_count  = mode.hdisplay / slice_width;
ctx->dsc.bits_per_component = desc->bits_per_component;
ctx->dsc.bits_per_pixel = desc->bits_per_pixel << 4;
ctx->dsc.block_pred_enable = true;
dsi->dsc = &ctx->dsc;
```

**只填几何，不逐字段解 RC。** 理由和我们 §19.3 的结论一致：反正
`drm_dsc_pps_payload_pack()` 会用自己的常量覆盖那一半，DPU 和面板只要
**用同一份 dsc_config 生成 PPS** 就自洽。

PPS 发两次，两次类型不同：

| 位置 | 形式 | dtype |
|---|---|---|
| `on()` 第 21 条 | `0x9e` + 88 字节（厂商原始 PPS） | 0x39 DCS 长写 |
| `prepare()` 在 `on()` 之后 | `drm_dsc_pps_payload_pack()` → `mipi_dsi_picture_parameter_set()` | 0x0a DTYPE_PPS |

这正是 §20.2/§20.3 从厂商内核里读出来的那两件事，我们后来也补上了
（`ana6706_enable()` 里同样是先 raw 0x9e、再 `picture_parameter_set()`）。
**这一条我们是对的。**

### 2.4 四组时序与 DSC 几何（可直接抄的表）

```c
#define AMS678UW01_MODE(hd, hfp, hpw, hbp, vd, vfp, vpw, vbp, hz)  \
        .clock = (hd+hfp+hpw+hbp) * (vd+vfp+vpw+vbp) * hz / 1000, ...
```

| # | 分辨率 | fps | hfp/hpw/hbp | vfp/vpw/vbp | slice | bpc | bpp | `0xba` scaler | `0x60` refresh |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 1080×2376 | 60 | 64/8/48 | 1100/188/1100 | 540×72 | 8 | 8 | 0x02 | 0x02 |
| 1 | 1080×2376 | 120 | 64/8/48 | 2/2/8 | 540×72 | 8 | 8 | 0x02 | 0x22（+ 0xb9 组） |
| 2 | 1440×3168 | 60 | 80/8/80 | 180/12/180 | 720×16 | 10 | 10 | 0x03 | 0x00 |
| 3 | 1440×3168 | 120 | 88/8/56 | 8/8/8 | 720×96 | 10 | 8 | 0x03 | 0x20 |

与 §21.1 的厂商 `panel-clockrate` 对照一致；porch 与我们转录的完全一致。
**`.clock` 用宏算，不手写** —— 正是 §21.5 那条教训的解法。

### 2.5 电源与 GPIO

| 项 | 他们 | 我们 |
|---|---|---|
| 稳压器 | `vdd`=l11c 3p3、`vddio`=l14a 1p8，`regulator_bulk` 两路 | `vddi`=l12a 1p8、`vddr`=l9a 1p2、`vci`=l17a 3p0、`px_v18r`=l10a 1p8，四路 |
| 复位 | gpio75 `GPIO_ACTIVE_LOW`，`0→1→0` + 10/2/10 ms | 同（§19 的 reset 极性结论是对的） |
| `panel_vout` | gpio8，pinctrl `output-high` | 同 |
| TE / vsync | gpio66，pinctrl `function = "mdp_vsync"` | 同 |
| `vddd-gpio`(24) | **完全没有** | 也没配（§3 那条怀疑可以彻底放下） |
| Iris | **完全没有**，不读 112、不做 lightup | 读 112 确认 `1` |
| DSI `vdda` | l9a 1p2 | 同 |
| PHY `vdds` | l5a 0p88 | 同 |

两个结论：

1. **他们不碰 `vddd-gpio`(24)、不碰 Iris 也点亮了。** §2 和 §8 那两条怀疑
   （gpio24 + Iris lightup）可以正式关掉，不必再花时间。
2. 电源路径的差异是真实存在的：他们用 l11c 3p3 当面板 `vdd` 并显式
   `regulator_bulk_enable`；我们的 DTS 里 l11c 是 `regulator-always-on`、
   面板节点不引用它。**目前看不是黑屏主因**（always-on 一样是通电），
   但它意味着「谁给面板 3.3V」这件事在我们的 DT 里没有被表达出来，
   以后做 suspend/resume 会咬人。

### 2.6 亮度

`backlight` 设备：`max_brightness = 2047`，**初值也是 2047**；写 `0x51`（large），
读 `0x52`（large），写前后切换 `MIPI_DSI_MODE_LPM`。
他们明确不需要 `bl-high2bit` 那套东西 —— 我们 §4/§F 里那个「读回 0 字节」的谜团
**大概率是「面板还没 prepare 时就读」造成的**，他们后来专门打了一个补丁
（`0070`：`defer brightness access until prepared`，未 prepare 时返回缓存值、
不发 DCS 读）。我们现在的背光初值是 1023（50%），不是致命问题，但可以先按他们的来。

---

## 3. 逐项差异：我们还差什么

按「值得先做」排序。**A 类是我们确实缺的，B 类是形态不同但未必要紧。**

### A1. `MIPI_DSI_MODE_CLOCK_NON_CONTINUOUS` 我们没设

他们设了，我们没设。连续的 HS 时钟在某些面板/PHY 组合上会让面板的
内部时序不认 burst 边界。**一行改动，零风险。**

### A2. 我们的 `LPM` 是常驻的

`dsi->mode_flags = VIDEO_BURST | LPM | NO_EOT_PACKET` —— video burst 和常驻 LPM
在语义上互相别扭。他们的写法是：base flags 里不放 LPM，`on()` 里临时加、
`off()` 里清，DCS 写完随视频流走 HS。

### A3. `simple-framebuffer` 没有带显示时钟和 MDSS GDSC

```dts
framebuffer0: framebuffer@9c000000 {
    ...
    clocks = <&dispcc DISP_CC_MDSS_AHB_CLK>, <&gcc GCC_DISP_HF_AXI_CLK>,
             ... <&dispcc DISP_CC_MDSS_ESC0_CLK>;
    power-domains = <&dispcc MDSS_GDSC>;
};
```

他们 0003 的 commit message 说得很直白：**不写这个，dispcc 一 probe，
bootloader 留下的 framebuffer 就丢掉时钟，显示在 msm 接手前冻住。**
我们的 DTS（`dts/sm8250-oneplus-instantnoodlep.dts:71`）没有这两行。
我们目前看到的是「黑」而不是「冻住的画面」，但这条零成本，应该补。

### A4. DSI PHY 的两个 upstream 修复（`0077`、`0078`）

- `0077`：PLL 锁失败时释放 bias 引用（clock core 不会在 prepare 失败后调 unprepare）
- `0078`：PLL/PHY 使用期间保持 digital top 供电，给 native PHY 持一个真实 bias 引用

**这是最值得看的一条。** 我们的症状是「一切软件指标正常、屏幕全黑」，
而 DSI PHY 的 digital top 没电/引用计数错，正好产生这种症状：PLL 写进去了、
面板也能回 DCS，但高速数据没真正出去。这两条是 `drivers/gpu/drm/msm/dsi/phy/dsi_phy_7nm.c`，
与面板无关，我们的树上应该没有。

### B1. 驱动形态不同（我们手写 msm 面板 vs 他们标准 drm_panel）

其实我们的驱动**已经**是标准 `drm_panel`（`devm_drm_panel_alloc`），
不是 msm 私有面板。初始化序列、`0xba`/`0x60`/`0x53`/`0x35`/`0xb9` 组、
raw 0x9e + DTYPE_PPS、reset 三步、vout pinctrl —— 逐条对下来**都在**。
所以「换驱动」不是必须的第一步；它最大的价值是当**已知能亮的对照组**。

### B2. 他们只暴露一个模式（`mode` 模块参数，默认 1440×3168@120）

我们用 1080×2376@120（`ANA6706_FPS_120`，preferred）。
他们的默认是原生 1440×3168@120，并且 **DSC 几何随模式变**（720×96 / 540×72）。
我们 §README 里「1440 模式不能暴露因为 slice 540 除不尽」的问题，
他们的解法就是「每个模式一套 dsc_config，probe 时选定一个」——
**这就是我们缺的那块 runtime 结构**，而且比想象中简单：不需要 atomic 钩子，
boot 时选一个、整个生命周期不变。

---

## 4. 他们已经踩过并修好的坑（可直接借用，不必重踩）

| 补丁 | 内容 | 对我们的意义 |
|---|---|---|
| `0070` | 背光在 panel prepared 之前被访问 → 缓存、不发 DCS 读 | 解释我们「0x52 读回 0 字节」 |
| `0115` | PPS 发失败时没关电源，regulator 泄漏 | prepare 错误路径 |
| `0077`/`0078` | DSI PHY digital top 供电 / PLL bias 引用 | **A4，优先看** |
| `0146`/`0147` | DPU 命令模式 disable 时不清理 DSC / LM / mixers | 我们跑 video 模式，暂时不咬 |
| `0163` | SM8250 上 DSC block 只能按索引配 pingpong，否则每帧 kickoff 超时 | 如果我们后面切回 cmd 模式，这条是必读 |
| `0003` | simple-framebuffer 带 dispcc 时钟 + MDSS GDSC | **A3** |

---

## 5. 结论：怎么接

三档，成本从低到高。**推荐按 1 → 2 → 3 走，不要跳。**

### 第 1 档：先把手头这版刷上去（0 行代码）

§「第四轮」那版（video burst + 14 项修复）**编译完了但从来没上过机**。
在写任何新代码之前，先看它在真机上是什么样 —— 它已经包含了 A2 的
一半（video burst）和全部 DSC 修复。判据：屏幕有没有输出、有没有花屏、
`vblank fps` 是否到 120。

### 第 2 档：补齐 A1 + A2 + A3（约 20 行）

- 驱动 `mode_flags` 加 `MIPI_DSI_CLOCK_NON_CONTINUOUS`，把常驻 `LPM` 移到 `on()/off()`
- DTS 的 `framebuffer0` 补 `clocks` + `power-domains`
- （顺手）`drivers/gpu/drm/msm/dsi/phy/dsi_phy_7nm.c` 打 `0077`/`0078`

### 第 3 档：整份换成他们的实现（对照组）

把 `kernel-patches/0001–0003` 移进 `external-and-mods/kernel-sm8250/patches/`，
删掉我们的 `0029`，DTS 面板节点按他们的写法（两路稳压器 + `vddio`/`vdd` 命名）。
**这一步的价值不是「他们的代码更好」，而是「如果他们的也不亮，问题就不在面板驱动，
而在内核/DPU/ABL」，这是一个决定性的排除实验。**
做这步之前必须能回滚：`0029` 的源码在 `drivers/panel-oneplus-ana6706.c`，别删。

---

## 6. 同时被这份实现确认/推翻的旧结论

| 旧结论（本文档之前） | 现在 |
|---|---|
| §3 `vddd-gpio`(24) 未配可能是原因 | **关掉**，他们也没配，能亮 |
| §8 Iris 必须 lightup 才放行 | **关掉**，他们完全不管 Iris，能亮（与我们读到 112=1 一致） |
| §19 结尾「值得一试视频模式」 | **确认**，他们就是 video burst |
| §21 `.clock` 手算错 | **确认解法**：用宏算，配 `dev_warn` 自检（我们已加） |
| 「1440 模式需要 runtime 切换，暂不做」 | **有更简单的解法**：probe 时选定一个模式 + 对应 DSC 几何 |
| 「没有现成实现可抄」（§18.5） | **作废**。这份就是。 |

---

## 7. 落地（2026-11-21）

按第 3 档直接落地，没有走 1、2 档：既然照着能亮的实现抄，就先抄到一致，
再谈差异。判断是「多留一处自己的改动 = 多一个无法排除的变量」。

| 文件 | 变化 |
|---|---|
| `drivers/panel-samsung-ams678uw01.c` | 新增。他们的驱动，只改稳压器表（4 路）+ 文件头注明来源 |
| `bindings/samsung,ams678uw01.yaml` | 新增。他们的 binding + `vci`/`px-v18r` 两路声明 |
| `patches/0029-...ams678uw01...patch` | 新增，替代原来的 0029；**0030 删除** |
| `drivers/panel-oneplus-ana6706.c` | 删除（在 git 历史里） |
| `dts/sm8250-oneplus-instantnoodlep.dts` | 面板节点换成 `samsung,ams678uw01`；`framebuffer0` 补时钟和 `MDSS_GDSC`；去掉 `mdss-dsc-slice-per-pkt`、`iris-abyp-ready-gpios` |
| `steamos.config` | `CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01=y` |
| `scripts/regen-op8p-panel-patch.sh` | 重写：从 .c + .yaml 生成，不再需要 docker，直接读 `work/cache/linux-7.2.8.tar.xz` |
| `scripts/assert-op8p-panel.sh` | 新增，39 条断言 |

两处刻意保留的差异：

1. **稳压器 4 路而不是 2 路。** 他们的 DT 只有 vdd/vddio；我们板子的
   `panel-supply-entries` 写了 vddi/vddr/vci + Iris 的 px_v18r，而这几路
   在 DTS 里没有别的消费者 —— 少写一路，regulator 核心在 late init 会把它关掉。
   `vddr` 没有列，因为它和 DSI 的 `vdda` 是同一颗 LDO（l9a），已经被引用。
2. **vddio 用 l12a，不是他们的 l14a。** 之前调试时 DCS 能读能写，说明
   l12a 确实在给这块屏的 I/O 供电；他们的 l14a 是另一台机器的同一个功能。

已在 7.2.8 上核对过 API（`devm_drm_panel_alloc`、`_multi` 系列 DCS 辅助、
`devm_regulator_bulk_get_const`、`<linux/device-id/of.h>`、DSC helper），
全部存在；补丁在 7.2.8 的 panel 目录上 `patch -p1` 干净应用。
