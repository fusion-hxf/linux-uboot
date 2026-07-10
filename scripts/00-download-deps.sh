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

download_uboot_image() {
    local archive="$1"
    local dest="$2"
    local extracted

    command -v unzip >/dev/null 2>&1 || die "缺少 unzip，无法解压 U-Boot 镜像"
    download_file "$UBOOT_IMG_URL" "$archive"
    unzip -tq "$archive" >/dev/null || die "U-Boot 压缩包校验失败: $archive"

    extracted="$(unzip -Z1 "$archive" | awk '/(^|\/)u-boot\.img$/ { print; exit }')"
    [ -n "$extracted" ] || die "U-Boot 压缩包中未找到 u-boot.img"

    unzip -p "$archive" "$extracted" > "$dest"
    [ -s "$dest" ] || die "解压出的 U-Boot 镜像为空: $dest"
}

repack_uboot_with_kernel_dtb() {
    local kernel_deb="$1"
    local dest="$2"
    local workdir base_img dtb tmp_dest

    command -v dpkg-deb >/dev/null 2>&1 || die "缺少 dpkg-deb，无法从内核包提取 DTB"
    command -v python3 >/dev/null 2>&1 || die "缺少 python3，无法重新打包 U-Boot"
    mkdir -p "$(dirname "$dest")"

    workdir="$(mktemp -d)" || die "无法创建 U-Boot 重打包临时目录"
    trap 'rm -rf "$workdir"' EXIT

    log "从内核包提取 sm8150-xiaomi-raphael.dtb"
    dpkg-deb -x "$kernel_deb" "$workdir/kernel"
    dtb="$(find "$workdir/kernel" -type f -name 'sm8150-xiaomi-raphael.dtb' -print -quit)"
    [ -n "$dtb" ] || die "内核包中未找到 sm8150-xiaomi-raphael.dtb: $kernel_deb"

    base_img="$workdir/u-boot-base.img"
    download_uboot_image "$workdir/u-boot.img.zip" "$base_img"

    tmp_dest="${dest}.tmp"
    rm -f "$tmp_dest"
    log "使用内核 DTB 重新打包 U-Boot"
    python3 "$SCRIPT_DIR/repack-uboot.py" "$base_img" "$dtb" "$tmp_dest"
    [ -s "$tmp_dest" ] || die "重新打包的 U-Boot 镜像为空: $tmp_dest"
    mv -f "$tmp_dest" "$dest"

    rm -rf "$workdir"
    trap - EXIT
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
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-$OUT_DIR/xiaomi-raphael-debs_$KERNEL_VERSION}"
BOOT_IMG="${BOOT_IMG:-$OUT_DIR/xiaomi-k20pro-boot.img}"
BOOT_IMG_URL="${BOOT_IMG_URL:-https://github.com/fusion-hxf/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img}"
UBOOT_IMG="${UBOOT_IMG:-$OUT_DIR/u-boot.img}"
UBOOT_IMG_URL="${UBOOT_IMG_URL:-https://github.com/GengWei1997/linux-xiaomi-raphael-uboot/releases/download/v1.0.0/u-boot-sm8150-xiaomi-raphael.img.zip}"
INCLUDE_ALSA="${INCLUDE_ALSA:-1}"

log "准备下载 rootfs 构建依赖"
log "内核版本:      $KERNEL_VERSION"
log "内核包仓库:    $KERNEL_REPO"
log "Release tag:   $KERNEL_RELEASE_TAG"
log "内核包目录:    $KERNEL_DEBS_DIR"
log "cache boot image: $BOOT_IMG"
log "U-Boot image:  $UBOOT_IMG"

download_kernel_deb linux-image
download_kernel_deb linux-headers
download_kernel_deb firmware

if [ "$INCLUDE_ALSA" != "0" ]; then
    download_kernel_deb alsa
fi

download_file "$BOOT_IMG_URL" "$BOOT_IMG"
repack_uboot_with_kernel_dtb "$KERNEL_DEBS_DIR/linux-image-xiaomi-raphael.deb" "$UBOOT_IMG"

log "下载完成"
ls -lh "$KERNEL_DEBS_DIR"
ls -lh "$BOOT_IMG"
ls -lh "$UBOOT_IMG"
