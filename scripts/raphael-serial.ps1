param(
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [int]$WaitMs = 2500,
  [string]$PortName = 'COM3'
)
$ErrorActionPreference = 'Continue'
$lines = @(Get-Content -LiteralPath $CommandFile | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' })
$port = New-Object System.IO.Ports.SerialPort $PortName,115200,None,8,One
$port.ReadTimeout = 4000
$port.WriteTimeout = 4000
try { $port.Open() } catch { "OPEN FAILED: $($_.Exception.Message)"; exit 1 }
$port.Write("`n")
Start-Sleep -Milliseconds 500
$null = $port.ReadExisting()
foreach ($line in $lines) {
  "--- $line"
  $port.WriteLine($line)
  Start-Sleep -Milliseconds $WaitMs
  $port.ReadExisting()
}
$port.Close()
