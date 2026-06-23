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


# 配置开机 15 秒后自动熄屏的 Systemd 服务
cat > rootdir/etc/systemd/system/blank_screen.service << 'EOF'
[Unit]
Description=Auto-blank screen after 15s
After=multi-user.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c "/usr/bin/sleep 15"
ExecStart=sh -c 'TERM=linux setterm --blank force </dev/tty1'
User=root
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
chroot rootdir systemctl enable blank_screen.service

# 禁用 WiFi 省电模式，解决连接 WiFi 跳 ping 问题
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 禁用 WiFi 省电模式"
mkdir -p rootdir/etc/NetworkManager/conf.d
cat > rootdir/etc/NetworkManager/conf.d/wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 配置 ath10k 无线参数"
mkdir -p rootdir/etc/modprobe.d
cat > rootdir/etc/modprobe.d/ath10k.conf << 'EOF'
options ath10k_core skip_otp=y
EOF

# [P0] 让 NetworkManager 不接管 usb0，避免与 usb-ncm.service + dnsmasq
# （静态 IP + DHCP 服务端）冲突
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 标记 usb0 为 NetworkManager 非托管"
mkdir -p rootdir/etc/NetworkManager/conf.d
cat > rootdir/etc/NetworkManager/conf.d/10-unmanage-usb0.conf << 'EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

# [设备报告确认] /dev/watchdog 存在（QCOM_WDT 已 probe）→ 启用 systemd 硬件看门狗：
# 系统挂死时由硬件自动重启（生产稳定性）。60s 心跳；调试期若不想自动重启可注释本段。
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 启用硬件看门狗 (RuntimeWatchdogSec=60s)"
mkdir -p rootdir/etc/systemd/system.conf.d
cat > rootdir/etc/systemd/system.conf.d/10-watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=10min
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13] ✅ 电源管理配置完成"
