#!/bin/bash
set -e

KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-.}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] 🧠 安装内核"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 内核包目录: ${KERNEL_DEBS_DIR}"

cp ${KERNEL_DEBS_DIR}/*-xiaomi-raphael.deb rootdir/tmp/

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 linux-image..."
chroot rootdir dpkg -i /tmp/linux-image-xiaomi-raphael.deb

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 linux-headers..."
chroot rootdir dpkg -i /tmp/linux-headers-xiaomi-raphael.deb

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 firmware..."
chroot rootdir dpkg -i /tmp/firmware-xiaomi-raphael.deb

# [P1] 锁定定制内核/固件包，避免被 apt 升级 / unattended-upgrades 误替换
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 锁定内核/固件包 (apt-mark hold)"
for f in linux-image linux-headers firmware; do
    pkg=$(chroot rootdir dpkg-deb -f /tmp/$f-xiaomi-raphael.deb Package 2>/dev/null || true)
    [ -n "$pkg" ] && chroot rootdir apt-mark hold "$pkg" || true
done

rm rootdir/tmp/*-xiaomi-raphael.deb

# [P1] 安装内核/initramfs 同步钩子：设备上更新内核或 initramfs 后，自动把最新版本
# 复制成 U-Boot 读取的固定名 /boot/linux.efi 与 /boot/initramfs（/boot 为 vfat 不支持软链，
# 故用复制；256MB 足够容纳两套）。否则设备端更新会"静默不生效"。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 boot 镜像同步钩子"
mkdir -p rootdir/usr/local/sbin
cat > rootdir/usr/local/sbin/sync-boot-images.sh <<'EOS'
#!/bin/sh
# 把最新的 vmlinuz-<ver> / initrd.img-<ver> 同步为 U-Boot 期望的固定名。
set -e
BOOT=/boot
ver="$1"
if [ -z "$ver" ] && command -v linux-version >/dev/null 2>&1; then
    ver=$(linux-version list | linux-version sort --reverse | head -n1)
fi
[ -n "$ver" ] || ver=$(ls "$BOOT"/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)
[ -n "$ver" ] || exit 0
if [ -f "$BOOT/vmlinuz-$ver" ]; then cp -f "$BOOT/vmlinuz-$ver" "$BOOT/linux.efi"; fi
if [ -f "$BOOT/initrd.img-$ver" ]; then cp -f "$BOOT/initrd.img-$ver" "$BOOT/initramfs"; fi
sync
exit 0
EOS
chmod 0755 rootdir/usr/local/sbin/sync-boot-images.sh
for d in etc/kernel/postinst.d etc/initramfs/post-update.d; do
    mkdir -p "rootdir/$d"
    cat > "rootdir/$d/zz-sync-uboot-images" <<'EOS'
#!/bin/sh
exec /usr/local/sbin/sync-boot-images.sh "$1"
EOS
    chmod 0755 "rootdir/$d/zz-sync-uboot-images"
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 更新 initramfs..."
chroot rootdir update-initramfs -c -k all

# [设备报告] 补齐外部固件 deb 缺失的【通用】固件：设备 dmesg 显示 qcom/a630_sqe.fw 与
# qca/crbtfw21.tlv 缺失 → GPU 故障、蓝牙起不来。来源：官方 linux-firmware。
# 仅在目标缺失时下载，绝不覆盖固件 deb 已提供的厂商签名 blob（adsp/cdsp/modem/zap 等）。
# 离线或下载失败则跳过、不影响构建。可用 LINUX_FIRMWARE_BASE 覆盖镜像源。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 补齐通用固件 (Adreno SQE/GMU/ZAP + QCA 蓝牙)"
LF_BASE="${LINUX_FIRMWARE_BASE:-https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main}"
fetch_fw() {
    local rel="$1" dst="rootdir/lib/firmware/$1" tmp
    if [ -e "$dst" ]; then echo "      = 保留厂商版(已存在): $rel"; return 0; fi
    tmp=$(mktemp)
    if curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "$tmp" "$LF_BASE/$rel" 2>/dev/null \
       && [ -s "$tmp" ] && ! head -c16 "$tmp" | grep -qiE '<!doctype|<html'; then
        mkdir -p "$(dirname "$dst")"
        install -m0644 "$tmp" "$dst"
        echo "      + 已补齐: $rel ($(stat -c%s "$dst") bytes)"
    else
        echo "      ! 跳过(下载失败/不可用): $rel"
    fi
    rm -f "$tmp"
    return 0
}
for fw in qcom/a630_sqe.fw qcom/a630_gmu.bin qcom/sm8150/a640_zap.mbn qca/crbtfw21.tlv qca/crnv21.bin; do
    fetch_fw "$fw"
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] ✅ 内核安装完成"
