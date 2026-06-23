#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] 🧠 配置内存与存储资源 (zram / sysctl / earlyoom / journald / fstrim)"

# --- zram swap：zstd 压缩，按内存比例自适应（兼容 6G/8G 版本，取代写死的 10GB）---
if [ -f rootdir/etc/default/zramswap ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 调整 zramswap：ALGO=zstd, PERCENT=150（按内存自适应）"
    sed -i \
        -e 's/^#*[[:space:]]*ALGO=.*/ALGO=zstd/' \
        -e 's/^#*[[:space:]]*PERCENT=.*/PERCENT=150/' \
        -e 's/^SIZE=/#SIZE=/' \
        rootdir/etc/default/zramswap
    grep -q '^ALGO=' rootdir/etc/default/zramswap || echo 'ALGO=zstd' >> rootdir/etc/default/zramswap
    grep -q '^PERCENT=' rootdir/etc/default/zramswap || echo 'PERCENT=150' >> rootdir/etc/default/zramswap
    chroot rootdir systemctl enable zramswap
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 未找到 /etc/default/zramswap，跳过 zram 配置"
fi

# --- VM 参数（面向 zram 优化）---
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 写入 zram 友好的 vm sysctl"
mkdir -p rootdir/etc/sysctl.d
cat > rootdir/etc/sysctl.d/99-raphael-vm.conf << 'EOF'
# zram 是内存内压缩 swap，换入换出极快：提高 swappiness、关闭 swap 预读更合适
vm.swappiness=150
vm.page-cluster=0
EOF

# --- earlyoom：内存压力下优雅杀进程，避免整机硬卡死 ---
# 选用 earlyoom 而非 systemd-oomd：earlyoom 仅依赖 /proc，不要求内核 PSI，
# 在该机型 mainline 内核上更稳妥（systemd-oomd 需 PSI + cgroup2 内存统计，能力待设备确认）
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 启用 earlyoom 内存保护"
if [ -f rootdir/etc/default/earlyoom ]; then
    if grep -q '^EARLYOOM_ARGS=' rootdir/etc/default/earlyoom; then
        sed -i 's/^EARLYOOM_ARGS=.*/EARLYOOM_ARGS="-m 5 -s 5 -r 0"/' rootdir/etc/default/earlyoom
    else
        echo 'EARLYOOM_ARGS="-m 5 -s 5 -r 0"' >> rootdir/etc/default/earlyoom
    fi
fi
chroot rootdir systemctl enable earlyoom 2>/dev/null || true

# --- journald：限制日志体积，降低闪存写放大并避免写满 rootfs ---
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 限制 journald 体积"
mkdir -p rootdir/etc/systemd/journald.conf.d
cat > rootdir/etc/systemd/journald.conf.d/00-raphael.conf << 'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=64M
Compress=yes
EOF

# --- 周期性 TRIM（UFS 支持 discard 则生效；不支持则空转，无害）---
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 启用 fstrim.timer"
chroot rootdir systemctl enable fstrim.timer 2>/dev/null || true

echo ""
echo "[/etc/default/zramswap]"
cat rootdir/etc/default/zramswap 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] ✅ 内存与存储资源配置完成"
