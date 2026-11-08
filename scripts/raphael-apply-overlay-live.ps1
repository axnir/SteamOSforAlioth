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
  $chmod += 'chmod 755 /opt/raphael/*.sh /usr/lib/steamos-arm/raphael-firstboot 2>/dev/null'
  $chmod += 'ls -l /opt/raphael/*.sh'
  $chmod += 'echo CHMOD_DONE'
  Run-Commands -Commands $chmod -WaitMs 800
}

# 清掉 /etc 下会盖住 /usr/lib 版本的手工副本
$stale = @(
  '/etc/systemd/system/tqftpserv.service',
  '/etc/systemd/system/rmtfs.service',
  '/etc/systemd/system/raphael-qrtr-ns.service',
  '/etc/systemd/system/raphael-rmtfs.service',
  '/etc/systemd/system/raphael-tqftpserv.service'
)
$rm = @('echo CLEAN')
foreach ($s in $stale) { $rm += "rm -f '$s'" }
$rm += 'ls /etc/systemd/system/ | grep -E "^(raphael|tqftp|rmtfs)" || echo NO_LEFT'
$rm += 'systemctl daemon-reload'
$rm += 'systemctl enable raphael-qrtr-ns raphael-rmtfs raphael-tqftpserv raphael-usb-gadget 2>&1 | tail -n 6'
$rm += 'systemctl restart raphael-qrtr-ns raphael-rmtfs raphael-tqftpserv'
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
