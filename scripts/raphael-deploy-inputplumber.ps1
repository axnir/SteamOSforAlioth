# Deploy InputPlumber + the raphael key composite to a running device.
#
# Why this is a separate script from raphael-apply-overlay-live.ps1: that one
# pushes the whole overlay over the serial console, which is fine for the ~20
# small text files it carries, but the InputPlumber binary is 9.5 MB. base64
# over 115200 baud works out to about 1 KB/s, i.e. two and a half hours. Large
# files go over USB NCM (usb0, 169.254.240.121) with netcat instead.
#
# Order matters: libiio.so.0 has to be in place before anything tries to exec
# inputplumber, otherwise the loader fails with "error while loading shared
# libraries" and systemd restarts it into StartLimitBurst.
param(
  [string]$PortName = 'COM3',
  [string]$DeviceIp = '169.254.240.121',
  [int]$NetPort = 9999,
  [switch]$SkipLarge,
  [switch]$SkipService
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$overlay = Join-Path $root 'scripts\raphael-overlay'
$ipBin = Join-Path $root 'external-and-mods\InputPlumber\inputplumber-0.81.0-konkr'
# libiio + its avahi dependencies. Kept out of /usr/lib on purpose: see the
# comment in the unit file. work/inputplumber-libs comes from Debian bookworm
# arm64 (libiio0 0.24-4, libavahi-*-3 0.8), whose glibc 2.33/2.31 requirement
# the device's 2.39 satisfies.
$libDir = Join-Path $root 'work\inputplumber-libs'
$libRemote = '/usr/lib/raphael-inputplumber'

function Send-Serial([string[]]$cmds, [int]$waitMs = 1200) {
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

function Push-Text([string]$local, [string]$remote) {
  $text = [IO.File]::ReadAllText($local) -replace "`r`n", "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
  $cmds = New-Object System.Collections.Generic.List[string]
  $cmds.Add('rm -f /tmp/_p.b64')
  for ($i = 0; $i -lt $b64.Length; $i += 400) {
    $seg = $b64.Substring($i, [Math]::Min(400, $b64.Length - $i))
    $cmds.Add("printf '%s' '$seg' >> /tmp/_p.b64")
  }
  $cmds.Add("mkdir -p `$(dirname '$remote') && base64 -d /tmp/_p.b64 > '$remote' && echo PUSH_OK_`$(wc -c < '$remote')")
  $out = Send-Serial -cmds $cmds.ToArray() -waitMs 260
  $ok = $out -match 'PUSH_OK_(\d+)'
  Write-Host ("  {0} -> {1} : {2}" -f (Split-Path -Leaf $local), $remote, $(if ($ok) { 'ok' } else { 'FAILED' }))
  if (-not $ok) { Write-Host $out }
}

function Push-Large([string]$local, [string]$remote) {
  $src = (Resolve-Path -LiteralPath $local).Path
  $size = (Get-Item -LiteralPath $src).Length
  $md5 = (Get-FileHash -LiteralPath $src -Algorithm MD5).Hash.ToLower()
  $tmp = '/tmp/nc-upload.bin'
  Write-Host ("  {0:N2} MiB -> {1}" -f ($size / 1MB), $remote)

  $null = Send-Serial @("rm -f $tmp", "busybox nc -l -p $NetPort > $tmp &") 900
  $client = New-Object System.Net.Sockets.TcpClient
  $client.NoDelay = $true
  $client.SendBufferSize = 1MB
  $client.Connect($DeviceIp, $NetPort)
  $stream = $client.GetStream()
  $fs = [IO.File]::OpenRead($src)
  $buf = New-Object byte[] 262144
  $sent = 0
  while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $stream.Write($buf, 0, $n); $sent += $n }
  $stream.Flush(); $fs.Dispose()
  Start-Sleep -Milliseconds 400
  $client.Close()

  $out = Send-Serial @(
    "md5sum $tmp",
    "mkdir -p `$(dirname '$remote') && cp $tmp '$remote' && echo PLACED",
    "ls -l '$remote'"
  ) 2000
  $ok = ($out -match 'PLACED') -and ($out -match [regex]::Escape($md5))
  Write-Host ("     md5 {0} : {1}" -f $md5.Substring(0, 12), $(if ($ok) { 'VERIFY-OK' } else { 'VERIFY-FAILED' }))
  if (-not $ok) { Write-Host $out }
}

Write-Host '== 目录 =='
$null = Send-Serial @(
  'mkdir -p /etc/inputplumber/devices.d /etc/inputplumber/capability_maps.d',
  'mkdir -p /usr/share/inputplumber/capability_maps'
) 900

Write-Host '== 配置（串口 base64） =='
Push-Text (Join-Path $overlay 'etc\inputplumber\devices.d\02-xiaomi-raphael.yaml') '/etc/inputplumber/devices.d/02-xiaomi-raphael.yaml'
Push-Text (Join-Path $overlay 'etc\inputplumber\capability_maps.d\raphael_keys.yaml') '/etc/inputplumber/capability_maps.d/raphael_keys.yaml'
Push-Text (Join-Path $overlay 'etc\inputplumber\capability_maps.d\raphael_keys.yaml') '/usr/share/inputplumber/capability_maps/raphael_keys.yaml'
Push-Text (Join-Path $overlay 'usr\lib\systemd\system\inputplumber.service') '/usr/lib/systemd/system/inputplumber.service'

if (-not $SkipLarge) {
  Write-Host '== 二进制与库（USB NCM） =='
  if (-not (Test-Path -LiteralPath $libDir)) {
    throw "缺 $libDir —— 先准备 libiio.so.0 + libavahi-client.so.3 + libavahi-common.so.3（Debian bookworm arm64）"
  }
  if (-not (Test-Path -LiteralPath $ipBin)) { throw "缺 $ipBin" }
  $null = Send-Serial @("mkdir -p $libRemote") 700
  foreach ($f in Get-ChildItem -LiteralPath $libDir -File) {
    Push-Large $f.FullName "$libRemote/$($f.Name)"
  }
  Push-Large $ipBin '/usr/bin/inputplumber'
  $null = Send-Serial @('chmod 755 /usr/bin/inputplumber', "chmod 644 $libRemote/*.so*") 700
}

Write-Host '== 依赖自检 =='
$chk = Send-Serial @("LD_LIBRARY_PATH=$libRemote ldd /usr/bin/inputplumber 2>&1 | grep -i 'not found' || echo LDD_CLEAN") 2200
Write-Host $chk
if ($chk -notmatch 'LDD_CLEAN') { Write-Host '  !! 有库没找到，服务会起不来' }

if (-not $SkipService) {
  Write-Host '== 启动 =='
  $out = Send-Serial @(
    'systemctl daemon-reload',
    'systemctl enable --now inputplumber 2>&1 | tail -n 2',
    'sleep 3',
    'systemctl is-active inputplumber',
    'journalctl -u inputplumber -n 12 --no-pager 2>&1 | tail -n 12'
  ) 2500
  Write-Host $out
}

Write-Host '== 手工验收 =='
Write-Host '  ls /dev/input/ | grep -i "deck\|inputplumber"'
Write-Host '  按一下音量加 -> 应该弹出 Steam 菜单；音量减 -> 快捷菜单'
