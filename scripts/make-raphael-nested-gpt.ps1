# 生成嵌套 GPT 的结构块（4K 逻辑扇区），供容器里 dd 稀疏组装。
# 布局：p1 ESP FAT32 256M（在 userdata 内），p2 ext4 root。
$ErrorActionPreference = 'Stop'
$outDir = 'D:\Developer\Repo\SteamOSforAlioth\work\steamos-raphael\gpt'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$BS = 4096
$P1_START = 2048
$P1_SECS  = 65536
$P2_START = $P1_START + $P1_SECS
$EXT4_BYTES = [long]12884901888   # 12 GiB，与 mkfs.ext4 的 truncate 一致
$P2_SECS    = 3145728             # 12 GiB / 4096
$LAST_USABLE = $P2_START + $P2_SECS - 1
$BACKUP_LBA  = $LAST_USABLE + 34
$TOTAL_SECS  = $BACKUP_LBA + 1

function Get-Crc32([byte[]]$data) {
    [long]$crc = 0xFFFFFFFFL
    foreach ($b in $data) {
        $crc = ($crc -bxor [long]$b) -band 0xFFFFFFFFL
        for ($k=0; $k -lt 8; $k++) {
            if (($crc -band 1L) -ne 0) { $crc = (($crc -shr 1) -bxor 0xEDB88320L) -band 0xFFFFFFFFL }
            else                       { $crc =  ($crc -shr 1) -band 0xFFFFFFFFL }
        }
    }
    return [Convert]::ToUInt32(((-bnot $crc) -band 0xFFFFFFFFL))
}
function Put64([byte[]]$a,[int]$o,[long]$v){ [BitConverter]::GetBytes([long]$v).CopyTo($a,$o) }
function Put32([byte[]]$a,[int]$o,[int]$v){ [BitConverter]::GetBytes([int]$v).CopyTo($a,$o) }

$diskGuid = [Guid]::Parse('e2a1c7d0-3b4f-4c21-9a55-8f0d7a2c11e9').ToByteArray()
$espGuid  = [Guid]::Parse('c12a7328-f81f-11d2-ba4b-00a0c93ec93b').ToByteArray()
$rootGuid = [Guid]::Parse('b921b045-1df0-41c3-af44-4c6f280d3fae').ToByteArray()
$p1Guid   = [Guid]::Parse('1bf4a32b-0000-4000-8000-000000000001').ToByteArray()
$p2Guid   = [Guid]::Parse('ee8d3593-59b1-480e-a3b6-4fefb17ee7d8').ToByteArray()

$ents = New-Object byte[] (128*128)
function Set-Entry([int]$i,[byte[]]$t,[byte[]]$u,[long]$f,[long]$l,[string]$n){
    $o=$i*128; $t.CopyTo($ents,$o); $u.CopyTo($ents,$o+16)
    Put64 $ents ($o+32) $f; Put64 $ents ($o+40) $l
    $nb=[Text.Encoding]::Unicode.GetBytes($n)
    [Array]::Copy($nb,0,$ents,$o+56,[Math]::Min($nb.Length,72))
}
Set-Entry 0 $espGuid  $p1Guid $P1_START ($P1_START+$P1_SECS-1) 'Boot'
Set-Entry 1 $rootGuid $p2Guid $P2_START $LAST_USABLE            'Root'
$entsCrc = Get-Crc32 $ents

function New-Header([long]$my,[long]$entLba,[long]$other){
    $h=New-Object byte[] 92
    [Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($h,0)
    Put32 $h 8 0x00010000; Put32 $h 12 92
    Put64 $h 24 $my; Put64 $h 32 $other; Put64 $h 40 2048; Put64 $h 48 $LAST_USABLE
    $diskGuid.CopyTo($h,56)
    Put64 $h 72 $entLba; Put32 $h 80 128; Put32 $h 84 128
    [BitConverter]::GetBytes([uint32]$entsCrc).CopyTo($h,88)
    [BitConverter]::GetBytes([uint32](Get-Crc32 $h)).CopyTo($h,16)
    $h
}
$h1 = New-Header 1 2 $BACKUP_LBA
$h2 = New-Header $BACKUP_LBA ($BACKUP_LBA-33) 1

$mbr = New-Object byte[] 512
$mbr[0x1C2]=0xEE; $mbr[0x1C3]=0xFF; $mbr[0x1C4]=0xFF; $mbr[0x1C5]=0xFF
[BitConverter]::GetBytes([uint32]1).CopyTo($mbr,0x1C6)
[BitConverter]::GetBytes([uint32]4294967295).CopyTo($mbr,0x1CA)
$mbr[0x1FE]=0x55; $mbr[0x1FF]=0xAA

[IO.File]::WriteAllBytes((Join-Path $outDir 'mbr.bin'), $mbr)
[IO.File]::WriteAllBytes((Join-Path $outDir 'hdr-primary.bin'), $h1)
[IO.File]::WriteAllBytes((Join-Path $outDir 'entries.bin'), $ents)
[IO.File]::WriteAllBytes((Join-Path $outDir 'hdr-backup.bin'), $h2)
$lines = @(
  "BS=$BS",
  "P1_START=$P1_START",
  "P1_SECS=$P1_SECS",
  "P2_START=$P2_START",
  "P2_SECS=$P2_SECS",
  "LAST_USABLE=$LAST_USABLE",
  "BACKUP_LBA=$BACKUP_LBA",
  "TOTAL_SECS=$TOTAL_SECS"
)
[IO.File]::WriteAllLines((Join-Path $outDir 'layout.env'), [string[]]$lines)
if ($P2_SECS -ne 3145728 -or $LAST_USABLE -lt 3000000) { throw "布局变量异常: P2_SECS=$P2_SECS LAST_USABLE=$LAST_USABLE" }
"GPT 结构已生成 -> $outDir"
$lines
