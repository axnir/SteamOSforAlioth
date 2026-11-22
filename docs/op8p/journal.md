# op8p 折腾记录

这份文档记**过程**：试了什么、为什么不行、怎么绕过去。
结论性的内容（怎么构建、怎么刷机、验收状态、待办清单）在
[README.md](README.md)，不要混进来。原始 sysfs 转储在
[hardware-inventory.txt](hardware-inventory.txt)。

格式与 `docs/alioth-journal.md` 一致：每条一个小节，日期 + 在做什么。
失败的尝试一样要留着——它们是这份文档的主要价值。

---

## 2026-10-25 立项：纸面工作与第一次真机启动

关键判断（结论在 README §0，过程要点）：

1. **直接参考 alioth**——alioth（sm8250-ac kona）和 OP8P（sm8250 kona）
   是同一代 SoC，显示走 msm/msm-drm、GPU 都是 a650，alioth 的九成经验
   可以直接搬。差异集中在面板（ANA6706 vs 三星 AMSED6 应对的那批）、
   触摸（S6SY761 vs 汇顶）、音频 codec（TFA987x vs WSA881x）。
2. **P4 第一次启动失败得很干净**（README §13）：ABL 拒绝的理由和 alioth
   一模一样——board-id / msm-id 不匹配。这台的实测值
   `dt_board_id=0000000800000000`、`dt_msm_id=0000016400020001`。
3. header v2 + 独立 dtb 段之后内核起来（README §17）。

## 2026-10-26 显示链：从全黑到花屏

三天里最大的坑全是 DCS 时序（README §18–§21）：`.clock` 算错、
panels 数据搬错一份。转折点是拿到 darknagel 的 Nura 移植
（`reference-nura-port.md`）做对照组——**同面板、同 mainline 路径、真机
1440×3168@120 已点亮**，前面所有推断一下子有了裁决依据。
已确认的问题清单单独沉淀在 `display-findings.md`。

## 2026-11-21 Steam 图形会话：九个故障串成一条链

纯黑到 Steam UI 卡了一整晚。九个故障按暴露顺序、各自的修法在 README §25.2
的表里，这里只记过程性教训：

- **没先查 alioth 记录，重踩了一遍已解决的问题**（`TimeoutStartSec`、
  steamwebhelper 判据）。alioth.md 10-24 那段早就写好了。这条教训之后
  升级成了硬约定：排障先翻 `docs/` 与 memory。
- gamescope 的音频死等是**行为特性不是 bug**：它只在「连得上但连不通」时
  卡死，把 `XDG_RUNTIME_DIR` 指到一个不存在的目录让它连接直接失败，
  它打条 warning 就继续跑。
- `mask steamvr.service` 会让 `steam.service` 以 `result 'dependency'`
  失败——mask 和 `Wants=` 不能这么混用，要用 drop-in 置空依赖。

## 2026-11-21 深夜 → 11-22 凌晨 回归事故：把能跑的系统改坏了

完整复盘在 README §27.3，这里记教训本身：

- 深夜按 §27.2 的逐段比对「推断」出 TZ 接受通用签名 zap，把两个脚本里
  本机签名的四件套换成了 linux-firmware 的 `.mbn`。逐段比对本身没错
  （b00/b02 相同、只有签名段不同），**错的是把「哪里不同」当成了
  「哪份可用」**——可用性必须查真机记录，而 `docs/alioth.md:1643`
  十天前就把答案写死了：TZ 拒收通用签名 PAS 镜像，报 `-22`。
- 302 次 `error -22`、sddm 反复 Removing display、屏幕纯黑——黑屏的
  观测判据（进程组 + swapchain + CEF 调试口）再次证明比「看屏幕」可靠。
- 镜像指纹方法：新旧镜像同为 15,937,536 B，光看大小分不出来；
  **前 4096 字节 sha256（含 ramdisk_size）**才是身份。

## 2026-11-22 00:24 恢复与验收

修好的镜像刷入 `boot_a`，屏幕回到 Steam 登录页。真机快照、5G 连网
（`Xiaomi_0A83_5G`，这一点 alioth 没做到）、阶段 2 温控/电量计在位，
全部记录在 README §28。

过程性新知识：

- COM4 是救援 shell：无 PATH、动态链接二进制直接执行报 not found
  （ELF 解释器按救援根解析）。正确姿势是 `/dbg/bin/busybox` +
  `chroot /proc/1/root /usr/bin/<命令>`，见 README §28.3。
- `grep -c` 数 steamwebhelper 会把 grep 自身数进去（得 9），
  `pgrep -c` 得 8 才是对的。
- 剩余 2 条 `-22` 是音频 DSP 固件缺失，**不是回归**，列为待办 #1。

## 下一站的路线（过程视角）

按 README §29 的难度序（低→高）：触摸真机验证 → 充电驱动移植（参照
alioth §2591）→ 音频（先做固件四件套提取，照 GPU zap 的成熟做法；
真正的硬骨头是 TFA98xx 扬声器通路）。每一步都先读 alioth 对应章节，
再动手。另：刷 b 槽做双槽冗余只要一条 fastboot 命令，下次刷机顺手做。

## 2026-11-22 深夜 充电：三次误判、一次悬空引脚、一个数据手册条款

过程（结论在 README §30，这里记弯路）：

1. **"驱动缺"**——§26 里写的结论。实际 ROCKNIX 0004/0011 一直把
   `qcom_pm8150b_charger.c` 带在内核里，配置也开着。真机 dmesg 是
   `deferred probe pending: failed to register power supply`。
2. **"typec 没启用导致 defer"**——这个是对的，修完充电器真的上线了。
3. **"gauge 温度 52 °C 导致过温禁充"**——也对，但接着猜"芯片可能是
   bq27411 被 b27541 表读错"——**错了**。i2c 寄存器转储（用户一句
   "电量一直是 37% 你不觉得奇怪吗"逼出来的关键实验）证明四张表自洽，
   芯片就是 bq27541。真正的问题是手册里那一句：TEMPS 位默认读 TS 引脚，
   而这块板没接热敏电阻。

这轮的元教训：

- **先查手册再看寄存器**。TI SLUS861 里 TEMPS 位的行为一句话就解释了
  全部症状，比任何猜测都快。
- 用户的直觉（"37% 恒定很奇怪"）是对的信号：净电流≈0 能解释 SOC 不动，
  但解释不了"瞬时电流"恒为 −2142 mA。**恒定的瞬时值 = 缓存或坏传感器**，
  沿这两条线查必然出结果。
- i2cget 在设备上现成有，`-f` 强制访问被内核占用的地址，chroot 进
  /proc/1/root 跑。十分钟拿到裁决级证据。
