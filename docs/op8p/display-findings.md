# ANA6706 显示排查：已确认的问题清单

这份文件只记一件事：**已经用代码或寄存器日志确认的问题**，
不是推测。每条都写清楚证据来源，方便下一个人核对或推翻。

排查对象：OnePlus 8 Pro（instantnoodlep / IN2020）的 ANA6706 面板，
在 sm8250-mainline 7.2 内核上的显示路径。

---

## 结论速览

| # | 问题 | 证据强度 | 状态 |
|---|---|---|---|
| 1 | DSC `slice_per_pkt` 被写死为 1，面板要 2 | **代码级确认** | 未修 |
| 2 | `pkt_per_line` 随之算错 | **代码级确认** | 未修 |
| 3 | `vddd-gpio`（gpio24）从未配置 | **DT 对比确认** | 未修 |
| 4 | 亮度寄存器读回失败（写有效、读无效） | 日志确认 | 未查清 |
| 5 | ~~`frame_done_cnt` 恒为 0~~ | ~~日志确认~~ | ❌ **已排除，见 §5：它是超时计数，0 是健康值** |
| 6 | 面板状态应为 `0x9f`，实测 `0x0c` | **DT 对比确认** | 未修 |
| 7 | TE 相关 DT 属性 mainline 完全不读 | **代码搜索确认** | 未修 |
| 8 | Iris 协处理器是否旁路 | 未验证 | 未查 |
| 9 | ~~背光使能 GPIO~~ | ~~代码查证~~ | ❌ **已排除，见 §9：本机没有这两个 GPIO** |

---

## 1 & 2. DSC 打包方式（最可能的主因）

### 厂商怎么算

`LineageOS/android_kernel_oneplus_sm8250`（4.19 downstream），
`drivers/video/fbdev/msm/mdss_panel.c` 的 `mdss_panel_dsc_pclk_param_calc()`：

```c
slice_per_pkt   = dsc->slice_per_pkt;                        // 2（来自 DT）
slice_per_intf  = DIV_ROUND_UP(intf_width, dsc->slice_width); // 1080/540 = 2
bytes_in_slice  = DIV_ROUND_UP(dsc->slice_width * dsc->bpp, 8); // 540*8/8 = 540
bytes_per_pkt   = bytes_in_slice * slice_per_pkt;            // 540*2 = 1080
pkt_per_line    = slice_per_intf / slice_per_pkt;            // 2/2 = 1
```

### mainline 怎么算

`drivers/gpu/drm/msm/dsi/dsi_host.c`，`dsi_update_dsc_timing()` 附近（约 950 行）：

```c
slice_per_intf       = dsc->slice_count;                       // 2
total_bytes_per_intf = dsc->slice_chunk_size * slice_per_intf;  // 540*2 = 1080
bytes_per_pkt        = dsc->slice_chunk_size;  /* * slice_per_pkt; */  // 540 ❌
pkt_per_line         = slice_per_intf;                          // 2     ❌
```

约 1126 行：

```c
/* 注释自己写了正确公式，然后没用 */
/* WC = slice_chunk_size * slice_per_pkt + 1 */
wc = msm_host->dsc->slice_chunk_size + 1;    // 541，应为 1081 ❌
```

### 差在哪

| 参数 | mainline（固定=1） | 厂商（=2） |
|---|---|---|
| `bytes_per_pkt` | 540 | **1080** |
| `pkt_per_line` | 2 | **1** |
| `WC`（命令模式） | 541 | **1081** |

`pkt_per_line` 会写进 `DSI_*_COMPRESSION_MODE_CTRL_PKT_PER_LINE(pkt_per_line >> 1)`，
即 mainline 写 1、厂商写 0。

### 对应的硬件现象

面板是 1080 宽、slice_width 540、slice_count 2，即**一行两个 slice**。

mainline 按「一个包一个 slice」发，面板按「一个包两个 slice」解：

- 面板把只装了半个 slice 的包当成完整一行来解码
- 左右两半各自错位
- 表现为**屏幕分成两段花屏**

这与实测现象吻合（用户描述：先是两段花屏，一闪而过。

### 修法（未实施）

1. 给 `struct msm_dsi_host` 加一个 `u32 dsc_slice_per_pkt`（默认 1）
2. `dsi_update_dsc_timing()` 里：
   ```c
   bytes_per_pkt = dsc->slice_chunk_size * msm_host->dsc_slice_per_pkt;
   pkt_per_line  = slice_per_intf / msm_host->dsc_slice_per_pkt;
   ```
3. WC 处：
   ```c
   wc = dsc->slice_chunk_size * msm_host->dsc_slice_per_pkt + 1;
   ```
4. 面板驱动里设为 2

默认值 1 时行为与现在完全一致，不影响 alioth（`ams667xx01` 也是 slice_per_pkt=1）。

### 注意

厂商代码里有一层保护：

```c
if (slice_per_pkt > slice_per_intf)
        slice_per_pkt = 1;
```

这里 `slice_per_intf = 2`、`slice_per_pkt = 2`，不触发降级，确实用 2。

---

## 3. `vddd-gpio`（gpio24）从未配置

本机原厂 DT（`/sys/firmware/devicetree/base/soc/qcom,mdss_mdp@ae00000/qcom,mdss_dsi_samsung_ana6706_dsc_cmd/`）里：

| 属性 | 原始值 | GPIO |
|---|---|---|
| `qcom,platform-reset-gpio` | `0x4B000000`（大端） | 75 ✓ 已配 |
| `qcom,platform-te-gpio` | `0x42000000` | 66 ✓ 已配 |
| `qcom,vddr-gpio` | `0x08000000` | **8** ✓ 已配（pinctrl `panel_vout_default`） |
| `qcom,vddd-gpio` | `0x18000000` | **24** ❌ **从未配置** |

`gpio24` 是面板 VDDD 电源使能。目前 DTS 里没有任何地方引用它。

修法：在 `&tlmm` 里加一个 `output-high` 的 pinctrl（参照 `panel_vout_default`），
挂到 `panel@0` 的 `pinctrl-0` 上。

---

## 4. 亮度寄存器读写不对称

`get_display_brightness_large()`（DCS 0x52）**读回 0 字节**（`r=0`），
但 `set_display_brightness_large()`（DCS 0x51）**写入是有效的**——
手动 `echo 1023 > brightness` 时背光确实亮过。

同一通道单向可用不寻常。厂商 DT 里有：

```
qcom,mdss-bl-high2bit          （布尔属性，存在）
qcom,mdss-brightness-max-level = 0x7ff
qcom,mdss-brightness-default-val = 0x168 (360)
```

`bl-high2bit` 表示亮度按高位 2 bit 单独处理，读写命令格式可能与标准
`0x51`/`0x52` 不同。**未查清。**

---

## 5. ~~`frame_done_cnt` 恒为 0~~ —— 已排除，是我读错了

`/sys/kernel/debug/dri/0/encoder-0/status` 输出：

```
intf:1  wb:-1  vsync:3621  underrun:0  frame_done_cnt:0  mode:INTF_MODE_CMD
```

一度以为 `frame_done_cnt: 0` 表示「帧完成事件一次都没到」。**错了。**

`dpu_encoder.c` 里打印这一行的是：

```c
seq_printf(s, "... underrun:%8d  frame_done_cnt:%d",
           atomic_read(&phys->underrun_cnt),
           atomic_read(&dpu_enc->frame_done_timeout_cnt));   // ← timeout_cnt
```

**它是 `frame_done_timeout_cnt`，超时计数。** 这个值为 0 是健康状态：
没有任何一帧等帧完成等到超时。

这一段的三项其实都是好指标：

| 字段 | 值 | 含义 |
|---|---|---|
| `vsync` | 3621 | TE 中断持续到达 |
| `underrun` | 0 | DMA 没断流 |
| `frame_done_cnt` | 0 | **没有帧超时** |

之前 dmesg 里出现过的 `[dpu error]enc35 frame done timeout` 是早期版本
（PPS 发送失败导致 enable 回滚那阵）的残留，现在不再出现。

**这一条作废，不要在这上面继续花时间。**

---

## 6. 面板健康值应为 `0x9f`，实测 `0x0c`

### 厂商怎么判面板是否正常

本机 DT 里面板节点带有：

```
qcom,mdss-dsi-panel-status-check-mode = "reg_read"
qcom,mdss-dsi-panel-status-command    = 06 01 00 01 05 00 02 0a 00
qcom,mdss-dsi-panel-status-value      = 00 00 00 9f
qcom,mdss-dsi-panel-status-read-length = 1
```

`status-command` 按 Qualcomm 的 `dsi_cmd_desc` 布局解开：

| 偏移 | 值 | 含义 |
|---|---|---|
| 0 | `06` | `DTYPE_DCS_READ` |
| 1-2 | `01 00` | vc |
| 3 | `01` | ack |
| 4-5 | `05 00` | wait 5 ms |
| 6-7 | `02 00` | **dlen = 2 字节** |
| 8+ | `0a 00` | DCS 0x0A（get_power_mode） |

也就是说厂商**读 2 字节**，并把 `0x9f` 当作「面板正常」的判据。

### 我们读到什么

驱动里 `mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &pm, 1)`
—— **只读 1 字节**，得到 `0x0c`。

| 位 | 期望 `0x9f` | 实测 `0x0c` |
|---|---|---|
| bit7 | 1 | **0** |
| bit4 (sleep_out) | **1** | **0** |
| bit3 (booster) | 1 | 1 ✓ |
| bit2 (display on) | 1 | 1 ✓ |

**面板返回的状态与厂商认为的「正常」差了 bit7 和 bit4。**

### 但这里有个未解的疑点

厂商要 2 字节，我们只读 1 字节。**第一个字节到底是不是 `0x9f` 的低 8 位，
没有验证过。**

如果面板真的返回 2 字节，只读 1 字节可能拿到的是高位或某个填充值，
那样 `0x0c` 就不能直接和 `0x9f` 比较。

**下一步**：改成读 2 字节，看完整返回值。

### 另外：sleep_out 位

`0x0c` 的 bit4 是 0。按 MIPI 标准这是「仍在睡眠」。但：

- 面板同时报告 bit2 display-on = 1
- 曾把 exit_sleep 后的等待从 11 ms 加到 120 ms，`0x0c` 不变
- `vsync` 在持续计数，说明面板在正常扫帧

所以 bit4 这一位在这块屏上可能不按标准语义解释，
或者它确实还在某个中间状态。**未定论。**

---

## 7. TE 相关 DT 属性 mainline 完全不读

厂商 DT 里有：

```
qcom,mdss-dsi-te-pin-select = 1
qcom,mdss-dsi-te-dcs-command = 1
qcom,mdss-dsi-te-using-te-pin      （布尔）
qcom,mdss-dsi-te-check-enable      （布尔）
```

在 mainline 7.2 的 `drivers/gpu/drm/msm/` 下搜索 `te-check` / `wait_for_te` /
`TE_CHECK`：**零匹配**。

也就是说 mainline 的 msm 没有「等 TE 再发下一帧」的机制。
命令模式面板靠 TE 同步，缺了它 DPU 会按固定节奏推帧。

不过 `vsync: 3621` 说明 TE 中断本身是通的，所以这未必是黑屏主因。
**未验证**。

---

## 8. Iris 协处理器：**必须 lightup 才会放行数据**

### 原厂日志（Android 上 `dmesg | grep -i iris`）

```
[1.258663] IRIS_LOG I iris_query_capability(), iris chip enable: true, soft iris enable: true
[1.259013] IRIS_LOG I iris_parse_param(), lightup node: pxlw,mdss_iris_cfg_samsung_oneplus_dsc8_90fps_cmd
[1.259023] IRIS_LOG I pxlw,split-pkt-payload-size: 228
[1.259032] IRIS_LOG E pxlw,add-last-for-split-pkt: 2, pxlw,add-pt-last-for-split-pkt: 0
[1.260845] IRIS_LOG E _iris_parse_tx_mode, panel_mode = 1
[1.262393] IRIS_LOG I iris_parse_gpio(), abyp ready status gpio 1212
[7.789327] IRIS_LOG I iris_lp_preinit:78, pcfg->abypss_ctrl.abypass_mode = 1
[7.789742] IRIS_LOG I send exit abyp, one_wired:0.
[7.789760] IRIS_LOG I iris_check_abyp_ready(), ABYP status: 0.
[7.789771] IRIS_LOG I iris_lightup(2528), mode: ABYP(1) +++
[7.837876] IRIS_LOG I iris_lightup() spend time0 47804 us, time1 291 us.
[7.837888] IRIS_LOG I Enter abyp mode start
[7.838045] IRIS_LOG I iris_check_abyp_ready(), ABYP status: 1.
[7.838194] IRIS_LOG I Enter abyp done
```

### 结论

**Iris 是启用状态（`chip enable: true`），而且必须经过一整套 lightup
序列才会进入 ABYP（analog bypass）模式。旁路生效后 `gpio112` 才会拉高
（日志里 `ABYP status: 1`）。**

`iris_lightup()` 在真机上耗时 **47.8 ms**，是有实质内容的一串寄存器
写入，不是简单拉个 GPIO。

### 我们的状态

**mainline 里没有任何 Iris 初始化代码。** 上电后 Iris 处于未配置状态，
它串联在 DSI 数据路径上，不放行数据。

这可以解释：

- 面板能读到状态（读命令可能被 Iris 转发，或走的是另一条通路）
- 但图像数据不完整/不显示
- 「两段花屏」可能是 Iris 部分转发的结果

### Iris 的 GPIO（三个都没配）

来自 `sm8250-oneplus-instantnoodlep/pxlw/pxlw-iris5.dtsi`：

| 属性 | 引脚 | 方向 |
|---|---|---|
| `qcom,iris-reset-gpio` | 174 | 输出 |
| `qcom,iris-wakeup-gpio` | 173 | 输出 |
| `qcom,iris-abyp-ready-gpio` | 112 | **输入**（Iris 报告旁路就绪） |

### 关键参数

```
pxlw,iris-tx-mode = 1            → CMD 模式（和面板一致）
pxlw,low-power = [00 01 01]      → 第 3 字节是 analog bypass 使能
pxlw,split-pkt-payload-size = 228 → Iris 会把包拆成 228 字节
pxlw,add-last-for-split-pkt = 2
```

**`split-pkt-payload-size = 228` 尤其需要注意**：它意味着 Iris 在转发时
会重新分包，而 mainline 完全不知道这个约束。

### 进入 ABYP 的确切机制（从驱动源码读出）

`dsi_iris5_lp.c` 的 `iris_enter_abyp()` 附近：

```c
IRIS_LOGI("Enter abyp mode start");
/* HS enter abyp */
iris_send_ipopt_cmds(IRIS_IP_SYS, 0x8);     // 让 Iris 切到 ABYP
udelay(100);

/* 轮询 gpio 直到就绪，最多 10 次、每次隔 3 ms */
for (i = 0; i < 10; i++) {
        abyp_status_gpio = iris_check_abyp_ready();
        if (abyp_status_gpio == 1) {
                iris_send_ipopt_cmds(IRIS_IP_SYS, 0x22);  // 关电源域
                iris_send_ipopt_cmds(IRIS_IP_SYS, 0x23);  // 关 PLL
                pcfg->abypss_ctrl.abypass_mode = ANALOG_BYPASS_MODE;
                break;
        }
        udelay(3 * 1000);
}
if (abyp_status_gpio == 0) { /* 失败处理 */ }
```

**`gpio112 == 1` 就是「Iris 已放行数据」的判据。** 厂商驱动会轮询它确认。

### 但另有一条线索说明可能不需要完整 lightup

`dsi_iris5_lightup.c` 里初始化时有一句注释：

```c
} else {
        // UEFI is running bypass mode.
        pcfg->abypss_ctrl.abypass_mode = ANALOG_BYPASS_MODE;
```

**「UEFI is running bypass mode」** —— 开机时 UEFI/ABL 可能已经让 Iris 处于
旁路状态。如果是这样，内核阶段不需要重新执行 lightup，数据本来就能通过。

这两条线索**互相矛盾**：

- 日志显示 lightup 前 `ABYP status: 0`，lightup 后 `1`
- 源码注释说 UEFI 已经设好 bypass

**要区分这两种情况，只能读实际硬件状态：mainline 启动后 `gpio112` 是 0 还是 1。**

- `1` → Iris 已放行，问题不在 Iris
- `0` → Iris 拦截数据，必须实现 `IRIS_IP_SYS 0x8` 那个切换

### 下一步（未做）

读 `gpio112`。方法：
- 在 mainline 的 DTS 里把 gpio112 配成输入，用 `gpiod_get_value()` 读
- 或直接在 initramfs 里读 `/sys/kernel/debug/pinctrl/*/pinconf-pins`

**这一步只读不写，风险为零。**

---

## 排查中用过的观察手段（可复用）

```sh
mount -t debugfs none /sys/kernel/debug

# DPU 危险信号（欠载/FIFO 错误）
cat /sys/kernel/debug/dri/0/debug/danger/danger_status

# 编码器实时状态：vsync 计数、underrun、frame_done
cat /sys/kernel/debug/dri/0/encoder-0/status

# 中断计数
cat /sys/kernel/debug/dri/0/debug/core_irq

# bridge 链（确认面板挂上了哪个 bridge、实现了哪些 ops）
cat /sys/kernel/debug/dri/0/encoder-0/bridges

# GPIO 实际电平
cat /sys/kernel/debug/pinctrl/*/pinconf-groups | grep -E '^8 \(|^24 \(|^75 \('

# 动态调试（注意：全量打开会让 DRM 卡死，按文件粒度开）
echo 'file drivers/gpu/drm/msm/dsi/dsi_host.c +p' > \
     /sys/kernel/debug/dynamic_debug/control
```

两个坑：
- `dmesg -c` 清空后再读会拿不到输出，重启恢复
- `echo "file drivers/gpu/drm/msm/* +p"` 全量打开会导致 DRM 死锁，不要用

---

# 第二轮排查（2026-10-27）：新增确认与推翻

## 状态速览

| # | 问题 | 证据强度 | 状态 |
|---|---|---|---|
| A | **Iris 已放行数据** | **硬件读数确认** | ❌ **排除** |
| B | **`slice_per_pkt=2` 已修正** | **运行期日志确认** | ✅ **已修，花屏消失** |
| C | **`sleep_out` 中间被破坏** | **运行期日志确认** | ⚠️ **当前焦点** |
| D | `vddd-gpio`(24) 未配 | DT 对比 | 未修 |
| E | TE 属性未映射 | 代码搜索 | 未修 |
| F | 亮度读回失败 | 日志 | 未查清 |

---

## A. Iris 已放行 —— 排除

在 DTS 里把 `gpio112` 配成输入（`iris-abyp-ready-gpios`），面板驱动在
`enable()` 开头读一次：

```
[1.347605] panel-oneplus-ana6706 ae94000.dsi.0: iris abyp-ready gpio = 1
```

**`1` = Iris 处于模拟旁路，数据可通。**

原因：`dsi_iris5_lightup.c` 里有一句注释

```c
} else {
        // UEFI is running bypass mode.
        pcfg->abypss_ctrl.abypass_mode = ANALOG_BYPASS_MODE;
```

**ABL/UEFI 启动时已经把 Iris 置为旁路**，内核阶段不需要再执行
`iris_lightup()`。厂商日志里 `ABYP status: 0 → 1` 的那个转换，是他们
在运行时切模式（ABYP ↔ 处理模式）时才需要的。

**结论：Iris 不是障碍。这一整条线可以放下。**

---

## B. `slice_per_pkt = 2` —— 已修，且确实改变了现象

### 改动

新增 `patches/0030-drm-msm-dsi-honour-slice-per-pkt.patch`：

1. `struct msm_dsi_host` 加 `u32 dsc_slice_per_pkt`（默认 1）
2. `dsi_host_parse_dt()` 从面板节点读 `qcom,mdss-dsc-slice-per-pkt`
3. `dsi_update_dsc_timing()`：
   ```c
   if (slice_per_pkt > slice_per_intf) slice_per_pkt = 1;
   bytes_per_pkt = slice_chunk_size * slice_per_pkt;
   pkt_per_line  = slice_per_intf / slice_per_pkt;
   ```
4. WC 计算：`wc = slice_chunk_size * slice_per_pkt + 1;`

面板 DTS 里加 `qcom,mdss-dsc-slice-per-pkt = <2>;`。

### 运行期确认生效

```
[1.288153] msm_dpu ae01000.display-controller:
           dsc: slice_per_pkt=2 slice_per_intf=2 chunk=540 pkt_per_line=1
```

**`slice_per_pkt=2`、`pkt_per_line=1`，与厂商
`mdss_panel_dsc_pclk_param_calc()` 算出来的完全一致。**

### 现象变化（重要）

**修正前**：两段花屏，一闪而过 → 黑
**修正后**：**花屏消失，直接全黑**

这是实质进展：两段花屏是 DSC 打包错位造成的，**这个问题已经解决**。
剩下的「全黑」是另一个独立问题。

---

## C. 当前焦点：`sleep_out` 在序列中途被破坏

### 日志

```
[1.347622] init sequence start
[1.469688] sleep-out check: r=1 power_mode=0x98 sleep_out=1     ← 正确
[1.630523] readback:  power_mode=1/0x0c sleep_out=0             ← 退回去了
```

中间隔 161 ms，序列共 57 条 `write_seq` 命令 + 若干延迟。

### 解读

| 时刻 | power_mode | bit4 (sleep_out) | bit2 (display on) |
|---|---|---|---|
| exit_sleep 后 | `0x98` | **1** ✅ | 1 |
| 序列结束后 | `0x0c` | **0** ❌ | 1 |

**面板在序列执行过程中被重新送回了睡眠。**

我们的序列里**没有** `0x10`（enter_sleep_mode）——这一点用 grep 确认过，
只有 `exit_sleep_mode`（第 192 行）和 `set_display_on`（第 276 行）。

所以只有两种可能：

1. **某条私有命令（`0xf0`/`0xb0` page lock 之后的写）间接触发了睡眠**
2. **`set_display_on` 之后，序列外部有代码调用了 `disable()`**

### 第 2 种更容易验证

`ana6706_disable()` 里有：

```c
mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);   // 0x28
mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);  // 0x10
```

如果 DRM 在 `enable()` 之后立刻调用 `disable()`，就会产生完全一样的日志。

**验证方法**：在 `disable()` 和 `unprepare()` 里各加一行 `dev_info`，
看它们是否被调用。改动极小。

### 第 1 种的验证

在序列的第 15/30/45 条命令之后各插一次 `power_mode` 读回，二分定位。

---

## D. `vddd-gpio`（gpio24）仍未配置

本机 DT 的 DSI ctrl 节点（`qcom,mdss_dsi_ctrl0@ae94000`）：

```
qcom,platform-reset-gpio   → 75  ✓ 已配
qcom,platform-te-gpio      → 66  ✓ 已配
qcom,vddr-gpio             → 8   ✓ 已配（panel_vout）
qcom,vddd-gpio             → 24  ❌ 从未配
```

另外确认了 DSI ctrl 节点上**没有**：
- `qcom,platform-bklight-en-gpio`
- `qcom,platform-avdd-en-gpio`

所以背光没有独立使能脚，完全靠 DCS `0x51`。这一条排除。

---

## E. TE 相关 DT 属性 mainline 完全不读

厂商 DT 有 `te-pin-select` / `te-dcs-command` / `te-using-te-pin` /
`te-check-enable`，mainline `drivers/gpu/drm/msm/` 下搜索 `te-check`、
`wait_for_te`、`TE_CHECK` 全部零匹配。

不过 `encoder-0/status` 显示 `vsync: 3350`，TE 中断是通的，
所以这未必是黑屏的直接原因。**仍未修。**

---

## F. 亮度读回始终失败

```
brightness=0/1023      ← r=0，读回 0 字节
```

写入有效（手动设 1023 背光会亮过），读取始终返回 0 字节。
`qcom,mdss-bl-high2bit` 是布尔属性（存在），可能影响读写格式。**未查清。**

---

## 排查手段备忘（新增）

```sh
# 在 DTS 里把 gpio112 配成输入，驱动里 gpiod_get_value_cansleep() 读
# 面板节点加：iris-abyp-ready-gpios = <&tlmm 112 GPIO_ACTIVE_HIGH>;

# 确认 DSI ctrl 节点上到底有哪些 GPIO 属性
ls /sys/firmware/devicetree/base/soc/qcom,mdss_dsi_ctrl0@ae94000/
```

---

## 下一步优先级

1. **在 `disable()` / `unprepare()` 加日志**，确认 DRM 是否在 enable 后立刻关了面板
   （改动最小，最可能命中）
2. 若 1 否定，则在序列中插多处读回，二分定位是哪条命令送回睡眠
3. 之后再处理 `vddd-gpio`、TE、亮度读回

---

## 已确认修复的清单（累计）

| 修复 | 文件 | 效果 |
|---|---|---|
| `&dispcc` 启用 | DTS | MDSS 不再超时 |
| 去掉 `MIPI_DSI_MODE_VIDEO_BURST` | 0029 | init sequence 开始执行 |
| 去掉不存在的 `avdd` 供电器 | 0029 | 日志干净 |
| `reset` 极性（GPIO_ACTIVE_LOW） | 0029 | DCS 不再 -110 超时 |
| `reset` 三步时序 | 0029 | 复位正确释放 |
| sleep-out 延迟 11→120 ms | 0029 | `sleep_out` 短暂置位 |
| PPS + compression mode | 0029 | 发送无错 |
| DSC 参数按真实 PPS 修正 | 0029 | 参数正确 |
| `panel_vout`(gpio8) pinctrl | DTS | 面板电源使能 |
| `slice_per_pkt = 2` | **0030** | **两段花屏消失** |
| iris abyp-ready 读取 | 0029 + DTS | 确认 Iris 已放行 |

---

# 第三轮（2026-10-27 深夜）：两个突破与一个仍未解的问题

## 突破一：压缩模式的包类型用错了

### 问题

厂商初始化序列的第 19 包：

```
#19  dtype=0x07  data=01
```

`0x07` 是 `DTYPE_COMPRESSION_MODE`（见厂商 `mdss_dsi_cmd.h`）。它出现在
page-lock 之后、PPS 写入（第 21 包）之前，作用是**让面板进入 DSC 压缩模式**。

我们写的是：

```c
mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0x01);
```

`mipi_dsi_generic_write_seq_multi()` 生成的是 **Generic Long Write
（dtype 0x29）**，不是压缩模式包（dtype 0x07）。两者的区别在于：

| | dtype | 面板行为 |
|---|---|---|
| 我们发的 | `0x29` Generic Long Write | **忽略** |
| 厂商发的 | `0x07` Compression Mode | **进入压缩模式** |

**也就是说：序列从第 19 包之后一直在假设面板已经进入压缩模式，而实际上
它从未进入。**

### 修复

```c
mipi_dsi_compression_mode_multi(&dsi_ctx, true);
```

### 修复后的日志变化

```
修复前: readback: power_mode=1/0x0c  sleep_out=0
修复后: readback: power_mode=1/0x9c  sleep_out=1
```

**`0x9c` = `1001 1100`：bit4 sleep_out、bit3 booster、bit2 display on
全部置位。这是整轮调试中第一次让面板达到「完全醒着」的状态。**

注意 `diag` 字节从 `0x00` 变成 `0x40`，说明面板确实换了状态。

---

## 突破二：三个公开移植包都不驱动这块面板

拿到并分析了三个声称「已验证显示」的第三方镜像：

| 镜像 | 来源 | 内核里的 `ana6706` | DTB 里的面板节点 | 实际显示方式 |
|---|---|---|---|---|
| pmOS（`sm8250-mainline`） | GitLab | 0 处 | 无 | 无 |
| OnePlus8Pro-Ubuntu24.04-v16 | Downloads | 0 处 | 无 | **simpledrm** |
| 一加8pro飞牛移植 v1 | Downloads | 0 处 | 无 | **simpledrm + `console=tty0`** |

### Ubuntu 包的解包过程（可复用）

```sh
simg2img userdata-ubuntu-op8p.img /tmp/ubx.raw        # sparse -> raw
# UFS userdata 里第一个 ext4 在 offset 8388608，卷标 pmOS_boot
dd if=/tmp/ubx.raw of=/tmp/boot.ext4 bs=1m skip=8 count=600
debugfs -R "ls -l /" /tmp/boot.ext4
debugfs -R "dump /sm8250-oneplus-instantnoodlep.dtb /tmp/work.dtb" /tmp/boot.ext4
dtc -I dtb -O dts /tmp/work.dtb > /tmp/work.dts
```

它 boot 分区里的 DTB 反编译出 7260 行，其中：

```dts
clock-controller@af00000 (dispcc)  → status = "disabled"
display-subsystem@ae00000 (mdss)   → status = "okay"
dsi@ae94000                        → status = "disabled"
phy@ae94400                        → status = "disabled"
panel@0                            → 不存在
```

**dispcc 和 DSI 全关，只有 MDSS 开着 —— 这正是 simpledrm 的配置。**

它们 README 里那句「内核含有针对特定 DSI 面板配置的修改；不同面板
版本可能无法点亮」的真实含义是：**他们没能点亮 DSI，退回了 simpledrm。**

### 飞牛包的启动方式

```sh
cmdline: clk_ignore_unused pd_ignore_unused console=tty0 root=/dev/sda24 rw
```

header v0，`root=/dev/sda24` 直接把 UFS 某分区当根。同样没有 DTB、没有面板驱动。

### 这个结论的意义

**目前没有现成实现可抄。** 这条路径上我们走得比所有公开方案都远：

| 项目 | 这三个包 | 我们 |
|---|---|---|
| 面板驱动 | 无 | 953 行完整驱动 |
| DCS 序列 | 无 | 668 字节逐字转录 |
| DSC 配置 | 无 | 按真实 PPS 修正 |
| `slice_per_pkt` | 无 | 已修 |
| **压缩模式包类型** | 无 | **已修** |
| **面板状态** | 未知 | **`0x9c` 完全唤醒** |

---

## 仍未解：面板醒着、状态正确，但屏幕不亮

修复压缩模式后：

```
iris abyp-ready gpio = 1                                    Iris 放行
sleep-out check: power_mode=0x98  sleep_out=1               面板醒了
bisect after#15: power_mode=0x98  sleep_out=1               仍然正常
bisect after#30: power_mode=0xff  sleep_out=1               读不到有效值
bisect after#45: power_mode=0xff  sleep_out=1               读不到有效值
readback: power_mode=0x9c diag=0x40                         结束状态正确
enable() done
```

`fb0/blank` 手动置 0、背光 1023、`dpms=On`、`encoder-0/status` 显示
`vsync` 持续增长、`underrun=0`。

**屏幕仍然没有任何输出。**

### 对中间那段 `0xff` 的解释

第 19 包进入压缩模式后，DCS 读命令返回 `0xff`（总线拉高/无效）。
这本身是**符合预期的**——压缩模式下 `get_power_mode` 可能不再有效。
所以 `after#30`/`after#45` 的 `0xff` 不应视为故障，而是压缩模式生效的旁证。

**真正奇怪的是序列末尾 `0x9c` 又恢复可读且状态正确，但屏幕不亮。**

### 剩余可能

| # | 可能 | 判断依据 |
|---|---|---|
| 1 | **帧数据没有被面板接收** | `vsync` 在跑但没画面，可能是 DPU 送出的是空帧或黑帧 |
| 2 | **背光 DCS 未被接受** | `brightness` 读回 `r=0`（`0x52` 读不通），`bl-high2bit` 模式未实现 |
| 3 | **TE 未同步导致帧被丢弃** | mainline 无 TE 等待机制 |
| 4 | **`vddd-gpio`(24) 未配** | 面板模拟电源可能未开 |
| 5 | **帧缓冲内容为黑** | initramfs 里没有人绘制内容 |

### 优先建议

**先验证「帧缓冲里到底有没有内容」**——这是最便宜的一步：

```sh
# 在 initramfs 里往 /dev/fb0 写一个已知图案，再看屏幕
# 或者用 drmtest 提交纯白帧
```

如果提交纯白帧后屏幕仍然全黑，说明问题在面板侧；
如果屏幕变了，说明问题只是「没人往帧缓冲画东西」。

---

## 累计修复清单（14 项）

| # | 修复 | 效果 |
|---|---|---|
| 1 | `&dispcc` 启用 | MDSS 不再超时 |
| 2 | 去掉 `MIPI_DSI_MODE_VIDEO_BURST` | init sequence 开始执行 |
| 3 | 去掉不存在的 `avdd` 供电器 | 日志干净 |
| 4 | `reset` 极性（ACTIVE_LOW） | DCS 不再 -110 |
| 5 | `reset` 三步时序 | 复位正确释放 |
| 6 | sleep-out 延迟 11→120ms | `sleep_out` 短暂置位 |
| 7 | PPS 发送 | 无错 |
| 8 | DSC 参数按真实 PPS | 参数正确 |
| 9 | `panel_vout`(gpio8) pinctrl | 面板电源使能 |
| 10 | `slice_per_pkt=2`（patch 0030） | **两段花屏消失** |
| 11 | iris abyp-ready 读取 | 确认 Iris 放行 |
| 12 | `disable()`/`unprepare()` 日志 | 确认 DRM 未关面板 |
| 13 | 二分探针 | 定位状态变化区间 |
| 14 | **压缩模式包类型 0x29→0x07** | **`power_mode` 达到 `0x9c`** |

---

# 第四轮（2026-10-27）：切到视频模式（已编译，未上机验证）

## 为什么

前面所有可疑点逐条排除后，剩下一个结构性差异：

```
这棵内核里唯一能点亮的 DSC 面板（alioth / ams667xx01，patches/0017）:
    .mode_flags = MIPI_DSI_MODE_VIDEO_BURST | ...     ← 视频模式

ANA6706（本面板）:
    .mode_flags = MIPI_DSI_MODE_LPM | ...             ← 命令模式
```

厂商 DT 也指向同一方向：

```
qcom,mdss-dsi-mdp-trigger = "none";
qcom,mdss-dsi-dma-trigger = "trigger_sw";
```

**`mdp-trigger = "none"` 表示厂商不走 MDP/DPU 那条通路，而是用 DSI 自己的
命令 DMA。** 而 mainline 的 `dsi_timing_setup()` 在命令模式下无条件编程
`REG_DSI_CMD_MDP_STREAM0_*` —— 正是厂商关掉的那条。

所以命令模式在这里的语义是：面板自报 display-on、DSI 无错误、帧被消费，
但什么都不显示。

## 关于「之前试过视频模式，初始化序列不跑」

那个观测是在 **reset 极性 bug 还没修**的时候做的（GPIO_ACTIVE_LOW 让
`gpiod_set_value(1)` 实际把复位线拉低，面板一直按在复位状态）。
**在那个前提下，任何模式都不会跑初始化序列，所以它没有证明视频模式不行。**

现在 reset 极性、压缩模式包类型、`slice_per_pkt` 都修好了，值得重测。

## 改动

```c
dsi->mode_flags = MIPI_DSI_MODE_VIDEO_BURST |
                  MIPI_DSI_MODE_LPM |
                  MIPI_DSI_MODE_NO_EOT_PACKET;
```

## 编译结果

```
补丁 0029     964 行（行数校验通过）
编译          0 error
Image         36,473,344 B
boot image    15,413,248 B
DTB           128,761 B
断言          全部通过
```

内核里已确认包含：`VIDEO_BURST`、`compression_mode_multi`、
`dsc_slice_per_pkt`（13 处）、DTS 的 `mdss-dsc-slice-per-pkt`。

**未上机验证**（设备已关机）。

## 下次验证时看什么

1. **`dmesg | grep ana6706`** —— 视频模式下 `readback` 是否还读得到
2. **屏幕** —— 有没有任何输出（花屏也算进展）
3. **`cat /sys/kernel/debug/dri/0/crtc-0/status`** —— `vblank fps` 是否到 120

如果视频模式下变成花屏/条纹，说明通路通了、只是时序或 DSC 参数还差一点，
那比现在的全黑更接近目标。
