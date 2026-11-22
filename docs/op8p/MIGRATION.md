# OP8P 换机迁移指南（2026-11-22，当前状态：macOS）

换电脑时按本清单操作。**`work/` 整个目录被 `.gitignore` 挡住，git clone 不会带走它**——迁移方式：**直接复制文件夹**（整个仓库目录，或至少 `work/` + `.workbuddy/`），不需要打包和校验。

## 1. 仓库（git 管理，复制或 clone 即得）

- 仓库：`SteamOSforAlioth`，工作分支 **`op8p-display`**
- 关键内容：`docs/op8p/`（结论）、`external-and-mods/kernel-sm8250/`（补丁 0029–0038 + DTS + 配置）、`scripts/`（构建/调试工具）、`make-op8p.sh`（打包入口）、`flash-op8p.sh`（刷机入口）

⚠️ **拷贝后先查行尾**：Windows 那台把工作树变成了 CRLF（110 个文件），
`git status` 会显示整棵树脏、但 `git diff --ignore-cr-at-eol` 为空。那就是
纯行尾，`git checkout -- .` 复原即可。**不要**带着 CRLF 去构建 ——
`initramfs/init` 的 shebang 带 `\r` 会让内核 exec 失败（起不来），overlay 里的
脚本会以 126 退出。判据与细节见 `README.md` §34.1。

## 2. work/ 与 .workbuddy/（手动复制，git 里没有）

复制时**可以排除**（均可再生）：

- `work/steamos-op8p/userdata.img`（12.9 GB）——`make-op8p.sh` 可重建
- `work/steamos-20261002.6232440/rootfs.img`（10 GB）——SteamOS 原始介质
- `work/kernel-sm8250/output/` 与 `output-*`——重编即可（macOS 上增量 29 秒，
  全量 7 分钟，见 §4）

**以下必须带上**：

| 内容 | 用途 |
|---|---|
| `work/op8p-firmware/` + `work/upload/` | **机内签名 zap 四件套（唯一副本，GPU 固件命脉，丢了无法再生）** |
| `work/rocknix-20261001/` | **构建依赖**：`build.sh` 校验它的 git 版本（`20261001`），没有 `.git` 直接 die |
| `work/steamos-op8p/`（img + ramdisk） | 可刷镜像与 GPU ramdisk |

其余：`work/ref-instantnoodlep/`（Nura 参考）、`work/stage1/`、`work/fftool-src/`、
串口/传输脚本、`wslc-op8p-*.sh`（Windows 用）。另把 `.workbuddy/`（项目记忆）一起拷走。

### 已删除且不可再生（2026-11-22 清理）

- `work/raphael-facts/`（raphael 原厂 boot/dtbo 唯一备份，原分区已被覆盖）——raphael 项目如需回原厂已无备份
- `work/steamos-raphael/`、`work/kernel-raphael/` 等 raphael 全部产物

## 3. 新机环境（macOS / Apple silicon）

- **docker**（colima 提供）：`colima start`、`docker context use colima`。
  colima 是 aarch64 VM，内核构建因此是**原生 aarch64**（容器里 `uname -m` 是
  `aarch64`），不传 `CROSS_COMPILE`
- **fastboot / adb**（`brew install android-platform-tools`）
- **dtc**（`brew install dtc`）——`assert-op8p-stage2.sh` 用它反编译产出的 dtb，
  确认节点真的进了产物；没有它那条检查会 SKIP（不假装通过）
- **PowerShell 相关脚本（`*.ps1`、`op8p-sh.ps1`）在这台机器上用不了**

### 旧机器（Windows）的环境，留档

Git Bash + wslc 容器 CLI（`/c/Program Files/WSL/wslc`）+ 镜像
`proxy.vvvv.ee/library/fedora:43`；Windows 原生 Python 在 PATH（`make-op8p.sh`
的 `python3w()` 依赖 `cygpath`）；串口 COM3 = ttyGS0 内核 console、COM4 =
ttyGS1 root shell（免驱动），工具 `scripts/op8p-sh.ps1`；PowerShell 7 必装。

## 4. 构建 / 打包 / 刷机速查（macOS）

```bash
# 内核（容器内：装依赖 → 取 busybox → 去 CRLF → build.sh sm8250 → 带回 output/）
./scripts/op8p-build-docker.sh              # 增量（首次自动建工具链镜像，~1.5 GB）
./scripts/op8p-build-docker.sh --clean      # 删 /work 卷，从零全量
./scripts/op8p-build-docker.sh --shell      # 进同一套挂载的 shell 排查
./scripts/op8p-build-docker.sh --bare       # 不用工具链镜像，验证脚本自足

# 断言（刷机前；flash-op8p.sh 自己也会跑前两类）
for t in scripts/assert-op8p-*.sh; do "$t" || echo "FAILED: $t"; done

# 打包 boot 镜像（打完自动跑 assert-op8p-boot-image.sh）
./make-op8p.sh --gzip

# rootfs（都在容器里做，宿主不需要 e2fsprogs）
./make-op8p.sh --verify     # 只读校验现有 userdata.img（已实测）
./make-op8p.sh --install    # 生成 userdata.img（解包 10 GB + 12.9 GB 输出）

# 串口（macOS：两个 ACM 口名字一样，先 --list 再试哪个是 root shell）
./scripts/op8p-sh.py --list
./scripts/op8p-sh.py 'uname -a'

# 刷 b 槽
fastboot flash boot_b work/steamos-op8p/boot-op8p-gzip.img
fastboot erase dtbo_b
fastboot --set-active=b
fastboot reboot
```

⚠️ 刷机动作等用户确认后再执行（约定）。

### macOS 上还没搬过来的

| 功能 | 现状 |
|---|---|
| `make-op8p.sh --install` / `--verify` | **已搬**：`scripts/op8p-rootfs-docker.sh` 在容器里做（`--verify` 已实测，`--install` 未实测） |
| 串口 | **已搬但真机未验证**：`scripts/op8p-sh.py`（pty 上端到端测过；真机要 `--list` 后确认哪个口是 shell） |

### 已经在 macOS 上验证过的

- `./scripts/op8p-build-docker.sh`：全量 7 分 19 秒 / 增量 29 秒
- `./make-op8p.sh --gzip`：打包 + 自动跑 `assert-op8p-boot-image.sh`
- `./make-op8p.sh --verify`：7 组检查全 ok（12.9 GB 镜像）
- `./flash-op8p.sh --test` 的门禁：断言通过后才碰设备（用假 fastboot 验证过顺序）

## 5. 设备当前状态（2026-11-22）

- **b 槽在用**（fg-primary + bq27411 镜像）；a 槽保留 00:24 验收的可用镜像作退路
- **已通**：显示/GPU/WiFi 5G/充电（双电量计 90–94% 真实读数）/触摸/手电筒/温控/按键/时区（Asia/Shanghai）
- **挂起**：aw8697 FF 链路 ioctl RC=0 但无手感（probe 已成功、`play_effect` 路径待查，§33）
- **adsp 三选一待决**：modem_b 对比 / 用户提供 OTA 备份 / 转 Venus（README §32.5）
- **本轮重编的内核（gcc 15.3.1）与已验收镜像不是同一个二进制**，
  配置契约一致但工具链版本不同（README §34.3）。要刷它就必须重新验收，
  旧的已验收产物在 `work/kernel-sm8250/output-1126-accepted/`

## 6. 排查铁律（历史教训，勿再犯）

1. 排查前先读 `docs/op8p/README.md` 对应章节 + memory——不要在已解决问题上试错
2. 取舍类动作先报事实和选项给用户拍板，不要自行推进
3. 串口写文件一律 base64 分块推送；救援 shell 无 PATH，命令用 `/dbg/bin/busybox`
4. 「寄存器自洽」不能当芯片身份证据——身份判据 = DeviceType + 独立第三方交叉验证
5. 「能编译、能启动」不等于「功能对」：aw8697 的 reset 极性、bq27541 的寄存器表、
   CRLF 的 shebang，三件事都是编得过、起得来、功能全错
6. 物理反馈动作（闪光灯/震动）先问后触发、触发后马上停
