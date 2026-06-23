#!/bin/bash
set -e

KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-.}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] 🧠 安装内核与固件"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 内核包目录: ${KERNEL_DEBS_DIR}"

# 1. 优先补齐外部固件 deb 缺失的【通用】固件（Adreno SQE/GMU/ZAP + QCA 蓝牙）
#    使其在安装内核和生成 initramfs 前就已经存在于 /lib/firmware 目录中。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 下载/补齐通用固件 (Adreno SQE/GMU/ZAP + QCA 蓝牙)"
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
for fw in qcom/a630_sqe.fw qcom/a630_gmu.bin qcom/a640_gmu.bin qcom/sm8150/a640_zap.mbn qca/crbtfw21.tlv qca/crnv21.bin; do
    fetch_fw "$fw"
done

# [GPU zap 路径修正] raphael 的 DTB 把 zap 的 firmware-name 指向【设备专属路径】而非通用路径：
#   设备 dmesg: Unable to load qcom/sm8150/Xiaomi/raphael/a640_zap.mbn → gpu hw init failed -2。
# mainline DT 用 qcom/sm8150/xiaomi/raphael/a640_zap.mbn，该下游内核 DTB 用 Xiaomi/（大写）。
# 通用 a640_zap 已由高通签名、sm8150 量产机普遍可用——把它铺到 DTB 要求的精确路径即可。
# 两种大小写都铺，避免 DTB 差异（社区做法：把通用 zap 桥接到设备路径，见 pmOS firmware-*-adreno）。
ZAP_GENERIC=rootdir/lib/firmware/qcom/sm8150/a640_zap.mbn
if [ -e "$ZAP_GENERIC" ]; then
    for dev in xiaomi Xiaomi; do
        mkdir -p "rootdir/lib/firmware/qcom/sm8150/$dev/raphael"
        install -m0644 "$ZAP_GENERIC" "rootdir/lib/firmware/qcom/sm8150/$dev/raphael/a640_zap.mbn"
    done
    echo "      + zap 已铺到设备专属路径: qcom/sm8150/{xiaomi,Xiaomi}/raphael/a640_zap.mbn"
else
    echo "      ! 无通用 a640_zap.mbn，无法桥接到设备路径（GPU zap 将仍缺失）"
fi

# 2. 安装 initramfs-tools 挂钩，强制将 GPU 固件打包进 initramfs（解决启动早期加载 msm_dpu 报 error -2 故障）
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 配置 initramfs GPU 固件打包挂钩"
mkdir -p rootdir/etc/initramfs-tools/hooks
cat > rootdir/etc/initramfs-tools/hooks/zz-copy-gpu-firmware <<'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

# 强制将 Adreno GPU 微码与 zap 固件包含到内存盘中
for fw in qcom/a630_sqe.fw qcom/a630_gmu.bin qcom/a640_gmu.bin qcom/sm8150/a640_zap.mbn \
          qcom/sm8150/xiaomi/raphael/a640_zap.mbn qcom/sm8150/Xiaomi/raphael/a640_zap.mbn; do
    if [ -e "/lib/firmware/$fw" ]; then
        copy_file firmware "/lib/firmware/$fw" "/lib/firmware/$fw"
    fi
done

exit 0
EOF
chmod 0755 rootdir/etc/initramfs-tools/hooks/zz-copy-gpu-firmware

# 3. 安装 boot 镜像同步挂钩：设备上更新内核或 initramfs 后，自动把最新版本
#    复制成 U-Boot 读取的固定名 /boot/linux.efi 与 /boot/initramfs。
#    （提前安装好，这样 dpkg 安装时就能直接触发同步）
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 boot 镜像同步挂钩"
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

# 4. 安装内核与固件包
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

# 5. 重新生成并更新 initramfs，使 GPU 固件和同步钩子生效
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 更新并生成最终 initramfs..."
chroot rootdir update-initramfs -c -k all

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] ✅ 内核与固件安装完成"
