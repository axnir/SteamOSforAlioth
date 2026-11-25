# OnePlus 8 Pro（instantnoodlep）音频 ADSP 卡点诊断：方案 A / B 结论

记录时间：2026-11-25 01:30 起，21:50 定稿。设备：OnePlus 8 Pro
（SM8250 / instantnoodlep，IN2020），内核 `7.2.8-sm8250-steamos`。
主文档是 [`README.md`](README.md) §32，本文件收拢这一轮 PAS/remoteproc
诊断的结论，不重复移植史。

> **用户决定（2026-11-25 21:50）**：「记录一下吧，不想折腾了」。
> 本轮到此停止，不再上机。设备保持现状（从 `boot_a` 调试内核启动），
> 未刷 bootloader、未动内核 Image。

---

## 0. 结论先行（最终）

**音频在这台 IN2020 上基本是 TrustZone 层硬限制，Linux 侧能调的都调完了。**
求助外部资源的两条路（刷 bootloader 更新 TZ / 拿到 TZ 认可的 adsp 固件形态）
代价都很高，前者违反现有硬规则，后者公开渠道没有。

卡点精确到 `qcom_scm_pas_mem_setup()`（PIL `PAS_MEM_SETUP`）返回 TZ 私有码
`0xffcfffba`，被 `qcom_scm_remap_error()` 压成 `-EINVAL`（日志里的 `-22`）。
TZ 原始码是靠本次专门打的内核补丁（`0039-firmware-qcom-scm-log-raw-pas-return.patch`）
在 remap 之前打印出来的。

**三个参数全部排除**：

| 变量 | 实验 | 结果 |
|---|---|---|
| 固件验签 | 5 份固件对照 | gh 那份 `init_image=0` 通过，其余 -22 |
| 地址 | probe 7 组 + 驱动路径 2 个不同地址 | 全部 `0xffcfffba` |
| size | probe 5 组（1 MiB – 37 MiB） | 全部 -22，`init_image` 每次都 0 |
| 驱动前置 | 换 gh 固件走真实驱动 | 仍卡 `mem_setup`，iommu/clock/power 救不了 |

**关键对照**：同一启动里 cdsp(pas_id=2)、slpi(pas_id=3) 的 `mem_setup`
都 `a0=0` 成功、`is now up`；只有 adsp(pas_id=1) 被拒。所以不是 PAS 命令
整体不可用，而是 **TZ 对 ADSP 这一路有设备特定限制**。这与更早"AYN 完整
mbn 能过 setting_up、唯独 OnePlus 自家固件被拒"的记录一致。

**关于方案 A / B 的历史口述更正**：曾说过"A 和 B 两条低成本路都走完了"
不准确——当时 B（`do_auth=1` 真启动 DSP）**未执行**。后来 A 的含义被扩展为
"扫 span 参数"并已执行（全 -22）。B 始终未执行，因为 `mem_setup` 在
`mdt_loader` 里是 `goto out` 的硬前置，probe 里虽无 `goto` 截断、
`auth_and_reset` 仍会执行，但在 mem_setup 全拒的前提下它的信息价值有限，
且有死机风险。用户决定停止，B 不再执行。

机型前提：本机是 **IN2020**（用户明确，`hardware.md` / `hardware-inventory.txt` /
`display-findings.md` 三处一致）。Nura 的音频验证是在 **IN2023** 上做的，
两者 TZ / bootloader 版本不同，不能用 Nura 的成功推断 IN2020 也能起。

---

## 1. 日志文本对应的内核层次（判据表）

| dmesg 文本 | 内核调用点 | 本轮实测 |
|---|---|---|
| `error -22 initializing firmware <name>` | `mdt_loader.c` 调 `qcom_scm_pas_init_image()`（固件准备 / TZ 验签） | 换 gh 固件后**消失** → 验签通过 |
| `error -22 setting up firmware <name>` | `mdt_loader.c` 调 `qcom_scm_pas_mem_setup()`（可重定位段内存区放置） | **仍然存在** → 最终卡点 |
| `error -22 initializing firmware`（AYN 那份旧记录） | 同上 `init_image` | 旧记录用整份镜像当 metadata，来源不可信（见 §3 第 2 轮） |
| `auth_and_reset -22`（旧记录） | `qcom_scm_pas_auth_and_reset()` | **本轮未测**，属方案 B |

`-22` 是 `qcom_scm_remap_error()` 把 TZ 原始返回码（如 `0xffcfffba`）压成的
`-EINVAL`，**不是签名被拒的同义词**。

---

## 2. 工具与环境（可复现）

源码树**不在仓库里**，而在 macOS 构建用的 docker named volume `op8p-build-work` 内：

```
/work/kernel-sm8250/linux-7.2.8        # SRC = $WORK/linux-$KVER
  .config / Module.symvers 都在（2026-11-22 09:09 编译留下）
```

推导链：`scripts/op8p-build-container.sh` 的 `WORK=/work/kernel-sm8250` →
`external-and-mods/kernel-common/build.sh` 的 `SRC="${WORK}/linux-${KVER}"`。
本机 `work/src-peek/` 只是读代码用的少量副本，不能编译。

编译（native aarch64；`CONFIG_MODULE_SIG is not set`，无需签名）：

```sh
cd /Users/moeka/Developer/SteamOSforAlioth/scripts/op8p-pas-probe
docker run --rm -v "$PWD/../..:/repo" -v op8p-build-work:/work \
  -w /repo/scripts/op8p-pas-probe op8p-build:43 \
  bash -c 'KDIR=/work/kernel-sm8250/linux-7.2.8 sh ./build.sh'
```

设备连接与传文件：

- `/dev/cu.usbmodem101` = ttyGS0 完整 root shell；`/dev/cu.usbmodem103` = initramfs 救援 shell。
- **串口 `--push` 推 12 KB 的 `.ko` 会卡死**（进程 SIGTERM）。大文件走 WiFi HTTP：
  设备 `192.168.5.21` ← 宿主 `192.168.5.7:8000`（`python3 -m http.server`），
  设备端 `curl -fsS -o /tmp/... http://192.168.5.7:8000/...`，用 sha256 校验。
- 最终模块：`scripts/op8p-pas-probe/op8p-pas-probe.ko`，sha256
  `23d44193b092bb8f4d2f33ed0d44c5a596dbbcbf258b58738a5ae4ae1a136348`。
  脚本 `run-on-device.sh` 的 `PHASE=1` 只跑裸 `mem_setup`，默认 `all` 跑验签 + `mem_setup`；
  `do_auth=1` 段永远只打印、不自动执行。

模块实现要点（避免重复踩坑）：

- `init_image` 的第 4 参数是 `devm_qcom_scm_pas_context_alloc()` 分配的
  `struct qcom_scm_pas_context *`；模块注册空 platform device 作载体，ctx 用 `void *` 传。
- 固件必须先经 `qcom_mdt_read_metadata()`（导出符号）提取 **ELF 头 + hash 段**，
  不能把整份 `.mbn` 传给 `init_image`（见 §3 第 2 轮）。
- `request_firmware_direct()` 的 device 不能传 NULL（`firmware_loader` 里有 `dev_dbg(device, ...)`）。
- 模块 init 故意返回 `-EAGAIN`，`insmod` 报 `Invalid argument` 是预期，结果只看 dmesg。

---

## 3. 实验链：哪几轮有效，哪几轮无效

| # | 实验 | 有效性 | 结论 |
|---|---|---|---|
| 1 | 裸 `mem_setup`（`PHASE=1`），9 组地址 | ❌ 无效 | 内核只在 `init_image` 成功后、对带 `QCOM_MDT_RELOCATABLE`（`BIT(27)`）的段调 `mem_setup`；裸调 -22 是预期。只证明 SCM 通道活着（`pre/post_shutdown` 恒 0）。 |
| 2 | `PHASE=all`，但把整份 15 MB 镜像当 metadata | ❌ 无效 | `init_image` 全 -22 是模块错误，不是固件问题。 |
| 3 | 修 metadata 后，五份固件对照 | ✅ 有效 | `adsp-gh.mbn` 的 `init_image` = **0**（首次验签通过），其余四份 -22。 |
| 4 | 用 gh 固件扫 7 组地址 | ✅ 有效 | `init_image` 全 0、`mem_setup` 全 -22 → 内存布局问题（Tab S6 式）排除。 |
| 5 | 方案 A：gh 固件设为默认，走真实驱动 | ✅ 有效 | 驱动同样卡 `mem_setup` → iommu/clk/power 前置救不了。 |

### 第 1 轮的坐标更正

矩阵初版用的 `0x8a100000` 是 raphael（SM8150）的 `adsp_mem`，这台机不存在。
op8p 真机 DT 是 `adsp_mem = memory@91b00000 + 0x2500000`
（`external-and-mods/kernel-sm8250/dts/sm8250-oneplus-instantnoodlep.dts:244`），
已从 `/sys/firmware/devicetree/base/reserved-memory/` 逐个读 reg 核实。
本机固件 `p_paddr` span = `0x1d00000`（29 MiB），18–19 个可重定位段。

### 第 3 轮：五份固件对照（同地址 `0x91b00000`、同 metadata 路径）

| 固件 | fw_size | metadata_len | `init_image` |
|---|---|---|---|
| `postmarketos/adsp.mbn`（本机拼接） | 15,523,964 | 8220 | -22 |
| **`postmarketos/adsp-gh.mbn`（GitHub pangwalla）** | 15,921,292 | 8220 | **0** ✅ |
| `postmarketos/adsp.mbn.ayn-bak` | 15,523,964 | 8220 | -22 |
| `qcom/sm8250/adsp.mbn` | 15,515,796 | 8300 | -22 |
| `qcom/sm8250/ayn/thor/adsp.mbn` | 15,523,964 | 8220 | -22 |

**推翻了先前"所有 OnePlus 固件都倒在验签"的记录**——那是整份镜像当 metadata 的
错误测法。TZ 的 trust root 认 GitHub 那份的 hash 段。

### 第 4 轮：7 组地址（`init_image` 全 0）

`0x91b00000` + span / 全容量、`0x98900000`（Tab S6 成功地址）+ 两种大小、
`0x8a100000`（raphael）、`0x8bb00000`（alioth）、`0xc0000000`（高内存）：
**`mem_setup` 全部 -22**。连 Tab S6 成功过的地址大小也一样拒 → 地址/容量不是原因。

---

## 4. 方案 A 的完整记录（已执行）

DTS `firmware-name` 确认为 `postmarketos/adsp.mbn`
（`/sys/firmware/devicetree/base/soc@0/remoteproc@17300000`）。
把验签通过的 gh 固件覆盖到该路径，原文件备份：

```
/lib/firmware/postmarketos/adsp.mbn          ← adsp-gh.mbn（sha 95b45c3a…）
/lib/firmware/postmarketos/adsp.mbn.orig-20261125  ← 原件（sha ccd2aae6…，可回滚）
```

在线触发（`echo start > /sys/class/remoteproc/remoteproc2/state`）：

```
[1984.095] remoteproc remoteproc2: powering up adsp
[1984.131] remoteproc remoteproc2: Booting fw image postmarketos/adsp.mbn, size 15921292
[1984.164] qcom_q6v5_pas 17300000.remoteproc: error -22 setting up firmware postmarketos/adsp.mbn
[1984.175] remoteproc remoteproc2: Boot failed: -22
```

`initializing firmware` 这一条**消失**了（验签确实过了），但停在 `setting up firmware`。
**A 排除**：驱动路径里的 iommu 映射 / clock / power domain 前置动作不能让这关通过。

副现象：这段时间 dmesg 里 slpi 反复 crash + recovering（已到 #47，
`dog_virtual_user.c ... stalled initialization`），与 adsp 无关，但会刷日志，排障要过滤。

---

## 4.1 方案 A 上机结果：TZ 私有错误码 `0xffcfffba`（2026-11-25 10:00）

用户确认后刷 `boot_a`（活动槽 b → 写 a）+ `set-active=a` 启动新内核。
`dmesg | grep PAS_RAW` 共 23 条，关键几条：

```
[    7.352] PAS_RAW: svc=0x02 cmd=0x01 a0=0x0                 ← INIT_IMAGE 成功
[    7.356] PAS_RAW: svc=0x02 cmd=0x02 a0=0x0                 ← 其他 DSP mem_setup 成功
[    7.522] PAS_RAW: svc=0x02 cmd=0x02 a0=0xffcfffba          ← 仅 ADSP 这次失败
[    7.523] remoteproc2: error -22 setting up firmware adsp.mbn
```

cmd 编号：`0x01`=INIT_IMAGE、`0x02`=MEM_SETUP、`0x05`=AUTH_RESET、`0x06`=SHUTDOWN。

**两个决定性发现**：

1. TZ **不是一律拒绝** `PAS_MEM_SETUP`——其他 DSP 的 cmd=0x02 全部 `a0=0x0`。
   "命令在这台 TZ 上不存在/被禁"的假设**排除**。
2. `0xffcfffba`（有符号 −3,145,798）**不是**五个标准 SCM 码
   （−1…−5）中的任何一个，是 **TZ 私有错误码**，被 `qcom_scm_remap_error()`
   默认分支压成 `-EINVAL`。这是 `-22` 的真实来源。

**结论修正**：卡点不是"命令不支持"，而是 TZ 对这一次特定 MEM_SETUP 返回了
设备私有错误。最可能指向 ADSP 保留区 / 上下文（本机 `memory@91b00000 + 0x2500000`）
与 IN2020 TZ 期望不符。probe 换地址全 -22 与之不矛盾：probe 没走驱动的
iommu/SMMU 映射，TZ 看到的上下文不同。

**`0xffcfffba` 查证结果（权威来源：Galaxy Tab S6 / SM8150 排障记录，
bentlybro.com）**：该码就是 TZ 在 PAS_MEM_SETUP 拒绝的私有码，含义是两个条件
同时强制——`size` 参数必须是固件 ELF 的 loadable span（不是保留区大小），
且区域不能与 TZ 已占用内存重叠；两种失败都回这个码，被
`qcom_scm_remap_error()` 压成 `-EINVAL`。Tab S6 靠把 adsp_mem 挪到
`0x98900000` + 39 MB 解决（改 4 行 DTS）。

**对照 IN2020——纠正一个错误推断**：曾以为"固件 p_paddr 与 adsp_mem 差
36 MB 导致拒绝"。**错**：固件带 `QCOM_MDT_RELOCATABLE`，p_paddr 只是链接基准，
TZ 本就会把它重定位到 adsp_mem，两者不同是正常的。

真正可疑的是 adsp_mem 的值：

| 来源 | adsp_mem | 结果 |
|---|---|---|
| mainline `sm8250.dtsi:853` | `0x8a100000` + `0x1d00000` | — |
| Nura（IN2023，音频能起） | **未改，沿用默认值** | 能起 |
| 我们（IN2020） | 删默认节点，改 `0x91b00000` + `0x2500000` | `0xffcfffba` |

只有我们改了这个值。且 `removed_mem`（`0x80b00000`–`0x8d80000`，两边相同）
恰好包住 mainline 的默认 adsp 区，却不含我们改后的区。这是支持性证据，
不是证明（removed_mem 是 Linux 侧 no-map，不等于 TZ 布局表）。

**下一步**：把 adsp_mem 改回 `0x8a100000` + `0x1d00000`，只重编 DTB +
重打包 boot，看 `PAS_RAW cmd=0x02` 的 a0 是否变 0。

## 5. 方案 B 的状态：未执行（含技术判据）

**事实**：本轮从未执行过 `do_auth=1`。探针脚本第 3 段只打印命令、不执行。

**更正**：上一轮说"B 已无意义"是过度推断。看模块源码，
`qcom_scm_pas_mem_setup()` 返回 -22 后**没有 `goto` 截断**，
`if (do_auth) qcom_scm_pas_auth_and_reset(pas_id)` 仍会执行。
所以 B 能独立回答一个尚未回答的问题：**TZ 是否接受 `AUTH_AND_RESET` 命令**。

若用户授权，命令：

```sh
insmod /tmp/op8p-pas-probe.ko pas_id=1 addr=0x91b00000 size=0x1d00000 \
    do_init=1 do_auth=1 fw_name=postmarketos/adsp-gh.mbn || true
dmesg | grep pas_probe
```

| 结果 | 解读 |
|---|---|
| `auth_and_reset = 0` | TZ 愿意启动 DSP，唯一障碍是 `PAS_MEM_SETUP` 这道门 |
| `auth_and_reset = -22` | 整个 PAS 启动链在这台机 TZ 上不可用，定性完成 |

**风险**：会真启动 DSP，可能导致死机重启。须用户明确决定，不自动执行。

---

## 6. 已排除 / 未排除

| 假设 | 状态 | 依据 |
|---|---|---|
| 固件签名 / trust root 不匹配 | **部分排除** | gh 那份 `init_image` = 0 |
| 内存区太小 / 地址冲突（Tab S6 式） | **排除** | 7 组地址（含 Tab S6 成功地址）`mem_setup` 全 -22 |
| 驱动前置（iommu / clock / power）缺失 | **排除** | 方案 A 真实驱动同样失败 |
| SCM 通道不通 | **排除** | `pas_shutdown` 恒 0，slpi / cdsp 正常 running |
| `PAS_MEM_SETUP` 命令在本机 TZ 不可用 / 需 bootloader 先初始化 | **未排除，最可能** | 所有证据汇聚于此 |
| `AUTH_AND_RESET` 是否可用 | **未测**（方案 B） | — |

---

## 7. 下一步选项（由用户判断，不自行执行）

| 选项 | 做什么 | 代价 | 判据 |
|---|---|---|---|
| **B** | 跑 `do_auth=1`（§5 命令） | 可能死机重启；不刷机 | 定性 `AUTH_AND_RESET` 是否可用 |
| **C** | 刷同型号 OOS 13 全套（`tz`/`abl`/`xbl`/`dsp`/`modem` 同时更新），让 TZ 与固件同版本 | **动 bootloader，有变砖风险，违反现有硬规则**；须本人明确授权 | TZ 版本更新后 PAS_MEM_SETUP 是否放行 |
| **接受现状** | 音频不可用，pipewire 继续走空目录绕过（§25.2） | 无 | — |

不推荐重新试"换固件 / 改 DTS"：第 3、4、5 轮已穷尽。

---

## 8. 当前设备状态（2026-11-25 01:30）

- `/lib/firmware/postmarketos/adsp.mbn` = gh 版（验签过但 `mem_setup` 仍 -22）；
  原件备份在 `adsp.mbn.orig-20261125`，随时可回滚。
- `adsp` remoteproc = **offline**；slpi / cdsp = running。
- 临时 HTTP 服务已关闭；设备仍开着。
- **全程未启动 DSP（方案 B 未跑）、未刷任何分区、未改内核源码树。**
