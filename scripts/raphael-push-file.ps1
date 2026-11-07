# 通过 COM3 的 root shell，把一个二进制文件分块 base64 推到 SteamOS 根里。
# 串口 canonical mode 单行上限 4096 字节，所以必须分块；关回显避免 43KB 回显
# 把读缓冲冲爆。全部 ASCII，PowerShell 5.1 / 7 都能跑。
param(
  [string]$LocalFile = 'D:\Developer\Repo\SteamOSforAlioth\work\raphael-fw\vendor-firmware\a630_sqe.fw',
  [string]$RemotePath = '/usr/lib/firmware/qcom/a630_sqe.fw'
)
$ErrorActionPreference = 'Stop'
$bytes = [IO.File]::ReadAllBytes($LocalFile)
$b64 = [Convert]::ToBase64String($bytes)
$md5 = (Get-FileHash -LiteralPath $LocalFile -Algorithm MD5).Hash.ToLower()
"local: $($bytes.Length) bytes, md5=$md5"

$port = New-Object System.IO.Ports.SerialPort COM3,115200,None,8,One
$port.ReadTimeout = 4000
$port.WriteTimeout = 4000
$port.Open()
$port.Write("`n")
Start-Sleep -Milliseconds 500
$null = $port.ReadExisting()

function Send-Cmd([string]$text, [int]$waitMs = 300, [switch]$Show) {
  $port.WriteLine($text)
  Start-Sleep -Milliseconds $waitMs
  $out = $port.ReadExisting()
  if ($Show) { $out }
}

$null = Send-Cmd 'stty -echo; : > /tmp/fw.b64; echo B64-READY' 400 -Show

$chunk = 480
$total = [Math]::Ceiling($b64.Length / $chunk)
for ($i = 0; $i -lt $b64.Length; $i += $chunk) {
  $part = $b64.Substring($i, [Math]::Min($chunk, $b64.Length - $i))
  $null = Send-Cmd "echo '$part' >> /tmp/fw.b64" 12
}
"sent $total chunks"

"=== decode + verify ==="
Send-Cmd "base64 -d /tmp/fw.b64 > $RemotePath; stty echo; echo ===RESULT===; wc -c $RemotePath; md5sum $RemotePath; rm -f /tmp/fw.b64" 3000 -Show
$port.Close()
