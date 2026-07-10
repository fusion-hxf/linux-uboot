#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"

. "$CONFIG_DIR/build-config.sh"

SYSTEM_TYPE="${SYSTEM_TYPE:-ubuntu-server}"
DESKTOP_ENV="${DESKTOP_ENV:-}"
DEBIAN_VERSION="${DEBIAN_VERSION:-trixie}"
UBUNTU_VERSION="${UBUNTU_VERSION:-resolute}"
KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-xiaomi-raphael-debs_${KERNEL_VERSION:-7.1}}"
REQUIRE_ALSA_DEB="${REQUIRE_ALSA_DEB:-1}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] 📦 安装软件包"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 更新系统包..."
chroot rootdir apt-get update
chroot rootdir apt-get upgrade -y

BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager initramfs-tools chrony curl wget locales tzdata iproute2 zram-tools e2fsprogs util-linux"

if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then 
    BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager initramfs-tools chrony curl wget locales tzdata fonts-wqy-microhei dnsmasq nftables iproute2 zram-tools e2fsprogs util-linux"
elif [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
    if [[ "$SYSTEM_TYPE" == *"server"* ]]; then
        BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager initramfs-tools chrony curl wget locales tzdata dnsmasq nftables iproute2 zram-tools e2fsprogs util-linux"
    else
        BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager initramfs-tools chrony curl wget locales tzdata dnsmasq nftables iproute2 zram-tools e2fsprogs util-linux"
    fi
fi

DEVICE_PACKAGES="rmtfs protection-domain-mapper tqftpserv"
AUDIO_PACKAGES="alsa-utils alsa-ucm-conf alsa-topology-conf pipewire pipewire-pulse wireplumber"

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    case "$DESKTOP_ENV" in
        "gnome")
            if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
                DESKTOP_PACKAGES="ubuntu-desktop"
            elif [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
                DESKTOP_PACKAGES="gnome"
            fi
            ;;
        "phosh-core")
            DESKTOP_PACKAGES="phosh-core"
            ;;
        "phosh-full")
            DESKTOP_PACKAGES="phosh-full"
            ;;
        "phosh-phone")
            DESKTOP_PACKAGES="phosh-phone"
            ;;
        *)
            DESKTOP_PACKAGES=""
            ;;
    esac
else
    DESKTOP_PACKAGES=""
fi

ALL_PACKAGES="$BASE_PACKAGES $DEVICE_PACKAGES $AUDIO_PACKAGES $DESKTOP_PACKAGES"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 基础包: $(echo "$BASE_PACKAGES" | tr ' ' ', ')"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 设备包: $(echo "$DEVICE_PACKAGES" | tr ' ' ', ')"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 音频包: $(echo "$AUDIO_PACKAGES" | tr ' ' ', ')"
if [ -n "$DESKTOP_PACKAGES" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 桌面包: $(echo "$DESKTOP_PACKAGES" | tr ' ' ', ')"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 开始安装（这可能需要几分钟...）"
chroot rootdir apt-get install -y $ALL_PACKAGES

# [P0] systemd-resolved：DNS 解析收口到 resolved（最终配置见 15-cleanup.sh）
# [P1] earlyoom：内存压力下优雅杀进程，避免整机硬卡死（配置见 14-config-zram.sh）
# [设备报告] wireless-regdb：确保 regulatory.db 存在（WiFi 监管域，配合 15 不再删除它）
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 systemd-resolved / earlyoom / wireless-regdb"
chroot rootdir apt-get install -y systemd-resolved earlyoom wireless-regdb

if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 修复 Debian dpkg 错误"
    chroot rootdir dpkg --remove --force-remove-reinstreq shim-signed 2>/dev/null || true
    chroot rootdir dpkg --purge shim-signed 2>/dev/null || true
    chroot rootdir dpkg --configure -a 2>/dev/null || true
    chroot rootdir apt-get -f install -y 2>/dev/null || true
fi

# 修改服务配置
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service 2>/dev/null || true
fi

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [ "$DESKTOP_ENV" = "gnome" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置 GDM 自动登录"
        cat > rootdir/etc/gdm3/custom.conf << 'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=user
EOF
    fi
fi

ALSA_DEB=""
for candidate in \
    "${ALSA_DEB_PATH:-}" \
    "${KERNEL_DEBS_DIR}/alsa-xiaomi-raphael.deb" \
    "alsa-xiaomi-raphael.deb"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        ALSA_DEB="$candidate"
        break
    fi
done

if [ -n "$ALSA_DEB" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 ALSA 配置: $ALSA_DEB"
    cp "$ALSA_DEB" rootdir/tmp/alsa-xiaomi-raphael.deb
    chroot rootdir dpkg -i /tmp/alsa-xiaomi-raphael.deb
    rm rootdir/tmp/alsa-xiaomi-raphael.deb
elif [ "$REQUIRE_ALSA_DEB" = "1" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 错误: 缺少 alsa-xiaomi-raphael.deb"
    exit 1
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 未安装 ALSA 配置 (REQUIRE_ALSA_DEB=0)"
fi

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [[ "$DESKTOP_ENV" == phosh* ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 启用 Phosh 服务"
        chroot rootdir systemctl enable phosh
    fi
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ✅ 软件包安装完成"
