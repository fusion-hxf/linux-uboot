#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo ./build.sh [system_type] [kernel_version] [desktop_env] [os_version]

Examples:
  bash scripts/00-download-deps.sh 7.1 fusion-hxf/kernel-deb
  sudo BOOTSTRAP_TOOL=mmdebstrap ./build.sh ubuntu-server 7.1
  sudo BOOTSTRAP_TOOL=mmdebstrap ./build.sh ubuntu-phosh 7.1 phosh-core resolute

Environment:
  BOOTSTRAP_TOOL       mmdebstrap or debootstrap, default: mmdebstrap
  DEBIAN_VERSION       Debian suite for debian-* images, default: trixie
  UBUNTU_VERSION       Ubuntu suite for ubuntu-* images, default: resolute
  BOOT_IMG             cache boot image path, default: xiaomi-k20pro-boot.img
  BOOT_IMG_URL         cache boot image download URL (used by 00-download-deps.sh)
  UBOOT_IMG            repacked U-Boot image path, default: u-boot.img
  KERNEL_DEBS_DIR      kernel deb directory, default: xiaomi-raphael-debs_<version>
  REQUIRE_ALSA_DEB     require alsa-xiaomi-raphael.deb, default: 1
  PERSISTENT_HOME      create persistent /home in userdata tail, default: 1
  PERSISTENT_HOME_OFFSET start offset for persistent /home, default: 16G
EOF
}

cleanup_mounts_on_failure() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    log "构建失败，尝试卸载已挂载目录"
    for mount_point in rootdir/sys rootdir/proc rootdir/dev/pts rootdir/dev rootdir/boot rootdir; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount "$mount_point" 2>/dev/null || true
        fi
    done
    return "$rc"
}

export_config_lines() {
    local lines="$1"
    local line

    [ -n "$lines" ] || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        export "$line"
    done <<< "$lines"
}

require_file() {
    [ -f "$1" ] || die "缺少文件: $1"
}

require_kernel_debs() {
    local dir="$1"
    local pkg

    [ -d "$dir" ] || die "缺少内核 deb 目录: $dir"
    for pkg in linux-image linux-headers firmware; do
        require_file "$dir/$pkg-xiaomi-raphael.deb"
    done
}

size_to_bytes() {
    local value="$1"
    local number unit multiplier

    number="${value%[KkMmGgTt]}"
    unit="${value#$number}"
    [ "$number" -eq "$number" ] 2>/dev/null || die "无效大小: $value"

    case "$unit" in
        "" ) multiplier=1 ;;
        [Kk] ) multiplier=1024 ;;
        [Mm] ) multiplier=$((1024 * 1024)) ;;
        [Gg] ) multiplier=$((1024 * 1024 * 1024)) ;;
        [Tt] ) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
        * ) die "无效大小单位: $value" ;;
    esac

    printf '%s\n' $((number * multiplier))
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    usage
    die "rootfs 构建需要 root 权限，请使用 sudo 运行 build.sh"
fi

SYSTEM_TYPE="${1:-ubuntu-server}"
KERNEL_VERSION="${2:-7.1}"
DESKTOP_ENV_ARG="${3:-phosh-full}"
OS_VERSION_ARG="${4:-}"
USE_DOCKER="${USE_DOCKER:-${5:-false}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=config/build-config.sh
. "$SCRIPT_DIR/config/build-config.sh"

case "$SYSTEM_TYPE" in
    debian-*)
        DEBIAN_VERSION="${DEBIAN_VERSION:-${OS_VERSION_ARG:-trixie}}"
        UBUNTU_VERSION="${UBUNTU_VERSION:-}"
        ;;
    ubuntu-*)
        UBUNTU_VERSION="${UBUNTU_VERSION:-${OS_VERSION_ARG:-resolute}}"
        DEBIAN_VERSION="${DEBIAN_VERSION:-}"
        ;;
    *)
        usage
        die "不支持的系统类型: $SYSTEM_TYPE"
        ;;
esac
export SYSTEM_TYPE KERNEL_VERSION USE_DOCKER DEBIAN_VERSION UBUNTU_VERSION

SYSTEM_CONFIG="$(system_config "$SYSTEM_TYPE" "$DESKTOP_ENV_ARG")" || die "无法生成系统配置: $SYSTEM_TYPE"
export_config_lines "$SYSTEM_CONFIG" || die "系统配置为空: $SYSTEM_TYPE"

SOURCES_CONFIG="$(sources_config "$SYSTEM_TYPE")" || die "无法生成镜像源配置: $SYSTEM_TYPE"
export_config_lines "$SOURCES_CONFIG" || die "镜像源配置为空: $SYSTEM_TYPE"

export SCRIPT_DIR
export IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
export IMAGE_UUID="${IMAGE_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"
export HOSTNAME="${HOSTNAME:-xiaomi-raphael}"
export BOOT_IMG="${BOOT_IMG:-xiaomi-k20pro-boot.img}"
export KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-xiaomi-raphael-debs_$KERNEL_VERSION}"
export BOOTSTRAP_TOOL="${BOOTSTRAP_TOOL:-mmdebstrap}"
export REQUIRE_ALSA_DEB="${REQUIRE_ALSA_DEB:-1}"
export PERSISTENT_HOME="${PERSISTENT_HOME:-1}"
export PERSISTENT_HOME_OFFSET="${PERSISTENT_HOME_OFFSET:-16G}"
export PERSISTENT_HOME_OFFSET_BYTES="${PERSISTENT_HOME_OFFSET_BYTES:-$(size_to_bytes "$PERSISTENT_HOME_OFFSET")}"
export PERSISTENT_HOME_MIN_SIZE_BYTES="${PERSISTENT_HOME_MIN_SIZE_BYTES:-$((2 * 1024 * 1024 * 1024))}"
export PERSISTENT_HOME_LABEL="${PERSISTENT_HOME_LABEL:-raphael-home}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND="noninteractive"

trap cleanup_mounts_on_failure EXIT

require_file "$BOOT_IMG"
require_kernel_debs "$KERNEL_DEBS_DIR"
if [ "$REQUIRE_ALSA_DEB" = "1" ]; then
    require_file "$KERNEL_DEBS_DIR/alsa-xiaomi-raphael.deb"
fi

chmod +x "$SCRIPT_DIR/scripts"/*.sh

log "=========================================="
log "系统镜像构建脚本"
log "=========================================="
log "系统类型:      $SYSTEM_TYPE"
log "内核版本:      $KERNEL_VERSION"
if [ -n "$DEBIAN_VERSION" ]; then
    log "Debian 版本:   $DEBIAN_VERSION"
elif [ -n "$UBUNTU_VERSION" ]; then
    log "Ubuntu 版本:   $UBUNTU_VERSION"
fi
log "镜像大小:      $IMAGE_SIZE"
if [ "${IS_DESKTOP:-false}" = "true" ]; then
    log "桌面环境:      $DESKTOP_ENV"
fi
log "bootstrap:     $BOOTSTRAP_TOOL"
log "boot image:    $BOOT_IMG"
log "kernel debs:   $KERNEL_DEBS_DIR"
if [ "$PERSISTENT_HOME" = "1" ]; then
    log "persistent /home: enabled, offset=$PERSISTENT_HOME_OFFSET ($PERSISTENT_HOME_OFFSET_BYTES bytes)"
else
    log "persistent /home: disabled"
fi
log "=========================================="

STEPS=(
    01-create-image.sh
    02-bootstrap.sh
    03-mount-dev.sh
    04-config-network.sh
    05-apt-setup.sh
    06-install-all-packages.sh
    07-config-locale.sh
    08-add-screen-commands.sh
    09-install-kernel.sh
    10-config-ncm.sh
    11-config-fstab.sh
    12-create-users.sh
    13-config-power.sh
    14-config-zram.sh
    15-cleanup.sh
    16-finalize.sh
)

log "开始构建"
for step in "${STEPS[@]}"; do
    log "运行步骤: $step"
    "$SCRIPT_DIR/scripts/$step"
done

log "构建完成"
log "产物文件:"
ls -lh rootfs.img 2>/dev/null || true
ls -lh rootfs.7z 2>/dev/null || true
