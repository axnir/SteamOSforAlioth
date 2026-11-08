# 把 scripts/raphael-overlay 里的文件按字节原样推到设备上，并清掉 /etc 下
# 手工写坏的 unit 影子文件。
#
# 为什么需要这个脚本：以前用 probe-ui.ps1 的“命令行文件”方式重建配置，
# 那个脚本会过滤掉空行和以 # 开头的行（本来是给命令用的），结果 unit 文件
# 变成 `ConditionPathExists=... [Service]` 这种粘连形态 —— ConditionPathExists
# 的路径多了一段 "[Service]"，条件不成立，unit 直接被 systemd 跳过
# （systemctl show 显示 ConditionResult=no，journal 里没有任何记录）。
# 所以文件传输必须走 base64，不能用命令行逐行 echo。
param(
  [string]$Root = 'D:\Developer\Repo\SteamOSforAlioth',
  [string]$PortName = 'COM3',
  [int]$ChunkWaitMs = 300,
  [switch]$SkipPush,
  [switch]$SetRegdom
)

$ErrorActionPreference = 'Stop'
$pwsh = 'C:\Users\moeka\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
$probe = Join-Path $Root 'work\probe-ui.ps1'
$cmdPath = Join-Path $Root 'work\_apply.cmd'

function New-CommandFile {
  param([string[]]$Commands)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllLines($cmdPath, [string[]]$Commands, $enc)
}

function Run-Commands {
  param([string[]]$Commands, [int]$WaitMs = 400)
  New-CommandFile -Commands $Commands
  & $pwsh -NoProfile -ExecutionPolicy Bypass -File $probe -CommandFile $cmdPath -PortName $PortName -WaitMs $WaitMs 2>&1
}

function Send-File {
  param([string]$LocalPath, [string]$RemotePath)
  $text = ([IO.File]::ReadAllText($LocalPath)) -replace "`r`n", "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("rm -f /tmp/_f.b64; mkdir -p `$(dirname '$RemotePath')")
  for ($i = 0; $i -lt $b64.Length; $i += 400) {
    $seg = $b64.Substring($i, [Math]::Min(400, $b64.Length - $i))
    $lines.Add("printf '%s' '$seg' >> /tmp/_f.b64")
  }
  $lines.Add("base64 -d /tmp/_f.b64 > '$RemotePath' && echo OK_$([IO.Path]::GetFileName($RemotePath))_`$(wc -c < '$RemotePath')")
  Run-Commands -Commands $lines.ToArray() -WaitMs $ChunkWaitMs | Select-String -Pattern 'OK_' | ForEach-Object { "  $_" }
}

$overlay = Join-Path $Root 'scripts\raphael-overlay'
$files = Get-ChildItem -Path $overlay -Recurse -File
Write-Output "overlay files: $($files.Count)"

if (-not $SkipPush) {
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($overlay.Length + 1) -replace '\\', '/'
    Write-Output "-> /$rel"
    Send-File -LocalPath $f.FullName -RemotePath "/$rel"
  }
  # base64 -d 建出来的文件是 644，unit 里直接 ExecStart=/opt/raphael/*.sh 的会起不来，
  # 而且 Windows 侧 checkout 成 CRLF 的 shebang 会让内核报 not found。两样一起修。
  $chmod = @('echo CHMOD')
  $chmod += "sed -i 's/\r$//' /opt/raphael/*.sh 2>/dev/null"
  # /usr/lib/steamos-arm/* 也要去 CR：Windows 侧 checkout 出来是 CRLF，而 shebang
  # 后面跟一个 \r 会让内核报 "bad interpreter" / 以 126 退出，unit 静默不跑。
  # 以前只处理了 /opt/raphael/*.sh，这里补齐。
  $chmod += "for f in /usr/lib/steamos-arm/raphael-*; do sed -i 's/\r$//' `"`$f`"; done"
  $chmod += 'chmod 755 /opt/raphael/*.sh /usr/lib/steamos-arm/raphael-firstboot 2>/dev/null'
  $chmod += 'chmod 755 /usr/lib/steamos-arm/raphael-game-tune /usr/lib/steamos-arm/raphael-charge-guard /usr/lib/steamos-arm/raphael-thermal /usr/lib/steamos-arm/raphael-macaddr 2>/dev/null'
  $chmod += 'ls -l /opt/raphael/*.sh /usr/lib/steamos-arm/raphael-*'
  $chmod += 'echo CHMOD_DONE'
  Run-Commands -Commands $chmod -WaitMs 800
}

# 清掉 /etc 下会盖住 /usr/lib 版本的手工副本
$stale = @(
  '/etc/systemd/system/tqftpserv.service',
  '/etc/systemd/system/rmtfs.service',
  '/etc/systemd/system/raphael-qrtr-ns.service',
  '/etc/systemd/system/raphael-rmtfs.service',
  '/etc/systemd/system/raphael-tqftpserv.service',
  # qcom 栈已经挪进 gadget.sh 的 ExecStart 末尾。这个 drop-in 在开机时会被
  # systemd 漏掉（DropInPaths 为空），留着只会让人误以为它生效了。
  '/etc/systemd/system/raphael-usb-gadget.service.d/50-qcom.conf'
)
$rm = @('echo CLEAN')
foreach ($s in $stale) { $rm += "rm -f '$s'" }
$rm += 'ls /etc/systemd/system/ | grep -E "^(raphael|tqftp|rmtfs)" || echo NO_LEFT'
$rm += 'systemctl daemon-reload'
$rm += 'systemctl enable raphael-qrtr-ns raphael-rmtfs raphael-tqftpserv raphael-usb-gadget 2>&1 | tail -n 6'
# 四个开机就要生效的守护：音频路由、游戏提频、充电看门狗、温度分档降频。
# audio-route 以前漏了 enable —— ASoC mixer 是易失状态，手工跑出来的声音一重启
# 就没了（FE 没有 BE，播放 EINVAL）。enable --now 顺便把当前这次也修好。
$rm += 'systemctl enable --now raphael-audio-route raphael-game-tune raphael-charge-guard raphael-thermal 2>&1 | tail -n 6'
# **enable 建的链接落在 /etc/systemd/system/*.wants，而 /etc 是 overlayfs**
# （lowerdir 是镜像里的 /etc，upper 在 /var/lib/overlays/etc/upper）。2026-11-08
# 实测：运行时 enable 的三个 unit，重启后 systemd 完全不知道它们存在
# （journal 里一条记录都没有，`systemctl show -p Wants` 里也没有），
# daemon-reload 之后才出现。qcom 三件套之所以还活着，是因为 qcom-setup.sh
# 自己 systemctl start 了它们，不是靠 wants。
#
# 解法是把链接放到 /usr/lib/systemd/system/multi-user.target.wants —— 那是
# 真实文件系统（root 上的 ext4），不受 /etc overlay 的读取时序影响。Valve
# 自己的 dbus / systemd-logind 等链接就在这里。
$rm += 'mkdir -p /usr/lib/systemd/system/multi-user.target.wants'
$rm += 'for u in raphael-audio-route raphael-game-tune raphael-charge-guard raphael-thermal; do ln -sfn /usr/lib/systemd/system/$u.service /usr/lib/systemd/system/multi-user.target.wants/$u.service; done'
$rm += 'ls -l /usr/lib/systemd/system/multi-user.target.wants/ | grep raphael'
$rm += 'systemctl daemon-reload'
$rm += 'for u in raphael-audio-route raphael-game-tune raphael-charge-guard raphael-thermal; do echo -n "$u "; systemctl show $u -p ActiveState -p ConditionResult --value | tr "\n" " "; echo; done'
# 蓝牙地址这一步不是 enable 出来的，而是 bluetooth.service 的 drop-in 拉起来
# 的（MGMT_OP_SET_PUBLIC_ADDRESS 只对未上电的控制器有效，顺序必须由 systemd
# 保证）。所以这里查的是「drop-in 有没有被读进去」，不是 ActiveState。
$rm += 'systemctl show bluetooth -p After --value | tr " " "\n" | grep -x raphael-macaddr.service && echo MACADDR_ORDERED || echo MACADDR_NOT_ORDERED'
$rm += 'systemctl show raphael-macaddr -p LoadState -p ActiveState --value | tr "\n" " "; echo'
# qcom 三件套**不能 restart**：2026-11-08 真机上 restart 之后老 rmtfs 进程没被
# 回收，还占着 qrtr 端口，新实例 bind 撞 Address already in use，NRestarts 涨到
# 170 —— 而 restart 对「互相依赖的三个进程」不是原子操作，旧进程释放端口和新
# 进程 bind 之间没有顺序保证。改成 stop → 等进程真的消失 → 按依赖顺序 start。
$rm += 'systemctl stop raphael-tqftpserv raphael-rmtfs raphael-qrtr-ns'
$rm += 'for i in $(seq 1 20); do pidof rmtfs qrtr-ns tqftpserv >/dev/null 2>&1 || break; sleep 0.5; done'
$rm += 'pidof rmtfs qrtr-ns tqftpserv && echo STILL_ALIVE || echo NO_RESIDUAL'
$rm += 'systemctl start raphael-qrtr-ns'
$rm += 'sleep 2'
$rm += 'systemctl start raphael-rmtfs raphael-tqftpserv'
$rm += 'sleep 3'
$rm += 'for u in raphael-qrtr-ns raphael-rmtfs raphael-tqftpserv; do echo -n "$u "; systemctl show $u -p ActiveState -p ConditionResult --value | tr "\n" " "; echo; done'
$rm += 'echo CLEAN_DONE'
Run-Commands -Commands $rm -WaitMs 1200

# 5GHz：把管制域钉成 CN（改 ESP 的 loader entry + 立刻 iw reg set）。
# 单独变成开关，是因为它会写引导项——不该跟"推配置"绑在一起默认执行。
if ($SetRegdom) {
  Write-Output "--- set regdom CN ---"
  Run-Commands -Commands @(
    'sh /opt/raphael/set-regdom.sh CN',
    'echo REGDOM_DONE'
  ) -WaitMs 1500
}
