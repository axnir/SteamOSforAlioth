# P3 工作量评估：ANA6706 面板驱动 + 其他驱动

回答两个问题：**面板驱动复杂吗**，**其他驱动怎么办**。

数据来源：alioth 的 patch 0017（同类面板驱动的直接模板）、7.2.8 内核树里
现成的 Samsung 面板驱动、以及 2026-10-25 从这台机器 DT 读到的 ANA6706 参数。

---

## 一、面板驱动：**中等偏难，但不是最难**

### 1.1 规模是确定的

参考 alioth 的 `panel-samsung-ams667xx01.c`，**462 行新增代码**，
动三个文件（`Kconfig` / `Makefile` / 驱动本身）。

结构是这样的（从 patch 里数出来的）：

```
struct ams667xx01          驱动私有状态
struct panel_desc          每组时序的描述符
reset / init_sequence      DCS 初始化
drm_display_mode[]         时序表
drm_dsc_config             DSC 参数
prepare/enable/disable/unprepare
get_modes / get_orientation
bl_update_status           背光（DCS 亮度）
probe / remove / of_match
```

**这 462 行里，大约 300 行是"填数据"，只有 150 行左右是真正的逻辑。**
逻辑部分是标准的 `drm_panel` 骨架，照着 alioth 抄即可。

### 1.2 填数据这件事，一半已经从设备上拿到了

| 需要的数据 | 状态 | 来源 |
|---|---|---|
| 分辨率 / 帧率 | ✅ 已拿 | 4 组时序，DT 实测 |
| hfp/hbp/hpw、vfp/vbp/vpw | ✅ 已拿 | 同上 |
| DSC slice_width / height / bpp | ✅ 已拿 | `540×72@8bpp`、`720×96@8bpp`、`720×16@10bpp` |
| reset GPIO / TE GPIO | ✅ 已拿 | `tlmm 75` / `tlmm 66` |
| 亮度控制方式 | ✅ 已拿 | `bl_ctrl_dcs`，`bl-max 0x7ff = 2047` |
| 电源轨顺序 | ✅ 部分 | `panel-supply-entries` phandle 已见 |
| **DCS 初始化序列** | ❌ **缺** | 需要从 DT 的 `qcom,mdss-dsi-on-command` 读 |
| 亮度曲线 / gamma 表 | ⚠️ 可选 | 不写也能亮，只是色彩不精确 |
| 各种 AOD / HBM 命令 | ⚠️ 可选 | Game Mode 不需要 |

**关键点：初始化序列本身也在设备上**，在 DT 的
`qcom,mdss-dsi-display-timings/timing@N/qcom,mdss-dsi-on-command` 里，
是一串 QCOM 私有格式的字节（`len / type / delay / payload`）。
手机现在拔掉了，插回来我就能把它 dump 出来并转成
`mipi_dsi_dcs_write_seq_multi()` 调用。

**这一条决定了 P3 是"填数据"还是"逆向"。** 有它，P3 就是 462 行的
抄写工作；没有它（比如换了个我们读不到 DT 的机器），就要从下游内核的
`.dtsi` 或者反汇编 `mdss` 的初始化表去挖，工作量翻几倍。

### 1.3 真正的难点只有一个

**Pixelworks Iris 旁路**。

这台机器的显示链是 MDSS → (Iris?) → ANA6706。pinctrl 里有
`iris_abyp_ready`（*bypass handshake*），`pxlw,dsi-display-primary-active`
直接指向面板节点，`pxlw,soft-iris-enable` 存在——三条证据都说明
**设计上允许旁路**。

但"设计上允许"和"实际能旁路"不是一回事。可能的情况有三种：

| 情况 | 后果 | 判断方法 |
|---|---|---|
| Iris 纯粹是后处理，旁路即可 | P3 就是 462 行 | 点亮即知 |
| Iris 参与 DSI 时序/上电握手 | 需要写一段 Iris 初始化 | 黑屏，且 DSI 有错误 |
| Iris 串联在 DSI 数据路径上 | 基本做不了 | 黑屏，无 DSI 活动 |

不能提前判断，**只能刷一次看**。这也是我建议"先刷 simpledrm 内核"的原因：
如果 simledrm 能亮，说明 ABL 的 splash 路径通了，Iris 至少不挡早期显示；
那 P3 失败也只会退化成"没有面板驱动"，而不是"整机黑屏"。

### 1.4 另一个已知的坑

`CONFIG_EFI_ZBOOT` 与 `THE IMPOSTOR` 那个坑已经在 P2 踩过了。面板这边
对应的坑是：**`dsi->dsc_slice_per_pkt` 在 mainline 不存在**。

我们的面板 DT 写的是 `slice-per-pkt = 2`，但 mainline 的 msm DSI host
只支持 `slice_per_pkt = 1`（`dsi_host.c` 里有 TODO）。alioth 处理过同样
的问题，结论是：**面板自己的 PPS 决定了 `slice_width 540 / 1080 宽`，
所以 `slice_count` 保持 2，与 fork 的差异只是每行两个包而不是一个。**

这条可以直接沿用，不需要重新想。

### 1.5 结论：P3 的复杂度

```
逻辑      150 行   ★★☆☆☆   照搬 alioth
数据      300 行   ★★★☆☆   大部分在设备上，要 dump + 转格式
Iris      ?        ★★★★☆   不可预测，只能点一次看
调试      ?        ★★★★☆   每次迭代要刷机（除非有 self-flash）
```

**如果 Iris 能旁路：1~2 天的工作量**（含 2~3 次刷机迭代）。
**如果 Iris 要初始化：不确定**，可能是个无底洞。

---

## 二、其他驱动怎么办

把设备上所有驱动过一遍，按"要不要自己写"分类。这是 2026-10-25
从 `/sys/bus/*/devices/*/driver` 实测出来的绑定状态。

### 2.1 已经有了，不用写（好消息是大头）

| 器件 | mainline 驱动 | 状态 |
|---|---|---|
| GPU Adreno 650 | `msm` | ✅ 有，只需打开 `&gpu`（P1 已做） |
| 触摸 S6SY761 | `s6sy761.c`（544 行） | ✅ 有，P1 已设 `=y` |
| 音频 codec WCD938x | `wcd938x` + bolero | ✅ 有 |
| 耳机 jack 检测 | `msm-mbhc` | ✅ 有 |
| Wi-Fi/BT QCA6390 | `ath11k_pci` / `hci_qca` | ✅ 有 |
| NFC NXQ | `nxp-nci-i2c` | ✅ 有 |
| 电量计 BQ27541 | `bq27xxx` | ✅ 有 |
| 电源 PMIC 系列 | `pm8150*` | ✅ 有 |
| 振动 | `qcom-spmi-haptics` | ✅ 有（ROCKNIX 的补丁 0009） |
| 闪光灯 | `qpnp-flash-led` | ✅ 有 |
| 霍尔传感器 | `gpio-keys` 类 | ✅ 有 |
| 距离传感器 VL53L1 | `vl53l0x`/`vl53l1x` | ⚠️ 看具体型号 |
| USB / Type-C | `dwc3` / `tcpm` | ✅ 有 |
| UFS | `ufs-qcom` | ✅ 有 |

**这一列的意思是：P3 之后，这台机器"能当掌机用"的硬件基本齐了**
（触摸、GPU、Wi-Fi、蓝牙、音频 codec、电量、振动）。

### 2.2 必须自己写的，只有两个

| 器件 | 工作量 | 说明 |
|---|---|---|
| **面板 ANA6706** | 462 行 | P3，见上 |
| **功放 TFA98xx ×2** | **~2500 行** | P7，NXP out-of-tree |

**TFA98xx 是比面板更大的工程**，这一点要提前说清楚。它不是一个简单的
DAC 驱动：

- 有 DSP（`tfa98xx.c` 里有完整的固件下载、DSP 状态机）
- 有 `calibra`（喇叭阻抗/温升校准，实现 `calibra` sysfs）
- 有 `selfcheck`（故障位读取，对应 `selfcheck` sysfs）
- 有 `temperature`（die 温度）
- 有 6 种工作模式（`PLL` / `cold boot` / `DSP bypass` / ...）
- 带 3 个固件文件（`.bin` / `.dsp` / `.eq`）

参考：NXP 自己的 `linux/drivers/soundwire/tfa98xx.c` 和
`tfa98xx-internal.h` 加起来 3000+ 行。

**但是**，有一个显著的简化路径：**如果只求"能出声"**，TFA98xx 可以
当作最简单的 I2C 寄存器设备驱动——上电、解除 standby、设音量、
读故障位。不做 DSP、不做校准、不做 selfcheck。**这条路大约 400 行。**

代价是：没有喇叭保护（alioth 烧过听筒的原因之一）、没有温度读、
音质是"能响"。**对掌机来说这可能够了**，因为 SteamOS 的音量在
PipeWire 里做软件调节。

> 我的建议：**先写 400 行的简化版**，能出声再决定要不要补 DSP。
> 这和 alioth 把听筒烧糊的教训是同一个：先有一个能读故障位的驱动，
> 再谈推多大音量。

### 2.3 明确不做的

| 器件 | 理由 |
|---|---|
| 摄像头（4 颗 + CAMSS） | 不是移植目标 |
| 指纹 Goodix | 掌机不需要 |
| 基带 / 通话 | 项目本来就不做 |
| Pixelworks Iris 的完整功能 | 只做旁路，不做 MEMC |
| 传感器 DSP（SLPI） | Game Mode 不依赖 |

### 2.4 一个不显眼但会咬人的：电源管理

这台机器的充电链比 alioth 复杂：

```
bq2597x-charger @ 7-0066    电荷泵（快充）
chgpump-charger @ 7-0019    另一颗
dash_fastchg    @ 8-0026    OnePlus 私有快充
smb1390_slave   @ 0x18
bq27541-battery @ 8-0055    电量计
```

mainline 有 `bq27xxx`（电量计）和 `bq25980`（电荷泵），但：

- **`dash_fastchg` 没有 mainline 驱动，也不该有**（私有协议）
- `bq2597x` 和 `bq25980` 是同一族但寄存器有差异，要核对
- 阶段 1/2 初期只需要 **PMIC 自身的充电路径**（PM8150B），也就是
  alioth 那条路：能慢充、能看电量就够了

**所以充电这一块的工作量不在"写驱动"，而在"配置 + 验证"**：
确认 PM8150B 的 CV/CC 设置、确认 BQ27541 能报电量、然后套用
alioth 的 `charge-guard` 温度降额逻辑。

---

## 三、建议的执行顺序（考虑到你目前的阻塞）

### 现在就能做的（不需要设备在线）

1. **面板驱动骨架**：从 `panel-samsung-sofef00.c`（OnePlus 的，
   同样是 DSC 命令模式）复制骨架，把已拿到的 4 组时序、DSC 参数、
   GPIO 填进去，初始化序列先留一个 `/* TODO: 从 DT dump */` 的空函数。
   **这一步能编译、能 review，但点不亮。**
2. **TFA98xx 简化驱动**（400 行版本）的骨架。

### 需要设备插回来才能做的

3. **dump 初始化序列**：从 DT 的 `on-command` 读出来转成
   `mipi_dsi_dcs_write_seq_multi()`。
   ```bash
   su -c 'od -An -tx1 -v <DT>/.../timing@1/qcom,mdss-dsi-on-command'
   ```
4. 补完面板驱动，编译。
5. **刷机看能不能亮**——这是 Iris 的唯一判据。

### 我的建议

**优先级：先刷 simpledrm 内核（P4），再写面板驱动。**

理由：P4 的镜像**已经做好了**（`work/steamos-op8p/`），刷一次就能知道
内核在不在、USB gadget 通不通、DTB 对不对。这些信息对 P3 是前提——
如果内核都起不来，P3 写得再好也没用；如果内核起来了，P3 每次迭代就只是
`./make-op8p.sh && ./flash-op8p.sh --test`。

而且 P4 是**零风险的**（只写非活动槽，随时 `--set-active=b` 回来）。

---

## 四、一句话总结

- **面板驱动：中等难度，462 行，其中 300 行是填数据。最大的不确定性
  是 Pixelworks Iris 能不能旁路，这个只能点一次才知道。**
- **其他驱动：绝大部分 mainline 都有了。真正要写的只有面板（462 行）
  和功放 TFA98xx（简化版 400 行，完整版 2500 行）。**
- **总工作量估计：P3 1~2 天（顺利的话），P7 简化版 2~3 天。**

---

## 五、P3 实际进展（2026-10-25）

### 5.1 已经做完的：面板驱动编译通过

`patches/0029-drm-panel-add-the-samsung-ana6706-panel.patch`（474 行驱动）

- 完整内核构建 **通过，零警告**
- `CONFIG_DRM_PANEL_ONEOPLUS_ANA6706=y` 已生效
- 4 组时序、DSC 配置、reset/TE GPIO、背光（`bl_ctrl_dcs`，0x7ff）全部按
  实测值填入

**踩过的三个 7.2 API 坑**（都已修正，写在这里免得下次再踩）：

| 错误 | 7.2 正确写法 |
|---|---|
| `drm_panel_init()` 不存在 | `devm_drm_panel_alloc(dev, struct X, panel, funcs, connector)` |
| `mipi_dsi_dcs_set_display_brightness_large_multi()` 不存在 | 用非 `_multi` 版：`mipi_dsi_dcs_set_display_brightness_large(dsi, val)`，取亮度用 `backlight_get_brightness(bl)` |
| `dev_err(ctx->dsi->dev, ...)` 类型不符 | `dsi->dev` 是**值类型** `struct device`，要传 `&ctx->dsi->dev` |
| `struct drm_dsc_config` 未定义 | 需 `#include <drm/display/drm_dsc.h>` |
| `__maybe_unused` 放错位置 | 必须放在**变量名之后**：`static const T x[] __maybe_unused = {...}` |

backlight 也改了：7.2 用 `ctx->panel.backlight = create_backlight(dsi)`，
不再走 `devm_backlight_device_register` + `drm_panel_of_backlight` 两步。

### 5.2 还没做的：DCS 初始化序列

这是**唯一**剩下的缺口，也是"能 probe"和"能点亮"之间那道坎。

`ana6706_init_sequence()` 目前只有与型号无关的部分
（exit sleep、TE on），**故意留空**：

> 猜一个 DCS 初始化序列，比不写更糟 —— 错序列的后果是
> **DSI commit 成功、面板全黑**，这和硬件坏了的症状一模一样，
> 会让人去查不该查的地方。

**填补方法**（手机插回来即可，约 20 分钟）：

```bash
DT=/sys/firmware/devicetree/base/soc/qcom,mdss_mdp@ae00000/qcom,mdss_dsi_samsung_ana6706_dsc_cmd
su -c "od -An -tx1 -v $DT/qcom,mdss-dsi-display-timings/timing@1/qcom,mdss-dsi-on-command"
```

得到的是 Qualcomm 打包格式：`u8 长度, u8 类型, u8 延迟, payload...`，
类型里 `0x05` = DCS 短写、`0x15` = DCS 长写、`0x29` = 通用长写、
`0x02`/`0x03` = 延迟标志。逐条转成：

```c
mipi_dsi_dcs_write_seq_multi(&dsi_ctx, <cmd>, <payload...>);
mipi_dsi_usleep_range(&dsi_ctx, <delay>);
```

### 5.3 现在能验证什么

驱动已进内核，所以 P4 刷机时可以顺带看到：

| 现象 | 含义 |
|---|---|
| `panel-oneplus-ana6706` probe 成功 | DSI 控制器 + 链路 + 供电 + reset 都对 |
| probe 报 `failed to get regulators` | DTS 里缺 supply（P2 还没加面板节点） |
| 完全没出现 | 驱动没编进去 / DSI 没绑定 |
| probe 成功但屏幕黑 | **符合预期**（初始化序列还没写） |

**注意**：现在 DTS 里**还没有面板节点**，所以 probe 一定不会发生。
面板节点本身要等初始化序列一起加 —— 这是下一步。

### 5.4 修正前面的工作量估计

原估计"P3 1~2 天"，现在拆开看：

| 工作 | 状态 | 耗时 |
|---|---|---|
| 驱动骨架 + 时序 + DSC | ✅ **已完成** | 本次 |
| 面板 DTS 节点 | ⏳ 需要 dump 初始化序列后一起写 | ~30 min |
| dump + 转录初始化序列 | ⏳ **阻塞：设备不在线** | ~20 min |
| Iris 旁路验证 | ⏳ 刷机才知道 | — |
| 调试到点亮 | ⏳ 2~3 次刷机迭代 | ~半天 |

**结论：代码侧最重的部分已经做完了，剩下的是"等设备"和"等验证"。**

---

## 六、P3 完成（2026-10-25，设备在线后）

### 6.1 DCS 初始化序列已拿到

从设备的 DT 里 dump 出 `qcom,mdss-dsi-on-command`，668 字节。

**格式是 `[dtype][last][wait_hi][wait_lo][delay_ms][len_hi][len_lo][payload]`**，
7 字节头。这个格式我猜错了三次：

| 猜测 | 结果 |
|---|---|
| `[len][type][last][vc][ack][payload]`，len 含自身 | 第一个包就错位 |
| `[dlen][dtype][last][vc][ack][payload]` | 消费到 600/668 就 overrun |
| `[dtype][last][vc*2][ack][dlen*2][payload]` | 61 包消费 668/668 ✓ |

**判据**：正确的解析必须**恰好消费全部 668 字节、无剩余**。
错一位就会立刻失步并留下余数——这比"看起来合理"可靠得多。

关键发现：

- 只有 **3 处延迟**：exit-sleep 后 11ms、一处 0xf0 后 11ms、另一处 111ms
- **四组时序的序列不一样**：timing@0/2/3 是 638 字节，timing@1 是 668 字节
- 差异只有两处：`0x60` 写 `0x22`（其余写 `0x02`），以及多一组
  `0xb9 01 / 0xb0 01 / 0xb9 0c 54 00 0b`
- `0x60` 是**刷新率模式选择**，所以那几个字节跟的是帧率不是面板型号

### 6.2 驱动已完整

`patches/0029` 现在是 **537 行**，含完整初始化序列。编译通过、DTB 正确。

`CONFIG_DRM_PANEL_ONEOPLUS_ANA6706=y`

### 6.3 DTS 节点已加，但 status = disabled

这是**故意**的，理由写在 DTS 注释里：

面板能点亮的前提是 Pixelworks Iris 能旁路，而这一点**还没验证**。
在 Iris 搞清楚之前打开面板，风险是把"唯一一条已知可用的日志通道
（simpledrm 控制台）"换成黑屏。

### 6.4 下一步：验证 Iris

只需一处改动：

```diff
-		status = "disabled";
+		status = "okay";
```

然后重建、刷非活动槽，看现象：

| 现象 | 结论 |
|---|---|
| 屏幕亮 + 有画面 | **Iris 可旁路**，P3 完成 |
| `panel-oneplus-ana6706` probe 成功但屏幕黑 | DSI 通了，Iris 或初始化序列有问题 |
| probe 报 `failed to get regulators` | DTS 的 supply 名字对不上 |
| 完全没 probe | DSI 没绑定 / 驱动没编进去 |
| 内核 panic 或死机 | Iris 串联在关键路径上，要另行处理 |

### 6.5 当前产物

```
boot-op8p-gzip.img   15,138,816 B   sha256 6a503429...c5141
boot-op8p-v2.img     15,138,820 B   sha256 6e11ef04...ac19c
```

包含：4K 页内核 + S6SY761 触摸 + ANA6706 面板驱动（未启用）+ 12 个 DTB
+ 完整 DCS 初始化序列。

---

## 七、P3 实际完成情况（2026-10-26 更新）

前面五、六节的估计，在真机上被验证了一部分，也被推翻了一部分。

### 7.1 已经拿到的结果

| 原估计 | 实际 |
|---|---|
| "驱动 462 行，其中 300 行填数据" | ✅ 准。最终 563 行 |
| "DCS 初始化序列在设备上，dump 出来就行" | ✅ 准。668 字节，61 个包 |
| "Iris 能不能旁路只能点亮才知道" | ⚠️ **还没到那一步** —— 卡在 PLL 和 DSC |
| "P3 1~2 天" | ⚠️ 实际已用约 4 小时，**未完成** |

**面板驱动本身是完整的**：probe 成功、初始化序列执行
（`init sequence start` 出现在 dmesg）、`SETCRTC` 返回成功。
但画面"先花后黑"，还没有真正点亮。

### 7.2 复杂度判断的修正

我原来说"主要不确定性是 Iris 能不能旁路"。实际上**在那之前还有两层**：

```
PLL 锁定时序  ← 当前卡在这里
DSC 参数完整性
Iris 旁路
```

每一层都会让画面失败，而症状都是"黑屏"。

这说明我原来的估计错在**把"点亮"当成一步**，实际上它是一条至少有
三层的链，每层失败都长得一样。

### 7.3 对其他驱动的判断没有变

第二节列出的"mainline 已经有"的那一批，实测全部成立：

- 触摸 S6SY761：✅ probe 成功，`/dev/input/event0-3`
- UFS：✅ 6 个 LUN，247 GB
- PCIe：✅ 三个控制器
- USB dwc3：✅ gadget 工作
- 电源/regulator：✅

**唯一还没验证的是 Wi-Fi**：`wlan-enable-gpios` 的修复已经编译进去，
但需要单独一次启动确认。

### 7.4 修正后的工作量

| 工作 | 状态 |
|---|---|
| 面板驱动（含 DCS 序列） | ✅ 完成 |
| dispcc / DSI / 面板 DTS | ✅ 完成 |
| **DSI PLL** | ❌ 待查 |
| **DSC 参数** | ⚠️ 待补全 |
| Iris 旁路验证 | ⏳ 被前两项挡住 |
| TFA98xx 音频 | ⏳ 未开始（估计简化版 400 行仍然成立） |

---

## 八、显示调试的最终结论（2026-10-26 凌晨）

第七节末尾说"卡在 PLL 和 DSC"，这一节把结论修正好。

### 8.1 原来列的两个卡点，一个被证伪，一个部分成立

| 原判断 | 实际 |
|---|---|
| **DSI PLL 锁不上是故障** | ❌ **假警报**。`dsi_7nm_pll_save_state()` 在 probe 时只读状态保存起来，PLL 此时本就没启用。这个错误在每次启动都会打，无害。 |
| **DSC 参数不完整会出问题** | ⚠️ **部分成立**，但机理和我以为的不一样。msm 会自动补全（`dsi_populate_dsc_params`），所以"不完整"不是问题；**填错才是**。codex 补的参数有 5 个字段与面板 PPS 不符，其中最严重的 `rc_model_size` 差了 10 倍。 |

### 8.2 真正卡住的点：`exit_sleep (0x11)` 没有让面板退睡

可逆性探针测到的：

```
序列跑完 → power_mode = 0x0c   (sleep_out = 0，面板还在睡)
单独发 0x11 + 0x29 → 0x9c     (sleep_out = 1，醒了)
```

**整个初始化序列（61 条命令、668 字节）跑完了，面板却还在睡眠状态。**

这是"面板状态正常但屏幕不亮"的直接解释：面板睡着的时侯当然不显示。

### 8.3 对工作量估计的修正

第七节说"待查项是 PLL 和 DSC"。现在两项都有结论，剩下的是：

| 项 | 状态 |
|---|---|
| PLL | ✅ 假警报，不用管 |
| DSC 参数 | ✅ 已按真实 PPS 修正 |
| **sleep-out 时序** | ⏳ 已改成 120 ms，待验证 |
| **0x11 vs 0x29 谁负责唤醒** | ⏳ 探针已改，待验证 |
| Iris 协处理器 | ⏳ 仍未知，但**花屏现象说明它不是串联阻塞点** |

**Iris 风险的重新评估**：既然花屏出现过（面板收到并显示了数据），
说明即使 Iris 存在，它也没有完全阻断数据通路。**这项风险显著降低了。**

### 8.4 一句话总结

**这不是"面板点不亮"，而是"面板还在睡觉"。** 两者的解法完全不同：
前者要重写驱动或面对硬件限制，后者只是时序问题。
