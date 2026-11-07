# 生成嵌套 GPT 的结构块（4K 逻辑扇区），供容器里 dd 稀疏组装。
# 布局：p1 ESP FAT32 256M（在 userdata 内），p2 ext4 root。
$ErrorActionPreference = 'Stop'
$outDir = 'D:\Developer\Repo\SteamOSforAlioth\work\steamos-raphael\gpt'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$BS = 4096
$P1_START = 2048
$P1_SECS  = 65536
$P2_START = $P1_START + $P1_SECS
# p2 占满整个 userdata：设备上是 122,857,467 个 4K 扇区，取 122,000,000 留余量，
# 尾部还要放 34 个扇区的 backup GPT。
#
# 镜像里 mkfs.ext4 只有 12 GiB（内容约 9.3 GiB），首次开机由
# raphael-firstboot 的 resize2fs 扩到 RAPHAEL_ROOT_SECS —— 就是这里的
# $P2_SECS。两处必须一致，scripts/assert-raphael-firstboot.sh 会断言。
# 这样做的理由与 alioth 相同：镜像按内容大小做（刷得快、sparse 小），
# 分区按整盘做（Steam 装游戏不会立刻撞墙）。
$P2_SECS    = 122000000
$EXT4_BYTES = [long]($P2_SECS * $BS)
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
# 自检：p2 必须覆盖绝大部分 userdata，但绝不能越过它 —— userdata 实测
# 122,857,467 个 4K 扇区（491,429,868 KiB），越过就刷不进去。
if ($P2_SECS -lt 100000000 -or $LAST_USABLE -ge 122857467) {
  throw "布局变量异常: P2_SECS=$P2_SECS LAST_USABLE=$LAST_USABLE"
}
"GPT 结构已生成 -> $outDir"
$lines
