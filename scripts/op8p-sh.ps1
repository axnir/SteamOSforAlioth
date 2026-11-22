# Run one shell command on the OnePlus 8 Pro over its USB-serial gadget.
#
# Why this exists: every check on this phone used to be an inline
# [System.IO.Ports.SerialPort] snippet pasted into a PowerShell session, which
# is both slow to write and easy to get wrong (the drain/read window matters).
#
#   COM3  kernel console (ttyGS0). Interleaved with dmesg; there is a root
#         shell on it too, but the noise makes parsing unreliable.
#   COM4  the dedicated root shell (ttyGS1, `steamos.usbshell=1`). This is the
#         one to use -- quiet, and every command starts at a fresh prompt.
#
# ASCII only on purpose: this repo is checked out on Windows and the default
# powershell.exe (5.1) reads a UTF-8 file without BOM as ANSI, which turns any
# non-ASCII byte in a comment into mojibake -- and worse, into a parse error if
# it lands inside a string.
#
# Usage:
#   pwsh scripts/op8p-sh.ps1 'uname -r'
#   pwsh scripts/op8p-sh.ps1 -Port COM3 -TimeoutMs 4000 'dmesg | tail -5'
#   pwsh scripts/op8p-sh.ps1 -Raw 'cat /proc/cmdline'
#
# Exit code is 0 when the marker came back, 1 on timeout -- callers can tell
# "the phone said nothing" apart from "the phone said an empty string".
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command,

    [string]$Port = 'COM4',
    [int]$Baud = 115200,
    [int]$TimeoutMs = 2500,

    # Do not append the completion marker. Use for commands whose output you
    # want verbatim (markers inside a quoted heredoc are confusing to strip).
    [switch]$Raw
)

$ErrorActionPreference = 'Stop'

$marker = 'OP8P_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '_DONE'
$payload = if ($Raw) { $Command } else { "$Command; echo $marker" }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 500
$sp.NewLine = "`n"

try {
    $sp.Open()
    $sp.DtrEnable = $true

    # Drain whatever the console printed before we got here (login banner,
    # dmesg from a resume, the tail of the previous command). Without this the
    # first read returns the backlog and the answer looks truncated.
    $sp.Write("`n")
    Start-Sleep -Milliseconds 250
    $null = $sp.ReadExisting()

    $sp.Write($payload + "`n")

    $acc = ''
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 120
        try { $acc += $sp.ReadExisting() } catch { }
        if (-not $Raw -and $acc.Contains($marker)) { break }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

# Normalise: CRLF -> LF, drop the echoed command line and the marker.
$text = $acc -replace "`r`n", "`n" -replace "`r", ''
$lines = $text -split "`n"

# The console echoes what we typed; drop everything up to and including it so
# the caller sees only the output.
$echoIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq $payload.Trim()) { $echoIdx = $i; break }
}
if ($echoIdx -ge 0) { $lines = $lines[($echoIdx + 1)..($lines.Count - 1)] }

$lines = $lines | Where-Object { $_ -ne $marker -and $_.Trim() -ne $marker }

$result = ($lines -join "`n").Trim()
$result
if ($Raw) { exit 0 }
if (-not $text.Contains($marker)) { exit 1 }
exit 0
