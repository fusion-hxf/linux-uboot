#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10] 📱 配置 USB NCM 网络"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10]   └─ 创建 dnsmasq 配置"

# 配置 NCM
cat > rootdir/etc/dnsmasq.d/usb-ncm.conf << 'EOF'
interface=usb0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=172.16.42.2,172.16.42.254,255.255.255.0,1h
dhcp-option=3,172.16.42.1
EOF
chroot rootdir systemctl enable dnsmasq
cat > rootdir/usr/local/sbin/setup-usb-ncm.sh << 'EOF'
#!/bin/sh
set -e
modprobe libcomposite
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/g1
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo xiaomi-raphael > $G/strings/0x409/manufacturer
echo NCM > $G/strings/0x409/product
echo $(cat /etc/machine-id) > $G/strings/0x409/serialnumber
mkdir -p $G/configs/c.1
mkdir -p $G/configs/c.1/strings/0x409
echo NCM > $G/configs/c.1/strings/0x409/configuration
mkdir -p $G/functions/ncm.usb0
ln -sf $G/functions/ncm.usb0 $G/configs/c.1/
# 等待 UDC 就绪（开机早期 USB 控制器可能尚未枚举，避免竞态失败）
UDC=""
for _ in $(seq 1 50); do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 0.2
done
[ -n "$UDC" ] || { echo "no UDC available" >&2; exit 1; }
echo "$UDC" > $G/UDC
# 等待 usb0 接口出现再配置
for _ in $(seq 1 50); do ip link show usb0 >/dev/null 2>&1 && break; sleep 0.2; done
ip link set usb0 up
ip addr add 172.16.42.1/24 dev usb0 || true
systemctl restart dnsmasq || true
EOF
chmod +x rootdir/usr/local/sbin/setup-usb-ncm.sh
cat > rootdir/etc/systemd/system/usb-ncm.service << 'EOF'
[Unit]
Description=USB CDC-NCM gadget setup
After=network.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-usb-ncm.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10]   └─ 启用 usb-ncm 服务"
chroot rootdir systemctl enable usb-ncm

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10] ✅ USB NCM 配置完成"
