#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13] 🔋 配置电源管理和熄屏"

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 禁用睡眠/挂起目标"
    chroot rootdir systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
fi

# 仅在 Ubuntu 构建时配置 NetworkManager
if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then 
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 配置 NetworkManager"
    cat > rootdir/etc/netplan/01-network-manager-all.yaml << 'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
fi


# 注：自动熄屏服务 blank_screen.service 统一在 08-add-screen-commands.sh 定义并启用
# （此处原有重复定义已删除，避免两处不同步）。

# 禁用 WiFi 省电模式，解决连接 WiFi 跳 ping 问题
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 禁用 WiFi 省电模式"
mkdir -p rootdir/etc/NetworkManager/conf.d
cat > rootdir/etc/NetworkManager/conf.d/wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF

# WCN3990 bring-up favors a stable permanent scan address.  NetworkManager's
# scan randomization can otherwise cause unnecessary address transitions while
# we are collecting association/beacon-loss evidence.
cat > rootdir/etc/NetworkManager/conf.d/20-wifi-bringup.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=no
EOF

# A regular SSH login is not an "active local seat", so the default polkit
# policy can let nmtui scan but reject activation.  The image already places
# the device user in netdev; grant that group NetworkManager management rights.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 允许 netdev 用户管理 NetworkManager"
mkdir -p rootdir/etc/polkit-1/rules.d
cat > rootdir/etc/polkit-1/rules.d/49-raphael-networkmanager.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        subject.isInGroup("netdev")) {
        return polkit.Result.YES;
    }
});
EOF
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 配置 ath10k 无线参数"
mkdir -p rootdir/etc/modprobe.d
cat > rootdir/etc/modprobe.d/ath10k.conf << 'EOF'
options ath10k_core skip_otp=y
EOF

# Venus bring-up can hang the NoC before the kernel has a chance to panic.
# Keep alias-based autoload disabled so the experimental DT can boot to SSH;
# the diagnostic helper explicitly loads venus_core after persistent logging
# has started.  An explicit `modprobe venus_core` is not blocked by blacklist.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 配置 Venus 手动探测与持久日志"
cat > rootdir/etc/modprobe.d/raphael-venus-bringup.conf << 'EOF'
# Temporary safety gate for SM8150/Iris1 bring-up.
blacklist venus_core
EOF

install -Dm0755 tools/raphael-venus-probe.sh \
    rootdir/usr/local/sbin/raphael-venus-probe.sh

# Refresh the initramfs after adding the blacklist.  This prevents udev in the
# initramfs from probing Venus before /home and SSH are available.
chroot rootdir update-initramfs -u -k all

# [P0] 让 NetworkManager 不接管 usb0，避免与 usb-ncm.service + dnsmasq
# （静态 IP + DHCP 服务端）冲突
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 标记 usb0 为 NetworkManager 非托管"
mkdir -p rootdir/etc/NetworkManager/conf.d
cat > rootdir/etc/NetworkManager/conf.d/10-unmanage-usb0.conf << 'EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

# [设备确认] /dev/watchdog0 (qcom_wdt) 存在 → 启用 systemd 硬件看门狗，系统挂死时硬件自动重启。
# 故意用 default 而非显式秒数：default = 打开并喂狗、但超时沿用内核/DT 默认值（sm8150=30s），永不 EINVAL。
# 已在设备上确认 armed（boot journal: "Watchdog running with a hardware timeout of 30s"）。
# 注意：default 模式下 `systemctl show -p RuntimeWatchdogUSec` 显示 infinity —— 那是"不改超时"的哨兵，
# 不是关闭；判定是否 armed 看 journal，别看这个属性（device-probe.sh §9 即按此核对）。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 启用硬件看门狗 (RuntimeWatchdogSec=default)"
mkdir -p rootdir/etc/systemd/system.conf.d
cat > rootdir/etc/systemd/system.conf.d/10-watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdogSec=default
RebootWatchdogSec=default
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13] ✅ 电源管理配置完成"
