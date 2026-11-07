param(
  [Parameter(Mandatory = $true)][string]$LocalFile,
  [Parameter(Mandatory = $true)][string]$RemotePath,
  [string]$DeviceIp = '169.254.240.121',
  [int]$Port = 9999,
  [string]$ComPort = 'COM3'
)
# 走 USB NCM（usb0）传文件：手机端 busybox nc 监听，Windows 端主动连接发包。
# 不用管理员权限（Windows 侧是主动外连），不受串口 ~8 KB/s 的限制。

$ErrorActionPreference = 'Stop'

function Send-Serial([string[]]$cmds, [int]$waitMs = 1200) {
  $p = New-Object System.IO.Ports.SerialPort $ComPort,115200,None,8,One
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

$tmp = "/tmp/nc-upload.bin"
$src = (Resolve-Path -LiteralPath $LocalFile).Path
$size = (Get-Item -LiteralPath $src).Length
$md5 = (Get-FileHash -LiteralPath $src -Algorithm MD5).Hash.ToLower()
Write-Host ("local: {0}  {1:N2} MiB  md5={2}" -f $src, ($size / 1MB), $md5)

# 1) 手机端：清旧文件、起监听（后台）
$null = Send-Serial @("rm -f $tmp", "busybox nc -l -p $Port > $tmp &") 900

# 2) 传
$client = New-Object System.Net.Sockets.TcpClient
$client.NoDelay = $true
$client.SendBufferSize = 1MB
$sw = [Diagnostics.Stopwatch]::StartNew()
$client.Connect($DeviceIp, $Port)
$stream = $client.GetStream()
$fs = [IO.File]::OpenRead($src)
$buf = New-Object byte[] 262144
$sent = 0
$nextMark = 4MB
while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
  $stream.Write($buf, 0, $n)
  $sent += $n
  if ($sent -ge $nextMark) {
    $nextMark += 4MB
    Write-Host ("  {0:N1}/{1:N1} MiB  {2:N0} KB/s" -f ($sent/1MB), ($size/1MB), ($sent/1KB/$sw.Elapsed.TotalSeconds))
  }
}
$stream.Flush(); $fs.Dispose()
Start-Sleep -Milliseconds 400
$client.Close()
$sw.Stop()
Write-Host ("sent {0:N2} MiB in {1:N1}s = {2:N0} KB/s" -f ($sent/1MB), $sw.Elapsed.TotalSeconds, ($sent/1KB/$sw.Elapsed.TotalSeconds))

# 3) 手机端：校验后落位
$out = Send-Serial @(
  "ls -l $tmp",
  "md5sum $tmp",
  "mkdir -p `$(dirname $RemotePath) && cp $tmp $RemotePath && echo PLACED",
  "ls -l $RemotePath"
) 2200
Write-Host $out
Write-Host "expected md5: $md5"
if ($out -match 'PLACED' -and $out -match [regex]::Escape($md5)) {
  Write-Host 'VERIFY-OK'
} else {
  Write-Host 'VERIFY-FAILED'
}
