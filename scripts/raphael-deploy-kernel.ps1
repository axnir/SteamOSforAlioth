# 把一个新编的内核 Image 装进设备已经在用的 ESP，不碰 boot 分区。
#
# 为什么单独一个脚本：Image 是 100 MB，串口 base64 大约 1 KB/s，要一天。
# 走 USB NCM（169.254.240.121，usb0）用 netcat，实测 30 MB/s，几秒钟。
#
# 这条路径**不刷任何分区**：内核是 ESP 上的一个普通文件 linux.efi，systemd-boot
# 从 loader/entries/steamos.conf 的 `linux /linux.efi` 读它。U-Boot 在 boot 分区
# （sde49）里，全程不动 —— 所以换坏了也只是换回备份文件的事，不会变砖。
#
# ESP 平时不挂载（steamOS 的 efi.mount 被我们从镜像里删掉了），所以这里要自己
# 用 losetup 建一个偏移环设备。**-b 512 是必须的**：设备的分区表是 4K LBA，
# 但分区内容是 FAT32，按 512 读才对得上（sgdisk 的默认值同理）。
param(
  [string]$Image = '',
  [string]$PortName = 'COM3',
  [string]$DeviceIp = '169.254.240.121',
  [int]$NetPort = 9999,
  [switch]$SkipFlash,     # 只上传并校验，不写 ESP（先看 md5 再决定）
  [switch]$KeepBackup,
  # 一起更新的模块，路径相对 modules/<ver>/。例如
  #   -Module kernel/drivers/bluetooth/btqca.ko
  # **只换 Image 不换模块是本项目踩过的真坑**：uname -r 不变，所以 rootfs 里
  # 的旧 .ko 照样被 insmod/modprobe 用，补丁看着「没生效」。见 docs §32.5。
  [string[]]$Module = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Image) {
  # output/current 是 Linux 侧建的符号链接，Windows 上 Test-Path 对它会返回
  # false（路径存在但 reparse point 不被当作普通目录）。所以显式退到真实目录。
  $Image = Join-Path $root 'work\kernel-raphael\output\current\boot\Image'
  if (-not (Test-Path -LiteralPath $Image)) {
    $ver = Get-ChildItem (Join-Path $root 'work\kernel-raphael\output') -Directory |
      Where-Object { $_.Name -like '7.*' } | Select-Object -First 1
    if ($ver) { $Image = Join-Path $ver.FullName 'boot\Image' }
  }
}
if (-not (Test-Path -LiteralPath $Image)) { throw "找不到 Image: $Image" }

$src = (Resolve-Path -LiteralPath $Image).Path
$size = (Get-Item -LiteralPath $src).Length
$md5 = (Get-FileHash -LiteralPath $src -Algorithm MD5).Hash.ToLower()
Write-Host ("Image: {0} ({1:N1} MiB) md5={2}" -f $src, ($size / 1MB), $md5)

function Send-Serial([string[]]$cmds, [int]$waitMs = 1500) {
  $p = New-Object System.IO.Ports.SerialPort $PortName,115200,None,8,One
  $p.ReadTimeout = 3000; $p.WriteTimeout = 3000
  $p.Open()
  $acc = ''
  try {
    $p.Write("`n"); Start-Sleep -Milliseconds 400; $null = $p.ReadExisting()
    foreach ($c in $cmds) {
      $p.WriteLine($c)
      Start-Sleep -Milliseconds $waitMs
      $acc += $p.ReadExisting()
    }
  } finally { $p.Close(); $p.Dispose() }
  $acc
}

# --- 1. 上传 -----------------------------------------------------------------
# 走 nc 而不是 scp：USB NCM 的链路是 169.254.240.121（usb0），设备侧只有
# busybox，nc 是唯一稳定存在的东西。串口只用来「起监听 / 收尾巴」。
function Send-Blob([string]$localPath, [string]$remotePath) {
  $null = Send-Serial @("rm -f $remotePath", "busybox nc -l -p $NetPort > $remotePath &") 900
  $client = New-Object System.Net.Sockets.TcpClient
  $client.NoDelay = $true
  $client.SendBufferSize = 1MB
  $client.Connect($DeviceIp, $NetPort)
  $stream = $client.GetStream()
  $fs = [IO.File]::OpenRead($localPath)
  $buf = New-Object byte[] 262144
  $sent = 0
  while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
    $stream.Write($buf, 0, $n); $sent += $n
  }
  $stream.Flush(); $fs.Dispose()
  Start-Sleep -Milliseconds 600
  $client.Close()
  Write-Host ("  发出 {0:N1} MiB -> {1}" -f ($sent / 1MB), $remotePath)
}

$tmp = '/tmp/Image.new'
Write-Host '== 上传（USB NCM + nc）=='
Send-Blob $src $tmp

$chk = Send-Serial @("md5sum $tmp", "wc -c < $tmp") 2500
Write-Host $chk
if ($chk -notmatch [regex]::Escape($md5)) {
  throw "设备上的 md5 与本地不一致，不要再往下走"
}
Write-Host '  md5 一致'

# --- 1b. 模块（可选，但「改了驱动」时必须给）---------------------------------
# 内核版本号不变，设备上的 /usr/lib/modules/<ver>/ 里全是上一版的 .ko。只换
# Image 会让「驱动补丁」看起来完全没生效 —— 2026-11-08 蓝牙就在这里空转了一轮：
# Image 换了、dmesg 里还是老行为，因为加载进去的是旧 btqca.ko。
$treeDir = Split-Path -Parent (Split-Path -Parent $src)   # .../<ver>/boot/Image -> .../<ver>
$ver = Split-Path -Leaf $treeDir
$modRoot = Join-Path $treeDir 'modules'                   # .../<ver>/modules/<ver>/kernel/...
if (Test-Path -LiteralPath $modRoot) {
  # Image 走 -Image .../output/current/boot/Image 时，$treeDir 叫 "current"，
  # 真实版本号在 modules/ 下面唯一那个目录名里。
  $real = Get-ChildItem -LiteralPath $modRoot -Directory | Select-Object -First 1
  if ($real) { $ver = $real.Name }
}
$imageMtime = (Get-Item -LiteralPath $src).LastWriteTime
if ($Module.Count -eq 0) {
  Write-Host '== 模块：未指定（-Module），只更新 Image =='
  Write-Host '   如果这次改的是驱动/net/bluetooth 等以模块形式存在的部分，设备上仍是旧 .ko。'
  Write-Host "   例：-Module kernel/drivers/bluetooth/btqca.ko（相对 $modRoot\$ver）"
} else {
  Write-Host '== 上传模块 =='
  $staging = Join-Path $env:TEMP 'raphael-mods'
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  $relList = @()
  foreach ($m in $Module) {
    $rel = $m -replace '\\', '/'
    if ($rel -notmatch "^$([regex]::Escape($ver))/") { $rel = "$ver/$rel" }
    $p = Join-Path $modRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { throw "找不到模块: $p" }
    $dest = Join-Path $staging ($rel -replace '/', '\')
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    Copy-Item -LiteralPath $p -Destination $dest
    $relList += $rel
    Write-Host ("  + {0}  md5={1}" -f $rel, (Get-FileHash -LiteralPath $p -Algorithm MD5).Hash.ToLower())
  }
  $tgz = Join-Path $env:TEMP 'raphael-mods.tar.gz'
  if (Test-Path -LiteralPath $tgz) { Remove-Item -LiteralPath $tgz -Force }
  # -C 到 modules/ 打包，解包点就是 /usr/lib/modules/，路径自然对齐
  & tar -czf $tgz -C $modRoot @relList
  if ($LASTEXITCODE -ne 0) { throw 'tar 打包模块失败' }
  Send-Blob $tgz '/tmp/raphael-mods.tar.gz'
  $mo = Send-Serial @(
    'tar -xzf /tmp/raphael-mods.tar.gz -C /usr/lib/modules && echo MODS_OK',
    ('cd /usr/lib/modules && md5sum ' + ($relList -join ' ')),
    'command -v depmod >/dev/null && depmod ' + $ver + ' && echo DEPMOD_OK || echo NO_DEPMOD'
  ) 2500
  Write-Host $mo
  if ($mo -notmatch 'MODS_OK') { throw '模块没解开' }
  foreach ($rel in $relList) {
    $want = (Get-FileHash -LiteralPath (Join-Path $staging ($rel -replace '/', '\')) -Algorithm MD5).Hash.ToLower()
    if ($mo -notmatch [regex]::Escape($want)) { throw "设备上的 $rel md5 与本地不一致（$want）" }
  }
  Write-Host '  模块 md5 全部一致'
}

if ($SkipFlash) { Write-Host '== -SkipFlash：Image 与模块已到位，ESP 没动 =='; return }

# --- 2. 备份 + 覆盖 ESP 上的 linux.efi --------------------------------------
Write-Host '== 写 ESP =='
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out = Send-Serial @(
  'mkdir -p /mnt/esp',
  'L=$(losetup -f --show -b 512 /dev/sda29) && echo LOOP=$L',
  'mount -t vfat "$L" /mnt/esp && echo MOUNTED || echo MOUNT_FAIL',
  "ls -l /mnt/esp/linux.efi",
  "cp -f /mnt/esp/linux.efi /mnt/esp/linux.efi.bak-$stamp && echo BACKUP_OK",
  "cp -f $tmp /mnt/esp/linux.efi && echo COPY_OK",
  'md5sum /mnt/esp/linux.efi',
  'sync',
  'umount /mnt/esp && echo UMOUNT_OK',
  'losetup -d "$L" 2>/dev/null; echo LOOP_DETACHED',
  "ls -l /mnt/esp 2>/dev/null | head -3"
) 1800
Write-Host $out

if ($out -notmatch 'COPY_OK') { throw '覆盖失败，ESP 可能还在挂载状态，检查 MOUNT_FAIL/md5sum 输出' }
if ($out -notmatch 'UMOUNT_OK') { Write-Host '  !! 没卸载成功，下次开机可能挂不上，手动 umount /mnt/esp' }
if ($out -notmatch [regex]::Escape($md5)) { Write-Host '  !! 写入后的 md5 没找到，人工核对上面的 md5sum 行' }

if (-not $KeepBackup) {
  Write-Host ''
  # ESP 只有 253 MB，一个 Image 就占 104 MB。上一版的备份 + 这一版 = 208 MB，
  # 剩不下几十 MB；再想留第二个备份就会 "No space left on device"，而 cp 失败
  # 之后**下一句 cp 仍然会把 linux.efi 覆盖掉** —— 所以这里必须区分
  # 「备份成功」和「备份失败但内核已经换了」，不能让脚本一律打印回滚命令。
  if ($out -match 'BACKUP_OK') {
    Write-Host "备份留在 ESP 上：linux.efi.bak-$stamp"
    Write-Host "回滚：cp /mnt/esp/linux.efi.bak-$stamp /mnt/esp/linux.efi（同样要 losetup -b 512）"
  } else {
    Write-Host '!! 备份**没有**成功（多半是 ESP 满了：df -h 显示 100%）'
    Write-Host '   内核已经换掉，但旧的 Image 没留在 ESP 上。'
    Write-Host '   要留回滚点：进设备删掉更早的 /mnt/esp/linux.efi.bak-*，或直接用'
    Write-Host '   work/kernel-raphael/output 里的上一个构建重推一次。'
  }
}
Write-Host ''
Write-Host '下一步：在设备上 reboot。起来之后先看这三样：'
Write-Host '  ls -l /dev/uhid                     # 应该出现'
Write-Host '  dmesg | grep -i uhid                # 应该有一行初始化'
Write-Host '  systemctl status inputplumber       # 应该 active 且不再刷 "Could not read"'
