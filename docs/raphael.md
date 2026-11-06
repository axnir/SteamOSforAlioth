# raphael（Redmi K20 Pro / Mi 9T Pro）移植起点

> 这台机器：`SM8150`（骁龙 855/855+，msmnile），不是 `sm8250`。  
> 本文只写**今天在真机上量到的**和**从参考仓库读到的**，两者分开标注；  
> 没量过的一律写“未验证”，不要当成结论往下推。

分支：`raphael`（自 `main` 拉出，未推送）。

---

## 1. 分支现状

```
main      73c85e1   SteamOS for alioth
raphael   同上       本分支：只有本文 + 后续移植提交
```

`main` 上的一切（`build-alioth-kernel.sh`、`make-steamos-alioth.sh`、  
`flash-alioth.sh`、`scripts/assert-alioth-*`、`alioth-overlay/`）都是 alioth 的，  
本分支**先不动它们**。移植走“新增一套 `raphael` 文件 + 共用 kernel-common”的路子，  
等 raphael 真机跑起来再回头决定哪些 alioth 专属脚本该泛化。

---

## 2. 设备实测（2026-11-06，adb 连在这台手机上）

| 项       | 值                                                                            | 怎么量的                                                     |
| ------- | ---------------------------------------------------------------------------- | -------------------------------------------------------- |
| 代号 / 型号 | `raphael` / Redmi K20 Pro Premium Edition                                    | `getprop ro.product.device` / `ro.product.model`         |
| 平台      | `msmnile`，`SM8150`                                                           | `getprop ro.board.platform`、`/proc/cpuinfo` 的 `Hardware` |
| 内存      | 7 680 516 kB ≈ 7.5 GiB（8 GB 版本）                                              | `/proc/meminfo`                                          |
| 存储      | UFS，`userdata` 461 G（512 GB 版本）                                              | `df -h /data`                                            |
| 屏幕      | 1080×2340，440 dpi，DSI `card0-DSI-1`                                          | `wm size` / `wm density` / `/sys/class/drm`              |
| 触摸      | Goodix（`goodix_ts`，vendor 树标 GT9886）                                         | `dumpsys input`，`Device 2: goodix_ts`                    |
| 音频      | `sm8150-tavil-snd-card`（WCD9340 SLIMbus + TFA9874 功放）                        | `dumpsys input` 里的声卡 jack 设备                             |
| Wi-Fi   | `ro.wlan.chip=39xx`，vendor 节点是 `wcn3998-wifi`                                | `getprop`，参考 DTB                                         |
| Android | MIUI 12.5，`RKQ1.200826.002` / `21.11.24`，内核 4.14.180                         | `getprop ro.build.fingerprint`、`uname -a`                |
| root    | **有**：Magisk 27（`/system/bin/su -> ./magisk`），shell 需在 Magisk 里放行            | `su -c id` → `uid=0(root) … u:r:magisk:s0`               |
| 分区槽位    | **没有 A/B**：`ro.boot.slot_suffix` 为空，`fastboot getvar all` 里**一个 slot 变量都没有** | 两处独立确认                                                   |

分区表（`/dev/block/by-name/`，全部列出，注意没有 `_a`/`_b` 后缀）：

```
abl ablbak aop aopbak ... boot cache dtbo ... modem ... super system userdata vbmeta vendor xbl xblbak
```

带 `bak` 的是**引导链备份分区**（`abl`/`ablbak`、`xbl`/`xblbak`、`tz`/`tzbak` …），  
不是 A/B 槽。这台机器是 **A-only**：一个 `boot`、一个 `dtbo`、没有 `set_active`。

> 这一条对刷机脚本的影响比看上去大，见 §6。

### 2.1 bootloader 侧的数字（`fastboot getvar all`）

| 项                                      | 值                                                  |
| -------------------------------------- | -------------------------------------------------- |
| `boot`                                 | `0x8000000` = 128 MiB                              |
| `dtbo`                                 | `0x2000000` = 32 MiB（`/dev/block/sde45`）           |
| `cache`                                | `0x10000000` = 256 MiB                             |
| `vbmeta`                               | `0x20000` = 128 KiB                                |
| `modem`                                | `0x14000000` = 320 MiB                             |
| `userdata`                             | `0x752A7FB000` ≈ 502.6 GB                          |
| `unlocked` / `variant` / `hw-revision` | `yes` / `SDM UFS` / `20002`，`board_version: 4.9.2` |
| `fastboot fetch`                       | **不支持**（"Device does not support fetch command"）   |

`fetch` 被关掉这一条决定了备份怎么做：**分区备份只能走 root**，`fastboot` 这条路没有。

### 2.2 原厂 boot 镜像的头部（备份自己解析出来的）

从 `stock-boot.img` 的前 1648 字节读出来：

```
magic ANDROID!        header_version 1   header_size 1648   pagesize 4096
kernel_size 43958697  kernel_addr 0x00008000
ramdisk_size 927736   ramdisk_addr 0x00000000
second_size 0         second_addr 0x00000000
tags_addr 0x00000100  os_version 0x16000155
recovery_dtbo_size 0  dtb_size 0          dtb_addr 0x0
cmdline: console=ttyMSM0,115200n8 androidboot.hardware=qcom ...
```

**这两个 0 是这份镜像最值得注意的地方**：头部是 v1（所以 `dtb_size` 字段存在），  
但 `dtb_size` 和 `recovery_dtbo_size` 都是 0 —— **这份 boot 镜像里没有 DTB 段**。  
而 `dtbo` 分区里那 7 条是带识别头的 overlay（`model` / `compatible` /  
`qcom,board-id` 后面跟 `fragment@0` / `__overlay__`），也不是整棵板级树。

也就是说：原厂镜像里 base DTB 既不在这两个分区的明面上，那它只能在内核 Image  
自己里面（qcom 的 `Image` + 追加 DTB 的产物，`kernel_size` 里就包含它）。这条和  
我们"把 DTB 追加在 gzip 流后面"的做法不冲突，但**ABL 到底按什么顺序找、认哪个  
字段，还没验证过**（见 §8）。

**这和 `make-steamos-alioth.sh` 里那四个值几乎一样**（`PAGESIZE=4096`、  
`KERNEL_ADDR=0x8000`、`TAGS_ADDR=0x100`），唯一不同的是 ramdisk 地址：  
raphael 是 `0x0`，alioth 用 `0x01000000`。也就是说打包逻辑可以整套搬过来，  
只需要把这一个值按 raphael 的来。

### 2.4 原厂 boot 的内核段：不是 gzip，是带标记的未压缩 Image

这一条是四个刷写回合之后才解开的，写在前面，因为它是这台机器和 alioth 最大的  
不同。原厂 `boot.img` 的内核段（页大小之后那 43 958 697 字节）是：

```
offset 0    "UNCOMPRESSED_IMG"        16 字节 ASCII
offset 16   u32  dtb_offset           DTB 在 Image 内的偏移（41 963 536）
offset 20   arm64 Image               裸镜像，不压缩
+dtb_offset FDT(s)                    追加在 Image 后面的设备树（4 个）
```

四条独立证据：段首是那串 ASCII；段内 +20 处 `0x38` 是 `ARMd`（arm64 Image 魔数）；  
段内 +20+417… 处正是 `d00dfeed`，后面跟着 4 个 FDT；头部 `kernel_size` 覆盖整段。

**所以 alioth 那套 "gzip(Image) + 后面拼 DTB" 在这里不成立。** 我们按 alioth 打的  
第一版镜像：`fastboot flash boot` 全部 OKAY，重启后屏幕出现 MIUI logo，6 秒回到  
fastboot —— 加载期就被拒，没有任何内核日志。

`external-and-mods/kernel-common/mkbootimg-v1.py` 就是照着这个格式写的：v1 头部  
（header_size 1648，原厂就是 v1；v1 里没有 `dtb_size`，那是 v2 才有的）+ 那 20 字节  
封装 + 窗口字段全部照抄原厂（4096 / 0x8000 / ramdisk 0x0 / tags 0x100 /  
os_version 0x16000155）。

### 2.3 已经做出来的备份

| 文件                                  | 大小                  | sha256                                                             |
| ----------------------------------- | ------------------- | ------------------------------------------------------------------ |
| `work/raphael-facts/stock-boot.img` | 134 217 728 B（整个分区） | `b794c34b2d868cc81e694ecd01d732a4c286ef8bc6ecf541548e0fe38ed048ce` |
| `work/raphael-facts/stock-dtbo.img` | 33 554 432 B（整个分区）  | `f921ddda9bc38bb4582287c0e2d6aafb5fc3b132680ab53774bdd9ae9fc6f540` |

两个都在机内 `dd` 出来、`adb pull` 回来，两边的 `sha256sum` 一致。`work/` 是  
`.gitignore` 的，不进仓库；丢了自己重做一遍即可：

```bash
adb shell su -c "dd if=/dev/block/by-name/boot of=/data/local/tmp/b.img bs=1M"
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/b.img work/raphael-facts/stock-boot.img
```

> 两个坑：`adb exec-out ... > file` 在 Windows/Git Bash 下会把 `0x0A` 换成  
> `0x0D 0x0A`，128 MiB 的镜像会长出 319 638 字节，`sha256` 对不上而文件看着正常；  
> `adb pull /data/...` 的绝对路径会被 MSYS 改写成 `C:/Program Files/...`，  
> 要加 `MSYS_NO_PATHCONV=1`。

回退：`fastboot flash boot work/raphael-facts/stock-boot.img` 就是现在这套  
Android（Magisk 补丁版）原样回去。

`/proc/cmdline`、`/proc/device-tree/*`、`/proc/bus/input/devices` 对 shell 全部  
`Permission denied`（SELinux），所以 board-id 这类东西**不能**从运行中的 Android 读，  
只能从 fastboot 侧或放行镜像里拿。

---

## 3. 参考仓库的真实结构（别照着 README 抄错一层）

你给的两个地址里，内核其实不在它们身上：

| 仓库                                              | 实际是什么                                                                 | 对移植的用处                                                                       |
| ----------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `Winter21c/archlinux-xiaomi-raphael`            | **只是镜像构建器**（Arch 的 rootfs + 分区镜像 + 刷机脚本）。内核是下载别人编好的 `.deb`            | 极有用：分区布局、U-Boot/systemd-boot 引导、UCM、以及一堆**踩坑记录**（`HANDOVER.md`、`notes/*.md`） |
| `GengWei1997/linux-xiaomi-raphael-uboot`        | 也只是构建器（Debian/Ubuntu），内核从 `GengWei1997/kernel-deb` 的 Release 下 `.deb` | 一般；价值在于它的 `scripts/` 里对 qcom 用户态（`rmtfs`/`pd-mapper`/`tqftpserv`）的处理         |
| **`GengWei1997/linux` 分支 `raphael-v7.3.0`**     | **真正的内核源码**：7.3.0 + raphael 板级支持，`sm8150-xiaomi-raphael.dts` 在这里      | 这才是“内核参考”                                                                    |
| `GengWei1997/kernel-deb`（Release `kernel-v7.3`） | 预编译的 `linux-image` / `headers` / `firmware` / `alsa` deb              | 想跳过编译先验证硬件时用；本仓库的路线是从源码编                                                     |

已克隆到 `work/ref/`（`.gitignore` 里，不会提交）：

```
work/ref/linux-raphael/                      # linux@raphael-v7.3.0（浅克隆，进行中）
work/ref/archlinux-xiaomi-raphael/           # 含 dtb/raphael-redmi-k20pro.dtb，可反解
work/ref/linux-xiaomi-raphael-uboot/         # Debian 构建器
work/ref/raphael-facts/sm8150-xiaomi-raphael.{dts,config}
```

### 3.1 内核树里已经有的东西

`arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dts`（1392 行）不是占位文件，  
它把这块板子写得相当完整，而且**注释就是设计说明**：

- 面板 `samsung,ea8076`，DSI0，`vddio`/`vcie` 供电、TE 脚
- 触摸 `goodix,gt9886`，`i2c19`（QUPv3 wrap 2 / SE19），两根 load switch 供电
- 音频：ADSP → SLIMbus → `wcd9340`，加 `nxp,tfa9874`（I2C1，`QUATERNARY_MI2S_RX`），  
  `qcom,sm8150-sndcard` 里四条 DAI link
- Wi-Fi `qcom,wcn3990-wifi`、BT `qcom,wcn3990-bt`（`uart13`，4 线流控）
- 充电 `pm8150b-charger` + SMB1390 电荷泵、电量计、振动、RTC（走 SDAM offset）、  
  UFS（**PHY 掉电后无法恢复，运行时 PM 全关**，注释写了原因）
- 保留区、`gpio-reserved-ranges`、UART 调试口（`qcom,geni-debug-uart`，`ttyMSM0`）

`arch/arm64/configs/sm8150-xiaomi-raphael.config` 是 **defconfig 的增量**，  
`CONFIG_LOCALVERSION="-raphael"`，面板/触摸都 `=y`（早期就要能出画面）。

### 3.2 但它没有一个 ABL 需要的标识

源码 DTS 里**没有** `qcom,msm-id` / `qcom,board-id`。原因很直接：这套板级文件是给  
U-Boot / UEFI 引导写的，DTB 由引导器直接递给内核，不需要“按 board-id 选 DTB”。

我们 `main` 上 alioth 的 DTS 是有的：

```dts
qcom,msm-id   = <QCOM_ID_SM8250 0x20001>;   /* SM8250 v2.1 */
qcom,board-id = <44 0>;
```

ABL 的 DTB 选择就是拿这两个值做匹配（`docs/alioth.md` 里 ABL 日志的  
`Best match DTB tags 356/0000002C`，`0x2C`=44 就是 board-id）。

**raphael 的两个值：**

```
qcom,msm-id   = <0x153 0x20000>     /* SM8150 v2.0 */
qcom,board-id = <0x28 0>            /* 40  */
```

`board-id` 已经在这台机器上**直接读到了**（root 下 `od /proc/device-tree/qcom,board-id`  
→ `00 00 00 28 00 00 00 00`），和参考项目那份从 U-Boot 机器导出的 DTB 完全一致。  
`msm-id` 那个文件被 SELinux 挡着读不到（`Permission denied`），但它是 SoC 级常量，  
不是板级的，按 SM8150 取 `0x153`。

### 3.3 参考 DTB 和源码 DTS 的差异，逐条核实过了

| 项        | 源码 DTS                  | 参考 DTB               | 这台机器上的实际值                                                                                             |
| -------- | ----------------------- | -------------------- | ----------------------------------------------------------------------------------------------------- |
| 面板       | `samsung,ea8076`        | `samsung,ams639rq08` | **ea8076**：dmesg 里 `panel name is dsi_ss_fhd_ea8076_cmd_display`、`[samsung ea8076 fhd cmd dsi panel]` |
| BT       | `qcom,wcn3990-bt`       | `qcom,wcn3998-bt`    | 未定，两个都试得起（同一个驱动）                                                                                      |
| Wi-Fi 供电 | 分散在 regulator           | 独立 `wcn3998-pmu` 节点  | 未测，起不来先怀疑这里                                                                                           |
| 内存节点     | 硬编码 3 段（≈6 GiB，UEFI 交接） | 没有                   | ABL 会填，见 §8                                                                                           |

所以**源码树那份 DTS 是准的**，参考项目那份是另一个修订（或另一块板子）。  
触摸也核实了：`[GTP9886-INF] goodix9886 Core layer init`，和 DTS 的 `goodix,gt9886` 对得上；  
功放 `tfa98xx_i2c_probe(): addr=0x34`，和 DTS 的 `amplifier@34` 对得上。

---

## 4. 与 alioth 的结构性差异

| 维度    | alioth（现状）             | raphael（本分支）                               | 影响                                                 |
| ----- | ---------------------- | ------------------------------------------ | -------------------------------------------------- |
| SoC   | SM8250 / Adreno 650    | SM8150 / Adreno 640                        | 整个 `kernel-sm8250` 不能复用，要新建 `kernel-sm8150`        |
| 槽位    | A/B 双槽                 | **A-only**                                 | `flash-alioth.sh` 的“只写 a 槽、留着 b 槽的 Android”安全模型不存在 |
| 引导    | 小米 ABL + 自带 boot.img   | 参考项目走 U-Boot + systemd-boot                | 见 §5，这是本分支第一个要拍的决定                                 |
| Wi-Fi | QCA6390 / ath11k（PCIe） | WCN3998 / ath10k_snoc（SNOC）                | 固件来源、MAC 地址处理、模块名全不同                               |
| 音频    | 两颗 CS35L41，无 codec     | WCD9340（SLIMbus）+ TFA9874                  | UCM 要重写；参考项目的 DTB 补丁可以直接抄                          |
| 触摸    | FocalTech FT8756（SPI）  | Goodix GT9886（I2C）                         | 驱动换了但都是 mainline 现成的                               |
| 内核基线  | ROCKNIX 7.2.8 + 我们的补丁  | 7.3.0 + raphael 板级（`linux@raphael-v7.3.0`） | 不能把 ROCKNIX 的 sm8250 补丁往上打                         |

---

## 5. 第一个决定：用哪条引导链

**A. 沿用本仓库的 ABL + boot.img（推荐先试这个）**

`boot` 分区放一个带 DTB 的 `boot.img`（`Image.gz` + 追加 DTB），`userdata` 放 SteamOS  
rootfs。这条路：

- 复用已经写好的整套东西：`mkbootimg-v0.py`、`make-steamos-*.sh` 的打包逻辑、  
  `scripts/assert-alioth-boot-image.sh` 的检查思路、`*-selfflash-boot.sh` 的机内刷写
- 不用往 `boot` 里写 U-Boot（少一个会失效的引导器）
- 代价：DTS 必须补 `msm-id`/`board-id`；内存节点要让 ABL 填而不是硬编码（alioth 就是没有 `memory` 节点）

**B. 照抄参考项目：U-Boot → systemd-boot → 内核**

- 好处：参考项目在真机上验证过整条链，`cache` 分区当 `/boot`，换内核不用刷机
- 代价：`boot` 分区被 U-Boot 占掉；本仓库的 boot.img 打包/断言全部作废；  
  多一层需要维护的引导器；U-Boot 的 `u-boot.img` 是别人编的二进制

建议：**先按 A 做一次调试启动**（能进 USB 网络 shell 就算过），失败再切 B。  
判据是 ABL 能不能认这个 DTB —— 一次刷写就能知道，代价可控。

---

## 6. 硬规则（在 alioth 之上新增的）

`AGENTS.md` 里那套（不碰 `abl*`/`super`/`vbmeta`、`userdata` 不可逆、不加功放增益）  
原样有效。raphael 额外三条：

1. **`boot` 只有一个，没有备用槽。** alioth 写坏 a 槽还能靠 b 槽的 Android 找回来，  
   这里写坏就是纯黑屏，只能靠 fastboot 重刷。安全网是 §2.3 那两个备份：
   - 回退命令记住一条就够：`fastboot flash boot work/raphael-facts/stock-boot.img`
   - 刷机脚本里“两槽写同一份镜像”的逻辑整段作废，换成“先校验备份在，再写”
2. **`dtbo` 不要乱清。** alioth 是 `erase dtbo` 再刷（防止厂商 overlay 叠上来）。  
   raphael 的 `dtbo` 里是**面板/触摸的 overlay**，清掉会不会黑屏还没验证 ——  
   本分支第一版**不写 `dtbo`**，保持原状。
3. **UFS 的运行时电源管理不能开。** 内核 DTS 注释写得很清楚：QMP UFS PHY 掉电后  
   只能靠 HCE-enable 重新编程，hibern8 退出会 PA fatal error，之后全部 `-EIO`。  
   启动参数和 overlay 都别去“优化”这一块。



---

## 7. 阶段计划

### 阶段 0：侦察（不用刷机）

- [x] 分支与设备型号确认（本文 §2）
- [x] 内核源码定位：`linux@raphael-v7.3.0`
- [x] board-id / msm-id 确认（`board-id` 在真机上直读得到，§3.2）
- [x] 面板 / 触摸 / 功放型号用 dmesg 核实（§3.3）
- [x] `fastboot getvar all` 与 boot 头部记下来（§2.1、§2.2）
- [x] `boot` + `dtbo` 整分区备份，两边 sha256 对过（§2.3）
- [ ] `work/ref/linux-raphael` 克隆完成后，确认 DTS 与 config 在树里的真实状态

### 阶段 1：能出画面、能进 shell（一次刷写）

产出：`work/steamos-raphael/boot-debug.img`

脚手架已经写好了，**但还一次都没编译过**（见下面的环境要求）：

- [x] `external-and-mods/kernel-sm8150/soc.env` —— `KSRC_URL` 按 commit 固定到
      `raphael-v7.3.0`、`KCONFIG_FRAGMENT` 用树里自带的增量、`DTBS` 一个、
      `CMDLINE_BUILTIN=1`、`FW_BUILTIN=0`、`OWN_KERNEL_TREE=1`
- [x] `kernel-sm8150/patches/0001-...` —— 补 `qcom,msm-id` / `qcom,board-id`。
      在真实那份 DTS 上 `patch -p1` 过了，零 fuzz，输出与预期逐字节一致
- [x] `kernel-sm8150/steamos.config` —— USB ACM 控制台（阶段 1 唯一的日志通道）
- [x] `kernel-common/build.sh` —— 加 `KCONFIG_FRAGMENT`（defconfig + 增量）和
      `OWN_KERNEL_TREE=1` 的四道门（不校验 ROCKNIX、不取 extra-firmware、
      不编 chipone_tddi、不复制 ROCKNIX 固件）
- [x] `build-raphael-kernel.sh`、`make-steamos-raphael.sh`（`--kernel-only`）、
      `flash-raphael.sh`（`--ramboot` / `--test`）
- [x] **编出来了**：`7.3.0-raphael-steamos`，`Image` 51 255 808 B，
      `sm8150-xiaomi-raphael.dtb` 104 463 B，模块 133 MB
- [x] DTB 里读回 `qcom,msm-id = <0x153 0x20000>` / `qcom,board-id = <0x28 0>` ——
      补丁 0001 确实进了被编译的那棵 DTS，不是只改了一份没人用的副本
- [x] `boot-debug.img` 51 372 032 B：v1 头部 + `UNCOMPRESSED_IMG` 封装（§2.4），
      DTB 偏移 51 255 808 对上，头部字段与原厂逐项一致
- [x] 加了面板控制台（`dts/*.append` 的 simpledrm framebuffer + `DRM_SIMPLEDRM=y`），
      因为这台机器没有可外接的串口，内核死在 USB 起来之前就完全没有观测通道
- [ ] **ABL 仍然拒这份镜像**：刷写 OKAY，重启 6 秒回 fastboot，五轮都没过去。
      已排除的项和剩下的三处差异见 §8.1
- [ ] 验收：USB 网卡 + `172.16.42.1:23` 能进 shell

### 阶段 2：rootfs 起得来

- `userdata` 写 SteamOS rootfs（ext4），`steamos.root=PARTLABEL=userdata`
- 固件：GPU（`a640_*`）、ADSP、modem、WCN3998 的 `board-2.bin` 都来自**这台手机自己**
  （`modem`/`vendor` 分区），不进 git —— 与 alioth 的 `extract-alioth-firmware.sh` 同一套逻辑
- 参考项目已知的坑（可直接抄结论）：
  - `regulatory.db` 签名不被这个内核信任 → 主动删掉，退化到 world 域
  - ath10k 读不到 `wlan_mac.bin` 会给随机 MAC → 用 systemd 服务固定
  - SLIMbus 的 `slimcap/slim-playback` DAI link 枚举失败会把整块声卡卡在 `EPROBE_DEFER`
    → 只要扬声器就删掉这两条（代价是耳机通路）

### 阶段 3：Steam Game Mode

- 到这一步才谈 `gamescope`、着色器缓存、`steamos-overlay/` 的复用
- GPU：Adreno 640 + freedreno，与 alioth 的 650 同一套 Mesa，但 `a640_sqe.fw` 等固件要机内提取

---

## 8. 未验证清单（别当结论用）

1. **ABL 为什么拒这份镜像 —— 阶段 1 卡在这里，五个回合还没解开。**
   已经排除的：

   - `fastboot boot`（RAM 启动）在这台机器上**整体不可用**：连原厂镜像都回
     `Failed to load/authenticate boot image: Load Error`。所以 `--ramboot` 这条路是死的，
     不是我们镜像的问题。
   - 不是 AVB：`ro.boot.verifiedbootstate=orange`、`flash.locked=0`。
   - 不是 gzip 的问题：换成原厂那种 `UNCOMPRESSED_IMG` 封装（§2.4）照样被拒。
   - 不是头部版本：v0 和 v1 都试过，字段已经和原厂逐项一致。
   - 不是我们的外壳：**保留原厂头部/ramdisk/AVB footer/128 MB 尺寸**、只把内核段换成
     我们的 Image + DTB，一样被拒。

   所以问题落在内核段的内容本身，但 ABL 不接受的理由还没找到。已知的差异只剩三处：
   我们的 Image 是 51 255 808 B（原厂 41 963 536 B，我们多了一个 initramfs）、
   `code0` 是 `fa405a4d`（原厂是 `147e0000`，一条 `b`）、以及 `image_size` 字段
   52 101 120（原厂 48 844 800）。下一步要么把这三处分头消掉，要么换引导链（§5 的 B）。
2. **BT 用 `wcn3990-bt` 还是 `wcn3998-bt`** —— 源码 DTS 写 3990，参考 DTB 写 3998，同一个
   驱动，两个都试得起，但只能试一次知道。
3. **清 `dtbo` 的后果** —— 未测。原厂 `dtbo` 是面板/触摸的 overlay，清掉会不会黑屏不知道，
   第一版不动它。
4. **内存节点**：ABL 填的布局和内核 DTS 里那 3 段（UEFI 交接，≈6 GiB）对不上 ——
   这台机器 `MemTotal` 7.5 GiB，说明那份映射本身就少给了一截。所以 append 里要把
   `memory@80000000` 删掉，让 ABL 填（alioth 就是这么做的）。
5. **`userdata` 覆盖即丢 Android** —— 502.6 GB，f2fs + 加密，不可逆。
6. **WCN3998 的 `board-2.bin` 与 MAC** —— 固件在 `vendor`/`persist` 里，得从 root 侧取；
   取不到 `wlan_mac.bin` 时 ath10k 会给随机 MAC（参考项目用 systemd 服务固定）。

### 8.1 五个回合的代价，和一条被验证过的安全网

一共刷了五次 `boot`，五次都靠 `fastboot flash boot work/raphael-facts/stock-boot.img`
在 40 秒内回到 Android。**这就是 A-only 没有备用槽时唯一的安全网，而且是可执行的**：
备份的 sha256 写死在 `flash-raphael.sh` 里，对不上就拒绝写。

每次失败的表现都一样：`fastboot flash` 全部 OKAY，重启后屏幕出现小米 logo（有一次是
直接进 fastboot），约 6 秒回到 bootloader。6 秒这个数字本身是线索：它比一次内核启动
短得多，比一次 ABL 拒绝长一点。

---

## 9. 怎么继续

```bash
git checkout raphael

# 1) 编译（Linux + docker/podman + aarch64 静态 busybox）
./build-raphael-kernel.sh

# 2) 打 boot.img（Image + 单个 DTB，参数全来自原厂头部）
./make-steamos-raphael.sh --kernel-only

# 3) 上真机。先 RAM 启动，不写任何分区
adb reboot bootloader
./flash-raphael.sh --ramboot

# 4) 起得来再落盘
./flash-raphael.sh --test
```

第 1 步在写这份文档时是在这台 Windows 上跑的，用 WSL 的容器 CLI（`wslc`，
镜像 `proxy.vvvv.ee/library/fedora:43`）。四件事值得记下来，因为每一件都让第一次
构建停在离原因很远的地方：

1. **仓库在 Windows 上检出是 CRLF**。`set -euo pipefail\r` 在 Linux 里报
   `pipefail: invalid option name`。容器里先把 `external-and-mods/` 与三个顶层脚本
   拷过去、`sed 's/\r$//'`，不改仓库本身。
2. **`build.sh` 的 `build_initramfs()` 读死 `/bin/busybox`**（ROCKNIX 上游的路径），
   平时由 `build-gcc15.sh` 用 `-v` 挂进去。绕开那层包装就得自己放一份，否则报
   "need a static busybox"。
3. **`set -u` 会撞 `ROCKNIX_REF`**：`ROCKNIX_DIR` 的默认值里展开它，而 raphael 的
   配方按设计不定义它。`build.sh` 里给了 `unused` 兜底。
4. **GitHub 直连 ~28 KB/s，还被 429 限流**；`ghfast.top` 也就 135 KB/s。
   258 MB 的源码树最后是人在外面下好丢进 `work/cache/`。构建脚本会把它放进
   `$WORK/cache/linux-raphael-<sha>.tar.gz`，`fetch()` 见到就不下了 —— 重跑不再联网。

另外记一个**看起来像 bug 但并不是**的：`Image` 前 4 字节是 `4d 5a`（"MZ"），
很像 `CONFIG_EFI_ZBOOT` 产出的 PE 包装。它不是 —— offset `0x38` 是 `ARMd`，
这是带 `CONFIG_EFI=y` 的裸 arm64 Image 的正常头部（前两字节刻意做成 "MZ" 让 PE
加载器认）。判断该看 `0x38`，别看头 4 字节，否则会把一个好内核丢掉。

`--install`（写 `userdata`、装 SteamOS rootfs）没有实现，也不该在阶段 1 之前实现：
它需要机内签名固件、一份 raphael overlay、以及一个已经确认能启动的 boot.img，
三样都还没有。
