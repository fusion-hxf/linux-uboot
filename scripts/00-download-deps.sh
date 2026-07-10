#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

download_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"

    mkdir -p "$(dirname "$dest")"
    log "下载: $url"
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 -o "$tmp" "$url"
    [ -s "$tmp" ] || die "下载结果为空: $url"
    mv -f "$tmp" "$dest"
}

download_kernel_deb() {
    local package="$1"
    local dest="$KERNEL_DEBS_DIR/${package}-xiaomi-raphael.deb"
    local url="https://github.com/$KERNEL_REPO/releases/download/$KERNEL_RELEASE_TAG/${package}-xiaomi-raphael.deb"

    download_file "$url" "$dest"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$dest" Package Version Architecture >/dev/null
    fi
}

KERNEL_VERSION="${1:-${KERNEL_VERSION:-7.1}}"
KERNEL_REPO="${2:-${KERNEL_REPO:-fusion-hxf/kernel-deb}}"
KERNEL_REPO="${KERNEL_REPO#https://github.com/}"
KERNEL_REPO="${KERNEL_REPO#git@github.com:}"
KERNEL_REPO="${KERNEL_REPO%.git}"
KERNEL_REPO="${KERNEL_REPO%/}"
KERNEL_RELEASE_TAG="${KERNEL_RELEASE_TAG:-kernel-v$KERNEL_VERSION}"
OUT_DIR="${OUT_DIR:-$(pwd)}"
KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-$OUT_DIR/xiaomi-raphael-debs_$KERNEL_VERSION}"
BOOT_IMG="${BOOT_IMG:-$OUT_DIR/xiaomi-k20pro-boot.img}"
BOOT_IMG_URL="${BOOT_IMG_URL:-https://github.com/fusion-hxf/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img}"
INCLUDE_ALSA="${INCLUDE_ALSA:-1}"

log "准备下载 rootfs 构建依赖"
log "内核版本:      $KERNEL_VERSION"
log "内核包仓库:    $KERNEL_REPO"
log "Release tag:   $KERNEL_RELEASE_TAG"
log "内核包目录:    $KERNEL_DEBS_DIR"
log "boot image:    $BOOT_IMG"

download_kernel_deb linux-image
download_kernel_deb linux-headers
download_kernel_deb firmware

if [ "$INCLUDE_ALSA" != "0" ]; then
    download_kernel_deb alsa
fi

download_file "$BOOT_IMG_URL" "$BOOT_IMG"

log "下载完成"
ls -lh "$KERNEL_DEBS_DIR"
ls -lh "$BOOT_IMG"
