#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] 🗂️ 配置 fstab"

# noatime 削减闪存写放大；/boot 用 pass=2（根为 1）
echo "PARTLABEL=userdata / ext4 noatime,errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat noatime,umask=0077 0 2" > rootdir/etc/fstab

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] ✅ fstab 配置完成"
