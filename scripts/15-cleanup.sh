#!/bin/bash
set -e

DEBIAN_VERSION="${DEBIAN_VERSION:-}"
UBUNTU_VERSION="${UBUNTU_VERSION:-}"
SYSTEM_TYPE="${SYSTEM_TYPE:-ubuntu-server}"
DEBIAN_TSUNING_MIRROR="${DEBIAN_TSUNING_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian/}"
UBUNTU_TSUNING_MIRROR="${UBUNTU_TSUNING_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15] 🧹 清理临时文件"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15]   └─ 清理 apt-get 缓存"
chroot rootdir apt-get -q clean

# ============================================================
# [P0] 出厂前系统加固：把"每台设备应唯一/应由运行期接管"的状态确定化
#      （详见 optimization-plan.md 第三、五节）
# ============================================================

# --- DNS 解析栈确定化 ---
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15]   └─ 加固 DNS 解析栈"
# 1) 移除 nss-tlsd/libnss-tls（DoH 的 NSS 模块；其内置上游在国内不可达，
#    导致所有走 getaddrinfo 的程序每次解析必现固定超时，见 dns-fix.md）
chroot rootdir apt-get purge -y nss-tlsd libnss-tls 2>/dev/null || true
chroot rootdir systemctl disable nss-tlsd 2>/dev/null || true
# 2) 防御性清理 nsswitch.conf 的 hosts 行，确保不残留 tls 模块
if [ -f rootdir/etc/nsswitch.conf ]; then
    sed -i -E '/^hosts:/ s/[[:space:]]+tls\b//g' rootdir/etc/nsswitch.conf
fi
# 3) DNS 收口到 systemd-resolved；为"无 DHCP DNS（如纯 USB-NCM）"场景设国内可达回退 DNS
chroot rootdir systemctl enable systemd-resolved 2>/dev/null || true
mkdir -p rootdir/etc/systemd/resolved.conf.d
cat > rootdir/etc/systemd/resolved.conf.d/fallback.conf << 'EOF'
[Resolve]
FallbackDNS=223.5.5.5 119.29.29.29
EOF
# 4) /etc/resolv.conf 收口到 resolved stub（替换 04 写入的静态文件；之后本脚本不再联网）
ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

# --- 设备身份唯一化（出厂镜像每台设备应各自生成）---
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15]   └─ 清除设备身份，交由首启重新生成"
# machine-id 清空后 systemd 首启自动重新生成
# （usb-ncm 的 USB 序列号、DHCP DUID、journald 均依赖其唯一性）
: > rootdir/etc/machine-id
mkdir -p rootdir/var/lib/dbus
rm -f rootdir/var/lib/dbus/machine-id
ln -sf /etc/machine-id rootdir/var/lib/dbus/machine-id
# 删除构建期生成的 SSH 主机密钥，避免全网设备共用同一套（首启重新生成）
rm -f rootdir/etc/ssh/ssh_host_*
cat > rootdir/etc/systemd/system/regenerate-ssh-host-keys.service << 'EOF'
# [设备报告] 不能 Before=ssh.socket：普通 service 默认 After=basic.target，而 basic.target
# After=sockets.target（含 ssh.socket），故 Before=ssh.socket 会成环：
#   sockets.target → ssh.socket → 本服务 → basic.target → sockets.target
# systemd 解环时会【非确定性】删掉环中某个 job，本次删掉了 ssh.socket → :22 无人监听
# → ssh 报 Connection refused（见 raphael-report 日志 "Found ordering cycle"）。
# 仅需在 ssh.service（实际处理连接的守护进程）之前生成密钥即可，不要排在监听 socket 之前。
[Unit]
Description=Regenerate SSH host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
chroot rootdir systemctl enable regenerate-ssh-host-keys.service 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15]   └─ 重命名内核文件"
mv rootdir/boot/initrd.img-* rootdir/boot/initramfs 2>/dev/null || true
mv rootdir/boot/vmlinuz-* rootdir/boot/linux.efi 2>/dev/null || true

# [设备报告] 不再删除 /lib/firmware/reg*：删除 regulatory.db 会让 cfg80211 无法加载监管域
# （设备 dmesg: failed to load regulatory.db），限制 WiFi 信道/发射功率。原 `rm -f reg*` 已移除。

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15]   └─ 配置清华源"
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    if [ -n "$DEBIAN_VERSION" ]; then
        cat > rootdir/etc/apt/sources.list << EOF
deb $DEBIAN_TSUNING_MIRROR $DEBIAN_VERSION main contrib non-free non-free-firmware
deb $DEBIAN_TSUNING_MIRROR $DEBIAN_VERSION-updates main contrib non-free non-free-firmware
deb $DEBIAN_TSUNING_MIRROR $DEBIAN_VERSION-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_VERSION-security main contrib non-free non-free-firmware
EOF
    fi
elif [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
    if [ -n "$UBUNTU_VERSION" ]; then
        cat > rootdir/etc/apt/sources.list << EOF
deb $UBUNTU_TSUNING_MIRROR $UBUNTU_VERSION main restricted universe multiverse
deb $UBUNTU_TSUNING_MIRROR $UBUNTU_VERSION-updates main restricted universe multiverse
deb $UBUNTU_TSUNING_MIRROR $UBUNTU_VERSION-backports main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $UBUNTU_VERSION-security main restricted universe multiverse
EOF
    fi
fi

echo ""
echo "========================================== 📋 配置文件预览 =========================================="

echo ""
echo "[/etc/apt/sources.list]"
cat rootdir/etc/apt/sources.list

echo ""
echo "[/etc/netplan/01-network-manager-all.yaml]"
cat rootdir/etc/netplan/01-network-manager-all.yaml 2>/dev/null || echo "(文件不存在)"

echo ""
echo "[/etc/systemd/system/usb-ncm.service]"
cat rootdir/etc/systemd/system/usb-ncm.service 2>/dev/null || echo "(文件不存在)"

echo ""
echo "[/etc/dnsmasq.d/usb-ncm.conf]"
cat rootdir/etc/dnsmasq.d/usb-ncm.conf 2>/dev/null || echo "(文件不存在)"

echo ""
echo "[/etc/fstab]"
cat rootdir/etc/fstab 2>/dev/null || echo "(文件不存在)"

echo ""
echo "[/etc/default/zramswap]"
cat rootdir/etc/default/zramswap 2>/dev/null || echo "(文件不存在)"

echo ""
echo "========================================== 📋 配置文件预览结束 =========================================="

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [15] ✅ 清理完成"
