# raphael（Redmi K20 Pro / Mi 9T Pro）移植起点

> 这台机器：`SM8150`（骁龙 855/855+，msmnile），不是 `sm8250`。  
> 本文只写**今天在真机上量到的**和**从参考仓库读到的**，两者分开标注；  
> 没量过的一律写“未验证”，不要当成结论往下推。

分支：`raphael`（自 `main` 拉出，未推送）。

---

## 1. 分支现状

```
main      73c85e1   SteamOS for alioth
raphael   95a7d11   +6 个提交
  c046198  docs: 移植起点（设备实测、内核来源、与 alioth 的六处结构差异）
  97ee575  docs: boot/dtbo 整分区备份，board-id 与面板型号核实
  8ba4fbc  feat: kernel-sm8150 配方与阶段 1 的三个脚本
  c2e4882  feat: 阶段 1 的内核和 boot 镜像编出来了
  0e2dbe4  feat: 解开原厂内核段的封装（ABL 仍然拒）
  95a7d11  fix: ABL 拒的是设备树 —— 清掉 dtbo 就过了
```

`main` 上的一切（`build-alioth-kernel.sh`、`make-steamos-alioth.sh`、
`flash-alioth.sh`、`scripts/assert-alioth-*`、`alioth-overlay/`）都是 alioth 的，
本分支没动它们。移植走的是"新增一套 `raphael` 文件 + 共用 kernel-common"的路子。

`kernel-common/build.sh` 是为了这条路改的（`OWN_KERNEL_TREE`、`KCONFIG_FRAGMENT`），
改法是加分支而不是改语义 —— 不设这两个变量的 alioth/sm8250 行为完全不变。

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
cmdline: console=ttyMSM0,115200n8 androidboot.hardware=qcom ...
```

这五个值和 `make-steamos-alioth.sh` 里那套几乎一样（`PAGESIZE=4096`、
`KERNEL_ADDR=0x8000`、`TAGS_ADDR=0x100`），唯一不同的是 ramdisk 地址：
raphael 是 `0x0`，alioth 用 `0x01000000`。打包逻辑可以整套搬过来，只需要把
这一个值按 raphael 的来。

头部是 **v1**（`header_size 1648`）。v1 里**没有** `dtb_size` / `dtb_addr` ——
那是 v2 才加的字段；1648 之后那些字节是页内填充，不是字段。所以"这份镜像没有
独立 DTB 段"这句话是对的，但原因不是值为 0，而是这一版头部根本没有这个字段。
DTB 在哪儿？见 §2.4。

### 2.3 已经做出来的备份

| 文件 | 大小 | sha256 |
|---|---|---|
| `work/raphael-facts/stock-boot.img` | 134 217 728 B（整个分区） | `b794c34b2d868cc81e694ecd01d732a4c286ef8bc6ecf541548e0fe38ed048ce` |
| `work/raphael-facts/stock-dtbo.img` | 33 554 432 B（整个分区） | `f921ddda9bc38bb4582287c0e2d6aafb5fc3b132680ab53774bdd9ae9fc6f540` |

两个都在机内 `dd` 出来、`adb pull` 回来，两边的 `sha256sum` 一致。`work/` 是
`.gitignore` 的，不进仓库；丢了自己重做一遍即可：

```bash
adb shell su -c "dd if=/dev/block/by-name/boot of=/data/local/tmp/b.img bs=1M"
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/b.img work/raphael-facts/stock-boot.img
```

> 两个坑：`adb exec-out ... > file` 在 Windows/Git Bash 下会把 `0x0A` 换成
> `0x0D 0x0A`，128 MiB 的镜像会长出 319 638 字节，看起来一切正常但 `sha256` 对不上；
> `adb pull /data/...` 的绝对路径会被 MSYS 改写成 `C:/Program Files/...`，
> 要加 `MSYS_NO_PATHCONV=1`。

回退要用**两条**命令（boot 和 dtbo 都要回来，见 §8.1）：

```bash
fastboot flash boot work/raphael-facts/stock-boot.img
fastboot flash dtbo work/raphael-facts/stock-dtbo.img
```

`/proc/cmdline`、`/proc/device-tree/*`、`/proc/bus/input/devices` 对 shell 全部
`Permission denied`（SELinux），所以 board-id 这类东西**不能**从运行中的 Android 读，
得在 Magisk 里放行 `su` 之后读。

### 2.4 原厂 boot 的内核段：不是 gzip，是带标记的未压缩 Image

这一条是六个刷写回合之后才解开的，先写在前面，因为它是这台机器和 alioth 最大的
不同。原厂 `boot.img` 的内核段（页大小之后那 43 958 697 字节）是：

```
offset 0      "UNCOMPRESSED_IMG"   16 字节 ASCII
offset 16     u32  dtb_offset      DTB 在 Image 内的偏移（41 963 536）
offset 20     arm64 Image          裸镜像，不压缩
+dtb_offset   FDT(s)               追加在 Image 后面的设备树（4 个）
```

四条独立证据：段首是那串 ASCII；段内 +20 处 `0x38` 是 `ARMd`（arm64 Image 魔数）；
段内 +20+u32 处正是 `d00dfeed`，后面跟着 4 个 FDT；头部 `kernel_size` 覆盖整段。
按这个格式重建原厂段，和原文件**逐字节相同** —— 这是"理解正确"最硬的证据。

**所以 alioth 那套 "gzip(Image) + 后面拼 DTB" 在这里不成立。** 我们按 alioth 打的
第一版镜像：`fastboot flash boot` 全部 OKAY，重启后 6 秒回到 fastboot ——
加载期就被拒，没有任何内核日志。

`external-and-mods/kernel-common/mkbootimg-v1.py` 就是照着这个格式写的：v1 头部
（1648 字节）+ 那 20 字节封装 + 其余字段全部照抄原厂（4096 / 0x8000 / ramdisk 0x0 /
tags 0x100 / os_version 0x16000155）。

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

## 5. 引导链：已定 A，而且已经过了一关

选的是 **A：沿用本仓库的 ABL + boot.img**（`boot` 放内核镜像，`userdata` 放 rootfs），
不引入 U-Boot。

这条路原本的风险写在这里是"DTS 必须补 msm-id/board-id，ABL 认不认一次刷写就知道"。
现在的答案：**认了，但前提是先清 `dtbo`**（§8.1）。小米 ABL 会把 `dtbo` 里的 overlay
叠到 boot 镜像的 DTB 上，叠不上就整个不启动 —— 那才是前五个回合失败的真正原因。

参考项目走的是 B（U-Boot → systemd-boot，`cache` 当 `/boot`）。它成立，但对这个仓库
意味着：`boot` 被 U-Boot 占掉、boot.img 那套打包与断言全部作废、多一层别人编的
二进制要维护。既然 A 的 ABL 关已经过了，没有理由再切过去。

## 6. 硬规则（在 alioth 之上新增的）

`AGENTS.md` 里那套（不碰 `abl*`/`super`/`vbmeta`、`userdata` 不可逆、不加功放增益）  
原样有效。raphael 额外三条：

1. **`boot` 只有一个，没有备用槽。** alioth 写坏 a 槽还能靠 b 槽的 Android 找回来，  
   这里写坏就是纯黑屏，只能靠 fastboot 重刷。安全网是 §2.3 那两个备份：
   - 回退命令记住一条就够：`fastboot flash boot work/raphael-facts/stock-boot.img`
   - 刷机脚本里“两槽写同一份镜像”的逻辑整段作废，换成“先校验备份在，再写”
2. **`dtbo` 要清，而且这是 ABL 接受我们镜像的前提。** 这一点最初写反了（"第一版不写
   dtbo"）：`dtbo` 里的 overlay 是给厂商设备树用的，叠到 mainline 板级文件上必然失败，
   ABL 于是拒绝启动（§8.1）。`fastboot erase dtbo` 是阶段 1 的必要步骤，不是可选项。
   清掉之后 Android 的屏幕调校也会没 —— 想回去就把备份 `adb push` 回
   `/dev/block/sde45`（§8.1 有命令），所以它仍然是一条"可逆但要记得"的操作。
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
- [x] 内核源码：GitHub 直连只有 28 KB/s，浅克隆卡在 171 MB 不动；最后是人肉下
      258 MB 的 tarball 放进 `work/cache/`，构建脚本从那里取（不再联网）。
      `work/ref/linux-raphael` 那个半截克隆可以直接删掉

### 阶段 1：能出画面、能进 shell（已验收，§12）

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
- [x] **ABL 那关过了**：前提是先 `fastboot erase dtbo`（§8.1）。清掉之后同一个镜像
      就被接受 —— 小米 logo 消失说明跳转了，设备也不再回 fastboot
- [x] 内存映射改成 ABL 实测值（`memory@80000000` 的三段从 `/proc/device-tree` 读的，
      高内存在 `0x180000000` 而不是 UEFI 那份的 `0x100000000`），花屏消失
- [x] splash framebuffer 补 `no-map` 预留（`0x9c000000` + `0x2400000`，从原厂 DTB 读的）
- [x] ramoops 按原厂地址接上（`0xB0000000` / 4 MiB / console 2 + pmsg 2），DTS 里 no-map
- [x] **内核进 userspace 了**（§12）：U-Boot 的 `fastboot boot` + header v2 +
      `page_size=0x200000`（2MB 对齐是 arm64 的硬要求，不对齐就是「Starting kernel
      之后一个字都没有」）。面板上 8 只 Tux、DPU/DSI/Adreno 依次 probe
- [x] 验收：**root shell 在 COM4 上**（`ttyGS1`），`id` = uid=0，`uname -a` =
      7.3.0-raphael-steamos，`free -m` = 7462 MB，`/proc/cpuinfo` 8 核
- [ ] 存储：`/proc/partitions` 空 —— `SCSI_UFS_QCOM` / `PHY_QCOM_QMP_UFS` 是 `=m`，
      boot 镜像不带模块。已改成 `=y`，重编中

### 阶段 1.5：把观测通道建起来（当前卡在这里，§10）

ABL 直接跳 mainline 这条路，卡点不是镜像格式也不是设备树内容，而是**看不见**：
没有串口、USB 还没起来、pstore 读不回来。所以换 U-Boot 接管 `boot`。

- [x] `fastboot flash boot u-boot.img` + `fastboot erase dtbo` → **面板上出现 U-Boot 日志**
- [x] 确认这版 U-Boot 的 USB 侧是空的（无 fastboot、无 adb），面板只能看不能敲
- [x] 解出这台机器的 GPT（4K LBA，头部在 4096，31 个分区）
- [x] 做好 256 MiB FAT32 启动盘（`Image` + DTB + `extlinux.conf`），`flash cache` 写入成功
- [ ] **U-Boot 没把 `cache` 当启动候选**：只试了 `scsi 0..5` 和 `blkmap 0`（§10.4）
- [ ] 下一步：USB 键盘直接问 U-Boot，或把 `cache` 的 GPT 类型改成 ESP（§10.5）

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

1. **ABL 已经接受我们的镜像了 —— 解药是清掉 `dtbo`。** 这是第六个回合才找到的，
   而且推翻了前面五轮的判断：问题不在 Image，不在头部，而在**设备树**。

   `dtbo`（32 MiB，7 条记录）里的每条都是带识别头的 overlay（`model` / `compatible` /
   `qcom,board-id` + `fragment@0` / `__overlay__`）。ABL 按 board-id 选一条，叠到
   boot 镜像里的 DTB 上 —— 而我们的 DTB 是 mainline 板级文件，`__overlay__` 要改的那些
   节点（`dsi_panel_pwr_supply`、`i2c@884000/tfa98xx@34` 之类）一个都不存在。
   叠加失败，ABL 就放弃启动，表现是刷写全 OKAY、重启 6 秒回 fastboot。

   判据很干净：**同一个镜像，`fastboot erase dtbo` 之后 ABL 就收下了** ——
   屏幕上的小米 logo 消失（说明跳转了），设备也不再回 fastboot。恢复同样干净：
   把备份 `dd` 回 `dtbo`（`/dev/block/sde45`）即可。

2. **内核跳过去了，但起不到能看见东西的程度。** 清掉 dtbo 之后：小米 logo 消失、
   屏幕全黑、40 秒内不回 fastboot、USB 上没有任何新设备（gadget 没起来）。
   logo 消失说明 ABL 跳了、内核拿到了显示；黑屏 + 无 USB 说明它死在 simpledrm
   出字之前，或者 fbcon 没绑上。下一步要么给 ramoops 找一块可靠区域（原厂 4 份 DTB
   里都**没有** ramoops 节点，所以地址得另找），要么把 `memory@80000000` 删掉让 ABL
   自己填 —— 现在的 DTS 硬编码的是 UEFI 交接的那 3 段（≈6 GiB），而这台机器有 7.5 GiB。
3. **BT 用 `wcn3990-bt` 还是 `wcn3998-bt`** —— 源码 DTS 写 3990，参考 DTB 写 3998，同一个
   驱动，两个都试得起，但只能试一次知道。
4. **内存节点** —— 见上，和 2 是同一件事的两个可能原因。
5. **`userdata` 覆盖即丢 Android** —— 502.6 GB，f2fs + 加密，不可逆。
6. **WCN3998 的 `board-2.bin` 与 MAC** —— 固件在 `vendor`/`persist` 里，得从 root 侧取；
   取不到 `wlan_mac.bin` 时 ath10k 会给随机 MAC（参考项目用 systemd 服务固定）。

### 8.1 六个回合的代价，和两条被验证过的安全网

一共刷了六次 `boot`，六次都回到 Android。两条路都实测过：

- **fastboot**：`fastboot flash boot work/raphael-facts/stock-boot.img`，40 秒回 Android。
  sha256 写死在 `flash-raphael.sh` 里，对不上就拒绝写。
- **fastboot 进不去的时候**（第六次的后果：设备自己掉进 recovery，音量下 + 电源也没用）：
  recovery 里的 `adb` 是 **root**，而且 `adb push <文件> /dev/block/<分区>` 能直接落到
  块设备上 —— 这条路绕开了 `adb push` 到 `/cache` 时那个"报告成功但文件不存在"的
  命名空间问题。两个分区写完都用 `sha256sum /dev/block/by-name/...` 对过：

  ```bash
  adb push work/raphael-facts/stock-boot.img /dev/block/sde49   # boot
  adb push work/raphael-facts/stock-dtbo.img /dev/block/sde45   # dtbo
  adb shell sha256sum /dev/block/by-name/boot /dev/block/by-name/dtbo
  ```

  这也是为什么 §2.3 的备份必须是**整分区**、且 sha256 两边对过：它救的不是"某次刷坏"，
  而是"连 fastboot 都进不去"。

---

## 9. 怎么继续

```bash
git checkout raphael

# 1) 编译（Linux + 容器 + aarch64 静态 busybox；见下面的环境要求）
./build-raphael-kernel.sh

# 2) 打 boot.img（内核段 = UNCOMPRESSED_IMG 封装，参数全来自原厂头部）
./make-steamos-raphael.sh --kernel-only

# 3) 上真机：写 boot + 清 dtbo，两个分区都动，备份都在 work/raphael-facts/
adb reboot bootloader
./flash-raphael.sh --test          # 提示符输入 BOOT

# 4) 回 Android（两条都要）
fastboot flash boot work/raphael-facts/stock-boot.img
fastboot flash dtbo work/raphael-facts/stock-dtbo.img
```

`--ramboot` 不要用了：这台机器的 ABL 连原厂镜像都拒绝 RAM 启动（§8.1）。

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

## 10. 换到 U-Boot：面板控制台成立，启动介质还没解决

§8 的结论是「ABL 直接跳 mainline 内核时，内核跑不到 userspace，而且没有任何观测通道」。
换 U-Boot 就是为了把观测通道建起来 —— 代价是 §5 里选 A 时那套 boot.img 打包逻辑作废
（参考项目在这台机器上用的就是 U-Boot → systemd-boot）。

### 10.1 怎么刷（两条命令，缺一不可）

```bash
fastboot flash boot work/uboot/u-boot.img    # 671 744 B，v0 头 + gzip 的 U-Boot
fastboot erase dtbo                          # 不清就 6 秒回 fastboot
fastboot reboot
```

`u-boot.img` 来自 `GengWei1997/linux-xiaomi-raphael-uboot` 的 v1.0.0 发布包
（`u-boot-sm8150-xiaomi-raphael-20260911.zip`，sha256 `ba6548b5…b992`）。
它的头部是 v0 + gzip，和我们最早被 ABL 拒掉的那版是同一种封装，但**它能跑**。
差别不在封装，在 `dtbo`：清掉之后 ABL 放行。

结果：**面板上出现完整的 U-Boot 日志**，`Model: Xiaomi Redmi K20 Pro` 识别正确。
观测通道这一关过了。

但 **USB 侧什么都没有**：`fastboot devices` 和 `adb devices` 全空。
面板是单向的 —— 看得见，敲不进去。这是这版 U-Boot 的硬约束，后面所有方案都得绕着它走。

### 10.2 它看到的是 6 个 LUN，不是分区

```
scanning bus for devices...
Device 0: (0:0) SAMSUNG KLUFG8R1EM-B0C1  481896.0 MB (123365376 x 4096)
Device 1: (0:1)  8 MB   Device 2: (0:2)  8 MB   Device 3: (0:3) 32 MB
Device 4: (0:4)  6 GB   Device 5: (0:5) 32 MB
Created "root"
Block 0x0+0x752a7fb mapped to block 0x7c000 of "scsi 0"
Cannot persist EFI variables without system partition
Loading Boot0000 'scsi 0' failed ... Boot0005 'scsi 5' failed
Loading Boot0006 'blkmap 0' failed
```

`scsi 0` 是**整块主 flash**（123 365 376 个 4096 字节块），不是某个分区。
`0x7c000` 是解开的钥匙：它正好是 `userdata` 的起始 LBA（见 10.3），
所以 U-Boot **确实解析了 GPT**，并且给最后一个分区建了一块 blkmap（名字 "root"）。

### 10.3 这台机器的 GPT 在 4K LBA 上

| 位置 | 值 |
|---|---|
| GPT 头 | 偏移 **4096**（不是 1024） |
| 分区表 | 偏移 8192，32 条目 × 128 B |
| 分区数 | 31 |

节选（LBA 按 4096 字节）：

| # | 分区 | 起始 LBA | 字节偏移 | 大小 |
|---|---|---|---|---|
| 11 | `misc` | 1024 | 4 194 304 | 4 MiB |
| 21 | `splash` | 32604 | 133 545 984 | 32.6 MiB |
| 28 | `recovery` | 163840 | 671 088 640 | 64 MiB |
| 29 | `cache` | 180224 | 738 197 504 | 256 MiB |
| 30 | `cust` | 245760 | 1 006 632 960 | 1024 MiB |
| 31 | `userdata` | **507904 = 0x7c000** | 2 080 374 784 | 479 912 MiB |

这一条要记牢：`sgdisk` 默认按 512 字节 LBA 干活，对这张表**读不到**。
要动就按 4096 当块长，或者直接按字节偏移读写（`work/gpt.bin` 前 256 KB 已备份）。

### 10.4 启动盘刷进去了，但没被尝试

做了一块 256 MiB FAT32（正好等于 cache）：`Image` + DTB + `extlinux/extlinux.conf`，
用 `make-raphael-bootfs.sh` 生成，`fastboot flash cache` 写进去了。U-Boot 的启动候选里
**一个都没有 cache** —— 只试了 `scsi 0..5` 和 `blkmap 0`。

同一个现象的另一半是 EFI：它打完 `Cannot persist EFI variables without system partition`
就去试 UEFI 启动项。而 `cache` 的类型 GUID 是 `5594c694-c871-4b5f-90b1-690a6f68e0f7`
（高通自定义的 cache），不是 ESP（`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`）。

**当前最合理的假设**：这版 U-Boot 的 bootstd 只按「整块设备」建 bootdev，不把 GPT
分区当成候选；唯一会按 GUID 去找的是 ESP。`cache` 两条都不满足，于是被跳过。
未验证，别当结论用。

> 后来的走向和这一节猜的不同：从 `u-boot.bin` 里读出默认环境之后才知道它有个
> `bootmenu`，第 4 项就是 `run fastboot`。走那条通道比改 GPT / 插键盘都省事，
> 所以 §10.5 的两条路**都没有再走**。真正用上的方法是 §12。

### 10.5 下一步（按代价排序）

1. **USB 键盘**（USB-C OTG）。插上重启，U-Boot 的 USB host 会认出来，在 `=>` 下敲
   `part list scsi 0` / `ls scsi 0:29 /` / `booti` 就能把问题问清楚，也能当场手工启动一次内核。
   这是唯一能立刻消除不确定性的手段。
2. **改 GPT 类型**：把 `cache` 的 type GUID 换成 ESP，重算 header 与 entries 的 CRC，
   用 root 的 `dd` 按字节偏移写回（备份 `work/gpt.bin`）；FAT 里再加
   `/EFI/BOOT/BOOTAA64.EFI`（systemd-boot aarch64，可从 Fedora 的
   `systemd-boot-unsigned` aarch64 包里取）。这条路要一轮 Android 往返。

## 11. 恢复 Android（每次都一样）

```bash
fastboot flash boot work/raphael-facts/stock-boot.img
fastboot flash dtbo work/raphael-facts/stock-dtbo.img
fastboot reboot
```

33 秒回到 Android，两个分区的 sha256 与备份逐字节一致（`b794c34b…`、`f921ddda…`）。
`cache` 里那块 FAT 不用管：Android 不挂载它，也不影响启动（已验）。

进不去 fastboot 时的逃生路见 §8.1：recovery 里的 adb 是 root，`adb push <文件> /dev/block/sde49`
（boot）/ `sde45`（dtbo）可以直接写块设备；推 `/cache` 会「报告成功但文件不存在」。

## 12. 阶段 1 通了：U-Boot 的 fastboot + 2MB 对齐 + 应急 shell

这一节是 11-07 下午的整条链路。结论先给：**内核进了 userspace，root shell 在 COM4 上**。

### 12.1 那版 U-Boot 的默认环境（从 u-boot.img 里读出来的）

`u-boot.img` 是 v0 头 + gzip。解开（`zlib.decompressobj(16+MAX_WBITS)`，尾部还有
107 KB 的 DTB）之后从 1.4 MB 的 `u-boot.bin` 里能直接读到默认环境：

```
bootdelay=0
stdin=serial,button-kbd                 ← 没有 usbkbd，键盘无论怎么插都不行
stdout=serial,vidconsole
bootcmd=bootefi bootmgr; pause; run menucmd
menucmd=setenv bootcmd run menucmd; bootmenu -1     ← -1 = 无限等
preboot=scsi scan; run setup_rootdev; run setup_blkmap
fastboot=fastboot -l $fastboot_addr_r usb 0
serial_gadget=setenv stdin serial,button-kbd,usbacm; ...
```

启动菜单（`bootmenu_N`）一共 11 项，其中三项有用：

| 项 | 内容 |
|---|---|
| 1 | `Enable serial console gadget` |
| 2 | `Enable USB mass storage`（`ums 0 scsi 0`） |
| 3 | **`Enable fastboot mode`（`run fastboot`）** |

菜单是 `button-kbd` 驱动的——**音量键和电源键**（`key-vol-up`=115、`resin`=114、
`pwrkey`=116）。所以即使没有键盘也能操作菜单，这是这条路能走通的前提。

### 12.2 迭代方式：`fastboot boot`，不写任何分区

选第 4 项之后，U-Boot 变成一个 fastboot 设备：

```
fastboot devices        → f4be9589  fastboot
version-bootloader     → U-Boot Tauchgang 2026.10-rc4-gc3cb35371
```

`fastboot flash` 在这里没用（`invalid partition or device`——它同样不认识 GPT 分区），
但 **`fastboot boot <img>` 可用**：把镜像下到 DRAM 里直接跑。**全程不写任何分区，
失败了长按电源就回到原状态。** 这是本轮最快的一条迭代通道，比刷 boot 分区安全得多。

### 12.3 三个非显然的必要条件

**（1）镜像必须是 Android boot header v2。** U-Boot 的 `fastboot boot` 走 `bootm` 的
Android 镜像解析，v1 会报：

```
Error: header_version must be >= 2 to get dtb
Working FDT set to 0
FDT and ATAGS support not compiled in
** ERROR: Please RESET the board **
```

v2 在 v1（1648 B）后面多 `dtb_size`(4) + `dtb_addr`(8)，共 1660 B，然后把 DTB 作为
独立段放在 recovery_dtbo 之后。`external-and-mods/kernel-common/mkbootimg-v2.py` 就是
干这个的。

**（2）内核必须落在 2MB 对齐的物理地址上。** 这是 arm64 启动协议的要求，不满足时
内核连第一张页表都建不起来，表现是 `Starting kernel ...` 之后**一个字都没有**、
USB 也不恢复——和「内核根本没跳」看起来一模一样。

`fastboot boot` 把镜像放在 `$fastboot_addr_r`＝`0x253400000`（2MB 对齐），但内核在
镜像内的偏移是 `page_size`。U-Boot 打印过：

```
Kernel load addr 0x253401000      ← page_size = 4096，只对齐到 4KB
```

所以把 **header 的 `page_size` 写成 `0x200000`**，内核段就落在镜像内偏移 2 MB 处，
加载地址变成 `0x255400000`，正好 2MB 对齐。这一改，内核当场就起来了。

**（3）命令行要能被引导器覆盖。** 内核的 `CMDLINE` / `CMDLINE_FORCE` / `CMDLINE_EXTEND`
在 Kconfig 里是一个 **choice**（三选一）。只写两个 `=n` 会把 choice 清成非法的
「全空」，`olddefconfig` 会回填 `CMDLINE_FORCE=y`，等于没改。正确的是把目标成员
写成 `y`：

```
CONFIG_CMDLINE_FROM_BOOTLOADER=y
CONFIG_CMDLINE_FORCE=n
CONFIG_CMDLINE_EXTEND=n
```

另一个坑：`kernel-common/build.sh` 的片段合并**只认 `NAME=value`，跳过 `#` 开头的行**，
所以 `# CONFIG_X is not set` 这种 Kconfig 惯例写法在这里是**无效**的，必须写 `=n`。

### 12.4 第一次进 userspace，和它暴露的两件事

对齐之后的那一屏：8 只 Tux、DPU/DSI/Adreno 依次 probe、`Run /init as init process`、
`configfs-gadget ... NCM` 注册，然后：

```
root mount failed
Kernel panic - not syncing: Attempted to kill init!
```

两个问题，都在这一屏里：

1. **init 的应急 shell 只对 REDMAGIC 6 生效。** `initramfs/init` 里写的是
   `if grep -qa "REDMAGIC 6" .../model`，raphael 不匹配 → PID 1 直接 `exec sh`，
   没有控制终端 → 退出 → 内核 panic。改成 `[ "$usbshell" = 1 ] || <REDMAGIC 条件>`
   之后，同一个镜像起来就有一个常驻 shell 挂在 ttyGS1 上。
2. **`/proc/partitions` 是空的。** `CONFIG_SCSI_UFS_QCOM=m`、`CONFIG_PHY_QCOM_QMP_UFS=m`
   ——都是模块，而 boot 镜像只带内核不带模块，手机等于没有存储。改成 `=y`（这一条
   正在编）。

### 12.5 现在的验收状态：能进去，并且能说话

应急 shell 在 USB 串口上（`VID_1D6B:0104`，产品串 `STEAMOS-ARM-DEBUG`）：

| 口 | 用途 |
|---|---|
| COM3 | `acm.usb0`，内核 console |
| COM4 | `acm.usb1` / `ttyGS1`，**交互 shell** |

Windows 上不需要装任何驱动、也不需要管理员权限，`System.IO.Ports.SerialPort` 直接开：

```
~ # id
uid=0 gid=0
~ # uname -a
Linux (none) 7.3.0-raphael-steamos #5 SMP PREEMPT Sat Nov  7 07:52:44 UTC 2026 aarch64
~ # free -m
Mem:  7462 MB total      ← 我们的内存映射对了（ABL 实测那份）
~ # grep -c processor /proc/cpuinfo
8
```

同一条链路上还有 NCM 网卡（`02-16-42-00-00-02`，配 `172.16.42.2/24` 之后
`ncat 172.16.42.1 23` 是同一个 shell），但**在 Windows 上给网卡加静态 IP 需要管理员**，
所以串口是更省事的那条。

### 12.6 每天的固定动作

```bash
# 1. 编（容器，源码与工具链都在 raphael-work 卷里）
./build-raphael-kernel.sh          # 或 work/wslc-build.sh（这台机器用的）

# 2. 打镜像（v2 头 + 2MB 页）
python3 external-and-mods/kernel-common/mkbootimg-v2.py \
  --kernel work/kernel-raphael/output/7.3.0-raphael-steamos/boot/Image \
  --dtb    work/kernel-raphael/output/7.3.0-raphael-steamos/dtbs/sm8150-xiaomi-raphael.dtb \
  --cmdline "console=tty0 loglevel=7 ignore_loglevel steamos.usbshell=1" \
  --pagesize 0x200000 --out work/steamos-raphael/boot-v2-2mb.img

# 3. 手机上：长按电源 10 秒 → 开机 → 菜单选 Enable fastboot mode
fastboot boot work/steamos-raphael/boot-v2-2mb.img

# 4. 电脑上开 COM4
```

第 3 步每次都要人按菜单——这是当前唯一的低效点（`bootdelay=0`，靠按键打断 autoboot
不可能）。等能动 `boot` 分区之后，把 U-Boot 本体 + 一个能自动选 fastboot 的环境
写进去就能免掉。

## 13. 下一步：存储，然后是 rootfs

### 13.1 存储：UFS 必须作为模块加载，不能编进内核（已实测）

`/proc/partitions` 为空的原因找到了：`CONFIG_SCSI_UFS_QCOM` 和
`CONFIG_PHY_QCOM_QMP_UFS` 在树里那份 defconfig 里是 `=m`，而 boot 镜像只带内核。

**但是改成 `=y` 会让内核在显示初始化之前直接死掉**：屏幕全黑、USB 上什么都不出现、
连 gadget 都来不及起——固件/时钟/PHY 的时序在 early probe 里炸，而那一刻还没有任何
控制台可以说话（`console=tty0` 要等 simpledrm 起来）。

所以正确做法是「**模块 + initramfs 里 insmod**」：先让控制台和 USB 立起来，再加载
UFS，出问题能看见。改动点在 `kernel-common/build.sh` 的 `build_initramfs()` ——
它现在只打 busybox 和三个脚本，需要在 `modules_install` 之后把
`phy-qcom-qmp-ufs.ko`、`ufs_qcom.ko`（按依赖顺序）塞进 initramfs 的
`/lib/modules/<release>/`，并在 `initramfs/init` 里 insmod。

注意构建顺序：`build_initramfs` 在编内核之前调用，所以要二次嵌入
（modules_install → 重打 cpio → 再 make 一次 Image）。

### 13.2 rootfs

存储通了之后才是阶段 2：把 SteamOS rootfs 写进 `userdata`（ext4），
`init` 已经会按 `steamos.root=PARTLABEL=userdata` 去挂。这一步会**覆盖 Android 的
/data**，不可逆，必须让本人确认。

### 13.3 现在能复现的状态

- `work/steamos-raphael/boot-v2-2mb.img`（56 623 104 B）：内核 51 255 808 B
  + DTB 104 670 B，v2 头、page_size 2 MB
- 刷法：U-Boot 菜单选 `Enable fastboot mode`，然后
  `fastboot boot work/steamos-raphael/boot-v2-2mb.img`
- 起来之后 COM4 是 root shell，`/proc/partitions` 仍然是空的（预期）
- 回 Android：`fastboot flash boot stock-boot.img` + `fastboot flash dtbo stock-dtbo.img`
