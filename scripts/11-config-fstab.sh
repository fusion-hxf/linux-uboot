#!/bin/bash
set -e

IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
PERSISTENT_HOME="${PERSISTENT_HOME:-1}"
PERSISTENT_HOME_OFFSET_BYTES="${PERSISTENT_HOME_OFFSET_BYTES:-17179869184}"
PERSISTENT_HOME_MIN_SIZE_BYTES="${PERSISTENT_HOME_MIN_SIZE_BYTES:-2147483648}"
PERSISTENT_HOME_LABEL="${PERSISTENT_HOME_LABEL:-raphael-home}"
USER_NAME="${USER_NAME:-user}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] 🗂️ 配置 fstab"

ROOT_OPTS="noatime,errors=remount-ro"
if [ "$PERSISTENT_HOME" != "1" ]; then
    ROOT_OPTS="${ROOT_OPTS},x-systemd.growfs"
fi

# noatime 削减闪存写放大；/boot 用 pass=2（根为 1）。
cat > rootdir/etc/fstab << EOF
PARTLABEL=userdata / ext4 ${ROOT_OPTS} 0 1
PARTLABEL=cache /boot vfat noatime,umask=0077 0 2
EOF

if [ "$PERSISTENT_HOME" = "1" ]; then
    ROOTFS_IMAGE_BYTES="$(stat -c%s "$IMAGE_NAME")"
    if [ "$ROOTFS_IMAGE_BYTES" -ge "$PERSISTENT_HOME_OFFSET_BYTES" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] ❌ 错误: rootfs 镜像大小 (${ROOTFS_IMAGE_BYTES}) 已达到/超过 /home offset (${PERSISTENT_HOME_OFFSET_BYTES})"
        exit 1
    fi

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11]   └─ 启用 userdata 尾部持久 /home"
    mkdir -p rootdir/etc rootdir/usr/local/sbin rootdir/etc/systemd/system
    cat > rootdir/etc/raphael-persistent-home.conf << EOF
PERSISTENT_HOME=1
PERSISTENT_HOME_OFFSET_BYTES=${PERSISTENT_HOME_OFFSET_BYTES}
PERSISTENT_HOME_MIN_SIZE_BYTES=${PERSISTENT_HOME_MIN_SIZE_BYTES}
PERSISTENT_HOME_LABEL=${PERSISTENT_HOME_LABEL}
USER_NAME=${USER_NAME}
EOF

    cat > rootdir/usr/local/sbin/raphael-persistent-home.sh << 'EOF'
#!/bin/sh
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/etc/raphael-persistent-home.conf

log() {
    echo "[raphael-home] $*"
}

[ -f "$CONF" ] || exit 0
. "$CONF"

[ "${PERSISTENT_HOME:-0}" = "1" ] || exit 0

if findmnt -rn /home >/dev/null 2>&1; then
    log "/home already mounted"
    exit 0
fi

root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
root_dev="$(readlink -f "$root_source" 2>/dev/null || true)"
if [ ! -b "$root_dev" ]; then
    root_dev="$(readlink -f /dev/disk/by-partlabel/userdata 2>/dev/null || true)"
fi
[ -b "$root_dev" ] || {
    log "cannot resolve userdata block device"
    exit 0
}

part_size="$(blockdev --getsize64 "$root_dev" 2>/dev/null || echo 0)"
home_offset="${PERSISTENT_HOME_OFFSET_BYTES:-17179869184}"
min_size="${PERSISTENT_HOME_MIN_SIZE_BYTES:-2147483648}"
if [ "$part_size" -le $((home_offset + min_size)) ]; then
    log "userdata too small for persistent /home: size=$part_size offset=$home_offset min=$min_size"
    exit 0
fi

loop_dev="$(losetup --list --noheadings --output NAME,BACK-FILE,OFFSET 2>/dev/null \
    | awk -v back="$root_dev" -v off="$home_offset" '$2 == back && $3 == off { print $1; exit }')"
if [ -z "$loop_dev" ]; then
    loop_dev="$(losetup --find --show --offset "$home_offset" "$root_dev")"
fi

fs_type="$(blkid -o value -s TYPE "$loop_dev" 2>/dev/null || true)"
if [ "$fs_type" != "ext4" ]; then
    log "format persistent /home at offset $home_offset on $root_dev"
    mkfs.ext4 -F -L "${PERSISTENT_HOME_LABEL:-raphael-home}" "$loop_dev"
fi

mkdir -p /mnt/raphael-home /home
mount -t ext4 -o noatime "$loop_dev" /mnt/raphael-home

if [ ! -e /mnt/raphael-home/.raphael-home-initialized ]; then
    existing="$(find /mnt/raphael-home -mindepth 1 -maxdepth 1 ! -name lost+found | head -n 1 || true)"
    if [ -z "$existing" ] && [ -d /home ]; then
        log "copy initial /home content"
        cp -a /home/. /mnt/raphael-home/ 2>/dev/null || true
    fi
    touch /mnt/raphael-home/.raphael-home-initialized
fi

umount /mnt/raphael-home
mount -t ext4 -o noatime "$loop_dev" /home

if [ -n "${USER_NAME:-}" ] && getent passwd "$USER_NAME" >/dev/null 2>&1 && [ ! -d "/home/$USER_NAME" ]; then
    mkdir -p "/home/$USER_NAME"
    chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
    chmod 0750 "/home/$USER_NAME"
fi

log "mounted persistent /home from $loop_dev"
exit 0
EOF
    chmod 0755 rootdir/usr/local/sbin/raphael-persistent-home.sh

    cat > rootdir/etc/systemd/system/raphael-persistent-home.service << 'EOF'
[Unit]
Description=Mount persistent /home from userdata tail
DefaultDependencies=no
After=systemd-udevd.service systemd-remount-fs.service
Before=local-fs.target
ConditionPathExists=/etc/raphael-persistent-home.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-persistent-home.sh

[Install]
WantedBy=local-fs.target
EOF

    chroot rootdir systemctl enable raphael-persistent-home.service
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] ✅ fstab 配置完成"
