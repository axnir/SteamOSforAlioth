#!/usr/bin/env bash
# 在容器里把 GPT 结构块 + p1(FAT 引导) + p2(ext4 root) 稀疏组装成 userdata 镜像。
# GPT 结构由 PowerShell 7 生成在 $G（4K 逻辑扇区）。
set -euo pipefail
G=/repo/SteamOSforAlioth/work/steamos-raphael/gpt
W=/work
OUT=$W/userdata-nested.img
DEST=/repo/SteamOSforAlioth/work/steamos-raphael

tr -d "\r" < "$G/layout.env" > /tmp/layout.env
. /tmp/layout.env
BS=$((BS))
echo "布局: p1 LBA $P1_START / p2 LBA $P2_START / 总 $TOTAL_SECS 扇区 ($BS B)"

rm -f "$OUT"
truncate -s $((TOTAL_SECS * BS)) "$OUT"

# 保护性 MBR 在偏移 0；主 GPT 头在 LBA1(=4096)，条目在 LBA2(=8192)
dd if="$G/mbr.bin"         of="$OUT" bs=512 seek=0 conv=notrunc status=none
dd if="$G/hdr-primary.bin" of="$OUT" bs="$BS" seek=1 conv=notrunc status=none
dd if="$G/entries.bin"     of="$OUT" bs="$BS" seek=2 conv=notrunc status=none
# 备份 GPT：条目在 BACKUP_LBA-33，头在 BACKUP_LBA
dd if="$G/entries.bin"     of="$OUT" bs="$BS" seek=$((BACKUP_LBA-33)) conv=notrunc status=none
dd if="$G/hdr-backup.bin"  of="$OUT" bs="$BS" seek=$BACKUP_LBA conv=notrunc status=none

# p1 FAT32 引导镜像（内部是完整 FAT 卷，从分区起始 LBA 开始）
dd if="$W/boot-cache.img" of="$OUT" bs="$BS" seek=$P1_START conv=notrunc status=none
echo "p1 写入完成"
# p2 ext4 root
dd if="$W/rootfs-ext4.img" of="$OUT" bs="$BS" seek=$P2_START conv=notrunc status=none
echo "p2 写入完成"

ls -lh "$OUT"
# 校验 GPT
echo "=== GPT 校验 ==="
sgdisk -p "$OUT" 2>/dev/null || true

img2simg "$OUT" "$W/userdata-nested-sparse.img" 4096
ls -lh "$W/userdata-nested-sparse.img"
cp "$W/userdata-nested-sparse.img" "$DEST/userdata-nested-sparse.img"
echo NESTED-DONE
